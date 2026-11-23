//
// Vespertine: the next song is prepared off the renderer's command worker. A player that wants whole files (a Sonos) waits
// up to two minutes for a processed stream to be written; while the next song waits like that, pause, stop, seek, skip
// and the status polls still go through at once, and the wait is given up the moment it no longer matters (a stop, a skip,
// the output let go of).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

/// Makes processed streams that are never finished (an encoder far slower than the music), and keeps them to look at.
private final class StuckStreamMaker: ProcessedStreamMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [GrowingFile] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-stuck-\(UUID().uuidString)")
    var files: [GrowingFile] { lock.withLock { made } }

    /// How long making a stream takes before its file exists (an encoder slow to open), whatever happens meanwhile.
    var openDelay: TimeInterval = 0
    private var _begun = 0
    /// Streams asked for, including one still being opened.
    var begun: Int { lock.withLock { _begun } }

    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat) {
        lock.withLock { _begun += 1 }
        if openDelay > 0 { Thread.sleep(forTimeInterval: openDelay) }
        let file = try GrowingFile(url: directory.appendingPathComponent(UUID().uuidString + ".flac"))
        lock.withLock { made.append(file) }
        return (file, SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2))
    }
}

/// A transport whose `load` waits while `held` (a renderer slow to take a song), counting the loads asked for.
private final class GatedTransport: RendererTransport, @unchecked Sendable {
    let inner: any RendererTransport
    let held = Locked(false)
    let loadsAsked = Locked(0)
    /// While set, every change of the next song fails (a player busy or briefly off the network); counted while set.
    let refusesNext = Locked(false)
    let nextRefused = Locked(0)
    init(_ inner: any RendererTransport) { self.inner = inner }
    var gapless: Bool { inner.gapless }
    func load(current: RendererTrack, next: RendererTrack?) async throws {
        loadsAsked.withLock { $0 += 1 }
        while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        try await inner.load(current: current, next: next)
    }
    func replaceNext(_ next: RendererTrack?) async throws {
        beforeReplaceNext.withLock { hook -> (@Sendable () -> Void)? in defer { hook = nil }; return hook }?()
        if refusesNext.withLock({ $0 }) {
            nextRefused.withLock { $0 += 1 }
            throw UPnPError.fault(code: 501, description: "Action Failed")
        }
        try await inner.replaceNext(next)
    }
    func play() async throws { try await inner.play() }
    func pause() async throws { try await inner.pause() }
    func stop() async throws { try await inner.stop() }
    func seek(to seconds: TimeInterval) async throws { try await inner.seek(to: seconds) }
    /// While set, a status request waits before it reaches the player (a slow answer); `statusWaiting` counts the waits.
    let statusHeld = Locked(false)
    let statusWaiting = Locked(0)
    /// Run once, at the next change of the next song, before it reaches the player (then cleared).
    let beforeReplaceNext = Locked<(@Sendable () -> Void)?>(nil)
    func status() async throws -> RendererStatus {
        if statusHeld.withLock({ $0 }) {
            statusWaiting.withLock { $0 += 1 }
            while statusHeld.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return try await inner.status()
    }
}

/// A stream's song whose download never finishes (a slow server that is still sending): its reads wait until the test ends
/// them, whatever the cache does meanwhile, the way a read the network never returns from does.
private final class EndlessRemoteReader: RemoteCacheReader, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reads = 0, cancels = 0
    var readsBegun: Int { lock.withLock { reads } }
    /// The cache gave the copy up.
    var cancelled: Bool { lock.withLock { cancels > 0 } }
    var size: Int64 { 8 << 20 }
    var fileExtension: String { "flac" }
    /// Never silent: a slow link that is still sending isn't given up on as gone.
    var quietFor: TimeInterval? { 0 }
    func read(at offset: Int64, count: Int) throws -> Data {
        lock.withLock { reads += 1 }
        _ = release.wait(timeout: .now() + 60)
        throw POSIXError(.ECANCELED)
    }
    func cancel() { lock.withLock { cancels += 1 } }
}

