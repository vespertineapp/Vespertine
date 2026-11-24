//
// Vespertine: a song on a share far away (SMB over a VPN, about 100 ms each way and back) is ready to play in about two seconds.
// Measured on a laptop reading //music@… over Tailscale (102 ms round trip, 290 Mbit/s): a Dolby Atmos DD+ song of 768 kbit/s,
// which is copied whole before it plays, sat at "Buffering from the network… 34%". Every read of the copy paid a full round trip,
// and the copy read little at a time: 128 KiB per read for its first two seconds, then 1 MiB, four reads in flight. On this link
// that is about 5 MB/s, then 17, where the link carries 30 and more.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// Where `waitPrecisely`'s timers fire: a queue of its own, which always gets a thread. On a global queue the timer waited for one
/// as long as other tests held them all (220 s once, with the scan-priority tests' blocking reads in the same run).
private let preciseTimers = DispatchQueue(label: "test.precise-wait", qos: .userInitiated)

/// Waits until `uptime` (on `ProcessInfo.systemUptime`) on a strict timer. A sleep (`Thread.sleep`, `usleep`, `mach_wait_until`, a
/// condition's timed wait) may be woken late by timer coalescing: on a busy Mac a sleep of 100 ms took about 240 ms, which turns a
/// share 100 ms away into one 240 ms away. A strict dispatch timer isn't coalesced.
func waitPrecisely(until uptime: TimeInterval) {
    let wait = uptime - ProcessInfo.processInfo.systemUptime
    guard wait > 0 else { return }
    let done = DispatchSemaphore(value: 0)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: preciseTimers)
    timer.schedule(deadline: .now() + wait, leeway: .nanoseconds(0))
    timer.setEventHandler { done.signal() }
    timer.resume()
    done.wait()
    timer.cancel()
}

/// A share at the end of a long link: every read is answered a round trip after it is sent, however small, and the bytes of all
/// the reads in flight share one link of `bytesPerSecond` (one answer's bytes after another's, on an absolute schedule). It
/// notes every read's size.
private final class LongLinkShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let roundTrip: TimeInterval
    let bytesPerSecond: Double
    private let lock = NSLock()
    private var linkFree: TimeInterval = 0
    private var sizes: [Int] = []
    var size: Int64 { Int64(bytes.count) }
    init(count: Int, roundTrip: TimeInterval, bytesPerSecond: Double) {
        bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 197 &+ ($0 >> 11)) })
        self.roundTrip = roundTrip; self.bytesPerSecond = bytesPerSecond
    }
    func read(at offset: Int64, count: Int) throws -> Data {
        let length = max(0, min(count, bytes.count - Int(offset)))
        let sent = ProcessInfo.processInfo.systemUptime
        let due: TimeInterval = lock.withLock {
            sizes.append(count)
            // The answer starts back a round trip after the request left, or once the link has carried the answers before it.
            let done = max(sent + roundTrip, linkFree) + Double(length) / bytesPerSecond
            linkFree = done
            return done
        }
        waitPrecisely(until: due)
        return bytes.subdata(in: Int(offset)..<Int(offset) + length)
    }
    var readSizes: [Int] { lock.withLock { sizes } }
}

@Suite("A share far away", .serialized)
struct FarShareReadyTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 768 kbit/s for 5 minutes: the DD+ song that sat at 34%. MP4 and the other formats `NetworkStart` does not start early are
    /// copied whole before they play, so the time to copy it is the time to its first note.
    private static let atmosSongBytes = 768_000 / 8 * 300

    @Test("A song copied whole before it plays (a DD+ Atmos song) is ready in about two seconds from a share 100 ms away")
    func copiedWholeSongIsReadyInTwoSeconds() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = LongLinkShare(count: Self.atmosSongBytes, roundTrip: 0.1, bytesPerSecond: 30 * 1_048_576)
        // Blocks and lanes as in the app.
        let cache = NetworkPlaybackCache(directory: dir, budget: 256 << 20)
        let started = Date()
        let entry = try cache.entry(key: "atmos", url: URL(fileURLWithPath: "/Volumes/music/Atmos/song.m4a"), reader: share)
        try #require(!NetworkStart.startsEarly(fileExtension: "m4a", size: entry.size, isRegion: false), "the song is copied whole first")
        try entry.prepare(full: true, lead: 0, cancelled: { Date().timeIntervalSince(started) > 60 })
        let seconds = Date().timeIntervalSince(started)
        #expect(entry.isComplete)
        #expect(try Data(contentsOf: entry.url) == share.bytes, "the copy is the file, byte for byte")
        let sizes = share.readSizes
        print(String(format: "far share, copied whole: %.1f MB ready in %.2f s (%.1f MB/s) in %d reads, largest %d KiB",
                     Double(entry.size) / 1e6, seconds, Double(entry.size) / 1e6 / seconds, sizes.count, (sizes.max() ?? 0) >> 10))
        // All of it crosses the link in about 0.9 s at 30 MiB/s; the round trips are what is left of the two seconds.
        #expect(seconds < 2, "ready after \(String(format: "%.2f", seconds)) s in \(sizes.count) reads")
    }

    @Test("From a share 100 ms away the copy fills the link: large reads, several in flight, not one small read per round trip")
    func copyFillsALongLink() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // A 5.1 DSD64 song's first minute: what a progressive start and its next song's prefetch have to bring in.
        let share = LongLinkShare(count: 64 << 20, roundTrip: 0.1, bytesPerSecond: 30 * 1_048_576)
        let cache = NetworkPlaybackCache(directory: dir, budget: 256 << 20)
        let started = Date()
        let entry = try cache.entry(key: "dsd", url: URL(fileURLWithPath: "/Volumes/music/DSD/song.dsf"), reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { Date().timeIntervalSince(started) > 60 })
        let seconds = Date().timeIntervalSince(started)
        #expect(try Data(contentsOf: entry.url) == share.bytes, "the copy is the file, byte for byte")
        let sizes = share.readSizes
        let rate = Double(entry.size) / 1_048_576 / seconds
        print(String(format: "far share, 64 MiB: %.2f s, %.1f MiB/s of a 30 MiB/s link, %d reads, largest %d KiB",
                     seconds, rate, sizes.count, (sizes.max() ?? 0) >> 10))
        #expect(sizes.contains { $0 >= 4 << 20 }, "reads of several megabytes once the link has shown it carries them: largest \((sizes.max() ?? 0) >> 10) KiB")
        // Wall-clock rate swings on a loaded CI runner (21-26 MiB/s here, 19 on CI 11-24), so the rate bar sits above
        // the old code's 16 MiB/s with room, and the read count (old code: 134) is what proves one read per round trip is gone.
        #expect(sizes.count < 60, "\(sizes.count) reads for 64 MiB")
        #expect(rate > 17.5, "the copy carried \(String(format: "%.1f", rate)) MiB/s of the link's 30")
    }
}
