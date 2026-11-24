//
// Vespertine: the phone's own index of a share: every song file it can play, with its tags, found by walking the
// share's folders. Kept on the phone between launches; a later scan reads only the files that are new or changed.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct ShareSong: Codable, Equatable, Sendable, Identifiable {
    /// The same for the same path on every scan, so queues, favorites and kept songs survive a rescan.
    public var id: Int64
    /// From the share's music folder, `/` between names.
    public var path: String
    public var size: Int64
    public var modified: Date
    public var tags: SongTags

    public init(id: Int64, path: String, size: Int64, modified: Date, tags: SongTags) {
        self.id = id
        self.path = path
        self.size = size
        self.modified = modified
        self.tags = tags
    }

    /// The folder the file is in.
    public var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Why a music file on a share can't be opened without the Mac.
public enum MacNeed: String, Codable, CaseIterable, Sendable {
    /// DSD with more than two channels.
    case surroundDSD
    /// DSD packed with DST (a DSDIFF from an SACD).
    case dst
    case dts
    /// Dolby TrueHD, and the MLP it is built on.
    case trueHD
    /// Dolby Digital and Dolby Digital Plus (AC-3, E-AC-3).
    case dolbyDigital
    case tta
    case tak
    case wma
    /// Audio in a Matroska file (.mka).
    case matroska
    /// A disc image (.iso), an SACD's mostly.
    case discImage
    /// More than two channels in a kind the phone otherwise opens (APE, WavPack, Ogg Vorbis, Opus).
    case surround
    /// Anything else: DSD inside WavPack, FLAC inside Ogg, a DSD rate that isn't a usual one.
    case other

    public struct Count: Equatable, Sendable {
        public var need: MacNeed
        public var files: Int

        public init(need: MacNeed, files: Int) {
            self.need = need
            self.files = files
        }
    }

    /// A library's `needs` as a list in this order, the reasons with no files left out.
    public static func counts(_ needs: [String: Int]) -> [Count] {
        allCases.compactMap { need in needs[need.rawValue].flatMap { $0 > 0 ? Count(need: need, files: $0) : nil } }
    }

    /// The need of every file whose name ends in `type`; nil for a kind that depends on what is inside.
    static func named(_ type: String) -> MacNeed? {
        switch type {
        case "dts": .dts
        case "thd", "mlp": .trueHD
        case "ac3", "ec3": .dolbyDigital
        case "tta": .tta
        case "tak": .tak
        case "wma": .wma
        case "mka": .matroska
        case "iso": .discImage
        default: nil
        }
    }
}

public struct ShareLibrary: Codable, Equatable, Sendable {
    public var songs: [ShareSong]
    /// The picture file found in a folder (`cover.jpg` and the like), by folder.
    public var covers: [String: String]
    /// Music files of kinds the phone can't open without the Mac converting them (APE, WavPack, surround DSD…).
    public var needTheMac: Int
    /// The same files by why they need the Mac (`MacNeed`'s raw values). Empty in a library saved before this was kept.
    public var needs: [String: Int]
    /// Files with a playable name that couldn't be read as what the name says.
    public var unreadable: Int
    public var scanned: Date?

    public init(songs: [ShareSong] = [], covers: [String: String] = [:], needTheMac: Int = 0, needs: [String: Int] = [:], unreadable: Int = 0, scanned: Date? = nil) {
        self.songs = songs
        self.covers = covers
        self.needTheMac = needTheMac
        self.needs = needs
        self.unreadable = unreadable
        self.scanned = scanned
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        songs = try values.decode([ShareSong].self, forKey: .songs)
        covers = try values.decode([String: String].self, forKey: .covers)
        needTheMac = try values.decode(Int.self, forKey: .needTheMac)
        needs = try values.decodeIfPresent([String: Int].self, forKey: .needs) ?? [:]
        unreadable = try values.decode(Int.self, forKey: .unreadable)
        scanned = try values.decodeIfPresent(Date.self, forKey: .scanned)
    }

    /// One more file that needs the Mac, and why.
    mutating func count(_ need: MacNeed) {
        needTheMac += 1
        needs[need.rawValue, default: 0] += 1
    }

