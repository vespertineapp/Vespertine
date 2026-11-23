//
// Vespertine: Sonos S1 and S2. An S2 speaker takes FLAC and Apple Lossless up to 24-bit, an S1 speaker up to 16-bit; which one
// it is comes from the speaker's own description (swGen, else its display version). One that says neither is taken as S1,
// the limits that are safe on both.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

/// A Sonos speaker's description as its root device states it, with `software` (swGen, displayVersion…) on the speaker.
private func sonosDescription(_ software: [(String, String)]) throws -> DeviceDescription {
    let fields = software.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
    let xml = "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
        + "<deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>192.168.1.20 - Sonos One</friendlyName>"
        + "<manufacturer>Sonos, Inc.</manufacturer><modelName>Sonos One</modelName><roomName>Kitchen</roomName>\(fields)<UDN>uuid:RINCON_ONE01400</UDN>"
        + "<deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Kitchen - Sonos One Media Renderer</friendlyName>"
        + "<UDN>uuid:RINCON_ONE01400_MR</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
        + "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/MediaRenderer/AVTransport/Control</controlURL>"
        + "<SCPDURL>/xml/AVTransport1.xml</SCPDURL></service></serviceList></device></deviceList></device></root>"
    return try DeviceDescription.parse(Data(xml.utf8), location: URL(string: "http://192.168.1.20:1400/xml/device_description.xml")!)
}

