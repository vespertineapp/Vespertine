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
    private var _fails = false
    /// Set: making a stream fails (an encoder that can't open the song), and the preparation with it.
    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    private var _settings: [RendererSettings] = []
    /// The settings each stream was asked for with, in order.
    var settingsAsked: [RendererSettings] { lock.withLock { _settings } }
    private var _items: [UUID] = []
    /// The settings each stream for `item` was asked for with, in order.
    func settingsAsked(for item: PlayableItem) -> [RendererSettings] {
        lock.withLock { zip(_items, _settings).filter { $0.0 == item.id }.map(\.1) }
    }

    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat) {
        lock.withLock { _begun += 1; _settings.append(settings); _items.append(item.id) }
        if fails { throw RendererPlaybackError.unplayable("the encoder couldn't open it") }
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
        let fails = failsLoad.withLock { $0 }
        while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        if fails { throw UPnPError.fault(code: 714, description: "Illegal MIME-type") }
        try await inner.load(current: current, next: next)
        // The next status request (the first poll of the song just loaded) waits, once set.
        if holdsStatusAfterLoad.withLock({ s in defer { s = false }; return s }) { statusHeld.withLock { $0 = true } }
    }
    /// While set, a load fails as a player that refuses the song does; decided when the load begins, so one held meanwhile
    /// still fails after this is cleared.
    let failsLoad = Locked(false)
    /// Set: once the next song is loaded, `statusHeld` is set (then this is cleared).
    let holdsStatusAfterLoad = Locked(false)
    func replaceNext(_ next: RendererTrack?) async throws {
        beforeReplaceNext.withLock { hook -> (@Sendable () -> Void)? in defer { hook = nil }; return hook }?()
        if refusesNext.withLock({ $0 }) {
            nextRefused.withLock { $0 += 1 }
            throw UPnPError.fault(code: 501, description: "Action Failed")
        }
        try await inner.replaceNext(next)
    }
    func play() async throws {
        if failsPlay.withLock({ $0 }) {
            playFailed.withLock { $0 += 1 }
            // The status request after this failed play waits, once set.
            if holdsStatusAfterFailedPlay.withLock({ s in defer { s = false }; return s }) { statusHeld.withLock { $0 = true } }
            throw UPnPError.fault(code: 701, description: "Transition not available")
        }
        try await inner.play()
    }
    /// While set, every Play (a resume; a load plays through the inner transport) fails as a player busy changing state
    /// does; `playFailed` counts the failures.
    let failsPlay = Locked(false)
    let playFailed = Locked(0)
    /// Set: once a Play has failed, `statusHeld` is set (then this is cleared).
    let holdsStatusAfterFailedPlay = Locked(false)
    func pause() async throws { try await inner.pause() }
    func stop() async throws {
        if stopHeld.withLock({ $0 }) {
            stopWaiting.withLock { $0 += 1 }
            while stopHeld.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        try await inner.stop()
    }
    /// While set, a stop waits before it reaches the player (a slow answer); `stopWaiting` counts the waits.
    let stopHeld = Locked(false)
    let stopWaiting = Locked(0)
    func seek(to seconds: TimeInterval) async throws {
        if failsSeek.withLock({ $0 }) {
            seekFailed.withLock { $0 += 1 }
            // The status request after this failed seek waits, once set.
            if holdsStatusAfterFailedSeek.withLock({ s in defer { s = false }; return s }) { statusHeld.withLock { $0 = true } }
            throw UPnPError.fault(code: 710, description: "Seek mode not supported")
        }
        try await inner.seek(to: seconds)
    }
    /// Set: once a seek has failed, `statusHeld` is set (then this is cleared).
    let holdsStatusAfterFailedSeek = Locked(false)
    /// While set, every seek fails (a player that won't seek yet); `seekFailed` counts the failures.
    let failsSeek = Locked(false)
    let seekFailed = Locked(0)
    /// While set, a status request waits before it reaches the player (a slow answer); `statusWaiting` counts the waits.
    let statusHeld = Locked(false)
    let statusWaiting = Locked(0)
    /// Run once, at the next change of the next song, before it reaches the player (then cleared).
    let beforeReplaceNext = Locked<(@Sendable () -> Void)?>(nil)
    /// While set, a status request fails as a player off the network does; decided when the request begins, so one held
    /// meanwhile still fails after this is cleared. `statusFailed` counts the failures.
    let failsStatus = Locked(false)
    let statusFailed = Locked(0)
    func status() async throws -> RendererStatus {
        let fails = failsStatus.withLock { $0 }
        if statusHeld.withLock({ $0 }) {
            statusWaiting.withLock { $0 += 1 }
            while statusHeld.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if fails {
            statusFailed.withLock { $0 += 1 }
            throw UPnPError.timeout
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
    /// `pollInterval` 0: no polls of its own (a test steps them with `settleForTests`).
    static func make(second: PlayableItem? = nil, startTimeout: TimeInterval = 15, lostAfter: TimeInterval = 10, pollInterval: TimeInterval = 0.05) async throws -> Rig {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_BAR01400_MR")
        fake.sonosRoom = "Living Room"
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        let media = MediaServer()
        try await media.start()
        let device = try await RendererDevice.load(location: fake.location)
        let maker = StuckStreamMaker()
        let transport = GatedTransport(try device.makeTransport())
        let playback = RendererPlayback(renderer: device, transport: transport, media: media, processed: maker, pollInterval: pollInterval,
                                        startTimeout: startTimeout, lostAfter: lostAfter)
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

    @Test("A stop, or a song chosen, while the poll that finds the player on the old next song waits for its answer, wins over putting it right",
          arguments: [false, true])
    func commandDuringStalePollWins(select: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let old = try await playerRefusedClear(rig, queue: [rig.first, rig.third])
        // The next poll is held on its way to the player; the player goes on to the old next song meanwhile.
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.fake.advance()
        #expect(rig.fake.currentURI == old)
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
            #expect(rig.playback.snapshot.item?.id == chosen.id)
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
            #expect(!rig.playback.wantsPlaying)
        }
        // Long enough for a put-right that overtook the command to have started the queue's next song.
        try await Task.sleep(for: .milliseconds(1500))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(rig.third.url.lastPathComponent)"), "the put-right overrode the listener's command")
        if select {
            #expect(rig.playback.snapshot.item?.id == chosen.id)
        } else {
            #expect(rig.playback.snapshot.state == .stopped)
            #expect(rig.fake.transportState == "Stopped")
        }
        #expect(rig.playback.heldNextURIsForTests.allSatisfy { $0 != old })
    }

    // MARK: The fifth review (2026-11-23)

    @Test("A poll queued before a stop, or a song chosen, that begins only after it finds the player on the old next song: the command still wins",
          arguments: [false, true])
    func pollQueuedBeforeCommandWins(select: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let old = try await playerRefusedClear(rig, queue: [rig.first, rig.third])
        // The worker is held in a poll waiting for the player's answer; the player goes on to the old next song meanwhile.
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.fake.advance()
        #expect(rig.fake.currentURI == old)
        // Another poll is queued behind it, then the command: the poll begins after the command moved the generation on,
        // and inspects the old song still loaded.
        rig.playback.queuePollForTests()
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
        }
        try await Task.sleep(for: .milliseconds(1500))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(rig.third.url.lastPathComponent)"), "the queued poll's put-right overrode the listener's command")
        if select {
            #expect(rig.playback.snapshot.item?.id == chosen.id)
        } else {
            #expect(!rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.state == .stopped)
            #expect(rig.fake.transportState == "Stopped")
        }
        #expect(rig.playback.heldNextURIsForTests.allSatisfy { $0 != old })
    }

    @Test("The player stopped at a song's end, found by a poll queued before a stop, or a song chosen, that begins after it: the stop holds, the chosen song plays (not paused), the queue's next song isn't started",
          arguments: [false, true])
    func endedPollQueuedBeforeCommandWins(select: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        await rig.playback.settleForTests()
        // Near the song's end (the fake reports 200 s).
        rig.fake.setPosition(195)
        await rig.playback.settleForTests()
        // A poll is held on its way to the player, which then stops at the song's end (without going on by itself); a
        // second poll is queued behind it: the two see it stopped twice in a row, the song's end.
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.fake.stopOnDevice()
        rig.playback.queuePollForTests()
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        }
        try await Task.sleep(for: .milliseconds(1000))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(ready.url.lastPathComponent)"), "the song's end overrode the listener's command")
        if select {
            #expect(rig.playback.snapshot.item?.id == chosen.id)
        } else {
            #expect(!rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.state == .stopped)
        }
    }

    // MARK: After the fifth review (2026-11-23): the rest of what a poll queued before a command does to the old song

    @Test("A poll queued before a song is chosen finds the old song never started, past the start timeout: the old song isn't failed, the chosen one plays (not paused)")
    func timedOutPollQueuedBeforeSelection() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready, startTimeout: 0.5)
        defer { rig.close() }
        // The player takes the first song and never starts it; the first poll after the load is held on its way.
        rig.fake.ignoresPlay = true
        rig.transport.holdsStatusAfterLoad.withLock { $0 = true }
        rig.playback.play(rig.first)
        #expect(await within(3) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        // Past the start timeout while it waits; another poll is queued behind it, then a song is chosen.
        try await Task.sleep(for: .milliseconds(700))
        rig.playback.queuePollForTests()
        rig.playback.play(chosen)
        rig.fake.ignoresPlay = false
        rig.transport.statusHeld.withLock { $0 = false }
        #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("failed") }, "the queued poll failed the old song after the selection")
        #expect(rig.playback.wantsPlaying)
        #expect(rig.playback.snapshot.item?.id == chosen.id)
        #expect(rig.playback.snapshot.state == .playing)
    }

    @Test("A poll queued before a stop, or a song chosen, finds the player gone on to the next song by itself: it isn't followed or announced",
          arguments: [false, true])
    func followPollQueuedBeforeCommand(select: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.fake.nextURI != nil })
        await rig.playback.settleForTests()
        // The worker is held in a poll; the player goes on to the next song meanwhile.
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.fake.advance()
        rig.playback.queuePollForTests()
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
        }
        try await Task.sleep(for: .milliseconds(1000))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(ready.url.lastPathComponent)"), "the queued poll announced the old next song after the command")
        if select {
            #expect(rig.playback.snapshot.item?.id == chosen.id)
            #expect(rig.playback.wantsPlaying)
        } else {
            #expect(!rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.state == .stopped)
            #expect(rig.playback.snapshot.item == nil)
        }
    }

    @Test("A poll queued before a stop, or a song chosen, finds the old song just started, with a seek pending: it isn't announced and the seek isn't sent",
          arguments: [false, true])
    func startedPollQueuedBeforeCommand(select: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        // The first song is started at 1 s (an output change carrying it over): the seek waits until it plays. The first
        // poll after the load is held on its way; the player plays meanwhile.
        rig.transport.holdsStatusAfterLoad.withLock { $0 = true }
        rig.playback.play(rig.first, at: 1)
        #expect(await within(3) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        #expect(await within(2) { rig.fake.transportState == "Playing" })
        rig.playback.queuePollForTests()
        let before = rig.fake.actions.count
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
        }
        try await Task.sleep(for: .milliseconds(500))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(rig.first.url.lastPathComponent)"), "the queued poll announced the old song after the command")
        #expect(!rig.fake.actions.dropFirst(before).contains("Seek"), "the queued poll sent the old song's seek after the command")
        if select { #expect(rig.playback.snapshot.item?.id == chosen.id) } else { #expect(!rig.playback.wantsPlaying) }
    }

    // MARK: After the sixth review (2026-11-23): a stale poll that finds the player lost, and events that arrive after a command

    @Test("A poll that fails for the last time before the player counts as lost, while a song chosen waits behind it: the chosen song plays (not paused), and nothing is lost")
    func lostPollQueuedBeforeSelection() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready, lostAfter: 1)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        // The player stops answering: three polls fail well within `lostAfter`; the next one is held on its way, decided to fail.
        let since = Date()
        rig.transport.failsStatus.withLock { $0 = true }
        #expect(await within(0.8) { rig.transport.statusFailed.withLock { $0 } >= 3 })
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(0.8) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        #expect(Date().timeIntervalSince(since) < 1, "the machine was too slow to hold a poll before the player counted as lost")
        // Past `lostAfter` while it waits; a song is chosen, and the player answers again. The held poll fails, the last one.
        try await Task.sleep(for: .milliseconds(max(0, Int((1.3 - Date().timeIntervalSince(since)) * 1000))))
        let failed = rig.transport.statusFailed.withLock { $0 }
        rig.playback.play(chosen)
        rig.transport.failsStatus.withLock { $0 = false }
        rig.transport.statusHeld.withLock { $0 = false }
        #expect(await within(2) { rig.transport.statusFailed.withLock { $0 } > failed }, "the held poll didn't fail")
        #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("lost") }, "the stale poll reported the player lost after the selection")
        #expect(rig.playback.wantsPlaying)
        #expect(rig.playback.snapshot.item?.id == chosen.id)
        #expect(rig.playback.snapshot.state == .playing)
        #expect(rig.playback.isEngaged)
    }

    @Test("The start timeout fails a song, and Stop or Play again comes while the player is being stopped: the old failure isn't reported",
          arguments: [false, true])
    func timeoutFailureOvertakenDuringStop(retry: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready, startTimeout: 0.5)
        defer { rig.close() }
        rig.fake.ignoresPlay = true
        rig.transport.stopHeld.withLock { $0 = true }
        rig.playback.play(rig.first)
        // The poll past the timeout has failed the song and waits for the player to stop.
        #expect(await within(3) { rig.transport.stopWaiting.withLock { $0 } > 0 })
        #expect(rig.playback.snapshot.lastError != nil)
        if retry {
            rig.fake.ignoresPlay = false
            rig.playback.play(rig.first)
        } else {
            rig.playback.stop()
        }
        rig.transport.stopHeld.withLock { $0 = false }
        if retry {
            #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)", timeout: 5), "the song played again didn't start")
        } else {
            #expect(await within(3) { rig.fake.actions.filter { $0 == "Stop" }.count >= 2 })
        }
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("failed") }, "the old song's failure was reported after the command")
        #expect(rig.playback.snapshot.lastError == nil)
        #expect(rig.playback.wantsPlaying == retry)
    }

    @Test("The start timeout fails a song, and Stop or Play again comes before the failure reaches the main actor: it isn't delivered",
          arguments: [false, true])
    func timeoutFailureOvertakenBeforeDelivery(retry: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready, startTimeout: 0.5)
        defer { rig.close() }
        rig.fake.ignoresPlay = true
        rig.playback.play(rig.first)
        #expect(await within(3) { rig.fake.actions.contains("Play") })
        // The main actor is busy until the failure has been sent its way (the player stopped by the timeout); the command
        // is given there, as the app gives it, before the failure is delivered.
        let stops = rig.fake.actions.filter { $0 == "Stop" }.count
        let seen = await MainActor.run { () -> Bool in
            let deadline = Date().addingTimeInterval(3)
            while rig.fake.actions.filter({ $0 == "Stop" }).count == stops, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.2)
            let seen = rig.playback.snapshot.lastError != nil
            if retry {
                rig.fake.ignoresPlay = false
                rig.playback.play(rig.first)
            } else {
                rig.playback.stop()
            }
            return seen
        }
        #expect(seen, "the start timeout didn't fail the song")
        if retry {
            #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)", timeout: 5), "the song played again didn't start")
        }
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("failed") }, "the old song's failure was delivered after the command")
        #expect(rig.playback.wantsPlaying == retry)
    }

    @Test("A song is announced as started, and Stop comes before the announcement reaches the main actor: it isn't delivered")
    func announcementOvertakenBeforeDelivery() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let polls = rig.fake.actions.filter { $0 == "GetTransportInfo" }.count
        let stopped = await MainActor.run { () -> Bool in
            rig.playback.play(rig.first)
            // The player plays, and a few polls have seen it (the first of them announced the song): Stop is pressed.
            let deadline = Date().addingTimeInterval(3)
            while rig.fake.transportState != "Playing", Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let playing = rig.fake.actions.filter { $0 == "GetTransportInfo" }.count
            while rig.fake.actions.filter({ $0 == "GetTransportInfo" }).count < max(polls, playing) + 3, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            rig.playback.stop()
            return rig.fake.transportState == "Playing"
        }
        #expect(stopped, "the player never played")
        #expect(await within(3) { rig.fake.transportState == "Stopped" })
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains("started \(rig.first.url.lastPathComponent)"), "the song was announced after Stop")
        #expect(!rig.playback.wantsPlaying)
    }

    // MARK: After vtsonos10 (2026-11-23): a start's own failure, and the pending seek given up, after a command

    @Test("The player refuses the song, and Stop or Play again comes while the load is on its way: the old failure isn't reported, and the song played again plays (not paused)",
          arguments: [false, true])
    func loadFailureOvertaken(retry: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        // The load is held on its way, decided to fail; the command is given meanwhile, and the next load succeeds.
        rig.transport.failsLoad.withLock { $0 = true }
        rig.transport.held.withLock { $0 = true }
        rig.playback.play(rig.first)
        #expect(await within(3) { rig.transport.loadsAsked.withLock { $0 } > 0 })
        rig.transport.failsLoad.withLock { $0 = false }
        if retry { rig.playback.play(rig.first) } else { rig.playback.stop() }
        rig.transport.held.withLock { $0 = false }
        if retry {
            #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)", timeout: 5), "the song played again didn't start")
        } else {
            #expect(await within(3) { rig.fake.actions.contains("Stop") })
        }
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("failed") }, "the refused load's failure was reported after the command")
        #expect(rig.playback.snapshot.lastError == nil)
        #expect(rig.playback.wantsPlaying == retry)
        if retry { #expect(rig.playback.snapshot.state == .playing) }
    }

    @Test("A song that can't be prepared fails, and Stop or Play again comes before the failure reaches the main actor: it isn't delivered",
          arguments: [false, true])
    func preparationFailureOvertakenBeforeDelivery(retry: Bool) async throws {
        // The song converted for Sonos: its stream can't be made.
        let rig = try await Rig.make()
        defer { rig.close() }
        rig.maker.fails = true
        let seen = await MainActor.run { () -> Bool in
            rig.playback.play(rig.stuck)
            // The main actor is busy until the song has been failed (and the failure sent its way); the command is given
            // there, as the app gives it, before the failure is delivered.
            let deadline = Date().addingTimeInterval(3)
            while rig.playback.snapshot.lastError == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.1)
            let seen = rig.playback.snapshot.lastError != nil
            if retry { rig.playback.play(rig.first) } else { rig.playback.stop() }
            return seen
        }
        #expect(seen, "the song wasn't failed")
        if retry {
            #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)", timeout: 5), "the song chosen didn't start")
        }
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("failed") }, "the old song's failure was delivered after the command")
        #expect(rig.playback.wantsPlaying == retry)
    }

    @Test("A song started part-way in whose seek the player keeps refusing: the listener is told the seek was given up")
    func seekGivenUpReported() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.transport.failsSeek.withLock { $0 = true }
        rig.playback.play(rig.first, at: 1)
        #expect(await rig.events.wait(for: "notice", timeout: 5), "the seek given up wasn't reported")
        #expect(rig.transport.seekFailed.withLock { $0 } == 5)
    }

    @Test("The seek of a song started part-way in is given up, and Stop comes before the notice reaches the main actor: it isn't delivered")
    func seekGivenUpOvertakenBeforeDelivery() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.transport.failsSeek.withLock { $0 = true }
        let gaveUp = await MainActor.run { () -> Bool in
            rig.playback.play(rig.first, at: 1)
            // The main actor is busy until the fifth try has failed (the notice sent its way); Stop is pressed there.
            let deadline = Date().addingTimeInterval(5)
            while rig.transport.seekFailed.withLock({ $0 }) < 5, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.2)
            rig.playback.stop()
            return rig.transport.seekFailed.withLock { $0 } >= 5
        }
        #expect(gaveUp, "the seek wasn't given up")
        #expect(await within(3) { rig.fake.transportState == "Stopped" })
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.events.all.contains { $0.hasPrefix("notice") }, "the seek given up was reported after Stop")
        #expect(!rig.playback.wantsPlaying)
    }

    // MARK: After the seventh review (2026-11-23): a seek queued before a command, and a pending seek after the player moves on

    @Test("A seek in a processed stream, queued before a song chosen or a Stop: the song chosen plays, or the Stop holds; the old song isn't started again",
          arguments: [false, true])
    func processedSeekQueuedBeforeCommand(select: Bool) async throws {
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make()
        defer { rig.close() }
        // The song converted for Sonos is offered as its stream grows (never written whole here): the player can't seek
        // in it, so a seek starts it again at the position.
        rig.playback.wholeFileWait = 0
        rig.playback.play(rig.stuck)
        #expect(await rig.events.wait(for: "started \(rig.stuck.url.lastPathComponent)"))
        await rig.playback.settleForTests()
        let streams = rig.maker.begun
        let loads = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.count
        // The worker is held in a poll; the seek, and then the command, are queued behind it.
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.playback.seek(to: 0.5)
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
        }
        try await Task.sleep(for: .milliseconds(500))
        await rig.playback.settleForTests()
        #expect(rig.maker.begun == streams, "the old song's stream was made again for the seek, after the command")
        let loaded = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.dropFirst(loads).map { $0.arguments["CurrentURI"] ?? "" }
        #expect(loaded.count == (select ? 1 : 0), "loaded after the command: \(loaded)")
        if select {
            #expect(rig.playback.snapshot.item?.id == chosen.id)
            #expect(rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.state == .playing)
        } else {
            #expect(!rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.item == nil)
            #expect(!rig.playback.isEngaged)
        }
    }

    @Test("A song started part-way in whose seek failed, and the player goes on to the next song by itself: the next song isn't seeked to the old position")
    func pendingSeekNotCarriedToNextSong() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        // The first song is started at 1 s and holds back from playing until the next song has been handed to the player.
        rig.fake.ignoresPlay = true
        rig.transport.failsSeek.withLock { $0 = true }
        rig.transport.holdsStatusAfterFailedSeek.withLock { $0 = true }
        rig.playback.play(rig.first, at: 1)
        #expect(await within(5) { rig.fake.nextURI != nil }, "the next song wasn't handed over")
        await rig.playback.settleForTests()
        #expect(rig.transport.seekFailed.withLock { $0 } == 0)
        // It plays: the pending seek fails once, and the poll after it is held.
        rig.fake.ignoresPlay = false
        rig.fake.playOnDevice()
        #expect(await within(3) { rig.transport.statusWaiting.withLock { $0 } > 0 }, "the pending seek wasn't tried")
        #expect(rig.transport.seekFailed.withLock { $0 } == 1)
        // The player would take a seek now, and goes on to the next song by itself.
        rig.transport.failsSeek.withLock { $0 = false }
        let before = rig.fake.actions.count
        rig.fake.advance()
        rig.transport.statusHeld.withLock { $0 = false }
        #expect(await rig.events.wait(for: "started \(ready.url.lastPathComponent)", timeout: 5), "the next song wasn't followed")
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(!rig.fake.actions.dropFirst(before).contains("Seek"), "the next song was seeked to the old song's position")
        #expect(!rig.events.all.contains { $0.hasPrefix("notice") })
    }

    // MARK: After the eighth review (2026-11-23): a change of settings queued before a command, and a seek after a pending one

    @Test("A change of settings that restarts the song, queued before a song chosen or a Stop: the song chosen plays, or the Stop holds; the old song isn't started again, and the settings still apply",
          arguments: [false, true])
    func settingsRestartQueuedBeforeCommand(select: Bool) async throws {
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make()
        defer { rig.close() }
        // The song converted for Sonos: any change of settings starts it again where it is.
        rig.playback.wholeFileWait = 0
        rig.playback.play(rig.stuck)
        #expect(await rig.events.wait(for: "started \(rig.stuck.url.lastPathComponent)"))
        await rig.playback.settleForTests()
        let streams = rig.maker.begun
        let loads = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.count
        // The worker is held in a poll; the change of settings (a volume, which every song is then processed for), and then
        // the command, are queued behind it.
        let quieter = RendererSettings(digitalVolumeDB: -6)
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.playback.queueSettingsForTests(quieter)
        if select { rig.playback.play(chosen) } else { rig.playback.stop() }
        rig.transport.statusHeld.withLock { $0 = false }
        if select {
            #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        } else {
            #expect(await within(3) { rig.fake.transportState == "Stopped" })
        }
        try await Task.sleep(for: .milliseconds(500))
        await rig.playback.settleForTests()
        let loaded = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.dropFirst(loads).map { $0.arguments["CurrentURI"] ?? "" }
        #expect(loaded.count == (select ? 1 : 0), "loaded after the command: \(loaded)")
        if select {
            // Only the chosen song's stream was made since, with the new settings.
            #expect(rig.maker.begun == streams + 1, "the old song's stream was made again for the settings, after the command")
            #expect(rig.maker.settingsAsked.last == quieter, "the chosen song wasn't made with the new settings")
            #expect(rig.playback.snapshot.item?.id == chosen.id)
            #expect(rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.state == .playing)
        } else {
            #expect(rig.maker.begun == streams, "the old song's stream was made again for the settings, after the Stop")
            #expect(!rig.playback.wantsPlaying)
            #expect(rig.playback.snapshot.item == nil)
            #expect(!rig.playback.isEngaged)
            // The settings were kept all the same: the next song played is made with them.
            rig.playback.play(chosen)
            #expect(await within(5) { rig.maker.begun > streams }, "the song played after the Stop wasn't processed")
            #expect(rig.maker.settingsAsked.last == quieter, "the settings given before the Stop were lost")
        }
    }

    @Test("A song started part-way in, seeked by the listener before the player played it: the seek asked for holds, the start's position isn't sent after it")
    func explicitSeekClearsPendingSeek() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        // No polls but the ones this test steps: the start's own seek (30 s) is still pending when the listener seeks.
        let rig = try await Rig.make(second: ready, pollInterval: 0)
        defer { rig.close() }
        rig.playback.play(rig.first, at: 30)
        #expect(await within(5) { rig.playback.isEngaged && rig.fake.transportState == "Playing" }, "the song wasn't loaded")
        let before = rig.fake.calls.filter { $0.action == "Seek" }.count
        rig.playback.seek(to: 60)
        await rig.playback.settleForTests()
        await rig.playback.settleForTests()
        let targets = rig.fake.calls.filter { $0.action == "Seek" }.dropFirst(before).map { DIDLLite.seconds($0.arguments["Target"]).map { Int($0) } ?? -1 }
        #expect(targets == [60], "seeks sent: \(targets)")
        let position = rig.playback.snapshot.position
        #expect(position >= 59.5 && position < 62, "position \(position)")
    }

    // MARK: After the ninth review (2026-11-23): a refused resume put right after a song chosen, and a next song prepared before a change of settings

    @Test("A resume the player refuses twice, and a song chosen while the status asked for to put it right is on its way: the song chosen plays (not paused by the old song's state), and the old refusal isn't reported")
    func staleResumeResyncAfterSelection() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let chosen = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 9)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        rig.playback.pause()
        #expect(await within(2) { rig.fake.transportState == "Paused" })
        await rig.playback.settleForTests()
        // The player refuses Play now; the status asked for after the second refusal (to put the snapshot right) is held.
        let waits = rig.transport.statusWaiting.withLock { $0 }
        rig.transport.failsPlay.withLock { $0 = true }
        rig.transport.holdsStatusAfterFailedPlay.withLock { $0 = true }
        rig.playback.resume()
        #expect(await within(3) { rig.transport.statusWaiting.withLock { $0 } > waits }, "the refused resume didn't ask for the status")
        #expect(rig.transport.playFailed.withLock { $0 } == 2)
        // A song is chosen while that status is on its way; it answers with the old song, paused.
        rig.playback.play(chosen)
        rig.transport.failsPlay.withLock { $0 = false }
        rig.transport.statusHeld.withLock { $0 = false }
        #expect(await rig.events.wait(for: "started \(chosen.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        try await Task.sleep(for: .milliseconds(300))
        await rig.playback.settleForTests()
        #expect(rig.playback.wantsPlaying, "the old song's paused state was applied after the song chosen")
        #expect(rig.playback.snapshot.item?.id == chosen.id)
        #expect(rig.playback.snapshot.state == .playing)
        #expect(rig.fake.transportState == "Playing", "the song chosen was paused on the player")
        #expect(!rig.events.all.contains { $0.hasPrefix("notice") }, "the refused resume of the old song was reported after the song chosen")
    }

    @Test("The next song prepared with the old settings, then a change of settings queued before it is chosen: it is made again with the new settings, not played as prepared")
    func preparedNextRebuiltForNewSettings() async throws {
        let rig = try await Rig.make()
        defer { rig.close() }
        // The song converted for Sonos is offered as its stream grows: prepared as the next song at once.
        rig.playback.wholeFileWait = 0
        rig.playback.play(rig.first)
        #expect(await rig.events.wait(for: "started \(rig.first.url.lastPathComponent)"))
        #expect(await within(5) { rig.fake.nextURI != nil }, "the next song wasn't handed over")
        await rig.playback.settleForTests()
        let prepared = try #require(rig.fake.nextURI)
        #expect(rig.maker.settingsAsked(for: rig.stuck) == [RendererSettings()])
        let loads = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.count
        // The worker is held in a poll; the change of settings, then the song prepared as next chosen, are queued behind it.
        let quieter = RendererSettings(digitalVolumeDB: -6)
        rig.transport.statusHeld.withLock { $0 = true }
        #expect(await within(2) { rig.transport.statusWaiting.withLock { $0 } > 0 })
        rig.playback.queueSettingsForTests(quieter)
        rig.playback.play(rig.stuck)
        rig.transport.statusHeld.withLock { $0 = false }
        #expect(await rig.events.wait(for: "started \(rig.stuck.url.lastPathComponent)", timeout: 5), "the song chosen didn't play")
        await rig.playback.settleForTests()
        #expect(rig.maker.settingsAsked(for: rig.stuck) == [RendererSettings(), quieter], "the song chosen wasn't made again with the new settings")
        let loaded = rig.fake.calls.filter { $0.action == "SetAVTransportURI" }.dropFirst(loads).map { $0.arguments["CurrentURI"] ?? "" }
        #expect(loaded.count == 1 && loaded.first != prepared, "the stream prepared with the old settings was loaded: \(loaded)")
        #expect(rig.playback.snapshot.signalPath?.volume == .digital(dB: -6), "volume \(String(describing: rig.playback.snapshot.signalPath?.volume))")
    }

    @Test("The player goes on to the old next song between a poll's answer and the clear's success: it is still recognised and put right")
    func advanceBeforeClearCompletes() async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        let old = try await playerRefusedClear(rig, queue: [rig.first, rig.third])
        // The clear tried again by a poll (after its status answer said the first song) reaches the player only after it
        // has gone on to the old next song, and then succeeds.
        let fake = rig.fake
        rig.transport.beforeReplaceNext.withLock { $0 = { fake.advance(); fake.succeed("SetNextAVTransportURI") } }
        #expect(await within(4) { rig.transport.beforeReplaceNext.withLock { $0 == nil } }, "the clear wasn't tried again")
        #expect(await rig.events.wait(for: "started \(rig.third.url.lastPathComponent)", timeout: 5), "the player plays the old next song on")
        #expect(rig.fake.currentURI != old)
        #expect(!rig.events.all.contains("started \(ready.url.lastPathComponent)"), "the song no longer next was announced")
    }

    @Test("A clear refused every time: tried ten more times, then only watched; the song is kept, and a stop or a shutdown lets go of it once",
          arguments: [false, true])
    func staleClearExhausted(shutdown: Bool) async throws {
        let ready = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 7)))
        let rig = try await Rig.make(second: ready)
        defer { rig.close() }
        rig.playback.staleClearSpacing = 0.05
        let old = try await playerRefusedClear(rig, queue: [rig.first])
        let clears = { rig.fake.calls.filter { $0.action == "SetNextAVTransportURI" && ($0.arguments["NextURI"] ?? "").isEmpty }.count }
        // The first song's load sent one empty NextURI; then the clear that failed, and the tries again.
        let expected = 1 + 1 + RendererPlayback.staleClearAttempts
        #expect(await within(5) { clears() >= expected })
        // A while longer: no more tries.
        try await Task.sleep(for: .milliseconds(600))
        await rig.playback.settleForTests()
        #expect(clears() == expected)
        #expect(rig.playback.heldNextURIsForTests.contains(old), "let go of while the player may still go on to it")
        #expect(rig.playback.releasesForTests(old) == 0)
        #expect(rig.media.tokens.contains(URL(string: old)!.deletingPathExtension().lastPathComponent))
        if shutdown { rig.playback.stopAndWait(timeout: 5) } else { rig.playback.stop(); await rig.playback.settleForTests() }
        #expect(rig.playback.heldNextURIsForTests.isEmpty)
        #expect(rig.playback.releasesForTests(old) == 1)
        // A shutdown after the stop lets go of nothing a second time.
        rig.playback.stopAndWait(timeout: 5)
        #expect(rig.playback.releasesForTests(old) == 1)
    }
}