    /// How many files need the Mac for each reason, in `MacNeed`'s order. Empty when the reasons weren't kept.
    public var needsByKind: [MacNeed.Count] { MacNeed.counts(needs) }
}

public enum ShareScanner {
    public struct Progress: Equatable, Sendable {
        public var folders: Int
        public var songs: Int
    }

    /// Folders that are never music: a NAS's own, a recycle bin, a drive's bookkeeping.
    static let skippedFolders: Set<String> = ["@eadir", "#recycle", "$recycle.bin", "system volume information", "lost+found", "#snapshot", "@recycle"]
    private static let coverNames = ["cover", "folder", "front", "album", "albumart"]
    private static let coverTypes: Set<String> = ["jpg", "jpeg", "png"]

    /// An ID from a path (FNV-1a), kept below 2^53 so it is the same number wherever it is written.
    static func id(for path: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int64(hash & 0x1f_ffff_ffff_ffff) | 1
    }

    /// An MPEG-4 file an earlier scan found no title, artist or album in is read again though it has not changed: it may
    /// be tagged the QuickTime way, which earlier versions could not read. A file with no tags at all costs one small
    /// read more per scan.
    static func readsAgain(_ old: ShareSong, type: String) -> Bool {
        guard ["m4a", "mp4", "m4b"].contains(type) else { return false }
        return old.tags.title == nil && old.tags.artist == nil && old.tags.album == nil
    }

