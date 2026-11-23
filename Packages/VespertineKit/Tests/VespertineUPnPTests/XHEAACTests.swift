//
// Vespertine: an xHE-AAC (USAC) song in an M4A is named as such by the probe itself, so a Sonos, which takes AAC in an M4A
// but not xHE-AAC, gets it decoded and sent as FLAC with the codec named, not the file as it is.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

@Suite("xHE-AAC to a Sonos", .serialized)
struct XHEAACTests {
    /// The engine tests' real xHE-AAC file (encoded with Apple's xHE-AAC encoder; see their Fixtures/README.md).
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VespertineAudioTests/Fixtures/Formats/xhe-stereo.m4a")

    /// Core Audio's USAC decoder is the system's: a runner without it can't open the file at all (as in the engine's tests).
    static let systemDecodesXHE: Bool = (try? AVAudioFile(forReading: fixture)) != nil

    @Test("The probe names an xHE-AAC file's codec, and Sonos's table then converts it", .enabled(if: XHEAACTests.systemDecodesXHE))
    func probedAndPlanned() throws {
        let described = try SourceDescription.describe(PlayableItem(url: Self.fixture), url: Self.fixture)
        #expect(described.format.codec == "xHE-AAC")
        #expect(described.format.encoding == .lossy)
        let plan = StreamNegotiation.plan(source: described.format, mime: MediaType.mime(forExtension: "m4a"), limits: .sonos)
        #expect(!plan.original)
        #expect(plan.changes.contains(.repacked(from: "xHE-AAC")))
    }

    @Test("Played to a Sonos, an xHE-AAC file goes as FLAC, not as the file", .enabled(if: XHEAACTests.systemDecodesXHE))
    func playedAsFLAC() async throws {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_XHE01400_MR")
        fake.sonosRoom = "Study"
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        let media = MediaServer()
        try await media.start()
        defer { media.stop(); fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media,
                                        processed: ProcessedStreamMaker(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")),
                                        pollInterval: 0.05)
        defer { playback.shutdown() }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        playback.play(PlayableItem(url: Self.fixture))
        #expect(await events.wait(for: "started"))
        let uri = try #require(fake.currentURI)
        let bytes = try #require(await fake.fetched(uri))
        #expect(bytes != (try Data(contentsOf: Self.fixture)))
        let path = try #require(playback.snapshot.signalPath)
        #expect(path.renderer?.sentCodec == "FLAC")
        #expect(path.renderer?.passesThrough == false)
        #expect(path.source.codec == "xHE-AAC")
    }
}
