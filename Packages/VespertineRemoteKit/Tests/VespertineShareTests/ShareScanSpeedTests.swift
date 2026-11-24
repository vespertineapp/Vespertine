//
// Vespertine: a scan over a share that takes a while to answer. Each song costs round trips to the server; read one at
// a time, a library of fifteen thousand songs over Tailscale took the better part of a day. With more connections the
// songs' tags are read at once, the library comes out the same, and what was read before the scan was stopped is kept.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// A share whose every answer takes `delay`, as one far away does. Counts how many reads are under way at once.
final class FarShare: ShareFiles, @unchecked Sendable {
    let share: FakeShare
    let delay: TimeInterval
    private let lock = NSLock()
    private var reading = 0
    private(set) var mostAtOnce = 0
    private(set) var reads = 0
    /// After this many reads, every read finds the line dead (nil: never).
    var dropsAfter: Int?

    init(_ share: FakeShare, delay: TimeInterval) {
        self.share = share
        self.delay = delay
    }

    func list(_ folder: String) throws -> [SMBEntry] {
        Thread.sleep(forTimeInterval: delay)
        return try share.list(folder)
    }

    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        let dead = lock.withLock { () -> Bool in
            reads += 1
            reading += 1
            mostAtOnce = max(mostAtOnce, reading)
            return dropsAfter.map { reads > $0 } ?? false
        }
        defer { lock.withLock { reading -= 1 } }
        Thread.sleep(forTimeInterval: delay)
        if dead { throw SMBError.timedOut }
        return try share.read(path, offset: offset, length: length)
    }

    func info(_ path: String) throws -> (size: Int64, modified: Date) { try share.info(path) }
    func rest() {}
}

@Suite struct ShareScanSpeedTests {
    /// Twelve albums of five songs each.
    static func shelf() -> FakeShare {
        let share = FakeShare()
        for album in 1...12 {
            for track in 1...5 {
                share.put("Artist \(album)/Album \(album)/\(track) Song.flac",
                          FlacMaker.file(["TITLE": "Song \(track)", "ALBUM": "Album \(album)", "ARTIST": "Artist \(album)", "TRACKNUMBER": "\(track)"]))
            }
        }
        return share
    }

    @Test func songsAreReadOverEveryConnectionAtOnceAndTheLibraryIsTheSame() throws {
        let one = try ShareScanner.scan(Self.shelf(), now: FakeShare.day)
        let share = Self.shelf()
        let far = FarShare(share, delay: 0.01)
        let readers = (0..<6).map { _ in FarShare(share, delay: 0.01) }
        let many = try ShareScanner.scan(far, readers: readers, now: FakeShare.day)
        #expect(many == one)
        #expect(many.songs.count == 60)
        // The connection that lists the folders reads no songs; the others read them side by side.
        #expect(far.reads == 0)
        #expect(readers.allSatisfy { $0.reads > 0 })
    }

    @Test func aScanOverSeveralConnectionsIsSeveralTimesFaster() throws {
        let share = Self.shelf()
        func timed(_ body: () throws -> Void) rethrows -> TimeInterval {
            let start = ProcessInfo.processInfo.systemUptime
            try body()
            return ProcessInfo.processInfo.systemUptime - start
        }
        let alone = try timed { _ = try ShareScanner.scan(FarShare(share, delay: 0.02), now: FakeShare.day) }
        let readers = (0..<6).map { _ in FarShare(share, delay: 0.02) }
        let together = try timed { _ = try ShareScanner.scan(FarShare(share, delay: 0.02), readers: readers, now: FakeShare.day) }
        // 60 songs and 25 folders at 20 ms an answer: about 1.7 s one at a time. Six at once leaves the listing (0.5 s)
        // and a sixth of the reads; the margin is wide for a busy test machine.
        #expect(together < alone / 2, "one connection \(alone) s, seven \(together) s")
    }

    @Test func aScanStoppedPartWayKeepsWhatItReadAndTheNextCarriesOn() throws {
        let share = Self.shelf()
        let readers = (0..<4).map { _ in FarShare(share, delay: 0.002) }
        var kept: ShareLibrary?
        var stop = false
        var seen = 0
        #expect(throws: CancellationError.self) {
            _ = try ShareScanner.scan(share, readers: readers, now: FakeShare.day, glimpseEvery: 0, progress: { progress in
                seen = progress.songs
                if progress.songs >= 20 { stop = true }
            }, glimpse: { kept = $0 }, cancelled: { stop })
        }
        // Nothing was glimpsed along the way (glimpseEvery 0, no time limit): what is kept is the last word as it stopped.
        let partial = try #require(kept)
        #expect(partial.scanned == nil)
        #expect(partial.songs.count == seen && seen >= 20 && seen < 60)

        // The next scan reads only the songs the first never got to.
        let counting = (0..<4).map { _ in FarShare(share, delay: 0) }
        let whole = try ShareScanner.scan(share, readers: counting, previous: partial, now: FakeShare.day)
        #expect(whole.songs.count == 60)
        #expect(counting.map(\.reads).reduce(0, +) <= (60 - partial.songs.count) * 4)
        #expect(whole == (try ShareScanner.scan(Self.shelf(), now: FakeShare.day)))
    }

    @Test func aFirstScanIsKeptEveryFewSecondsHoweverFewSongsItHasRead() throws {
        var glimpses: [Int] = []
        let readers = (0..<2).map { _ in FarShare(Self.shelf(), delay: 0) }
        _ = try ShareScanner.scan(Self.shelf(), readers: readers, now: FakeShare.day, glimpseEvery: 10_000, glimpseAfter: 0, glimpse: { glimpses.append($0.songs.count) })
        // Time's up after every batch: each is kept as it is read, though far fewer than 10,000 songs have been.
        #expect(glimpses.count >= 2)
        #expect(glimpses == glimpses.sorted() && glimpses.last == 60)
    }

    @Test func aConnectionThatDiesEndsTheScanAndWhatWasReadIsKept() throws {
        let share = Self.shelf()
        let readers = (0..<3).map { _ in FarShare(share, delay: 0.001) }
        for reader in readers { reader.dropsAfter = 6 }
        var kept: ShareLibrary?
        #expect(throws: SMBError.timedOut) {
            _ = try ShareScanner.scan(share, readers: readers, now: FakeShare.day, glimpseEvery: 0, glimpse: { kept = $0 })
        }
        let partial = try #require(kept)
        #expect(!partial.songs.isEmpty && partial.songs.count < 60)
    }
}