    /// Walks `files` from the top and returns its library. `previous`: the last scan, whose tags are reused for files
    /// with the same size and date. A folder that can't be opened is passed over; a share that stops answering ends the
    /// scan with the error (and `previous` stays what the app has).
    ///
    /// `readers`: more connections to the same share. The songs' tags are read over all of them at once while `files`
    /// lists the folders: a song costs a few round trips to the server, and over a line that takes a while to answer
    /// (Tailscale, a busy Wi-Fi) a scan that read one song at a time spent nearly all of its time waiting. Empty: one
    /// song at a time over `files`.
    ///
    /// `glimpse`: while a share is scanned for the first time (no earlier scan ever finished), what has been found so
    /// far, every `glimpseEvery` songs or `glimpseAfter` seconds, whichever comes first, and once more when the scan is
    /// stopped or fails; with `scanned` nil. A large library over a slow line can be browsed, and picked up again where
    /// it stopped, long before the scan is done.
    ///
    /// `decoders`: the kinds of file the app opens with a decoder library (DecodedFormats.swift).
    public static func scan(_ files: any ShareFiles, readers: [any ShareFiles] = [], previous: ShareLibrary? = nil, now: Date = Date(),
                            glimpseEvery: Int = 200, glimpseAfter: TimeInterval = .infinity, decoders: (any ShareDecoders)? = nil,
                            progress: (Progress) -> Void = { _ in }, glimpse: (ShareLibrary) -> Void = { _ in },
                            cancelled: () -> Bool = { false }) throws -> ShareLibrary {
        var known: [String: ShareSong] = [:]
        for song in previous?.songs ?? [] { known[song.path] = song }
        var library = ShareLibrary(scanned: now)
        var used = Set<Int64>()
        var waiting = [""]
        var folders = 0
        let firstTime = previous?.scanned == nil
        let lanes = readers.isEmpty ? [files] : readers
        // Enough songs waiting that every connection has several to read while the slowest finishes its last.
        let batchSize = lanes.count == 1 ? 1 : lanes.count * 4
        var batch: [Pending] = []
        // Songs read (not taken from `previous`), and how many of them the last glimpse had, and when it was.
        var read = 0
        var glimpsed = 0
        var glimpsedAt = ProcessInfo.processInfo.systemUptime

        func keepSoFar() {
            guard firstTime, read > glimpsed else { return }
            glimpsed = read
            glimpsedAt = ProcessInfo.processInfo.systemUptime
            glimpse(arranged(library, scanned: nil))
        }

        func flush() throws {
            guard !batch.isEmpty else { return }
            let outcomes = try readAll(batch, lanes: lanes, decoders: decoders, cancelled: cancelled)
            for (item, outcome) in zip(batch, outcomes) {
                switch outcome {
                case .needs(let need): library.count(need)
                case .unreadable: library.unreadable += 1
                case .tags(let tags):
                    var songID = known[item.path]?.id ?? id(for: item.path)
                    while used.contains(songID) { songID += 2 }
                    used.insert(songID)
                    library.songs.append(ShareSong(id: songID, path: item.path, size: item.entry.size, modified: item.entry.modified, tags: tags))
                    read += 1
                    progress(Progress(folders: folders, songs: library.songs.count))
                }
            }
            batch.removeAll(keepingCapacity: true)
            guard firstTime, read > glimpsed else { return }
            if (glimpseEvery > 0 && read - glimpsed >= glimpseEvery) || ProcessInfo.processInfo.systemUptime - glimpsedAt >= glimpseAfter { keepSoFar() }
        }

        do {
            while let folder = waiting.popLast() {
                if cancelled() { throw CancellationError() }
                let entries: [SMBEntry]
                do {
                    entries = try files.list(folder)
                } catch let error as SMBError where !SMBShare.lineIsGone(error) && error != .unreachable && !folder.isEmpty {
                    continue
                }
                folders += 1
                let sorted = entries.filter { !$0.hidden && !$0.name.hasPrefix(".") }
                    .sorted { $0.name.compare($1.name, options: [.numeric, .caseInsensitive]) == .orderedAscending }
                var cover: (rank: Int, name: String)?
                for entry in sorted {
                    let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                    if entry.isFolder {
                        if !skippedFolders.contains(entry.name.lowercased()), path.split(separator: "/").count <= 24 { waiting.append(path) }
                        continue
                    }
                    let type = SongTagReader.fileExtension(entry.name)
                    if coverTypes.contains(type) {
                        let stem = entry.name.dropLast(type.count + 1).lowercased()
                        if let rank = coverNames.firstIndex(of: String(stem)), cover.map({ rank < $0.rank }) ?? true { cover = (rank, entry.name) }
                        continue
                    }
                    // A kind the app has a decoder for is opened here, whatever the list of the Mac's kinds says.
                    let decoded = decoders?.extensions.contains(type) ?? false
                    if !decoded, SongTagReader.needsTheMac.contains(type) { library.count(MacNeed.named(type) ?? .other); continue }
                    guard decoded || SongTagReader.playable.contains(type), entry.size > 0 else { continue }
                    if let old = known[path], old.size == entry.size, old.modified == entry.modified, !readsAgain(old, type: type) {
                        used.insert(old.id)
                        library.songs.append(old)
                        continue
                    }
                    batch.append(Pending(path: path, entry: entry, type: type, decoded: decoded))
                    if batch.count >= batchSize {
                        if cancelled() { throw CancellationError() }
                        try flush()
                    }
                }
                if let cover { library.covers[folder] = cover.name }
                progress(Progress(folders: folders, songs: library.songs.count))
            }
            if cancelled() { throw CancellationError() }
            try flush()
        } catch {
            // What was read before the scan stopped is kept: the next scan carries on from it.
            keepSoFar()
            throw error
        }
        return arranged(library, scanned: now)
    }

    /// A song file the walk found new or changed, waiting for its tags to be read.
    private struct Pending: Sendable {
        var path: String
        var entry: SMBEntry
        var type: String
        var decoded: Bool
    }

    /// What reading a song file found.
    private enum Outcome: Sendable {
        case tags(SongTags)
        /// A file the phone can't open without the Mac converting it.
        case needs(MacNeed)
        /// A playable name, but not what the name says.
        case unreadable
    }

