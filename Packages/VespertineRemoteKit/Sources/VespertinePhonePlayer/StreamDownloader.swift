//
// Vespertine: fetches a stream's bytes into a file on the phone, a few ranges at a time. A run that stops part way (the line
// went, the app was closed or iOS ended its time in the background) leaves what arrived, with a note beside it of which
// ranges those are and of which song's bytes they are; the next run for the same bytes fetches only the rest. The skeleton of
// the phone's source: the first player plays a finished file; reading ahead while it plays builds on `downloaded`.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public actor StreamDownloader {
    public enum Failure: Error, Equatable {
        /// The Mac sent bytes for another range than the one asked for.
        case wrongRange(asked: Int64, got: Int64)
        /// The stream ended before the descriptor's size.
        case endedEarly(expected: Int64, got: Int64)
        case cannotWrite(String)

        var isWriting: Bool { if case .cannotWrite = self { true } else { false } }
    }

    /// Reads up to `length` bytes of the stream from `offset`.
    public typealias Reader = @Sendable (_ offset: Int64, _ length: Int) async throws -> StreamFrame

    public let descriptor: StreamDescriptor
    public let destination: URL
    private let read: Reader
    private let window: Int
    private let attempts: Int
    private(set) public var downloaded: Int64 = 0
    private(set) public var peakInFlight = 0
    private var inFlight = 0
    private var handle: FileHandle?
    /// The ranges in the file already, by number (`chunk` bytes each), from an earlier run for the same bytes.
    private var done: Set<Int>
    private let chunk: Int64
    private var noted = ContinuousClock.now

    /// What is written beside a part-made file: whose bytes they are and which ranges have arrived.
    private struct Progress: Codable {
        var tag: String
        var byteSize: Int64
        var chunk: Int64
        /// Arrived ranges by number, as runs: [first, last] each.
        var runs: [[Int]]
    }

    /// The note kept beside `destination` while it is part made.
    public static func progressFile(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".progress")
    }

    /// `window`: how many ranges are asked for at once. `attempts`: tries per range before the download fails.
    public init(descriptor: StreamDescriptor, destination: URL, read: @escaping Reader, window: Int = 4, attempts: Int = 3) {
        self.descriptor = descriptor
        self.destination = destination
        self.read = read
        self.window = max(1, window)
        self.attempts = max(1, attempts)
        let chunk = Int64(max(1, min(descriptor.chunkSize, RemoteProtocol.maximumChunk)))
        self.chunk = chunk
        var done = Set<Int>()
        // What an earlier run left is used only when it is this song's bytes (the same tag and size), cut the same way.
        if let data = try? Data(contentsOf: Self.progressFile(for: destination)), let note = try? JSONDecoder().decode(Progress.self, from: data),
           note.tag == descriptor.tag, note.byteSize == descriptor.byteSize, note.chunk == chunk,
           let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64, size <= descriptor.byteSize {
            for run in note.runs where run.count == 2 && run[0] <= run[1] && run[0] >= 0 { done.formUnion(run[0]...run[1]) }
            let count = Int((descriptor.byteSize + chunk - 1) / chunk)
            done = done.filter { $0 < count }
        }
        self.done = done
    }

    /// Bytes an earlier run left that this one keeps.
    public var alreadyHere: Int64 { done.reduce(0) { $0 + length(of: $1) } }

    private func length(of index: Int) -> Int64 { min(chunk, descriptor.byteSize - Int64(index) * chunk) }

    /// Downloads the whole stream to `destination`, reporting the bytes in so far. What an earlier run for the same bytes
    /// left there is kept and only the rest is fetched; anything else there is replaced. On failure or cancellation what
    /// arrived stays, with its note, for the next run; only bytes that came for the wrong place are thrown away.
    public func run(progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        if done.isEmpty || !FileManager.default.fileExists(atPath: destination.path) {
            done = []
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.cannotWrite("\(destination.lastPathComponent) can’t be created")
            }
        }
        do {
            let file = try FileHandle(forWritingTo: destination)
            handle = file
            let size = descriptor.byteSize
            let count = Int((size + chunk - 1) / chunk)
            downloaded = alreadyHere
            if downloaded > 0 { progress?(downloaded) }
            note(force: true)
            let wanted = (0..<count).filter { !done.contains($0) }
            try await withThrowingTaskGroup(of: Int.self) { group in
                var next = 0
                func startNext() {
                    guard next < wanted.count else { return }
                    let index = wanted[next]
                    let offset = Int64(index) * chunk
                    let length = Int(min(chunk, size - offset))
                    next += 1
                    group.addTask { [self] in
                        _ = try await fetch(offset: offset, length: length)
                        return index
                    }
                }
                for _ in 0..<min(window, wanted.count) { startNext() }
                while let index = try await group.next() {
                    done.insert(index)
                    downloaded += length(of: index)
                    progress?(downloaded)
                    note(force: false)
                    startNext()
                }
            }
            try handle?.close()
            handle = nil
            guard downloaded == size else { throw Failure.endedEarly(expected: size, got: downloaded) }
            try? FileManager.default.removeItem(at: Self.progressFile(for: destination))
        } catch {
            if let failure = error as? Failure, !failure.isWriting {
                // Bytes for another place than asked, or a song shorter than it said: nothing in the file can be trusted.
                try? handle?.close()
                handle = nil
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: Self.progressFile(for: destination))
                throw error
            }
            note(force: true)
            try? handle?.close()
            handle = nil
            throw error
        }
    }

    /// Writes down which ranges are in the file (after making sure they are on the disk), at most twice a second
    /// unless `force`d.
    private func note(force: Bool) {
        guard force || ContinuousClock.now - noted > .milliseconds(500) else { return }
        noted = ContinuousClock.now
        try? handle?.synchronize()
        var runs: [[Int]] = []
        for index in done.sorted() {
            if let last = runs.last, last[1] == index - 1 { runs[runs.count - 1][1] = index } else { runs.append([index, index]) }
        }
        let record = Progress(tag: descriptor.tag, byteSize: descriptor.byteSize, chunk: chunk, runs: runs)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: Self.progressFile(for: destination), options: .atomic) }
    }

    /// One range, in as many reads as the Mac needs to answer it in full; retried when a read fails.
    private func fetch(offset: Int64, length: Int) async throws -> Int64 {
        var done = 0
        while done < length {
            try Task.checkCancellation()
            let frame = try await readWithRetry(offset: offset + Int64(done), length: length - done)
            guard frame.offset == offset + Int64(done) else { throw Failure.wrongRange(asked: offset + Int64(done), got: frame.offset) }
            if frame.payload.isEmpty { throw Failure.endedEarly(expected: descriptor.byteSize, got: offset + Int64(done)) }
            let usable = min(frame.payload.count, length - done)
            try write(frame.payload.prefix(usable), at: offset + Int64(done))
            done += usable
        }
        return Int64(length)
    }

    private func readWithRetry(offset: Int64, length: Int) async throws -> StreamFrame {
        var lastError: Error?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            defer { inFlight -= 1 }
            do { return try await read(offset, length) } catch {
                lastError = error
                if error is CancellationError { throw error }
                try? await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
            }
        }
        throw lastError ?? Failure.cannotWrite("")
    }

    private func write(_ data: Data, at offset: Int64) throws {
        guard let handle else { throw CancellationError() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }
}