private struct Rig {
    let fake: FakeRenderer
    let media: MediaServer
    let playback: RendererPlayback
    let maker: StuckStreamMaker
    let events: EventLog
    let transport: GatedTransport
    /// Plays as the file (24/48 FLAC), then one that must be converted for Sonos (96 kHz), then another file.
    let first: PlayableItem, stuck: PlayableItem, third: PlayableItem
    /// The queue, which a test may change (then `playback.queueChanged()`).
    let queue: Locked<[PlayableItem]>

    /// `second`: the song after the first one, in place of the one converted for Sonos.
    static func make(second: PlayableItem? = nil) async throws -> Rig {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_BAR01400_MR")
        fake.sonosRoom = "Living Room"
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        let media = MediaServer()
        try await media.start()
        let device = try await RendererDevice.load(location: fake.location)
        let maker = StuckStreamMaker()
        let transport = GatedTransport(try device.makeTransport())
        let playback = RendererPlayback(renderer: device, transport: transport, media: media, processed: maker, pollInterval: 0.05)
        // Long enough that a worker held by it would fail every check below; short enough not to hold the run up for long.
        playback.wholeFileWait = 30
        let first = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 3)))
        let stuck = try second ?? PlayableItem(url: try makeWAV(seconds: 1, rate: 96_000, seed: 4))
        let third = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 5)))
        let queue = Locked([first, stuck, third])
        playback.nextItemProvider = { item in
            let q = queue.withLock { $0 }
            return q.firstIndex { $0.id == item.id }.flatMap { $0 + 1 < q.count ? q[$0 + 1] : nil }
        }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        return Rig(fake: fake, media: media, playback: playback, maker: maker, events: events, transport: transport,
                   first: first, stuck: stuck, third: third, queue: queue)
    }

    /// The first song plays, and the stuck one is being prepared as the next.
    func playFirst() async throws {
        playback.play(first)
        #expect(await events.wait(for: "started \(first.url.lastPathComponent)"))
        #expect(await within(5) { !maker.files.isEmpty })
    }

    func close() {
        playback.shutdown()
        media.stop()
        fake.stop()
    }
}

