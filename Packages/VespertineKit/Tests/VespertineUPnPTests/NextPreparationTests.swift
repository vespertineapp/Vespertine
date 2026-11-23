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

    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat) {
        let file = try GrowingFile(url: directory.appendingPathComponent(UUID().uuidString + ".flac"))
        lock.withLock { made.append(file) }
        return (file, SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 2))
    }
}

private struct Rig {
    let fake: FakeRenderer
    let media: MediaServer
    let playback: RendererPlayback
    let maker: StuckStreamMaker
    let events: EventLog
    /// Plays as the file (24/48 FLAC), then one that must be converted for Sonos (96 kHz), then another file.
    let first: PlayableItem, stuck: PlayableItem, third: PlayableItem

    static func make() async throws -> Rig {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_BAR01400_MR")
        fake.sonosRoom = "Living Room"
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        let media = MediaServer()
        try await media.start()
        let device = try await RendererDevice.load(location: fake.location)
        let maker = StuckStreamMaker()
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media, processed: maker, pollInterval: 0.05)
        // Long enough that a worker held by it would fail every check below; short enough not to hold the run up for long.
        playback.wholeFileWait = 30
        let first = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 3)))
        let stuck = PlayableItem(url: try makeWAV(seconds: 1, rate: 96_000, seed: 4))
        let third = PlayableItem(url: try makeFLAC(from: try makeWAV(seconds: 2, seed: 5)))
        let queue = [first, stuck, third]
        playback.nextItemProvider = { item in queue.firstIndex { $0.id == item.id }.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil } }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        return Rig(fake: fake, media: media, playback: playback, maker: maker, events: events, first: first, stuck: stuck, third: third)
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
}
