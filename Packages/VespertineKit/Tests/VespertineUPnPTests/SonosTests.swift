//
// Vespertine: Sonos among the network players: what a song is sent as (the table), how the system's rooms are read, which
// speakers are outputs, and a song past the limits played to a pretend Sonos on 127.0.0.1. Nothing here needs a real one.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

/// 24-bit stereo WAV at any rate, as `makeWAV` writes it.
private func source(_ rate: Double, bits: Int? = 24, channels: Int = 2, codec: String = "FLAC", encoding: SourceFormat.Encoding = .pcm) -> SourceFormat {
    SourceFormat(encoding: encoding, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
}

@Suite("What a song is sent as to a player with limits")
struct StreamNegotiationTests {
    @Test("A rate the player takes stays; a higher one goes to the highest rate that divides it exactly",
          arguments: [(44_100.0, 44_100.0), (48_000, 48_000), (32_000, 32_000), (88_200, 44_100), (96_000, 48_000), (176_400, 44_100),
                      (192_000, 48_000), (352_800, 44_100), (384_000, 48_000), (64_000, 48_000)])
    func rates(sourceRate: Double, sent: Double) {
        #expect(StreamNegotiation.rate(for: sourceRate, max: 48_000) == sent)
    }

    @Test("A player that takes 96 kHz gets 192 kHz at 96 and 176.4 kHz at 88.2")
    func ratesUnderAHigherLimit() {
        #expect(StreamNegotiation.rate(for: 192_000, max: 96_000) == 96_000)
        #expect(StreamNegotiation.rate(for: 176_400, max: 96_000) == 88_200)
        #expect(StreamNegotiation.rate(for: 96_000, max: 96_000) == 96_000)
    }

    /// (source, the file's type, sent as the original, rate, bits, channels, what was done)
    static let table: [(SourceFormat, String?, Bool, Double, Int?, Int, [StreamChange])] = [
        // What Sonos plays as it is.
        (source(44_100, bits: 16), "audio/flac", true, 44_100, 16, 2, []),
        (source(48_000), "audio/flac", true, 48_000, 24, 2, []),
        (source(48_000, codec: "ALAC"), "audio/mp4", true, 48_000, 24, 2, []),
        (source(44_100, bits: 16, codec: "WAV"), "audio/wav", true, 44_100, 16, 2, []),
        (source(44_100, bits: 16, codec: "AIFF"), "audio/aiff", true, 44_100, 16, 2, []),
        (source(44_100, bits: 16, channels: 1), "audio/flac", true, 44_100, 16, 1, []),
        (source(44_100, bits: nil, codec: "MP3", encoding: .lossy), "audio/mpeg", true, 44_100, nil, 2, []),
        (source(48_000, bits: nil, codec: "AAC", encoding: .lossy), "audio/mp4", true, 48_000, nil, 2, []),
        // Above 48 kHz: resampled, to the rate that divides the song's own.
        (source(96_000), "audio/flac", false, 48_000, 24, 2, [.resampled(from: 96_000, to: 48_000)]),
        (source(192_000), "audio/flac", false, 48_000, 24, 2, [.resampled(from: 192_000, to: 48_000)]),
        (source(88_200), "audio/flac", false, 44_100, 24, 2, [.resampled(from: 88_200, to: 44_100)]),
        (source(176_400, codec: "ALAC"), "audio/mp4", false, 44_100, 24, 2, [.resampled(from: 176_400, to: 44_100)]),
        // Surround: folded to stereo, and resampled as well when it is above 48 kHz.
        (source(48_000, channels: 6), "audio/flac", false, 48_000, 24, 2, [.downmixed(from: 6, to: 2)]),
        (source(96_000, channels: 6), "audio/flac", false, 48_000, 24, 2, [.resampled(from: 96_000, to: 48_000), .downmixed(from: 6, to: 2)]),
        (source(48_000, bits: nil, channels: 6, codec: "Dolby Atmos", encoding: .lossy), nil, false, 48_000, 24, 2, [.downmixed(from: 6, to: 2)]),
        (source(48_000, channels: 8, codec: "Dolby TrueHD"), nil, false, 48_000, 24, 2, [.downmixed(from: 8, to: 2)]),
        // DSD: PCM at 44.1 kHz (a multiple of every DSD rate).
        (source(2_822_400, bits: nil, codec: "DSF", encoding: .dsd), "audio/x-dsf", false, 44_100, 24, 2, [.dsdToPCM("DSD64")]),
        (source(11_289_600, bits: nil, codec: "DSF", encoding: .dsd), "audio/x-dsf", false, 44_100, 24, 2, [.dsdToPCM("DSD256")]),
        (source(2_822_400, bits: nil, channels: 6, codec: "DSF", encoding: .dsd), "audio/x-dsf", false, 44_100, 24, 2, [.dsdToPCM("DSD64"), .downmixed(from: 6, to: 2)]),
        // The same samples in a file Sonos doesn't read as it is: FLAC, nothing lost.
        (source(48_000, codec: "WAV"), "audio/wav", false, 48_000, 24, 2, [.repacked(from: "WAV")]),
        (source(44_100, codec: "AIFF"), "audio/aiff", false, 44_100, 24, 2, [.repacked(from: "AIFF")]),
        (source(44_100, bits: 16, codec: "APE"), "audio/x-ape", false, 44_100, 24, 2, [.repacked(from: "APE")]),
        (source(44_100, bits: 16, codec: "WavPack"), "audio/x-wavpack", false, 44_100, 24, 2, [.repacked(from: "WavPack")]),
        (source(48_000, bits: nil, codec: "Opus", encoding: .lossy), "audio/ogg", false, 48_000, 24, 2, [.repacked(from: "Ogg")]),
        // A track of a CUE sheet or a disc image has no file of its own to hand over.
        (source(44_100, bits: 16), nil, false, 44_100, 24, 2, [.repacked(from: "FLAC")]),
        // 32-bit: sent as 24-bit.
        (source(48_000, bits: 32, codec: "WAV"), "audio/wav", false, 48_000, 24, 2, [.wordLength(from: 32, to: 24)]),
    ]

    @Test("The Sonos table: the original when it fits, else 24-bit FLAC with every change named", arguments: table.indices)
    func sonosTable(row: Int) {
        let (format, mime, original, rate, bits, channels, changes) = Self.table[row]
        let plan = StreamNegotiation.plan(source: format, mime: mime, limits: .sonos)
        #expect(plan.original == original, "\(format)")
        #expect(plan.sampleRate == rate, "\(format)")
        #expect(plan.bitDepth == bits, "\(format)")
        #expect(plan.channels == channels, "\(format)")
        #expect(plan.changes == changes, "\(format)")
    }

    @Test("Putting the same samples in another file isn't a change to them; everything else is")
    func whatChangesTheSamples() {
        #expect(!StreamChange.repacked(from: "WAV").changesSamples)
        #expect(StreamChange.resampled(from: 96_000, to: 48_000).changesSamples)
        #expect(StreamChange.downmixed(from: 6, to: 2).changesSamples)
        #expect(StreamChange.dsdToPCM("DSD64").changesSamples)
        #expect(StreamChange.wordLength(from: 32, to: 24).changesSamples)
    }

    @Test("Every change has a sentence that names the player and both ends of the change")
    func sentences() {
        #expect(StreamChange.resampled(from: 192_000, to: 48_000).message(player: "Sonos") == "Sonos plays up to 48 kHz here, so this 192 kHz song is resampled to 48 kHz.")
        #expect(StreamChange.downmixed(from: 6, to: 2).message(player: "Sonos") == "Sonos takes two-channel music only, so this song's 6 channels are folded down to stereo.")
        #expect(StreamChange.dsdToPCM("DSD64").message(player: "Sonos") == "Sonos doesn't play DSD, so this DSD64 song is converted to PCM.")
    }

    @Test("With limits, a song past them is processed and the reasons say how; within them the original file still goes")
    func modeWithLimits() throws {
        let caps = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*,http-get:*:audio/wav:*,http-get:*:audio/mp4:*")
        let flac = PlayableItem(url: URL(fileURLWithPath: "/tmp/a.flac"))
        func decide(_ format: SourceFormat, _ item: PlayableItem = flac, settings: RendererSettings = .init()) -> RendererModeDecision {
            RendererMode.decide(item: item, url: item.url, source: format, settings: settings, capabilities: caps, limits: .sonos)
        }
        #expect(decide(source(44_100, bits: 16)) == .passThrough(mime: "audio/flac"))
        #expect(decide(source(48_000)) == .passThrough(mime: "audio/flac"))
        #expect(decide(source(192_000)) == .processed([.resampled]))
        #expect(decide(source(96_000, channels: 6)) == .processed([.resampled, .downmix]))
        #expect(decide(source(2_822_400, bits: nil, codec: "DSF", encoding: .dsd), PlayableItem(url: URL(fileURLWithPath: "/tmp/a.dsf"))) == .processed([.dsdToPCM]))
        #expect(decide(source(48_000, codec: "WAV"), PlayableItem(url: URL(fileURLWithPath: "/tmp/a.wav"))) == .processed([.format]))
        // The listener's own processing comes first, then what the player's limits add.
        #expect(decide(source(192_000), settings: .init(digitalVolumeDB: -6)) == .processed([.volume, .resampled]))
        // Without limits nothing changes for other players: the file goes as it is, whatever its rate.
        #expect(RendererMode.decide(item: flac, url: flac.url, source: source(192_000), settings: .init(), capabilities: caps) == .passThrough(mime: "audio/flac"))
    }
}

/// A Playbar with two Ones as surrounds and a Sub, a stereo pair in the kitchen grouped under it, and an office on its own.
let sonosHome = """
<ZoneGroupState><ZoneGroups>
<ZoneGroup Coordinator="RINCON_BAR01400" ID="RINCON_BAR01400:1">
<ZoneGroupMember UUID="RINCON_BAR01400" Location="http://192.168.1.20:1400/xml/device_description.xml" ZoneName="Living Room" HTSatChanMapSet="RINCON_BAR01400:LF,RF;RINCON_SUB01400:SW;RINCON_LS01400:LR;RINCON_RS01400:RR">
<Satellite UUID="RINCON_SUB01400" Location="http://192.168.1.21:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1" HTSatChanMapSet="RINCON_BAR01400:LF,RF;RINCON_SUB01400:SW"/>
<Satellite UUID="RINCON_LS01400" Location="http://192.168.1.22:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1" HTSatChanMapSet="RINCON_BAR01400:LF,RF;RINCON_LS01400:LR"/>
<Satellite UUID="RINCON_RS01400" Location="http://192.168.1.23:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1" HTSatChanMapSet="RINCON_BAR01400:LF,RF;RINCON_RS01400:RR"/>
</ZoneGroupMember>
<ZoneGroupMember UUID="RINCON_KL01400" Location="http://192.168.1.30:1400/xml/device_description.xml" ZoneName="Kitchen" ChannelMapSet="RINCON_KL01400:LF,LF;RINCON_KR01400:RF,RF"/>
<ZoneGroupMember UUID="RINCON_KR01400" Location="http://192.168.1.31:1400/xml/device_description.xml" ZoneName="Kitchen" Invisible="1" ChannelMapSet="RINCON_KL01400:LF,LF;RINCON_KR01400:RF,RF"/>
</ZoneGroup>
<ZoneGroup Coordinator="RINCON_OFF01400" ID="RINCON_OFF01400:7">
<ZoneGroupMember UUID="RINCON_OFF01400" Location="http://192.168.1.40:1400/xml/device_description.xml" ZoneName="Office"/>
</ZoneGroup>
</ZoneGroups><VanishedDevices></VanishedDevices></ZoneGroupState>
"""

@Suite("How a Sonos system's rooms are read")
struct SonosTopologyTests {
    @Test("A speaker's id is its UDN without the uuid: and the renderer's or server's ending; other players have none")
    func ids() {
        #expect(SonosTopology.uuid(udn: "uuid:RINCON_347E5C0CF1E401400_MR") == "RINCON_347E5C0CF1E401400")
        #expect(SonosTopology.uuid(udn: "uuid:RINCON_347E5C0CF1E401400_MS") == "RINCON_347E5C0CF1E401400")
        #expect(SonosTopology.uuid(udn: "uuid:RINCON_347E5C0CF1E401400") == "RINCON_347E5C0CF1E401400")
        #expect(SonosTopology.uuid(udn: "uuid:4d696e69-444c-164e-9d41-b827eb0a1b2c") == nil)
    }

    @Test("The soundbar is the room: 5.1 with its two surrounds and Sub, leading the group it is in")
    func homeTheater() throws {
        let topology = try #require(SonosTopology.parse(sonosHome))
        #expect(topology.groups.count == 2)
        let bar = try #require(topology.zone(uuid: "RINCON_BAR01400"))
        #expect(bar.isOutput)
        #expect(bar.isHomeTheater)
        #expect(bar.surrounds == 2)
        #expect(bar.hasSub)
        #expect(bar.speakerSetup == "5.1")
        #expect(bar.groupRooms == ["Living Room", "Kitchen"])
        #expect(bar.displayName == "Living Room + Kitchen")
        #expect(bar.isGroup)
    }

    @Test("Surrounds, the Sub, the second speaker of a pair and a room that follows another are not outputs")
    func parts() throws {
        let topology = try #require(SonosTopology.parse(sonosHome))
        for part in ["RINCON_SUB01400", "RINCON_LS01400", "RINCON_RS01400", "RINCON_KR01400"] {
            let zone = try #require(topology.zone(uuid: part))
            #expect(!zone.isRoom, "\(part)")
            #expect(!zone.isOutput, "\(part)")
        }
        let kitchen = try #require(topology.zone(uuid: "RINCON_KL01400"))
        #expect(kitchen.isRoom)
        #expect(kitchen.isStereoPair)
        #expect(!kitchen.isCoordinator)
        #expect(!kitchen.isOutput)
        let office = try #require(topology.zone(uuid: "RINCON_OFF01400"))
        #expect(office.isOutput)
        #expect(office.displayName == "Office")
        #expect(office.speakerSetup == nil)
        #expect(!office.isGroup)
        #expect(topology.zone(uuid: "RINCON_NOBODY") == nil)
    }

    @Test("A soundbar with surrounds and no Sub is 5.0; an answer with no group in it isn't an arrangement")
    func withoutSub() throws {
        let xml = """
        <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:1">
        <ZoneGroupMember UUID="RINCON_A" ZoneName="Den" HTSatChanMapSet="RINCON_A:LF,RF;RINCON_B:LR;RINCON_C:RR">
        <Satellite UUID="RINCON_B" ZoneName="Den" Invisible="1"/><Satellite UUID="RINCON_C" ZoneName="Den" Invisible="1"/>
        </ZoneGroupMember></ZoneGroup></ZoneGroups></ZoneGroupState>
        """
        let den = try #require(SonosTopology.parse(xml)?.zone(uuid: "RINCON_A"))
        #expect(den.speakerSetup == "5.0")
        #expect(den.displayName == "Den")
        #expect(SonosTopology.parse("<ZoneGroupState><ZoneGroups></ZoneGroups></ZoneGroupState>") == nil)
        #expect(SonosTopology.parse("not xml") == nil)
    }
}

@Suite("A Sonos on the network", .serialized)
struct SonosPlayerTests {
    /// A pretend Playbar whose system is `state` with its own id put in for RINCON_BAR01400.
    private func playbar(room: String = "Living Room", state: String = sonosHome) async throws -> FakeRenderer {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_BAR01400_MR")
        fake.sonosRoom = room
        fake.zoneGroupState = state
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        return fake
    }

    @Test("Its description gives the room's name, the speaker's model, the renderer's services and the system's arrangement service")
    func description() async throws {
        let fake = try await playbar()
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.isSonos)
        #expect(device.name == "Living Room")
        #expect(device.description.modelName == "Sonos Playbar")
        #expect(device.description.udn == "uuid:RINCON_BAR01400_MR")
        #expect(device.kind == .av(gapless: true))
        #expect(device.description.service(.zoneGroupTopology) != nil)
        #expect(device.description.service(.groupRenderingControl) != nil)
        #expect(device.limits == .sonos)
        // Any other player has no limits of Vespertine's making.
        let other = try await FakeRenderer(kind: .av(setNext: true))
        defer { other.stop() }
        let plain = try await RendererDevice.load(location: other.location)
        #expect(!plain.isSonos)
        #expect(plain.limits == nil)
        #expect(plain.makeVolume() == nil)
    }

    @Test("A search lists the room once, by the rooms playing together, and leaves out its surrounds and Sub")
    func discovery() async throws {
        let bar = try await playbar()
        let surround = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_LS01400_MR")
        surround.sonosRoom = "Living Room"
        surround.sonosModel = "Sonos One"
        surround.zoneGroupState = sonosHome
        defer { bar.stop(); surround.stop() }
        // Each speaker answers three times: as itself, as its renderer, as its media server.
        func replies(_ fake: FakeRenderer, _ id: String) -> [SSDPResponse] {
            [("uuid:\(id)", "urn:schemas-upnp-org:device:ZonePlayer:1"), ("uuid:\(id)_MR", "urn:schemas-upnp-org:device:MediaRenderer:1"),
             ("uuid:\(id)_MS", "urn:schemas-upnp-org:device:MediaServer:1")].map {
                SSDPResponse(location: fake.location, st: $0.1, usn: "\($0.0)::\($0.1)", udn: $0.0, responder: "127.0.0.1")
            }
        }
        let searcher = CountingSearcher(replies: replies(bar, "RINCON_BAR01400") + replies(surround, "RINCON_LS01400"))
        let discovery = RendererDiscovery(searcher: searcher)
        discovery.start()
        defer { discovery.stop() }
        await firstSearchDone(discovery)
        let found = discovery.renderers
        #expect(found.map(\.name) == ["Living Room + Kitchen"])
        #expect(found.first?.uid == "upnp:uuid:RINCON_BAR01400_MR")
        #expect(found.first?.sonos?.speakerSetup == "5.1")
        // Ungrouped from the Sonos app: the next search names it by its own room again.
        bar.zoneGroupState = sonosHome.replacingOccurrences(of: "<ZoneGroupMember UUID=\"RINCON_KL01400\"", with: "</ZoneGroup><ZoneGroup Coordinator=\"RINCON_KL01400\" ID=\"x\"><ZoneGroupMember UUID=\"RINCON_KL01400\"")
        surround.zoneGroupState = bar.zoneGroupState
        await discovery.searchOnce()
        #expect(discovery.renderers.map(\.name) == ["Living Room"])
    }

    @Test("A system that doesn't say how it is arranged keeps every speaker listed, by its room")
    func noTopology() async throws {
        let bar = try await playbar(state: "")
        defer { bar.stop() }
        let searcher = CountingSearcher(replies: [SSDPResponse(location: bar.location, st: "", usn: "uuid:RINCON_BAR01400::x", udn: "uuid:RINCON_BAR01400", responder: "127.0.0.1")])
        let discovery = RendererDiscovery(searcher: searcher)
        discovery.start()
        defer { discovery.stop() }
        await firstSearchDone(discovery)
        #expect(discovery.renderers.map(\.name) == ["Living Room"])
        #expect(discovery.renderers.first?.sonos == nil)
    }

    @Test("Its volume is set on the room, or on the whole group when several rooms play together; the samples aren't touched")
    func volume() async throws {
        let fake = try await playbar()
        defer { fake.stop() }
        var device = try await RendererDevice.load(location: fake.location)
        let room = try #require(device.makeVolume())
        #expect(try await room.volume() == 20)
        try await room.setVolume(35)
        #expect(fake.volume == 35)
        try await room.setVolume(140)
        #expect(fake.volume == 100)
        try await room.setMuted(true)
        #expect(try await room.isMuted())
        #expect(fake.calls.contains { $0.service == "RenderingControl" && $0.action == "SetVolume" && $0.arguments["Channel"] == "Master" })
        device.sonos = SonosTopology.parse(sonosHome)?.zone(uuid: "RINCON_BAR01400")
        let group = try #require(device.makeVolume())
        try await group.setVolume(12)
        #expect(fake.volume == 12)
        #expect(fake.actions.suffix(2) == ["SnapshotGroupVolume", "SetGroupVolume"])
    }

    @Test("A 24-bit / 96 kHz song goes to it as a whole 24-bit / 48 kHz FLAC with its length, and the path says what was done")
    func aboveItsLimits() async throws {
        let fake = try await playbar()
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
        let wav = try makeWAV(seconds: 1, rate: 96_000, seed: 2)
        playback.play(PlayableItem(url: wav))
        #expect(await events.wait(for: "started"))
        let uri = try #require(fake.currentURI)
        #expect(uri.hasSuffix(".flac"))
        // The stream was whole when it was offered: a length and ranges, as for a file, not a chunked stream.
        var head = URLRequest(url: try #require(URL(string: uri)))
        head.httpMethod = "HEAD"
        let (_, answer) = try await URLSession.shared.data(for: head)
        let response = try #require(answer as? HTTPURLResponse)
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect((Int(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) > 1000)
        // What it holds: 24-bit stereo at 48 kHz, half the frames of the source.
        let bytes = try #require(await fake.fetched(uri))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString).flac")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let described = try SourceDescription.describe(PlayableItem(url: copy), url: copy)
        #expect(described.format.sampleRate == 48_000)
        #expect(described.format.bitDepth == 24)
        #expect(described.format.channels == 2)
        let frames = try flacSamples(copy).count / 2
        #expect(abs(frames - 48_000) <= 64)
        // The song's metadata says the same, with the stream's size.
        let set = try #require(fake.calls.last { $0.action == "SetAVTransportURI" })
        let didl = try #require(set.arguments["CurrentURIMetaData"])
        #expect(didl.contains("sampleFrequency=\"48000\""))
        #expect(didl.contains("bitsPerSample=\"24\""))
        #expect(didl.contains("protocolInfo=\"http-get:*:audio/flac:*\""))
        #expect(didl.contains("size=\"\(bytes.count)\""))
        #expect(didl.contains("object.item.audioItem.musicTrack"))
        // And the signal path: resampled, 24/48 sent, with the reason in a sentence.
        let path = try #require(playback.snapshot.signalPath)
        #expect(path.renderer?.processing == [.resampled])
        #expect(path.renderer?.sentSampleRate == 48_000)
        #expect(path.renderer?.sentBitDepth == 24)
        #expect(path.statusLine == "RESAMPLED · 24/48 SENT")
        #expect(path.renderer?.warnings == ["Sonos plays up to 48 kHz here, so this 96 kHz song is resampled to 48 kHz."])
        #expect(!path.isUntouched)
        // A seek in a stream that was whole is the player's own seek, not a new stream.
        playback.seek(to: 0.5)
        await playback.settleForTests()
        #expect(fake.actions.contains("Seek"))
        #expect(fake.calls.filter { $0.action == "SetAVTransportURI" }.count == 1)
    }

    @Test("A 24-bit / 48 kHz FLAC goes to it as the file itself, and the next song is handed over for it to join")
    func withinItsLimits() async throws {
        let fake = try await playbar()
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
        // The same samples as FLAC files, which is what Sonos takes at 24 bits.
        let first = try makeFLAC(from: try makeWAV(seconds: 0.5, seed: 3)), second = try makeFLAC(from: try makeWAV(seconds: 0.5, seed: 4))
        let a = PlayableItem(url: first), b = PlayableItem(url: second)
        playback.nextItemProvider = { $0.id == a.id ? b : nil }
        playback.play(a)
        #expect(await events.wait(for: "started"))
        let uri = try #require(fake.currentURI)
        #expect(await fake.fetched(uri) == (try Data(contentsOf: first)))
        #expect(playback.snapshot.signalPath?.renderer?.passesThrough == true)
        #expect(playback.snapshot.signalPath?.renderer?.warnings == [])
        #expect(playback.snapshot.signalPath?.statusLine == "BIT-PERFECT · 24/48 SENT")
        for _ in 0..<200 where fake.nextURI == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fake.nextURI?.hasSuffix(".flac") == true)
        #expect(fake.actions.contains("SetNextAVTransportURI"))
        // It moves on by itself; Vespertine follows.
        fake.advance()
        #expect(await events.wait(for: "started \(second.lastPathComponent)"))
    }

    @Test("A 24-bit WAV, which Sonos doesn't read, goes as FLAC with the very same samples")
    func repacked() async throws {
        let wav = try makeWAV(seconds: 0.5, seed: 9)
        let plan = StreamNegotiation.plan(source: try SourceDescription.describe(PlayableItem(url: wav), url: wav).format, mime: "audio/wav", limits: .sonos)
        #expect(plan.changes == [.repacked(from: "WAV")])
        let maker = ProcessedStreamMaker(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)"))
        let (file, format) = try maker.makeStream(item: PlayableItem(url: wav), url: wav, settings: RendererSettings(), startSeconds: 0, target: .init(plan))
        for _ in 0..<500 where !file.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(format.sampleRate == 48_000)
        #expect(try flacSamples(file.url) == (try wavSamples(wav)))
    }
}

/// The FLAC of a WAV written by `makeWAV`, beside it.
func makeFLAC(from wav: URL) throws -> URL {
    let url = wav.deletingPathExtension().appendingPathExtension("flac")
    let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: nil)
    try FLACStreamWriter.encode(render, to: url, isCancelled: { false })
    return url
}