    /// Results filled in by several threads.
    private final class Gathered: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Outcome?]
        private var taken = 0
        private(set) var failure: Error?

        init(_ count: Int) { results = Array(repeating: nil, count: count) }

        /// The next song to read; nil when there are none left or one has failed.
        func next() -> Int? {
            lock.withLock {
                guard failure == nil, taken < results.count else { return nil }
                taken += 1
                return taken - 1
            }
        }

        func put(_ outcome: Outcome, at index: Int) { lock.withLock { results[index] = outcome } }
        func fail(_ error: Error) { lock.withLock { if failure == nil { failure = error } } }
        var outcomes: [Outcome] { lock.withLock { results.map { $0 ?? .unreadable } } }
    }

    /// Reads every song in `batch`, each lane (a connection) taking the next one as it finishes the last, and gives
    /// what each was found to be in `batch`'s order. The first failure that ends the scan is thrown once all have stopped.
    private static func readAll(_ batch: [Pending], lanes: [any ShareFiles], decoders: (any ShareDecoders)?,
                                cancelled: () -> Bool) throws -> [Outcome] {
        if lanes.count == 1 || batch.count == 1 {
            return try batch.map { item in
                if cancelled() { throw CancellationError() }
                return try readOne(item, from: lanes[0], decoders: decoders)
            }
        }
        let gathered = Gathered(batch.count)
        // `cancelled` is asked here, on the scan's own thread, and passed on to the lanes as a flag.
        let stop = StopFlag()
        let group = DispatchGroup()
        for lane in lanes.prefix(batch.count) {
            group.enter()
            // A thread each: the reads block on the network, and GCD's pool of a few threads would take turns.
            let thread = Thread {
                defer { group.leave() }
                while let index = gathered.next() {
                    if stop.isSet { gathered.fail(CancellationError()); return }
                    do {
                        gathered.put(try readOne(batch[index], from: lane, decoders: decoders), at: index)
                    } catch {
                        gathered.fail(error)
                        return
                    }
                }
            }
            thread.qualityOfService = .utility
            thread.start()
        }
        while group.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if !stop.isSet, cancelled() { stop.set() }
        }
        if let failure = gathered.failure { throw failure }
        return gathered.outcomes
    }

    /// Reads one song file's tags over `files`.
    private static func readOne(_ item: Pending, from files: any ShareFiles, decoders: (any ShareDecoders)?) throws -> Outcome {
        let path = item.path, size = item.entry.size
        let tags: SongTags?
        do {
            if item.decoded, let decoders {
                switch try decoders.open(type: item.type, size: size, read: { offset, length in
                    offset == 0 ? try files.head(path, length: length) : try files.read(path, offset: offset, length: length)
                }) {
                case .opened(let decoder) where decoder.info.playsHere: tags = SongTagReader.tags(decoder.info, size: size)
                case .opened(let decoder): return .needs(decoder.info.channels > 2 ? .surround : .other)
                case .needsTheMac: return .needs(.other)
                case .unreadable: tags = nil
                }
            } else {
                // The start of the file in one round trip (most tags are there); anything further the usual way.
                tags = try SongTagReader.read(name: item.entry.name, size: size) { offset, length in
                    offset == 0 ? try files.head(path, length: length) : try files.read(path, offset: offset, length: length)
                }
            }
        } catch let error as SMBError where !SMBShare.lineIsGone(error) && error != .unreachable {
            tags = nil
        }
        guard let tags else { return .unreadable }
        // DSD in surround, or packed with DST: a file the Mac has to convert.
        if let dsd = tags.dsd, !dsd.playsHere { return .needs(dsd.dst ? .dst : dsd.channels > 2 ? .surroundDSD : .other) }
        return .tags(tags)
    }

    private static func arranged(_ library: ShareLibrary, scanned: Date?) -> ShareLibrary {
        var library = library
        library.scanned = scanned
        library.songs.sort { $0.path.compare($1.path, options: [.numeric, .caseInsensitive]) == .orderedAscending }
        return library
    }
}

/// The few words the library puts where a file says nothing, in the app's language.
public struct ShareWords: Sendable, Equatable {
    public var unknownArtist: String
    public var unknownAlbum: String
    public var variousArtists: String

    public init(unknownArtist: String, unknownAlbum: String, variousArtists: String) {
        self.unknownArtist = unknownArtist
        self.unknownAlbum = unknownAlbum
        self.variousArtists = variousArtists
    }

    public static let english = ShareWords(unknownArtist: "Unknown Artist", unknownAlbum: "Unknown Album", variousArtists: "Various Artists")
}
