//
// Vespertine: a streamed song handed from a network player to the Mac while it is still downloading. The player's preparation
// (`StagedRemoteFile.stage`) and the engine share one copy in the playback cache; the player giving its preparation up (the
// listener switched to the Mac) lets go of its hold on the copy, and must not cancel the download the engine now plays from.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A slow stream: the share's bytes, at the share's pace, with its silence.
private final class SlowStream: RemoteCacheReader, @unchecked Sendable {
    let share: ControlledShare
    var fileExtension: String { "flac" }
    var size: Int64 { share.size }
    init(_ share: ControlledShare) { self.share = share }
    func read(at offset: Int64, count: Int) throws -> Data { try share.read(at: offset, count: count) }
}

@Suite("A stream handed from a network player to the Mac", .serialized)
struct StagedHandoffTests {
    @Test("Switching from a network player to the Mac while the song downloads: the player giving its copy up doesn't cancel the Mac's")
    func networkToMac() async throws {
        let rig = try PlayPauseRig(seconds: 4, fileExtension: "flac", cacheClock: PlayPauseRig.slowCacheClock())
        let scheme = "x-handoff-\(UUID().uuidString.prefix(8).lowercased())"
        NetworkPlaybackCache.registerRemoteReader(scheme: scheme) { [share = rig.share] _ in SlowStream(share) }
        defer { NetworkPlaybackCache.unregisterRemoteReader(scheme: scheme) }
        let url = URL(string: "\(scheme)://track/1")!
        let item = PlayableItem(url: url, cacheKey: url.absoluteString)
        // A slow server: the first 256 KiB come, then nothing until the test lets the rest through.
        rig.share.goQuiet(from: 256 << 10)
        defer { rig.share.goQuiet(from: nil) }

        // The network player prepares the song: its copy, whole.
        let playerLetGo = Locked(false)
        let staged = Locked<Result<Bool, Error>?>(nil)
        let cache = rig.cache
        Thread.detachNewThread {
            let result = Result { try StagedRemoteFile.stage(item, in: cache, cancelled: { playerLetGo.withLock { $0 } }) != nil }
            staged.withLock { $0 = result }
        }
        #expect(Patience.until { rig.share.readsWaiting > 0 }, "the player's copy never began")

        // The listener switches to the Mac: the engine plays the same song, from the same copy.
        let outcome = Task { await EngineOutcome.ofPlaying(item, on: rig.engine) }
        do {
            let shared = try rig.cache.entry(key: url.absoluteString, url: url)
            #expect(Patience.until { shared.readsWaiting >= 2 }, "the engine isn't waiting on the player's copy")
        }
        // The player is let go of: its preparation gives up.
        playerLetGo.withLock { $0 = true }
        #expect(Patience.until { staged.withLock { $0 } != nil })
        if case .success? = staged.withLock({ $0 }) { Issue.record("the player's preparation didn't give up") }

        // The rest of the song arrives: the Mac plays it.
        rig.share.goQuiet(from: nil)
        let result = await outcome.value
        #expect(result == .started, "the Mac plays: \(result), \(rig.engine.snapshot.lastError ?? "-")")
        rig.engine.stop()
    }
}