/// True once `condition` holds, looking every 20 ms for up to `seconds`.
private func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 50) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Next song prepared off the command worker", .serialized)
struct NextPreparationTests {
    @Test("While the next song's stream is still being written, pause, play, seek and the status polls go through at once")
    func commandsGoThrough() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        try await rig.playFirst()
        let polls = rig.fake.actions.filter { $0 == "GetTransportInfo" }.count
        #expect(await within(2) { rig.fake.actions.filter { $0 == "GetTransportInfo" }.count > polls + 2 })
        rig.playback.pause()
        #expect(await within(2) { rig.fake.actions.contains("Pause") })
        rig.playback.resume()
        #expect(await within(2) { rig.fake.actions.filter { $0 == "Play" }.count >= 2 })
        rig.playback.seek(to: 1)
        #expect(await within(2) { rig.fake.actions.contains("Seek") })
        // Nothing half-written was offered as the next song.
        #expect(!rig.fake.actions.contains("SetNextAVTransportURI") || rig.fake.nextURI == nil)
    }

    @Test("A stop goes through at once, and the stream being written for the next song is given up")
    func stop() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        try await rig.playFirst()
        rig.playback.stop()
        #expect(await within(2) { rig.fake.actions.contains("Stop") })
        #expect(await within(2) { rig.maker.files.allSatisfy(\.isAbandoned) })
    }

    @Test("A skip goes through at once and plays; the stream for the song skipped past is given up")
    func skip() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        try await rig.playFirst()
        let stuck = try #require(rig.maker.files.first)
        rig.playback.play(rig.third)
        #expect(await rig.events.wait(for: "started \(rig.third.url.lastPathComponent)", timeout: 3))
        #expect(await within(2) { stuck.isAbandoned })
    }

    @Test("Letting go of the output gives the wait up too")
    func shutdown() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        try await rig.playFirst()
        rig.playback.shutdown()
        #expect(await within(2) { rig.maker.files.allSatisfy(\.isAbandoned) })
    }

    @Test("A next song that is ready in time is still handed to the player")
    func stillHandedOver() async throws {
        let h = try await Harness.make(kind: .av(setNext: true))
        defer { h.close() }
        h.playback.play(h.queue[0])
        #expect(await h.events.wait(for: "started \(h.queue[0].url.lastPathComponent)"))
        #expect(await within(3) { h.fake.nextURI != nil })
        await h.playback.settleForTests()
        #expect(h.fake.actions.contains("SetNextAVTransportURI"))
    }

    // MARK: The second review (2026-11-23)

    /// Registers a scheme whose songs never finish downloading; the reader is handed back to look at.
    private func endlessRemoteItem() -> (PlayableItem, EndlessRemoteReader) {
        let reader = EndlessRemoteReader()
        let scheme = "x-endless-\(UUID().uuidString.prefix(8).lowercased())"
        NetworkPlaybackCache.registerRemoteReader(scheme: scheme) { _ in reader }
        let url = URL(string: "\(scheme)://track/1")!
        return (PlayableItem(url: url, cacheKey: url.absoluteString), reader)
    }

    @Test("A next song still downloading is given up by a skip: the song skipped to, a local file, plays at once")
    func remoteDownloadFreesTheQueue() async throws {
        let (remote, reader) = endlessRemoteItem()
        defer { reader.release.signal() }
        let rig = try await Rig.make(second: remote)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { reader.readsBegun > 0 })
        rig.playback.play(rig.third)
        #expect(await rig.events.wait(for: "started \(rig.third.url.lastPathComponent)", timeout: 3))
        #expect(await within(2) { reader.cancelled })
    }

    @Test("A stop gives up a next song still downloading at once, and stopAndWait doesn't wait on it")
    func remoteDownloadStop() async throws {
        let (remote, reader) = endlessRemoteItem()
        defer { reader.release.signal() }
        let rig = try await Rig.make(second: remote)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { reader.readsBegun > 0 })
        let began = Date()
        rig.playback.stopAndWait(timeout: 10)
        #expect(Date().timeIntervalSince(began) < 2)
        #expect(await within(2) { reader.cancelled })
    }

    @Test("A stop while the first song is being loaded: the next song planned once it is loaded is given up",
          arguments: [false, true])
    func stopDuringLoad(shutdown: Bool) async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        rig.transport.held.withLock { $0 = true }
        rig.playback.play(rig.first)
        #expect(await within(5) { rig.transport.loadsAsked.withLock { $0 } > 0 })
        if shutdown { rig.playback.shutdown() } else { rig.playback.stop() }
        rig.transport.held.withLock { $0 = false }
        // Long enough for a next song planned after the load to have begun its stream.
        try await Task.sleep(for: .milliseconds(1500))
        let abandoned = rig.maker.files.allSatisfy { $0.isAbandoned }
        #expect(abandoned, "a stream is still being written for nobody")
    }

    @Test("stopAndWait waits for a next song still being prepared to be given up")
    func stopAndWaitWaitsForPreparation() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        rig.maker.openDelay = 0.4
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.maker.begun > 0 })
        rig.playback.stopAndWait(timeout: 5)
        let files = rig.maker.files
        #expect(files.count == 1)
        #expect(files.allSatisfy { $0.isAbandoned })
    }

    @Test("A queue edit takes the old next song off the player at once, before the new one is ready; the song ending meanwhile doesn't go on to it",
          arguments: [false, true])
    func queueEditClearsNext(insert: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.fake.nextURI != nil })
        await rig.playback.settleForTests()
        let old = try #require(rig.fake.nextURI)
        // The new next song is one converted for Sonos whose stream is never finished.
        let slow = PlayableItem(url: try makeWAV(seconds: 1, rate: 96_000, seed: 8))
        rig.queue.withLock { $0 = insert ? [rig.first, slow, ready, rig.third] : [rig.first, slow, rig.third] }
        rig.playback.queueChanged()
        #expect(await within(2) { rig.fake.nextURI == nil }, "the player still holds the song no longer next")
        #expect(await within(5) { !rig.maker.files.isEmpty })
        // The first song ends while the new next one is still being prepared.
        rig.fake.advance()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.fake.currentURI != old, "the player went on to the song no longer next")
    }

    // MARK: The third review (2026-11-23)

    /// The first song plays and its next one is on the player; then the player refuses changes of its next song and the queue
    /// is edited to `queue`. Hands back the next song's address the player still holds.
    private func refusedClear(_ rig: Rig, queue: [PlayableItem]) async throws -> String {
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.fake.nextURI != nil })
        await rig.playback.settleForTests()
        let old = try #require(rig.fake.nextURI)
        rig.transport.refusesNext.withLock { $0 = true }
        rig.queue.withLock { $0 = queue }
        rig.playback.queueChanged()
        #expect(await within(2) { rig.transport.nextRefused.withLock { $0 } > 0 }, "the clear wasn't asked for")
        await rig.playback.settleForTests()
        return old
    }

    @Test("A clear of the next song that fails keeps the song (its address, its copy) until the clear is confirmed, and is tried again")
    func refusedClearIsKeptAndRetried() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        // The next song is taken out of the queue: nothing follows the first song now.
        let old = try await refusedClear(rig, queue: [rig.first])
        #expect(rig.fake.nextURI == old)
        #expect(rig.playback.heldNextURIsForTests.contains(old), "let go of while the player may still go on to it")
        // The player answers again: the clear is tried again, and the song let go of once the player has taken it off.
        rig.transport.refusesNext.withLock { $0 = false }
        #expect(await within(3) { rig.fake.nextURI == nil }, "the clear wasn't tried again")
        #expect(await within(2) { !rig.playback.heldNextURIsForTests.contains(old) }, "kept after the clear was confirmed")
    }

    @Test("A player that goes on to a next song it couldn't be told to drop is put right: the queue's next song plays, or it stops at the queue's end",
          arguments: [false, true])
    func refusedClearPlayerMovesOn(following: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let old = try await refusedClear(rig, queue: following ? [rig.first, rig.third] : [rig.first])
        // The player still refuses: the first song ends and it goes on to the song no longer in the queue.
        rig.fake.advance()
        #expect(rig.fake.currentURI == old)
        if following {
            #expect(await rig.events.wait(for: "started \(rig.third.url.lastPathComponent)", timeout: 5), "the queue's next song didn't play")
            #expect(rig.fake.currentURI != old)
        } else {
            #expect(await rig.events.wait(for: "ended", timeout: 5), "the queue's end wasn't reached")
            #expect(await within(2) { rig.fake.transportState == "Stopped" }, "the song no longer in the queue plays on")
        }
    }

    // MARK: The fourth review (2026-11-23)

    /// As `refusedClear`, but the player itself refuses (`FakeRenderer.fail`): the failure goes through the real transport,
    /// which must still know the song the player holds. `times`: how many changes of the next song it refuses.
    private func playerRefusedClear(_ rig: Rig, queue: [PlayableItem], times: Int = 10_000) async throws -> String {
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.fake.nextURI != nil })
        await rig.playback.settleForTests()
        let old = try #require(rig.fake.nextURI)
        let asked = rig.fake.actions.filter { $0 == "SetNextAVTransportURI" }.count
        rig.fake.fail("SetNextAVTransportURI", code: 501, times: times)
        rig.queue.withLock { $0 = queue }
        rig.playback.queueChanged()
        #expect(await within(2) { rig.fake.actions.filter { $0 == "SetNextAVTransportURI" }.count > asked }, "the clear wasn't asked for")
        await rig.playback.settleForTests()
        #expect(rig.fake.nextURI == old)
        return old
    }

    @Test("The player itself refuses the clear and then goes on to the old next song: it is recognised and put right",
          arguments: [false, true])
    func playerRefusedClearMovesOn(following: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let old = try await playerRefusedClear(rig, queue: following ? [rig.first, rig.third] : [rig.first])
        rig.fake.advance()
        #expect(rig.fake.currentURI == old)
        if following {
            #expect(await rig.events.wait(for: "started \(rig.third.url.lastPathComponent)", timeout: 5), "the queue's next song didn't play")
            #expect(rig.fake.currentURI != old)
        } else {
            #expect(await rig.events.wait(for: "ended", timeout: 5), "the queue's end wasn't reached")
            #expect(await within(2) { rig.fake.transportState == "Stopped" }, "the song no longer in the queue plays on")
        }
        #expect(!rig.events.all.contains("started \(ready.url.lastPathComponent)"), "the song no longer next was announced")
    }
}