/// A 16-bit stereo WAV of `seconds` at `rate`.
func makeWAV16(seconds: Double = 0.5, rate: Int = 44_100, seed: Int = 1) throws -> URL {
    let frames = Int(Double(rate) * seconds)
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataSize = UInt32(frames * 2 * 2)
    data.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(2); le32(UInt32(rate)); le32(UInt32(rate * 4)); le16(4); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(dataSize)
    for i in 0..<frames {
        for c in 0..<2 {
            let v = Int16(truncatingIfNeeded: ((i * (37 + seed) + c * 1000) % 20_000) - 10_000)
            le16(UInt16(bitPattern: v))
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

private func source(_ rate: Double, bits: Int? = 24, channels: Int = 2, codec: String = "FLAC", encoding: SourceFormat.Encoding = .pcm) -> SourceFormat {
    SourceFormat(encoding: encoding, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
}

@Suite("Sonos S1 and S2")
struct SonosGenerationTests {
    @Test("The speaker's description says which: swGen first, else the display version (12 and later are S2); neither is unknown",
          arguments: [([("swGen", "2")], SonosGeneration.s2), ([("swGen", "1"), ("displayVersion", "11.2")], .s1),
                      ([("displayVersion", "12.3")], .s2), ([("displayVersion", "16.1")], .s2), ([("displayVersion", "11.15")], .s1),
                      ([("swGen", "2"), ("displayVersion", "11.2")], .s2), ([("swGen", "x")], .unknown), ([], .unknown)])
    func generation(software: [(String, String)], expected: SonosGeneration) throws {
        let description = try sonosDescription(software)
        let device = RendererDevice(description: description, kind: .av(gapless: true), capabilities: .init())
        #expect(device.isSonos)
        #expect(device.sonosGeneration == expected)
    }

    @Test("S2 gets S2's limits; S1, and a speaker that doesn't say, get S1's: 16-bit")
    func limits() throws {
        func device(_ software: [(String, String)]) throws -> RendererDevice {
            RendererDevice(description: try sonosDescription(software), kind: .av(gapless: true), capabilities: .init())
        }
        #expect(try device([("swGen", "2")]).limits == .sonos)
        #expect(try device([("swGen", "1")]).limits == .sonosS1)
        #expect(try device([]).limits?.maxBitDepth == 16)
        #expect(try device([]).limits?.maxSampleRate == 48_000)
        #expect(StreamLimits.sonos.maxBitDepth == 24)
        #expect(StreamLimits.sonosS1.maxBitDepth == 16)
    }

    /// (source, the file's type, sent as the original, rate, bits, channels, what was done)
    static let s1Table: [(SourceFormat, String?, Bool, Double, Int?, Int, [StreamChange])] = [
        (source(44_100, bits: 16), "audio/flac", true, 44_100, 16, 2, []),
        (source(48_000, bits: 16, codec: "ALAC"), "audio/mp4", true, 48_000, 16, 2, []),
        (source(44_100, bits: 16, codec: "WAV"), "audio/wav", true, 44_100, 16, 2, []),
        (source(44_100, bits: nil, codec: "MP3", encoding: .lossy), "audio/mpeg", true, 44_100, nil, 2, []),
        (source(48_000, bits: nil, codec: "AAC", encoding: .lossy), "audio/mp4", true, 48_000, nil, 2, []),
        // 24-bit: sent as 16-bit FLAC.
        (source(48_000), "audio/flac", false, 48_000, 16, 2, [.wordLength(from: 24, to: 16)]),
        (source(44_100, codec: "ALAC"), "audio/mp4", false, 44_100, 16, 2, [.wordLength(from: 24, to: 16)]),
        (source(96_000), "audio/flac", false, 48_000, 16, 2, [.resampled(from: 96_000, to: 48_000), .wordLength(from: 24, to: 16)]),
        (source(48_000, channels: 6), "audio/flac", false, 48_000, 16, 2, [.downmixed(from: 6, to: 2), .wordLength(from: 24, to: 16)]),
        // DSD and lossy codecs it doesn't read become 16-bit FLAC too.
        (source(2_822_400, bits: nil, codec: "DSF", encoding: .dsd), "audio/x-dsf", false, 44_100, 16, 2, [.dsdToPCM("DSD64")]),
        (source(48_000, bits: nil, codec: "Dolby Digital Plus", encoding: .lossy), "audio/mp4", false, 48_000, 16, 2, [.repacked(from: "Dolby Digital Plus")]),
        (source(44_100, bits: 16, codec: "APE"), "audio/x-ape", false, 44_100, 16, 2, [.repacked(from: "APE")]),
    ]

    @Test("The S1 table: 16-bit files as they are, everything deeper as 16-bit FLAC with the change named", arguments: s1Table.indices)
    func s1Row(row: Int) {
        let (format, mime, original, rate, bits, channels, changes) = Self.s1Table[row]
        let plan = StreamNegotiation.plan(source: format, mime: mime, limits: .sonosS1)
        #expect(plan.original == original, "\(format)")
        #expect(plan.sampleRate == rate, "\(format)")
        #expect(plan.bitDepth == bits, "\(format)")
        #expect(plan.channels == channels, "\(format)")
        #expect(plan.changes == changes, "\(format)")
    }

    @Test("The sentence for S1's word length names it")
    func sentence() {
        #expect(StreamChange.wordLength(from: 24, to: 16).message(player: StreamLimits.sonosS1.playerKind)
            == "Sonos S1 takes up to 16-bit, so this 24-bit song is sent as 16-bit.")
    }

    @Test("A 16-bit stream from a 24-bit song: every sample within dither of the source's top 16 bits")
    func sixteenBitRender() throws {
        let wav = try makeWAV(seconds: 0.25, seed: 5)
        defer { try? FileManager.default.removeItem(at: wav) }
        let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: nil,
                                       target: .fixed(sampleRate: 48_000, channels: 2, bitDepth: 16))
        #expect(render.format.bitDepth == 16)
        let out = renderAll(render), source = try wavSamples(wav)
        #expect(out.count == source.count)
        #expect(out.allSatisfy { $0 >= -32_768 && $0 <= 32_767 })
        let worst = zip(out, source).map { abs(Double($0) - Double($1) / 256) }.max() ?? 99
        #expect(worst <= 2)
        // Dithered: not simply the top 16 bits of every sample.
        #expect(zip(out, source).contains { Double($0) != (Double($1) / 256).rounded() })
    }

    @Test("A 16-bit song made into a 16-bit stream keeps its samples exactly: no dither where nothing is re-quantised")
    func sixteenBitExact() throws {
        let wav = try makeWAV16(seconds: 0.25)
        defer { try? FileManager.default.removeItem(at: wav) }
        let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: nil,
                                       target: .fixed(sampleRate: 44_100, channels: 2, bitDepth: 16))
        let out = renderAll(render)
        let data = try Data(contentsOf: wav).dropFirst(44)
        var source: [Int32] = []
        var i = data.startIndex
        while i + 1 < data.endIndex { source.append(Int32(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))); i += 2 }
        #expect(out == source)
    }

    @Test("A 24-bit / 48 kHz FLAC goes to an S1 room as a whole 16-bit FLAC, and the path says why; a 16-bit WAV goes as it is")
    func s1Playback() async throws {
        let fake = try await FakeRenderer(kind: .av(setNext: true), udn: "uuid:RINCON_ONE01400_MR")
        fake.sonosRoom = "Kitchen"
        fake.sonosModel = "Sonos Play:1"
        fake.sonosSoftware = [("swGen", "1"), ("displayVersion", "11.15")]
        fake.sink = "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*"
        let media = MediaServer()
        try await media.start()
        defer { media.stop(); fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.sonosGeneration == .s1)
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media,
                                        processed: ProcessedStreamMaker(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")),
                                        pollInterval: 0.05)
        defer { playback.shutdown() }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        let flac = try makeFLAC(from: try makeWAV(seconds: 0.5, seed: 6))
        playback.play(PlayableItem(url: flac))
        #expect(await events.wait(for: "started"))
        let uri = try #require(fake.currentURI)
        let bytes = try #require(await fake.fetched(uri))
        #expect(bytes != (try Data(contentsOf: flac)))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString).flac")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let described = try SourceDescription.describe(PlayableItem(url: copy), url: copy)
        #expect(described.format.bitDepth == 16)
        #expect(described.format.sampleRate == 48_000)
        let didl = try #require(fake.calls.last { $0.action == "SetAVTransportURI" }?.arguments["CurrentURIMetaData"])
        #expect(didl.contains("bitsPerSample=\"16\""))
        let path = try #require(playback.snapshot.signalPath)
        #expect(path.renderer?.sentBitDepth == 16)
        #expect(path.renderer?.processing == [.dithered])
        #expect(path.renderer?.warnings == ["Sonos S1 takes up to 16-bit, so this 24-bit song is sent as 16-bit."])

        let wav16 = try makeWAV16(seconds: 0.5)
        playback.play(PlayableItem(url: wav16))
        #expect(await events.wait(for: "started \(wav16.lastPathComponent)"))
        let second = try #require(fake.currentURI)
        #expect(await fake.fetched(second) == (try Data(contentsOf: wav16)))
        #expect(playback.snapshot.signalPath?.renderer?.passesThrough == true)
    }
}
