//
// Vespertine: the output list's forecast: what a song would be played as on each kind of output, before it is chosen.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

private func pcm(_ rate: Double, _ bits: Int? = 24, channels: Int = 2, codec: String = "FLAC") -> SourceFormat {
    SourceFormat(encoding: .pcm, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
}
private let dsd64 = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: nil, channels: 2)
private let atmos = SourceFormat(encoding: .lossy, codec: "Dolby Atmos", sampleRate: 48_000, bitDepth: nil, channels: 6)

/// The forecast for a player that lists nothing (so takes anything): `mime` nil is a song with no file of its own to hand over
/// (one stream of a file); `processed`, the listener's digital volume on.
private func renderer(source: SourceFormat, mime: String?, limits: StreamLimits?, processed: Bool = false, homeTheater: Bool = false) -> RouteForecast {
    let ext = ["audio/flac": "flac", "audio/wav": "wav", "audio/x-dsf": "dsf", "audio/mp4": "m4a"][mime ?? ""] ?? "m4a"
    let item = PlayableItem(url: URL(fileURLWithPath: "/tmp/song.\(ext)"), audioStream: mime == nil ? 1 : nil)
    return RouteForecast.renderer(item: item, url: item.url, source: source, settings: processed ? RendererSettings(digitalVolumeDB: -6) : RendererSettings(),
                                  capabilities: RendererCapabilities(), limits: limits, homeTheater: homeTheater)
}

@Suite("What a song would be played as, per output")
struct RouteForecastTests {
    @Test("Sonos: the file as it is within its limits; above them, what it is resampled to, with the song's own format in brackets")
    func sonos() {
        let hiRes = renderer(source: pcm(192_000), mime: "audio/flac", limits: .sonos)
        #expect(hiRes.line == "24-bit / 48 kHz FLAC, stereo (source 24/192)")
        #expect(hiRes.notes.isEmpty)
        #expect(!hiRes.unchanged)
        let cd = renderer(source: pcm(44_100, 16), mime: "audio/flac", limits: .sonos)
        #expect(cd.line == "16-bit / 44.1 kHz FLAC, stereo, the file as it is")
        #expect(cd.unchanged)
        #expect(renderer(source: dsd64, mime: "audio/x-dsf", limits: .sonos).line == "24-bit / 44.1 kHz FLAC, stereo (source DSD64)")
        // The same samples in another file: said as what is sent, not as a loss.
        let wav = renderer(source: pcm(48_000, codec: "WAV"), mime: "audio/wav", limits: .sonos)
        #expect(wav.line == "24-bit / 48 kHz FLAC, stereo")
        #expect(wav.unchanged)
    }

    @Test("Sonos and surround: folded to stereo and said so; Dolby Atmos is named as not possible; a home theater room adds how its surrounds play music")
    func sonosSurround() {
        let surround = renderer(source: pcm(96_000, channels: 6), mime: "audio/flac", limits: .sonos, homeTheater: true)
        #expect(surround.line == "24-bit / 48 kHz FLAC, stereo (source 24/96 5.1)")
        #expect(surround.notes == ["Surround can't be sent to Sonos from a computer: the song is folded to stereo.",
                                   "The room's surround speakers play two-channel music the way the Sonos app's Music Playback setting says: Ambient or Full."])
        let object = renderer(source: atmos, mime: nil, limits: .sonos)
        #expect(object.line == "24-bit / 48 kHz FLAC, stereo (source Dolby Atmos)")
        #expect(object.notes == ["Dolby Atmos can't be sent to Sonos from a computer: the song's 5.1 bed is folded to stereo."])
    }

    @Test("Any other network player gets the file as it is, or 24-bit FLAC at the song's rate when Vespertine's own processing is on")
    func otherPlayers() {
        #expect(renderer(source: pcm(192_000), mime: "audio/flac", limits: nil).line == "24-bit / 192 kHz FLAC, stereo, the file as it is")
        #expect(renderer(source: pcm(96_000, 16), mime: "audio/flac", limits: nil, processed: true).line == "24-bit / 96 kHz FLAC, stereo (source 16/96)")
        #expect(renderer(source: dsd64, mime: "audio/x-dsf", limits: nil).line == "DSD64 DSF, stereo, the file as it is")
    }

    @Test("AirPlay: Apple Lossless at what the receiver takes; only a song already in that format arrives unchanged")
    func airPlay() {
        #expect(RouteForecast.airPlay(source: pcm(44_100, 16), rate: 44_100, bits: 16).line == "16-bit / 44.1 kHz ALAC, stereo")
        #expect(RouteForecast.airPlay(source: pcm(96_000), rate: 44_100, bits: 16).line == "16-bit / 44.1 kHz ALAC, stereo (source 24/96)")
        #expect(RouteForecast.airPlay(source: pcm(96_000), rate: 48_000, bits: 24).line == "24-bit / 48 kHz ALAC, stereo (source 24/96)")
        let surround = RouteForecast.airPlay(source: pcm(48_000, channels: 6), rate: 44_100, bits: 16)
        #expect(surround.line == "16-bit / 44.1 kHz ALAC, stereo (source 24/48 5.1)")
        #expect(surround.notes == ["AirPlay from Vespertine carries two channels: the song is folded to stereo."])
        #expect(RouteForecast.airPlay(source: atmos, rate: 44_100, bits: 16).notes.first?.contains("no Dolby Atmos") == true)
    }

    private func dac(rates: [Double], bits: Int = 24, channels: Int = 2, dop: Bool = false) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates, physicalFormats: [PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: bits, isInteger: true,
                                                                                 isMixable: true, channels: channels)],
                           outputChannels: channels, supportsDoP: dop)
    }

    @Test("A DAC: the song's own rate when it has it (nothing in brackets), the nearest it has when not, DSD as DSD when it does DoP")
    func dacs() {
        let all = dac(rates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000])
        let match = RouteForecast.device(source: pcm(192_000), plan: FormatPlanner.plan(source: pcm(192_000), device: all))
        #expect(match.line == "24-bit / 192 kHz, stereo")
        #expect(match.unchanged)
        let only48 = dac(rates: [48_000])
        #expect(RouteForecast.device(source: pcm(192_000), plan: FormatPlanner.plan(source: pcm(192_000), device: only48)).line == "24-bit / 48 kHz, stereo (source 24/192)")
        let dop = dac(rates: [44_100, 176_400], dop: true)
        #expect(RouteForecast.device(source: dsd64, plan: FormatPlanner.plan(source: dsd64, device: dop)).line == "DSD64 as DSD (DoP), untouched")
        let noDoP = RouteForecast.device(source: dsd64, plan: FormatPlanner.plan(source: dsd64, device: all))
        #expect(noDoP.source == "DSD64")
    }

    @Test("Surround on a device: every channel to its own speaker on six outputs, folded and said so on two; Atmos goes to macOS's renderer")
    func surroundDevices() {
        let six = dac(rates: [48_000, 96_000], channels: 6), two = dac(rates: [48_000, 96_000])
        let file = pcm(96_000, channels: 6)
        let discrete = RouteForecast.device(source: file, plan: FormatPlanner.plan(source: file, device: six))
        #expect(discrete.line == "24-bit / 96 kHz, 5.1")
        #expect(discrete.notes == ["Surround: every channel goes to its own speaker."])
        let folded = RouteForecast.device(source: file, plan: FormatPlanner.plan(source: file, device: two))
        #expect(folded.line == "24-bit / 96 kHz, stereo (source 24/96 5.1)")
        #expect(folded.notes == ["Surround is folded to stereo: this output has 2 channels."])
        let rendered = RouteForecast.device(source: atmos, plan: FormatPlanner.plan(source: atmos, device: six))
        #expect(rendered.sent == "Dolby Atmos, rendered by macOS")
        let bed = RouteForecast.device(source: atmos, plan: FormatPlanner.plan(source: atmos, device: six), atmosBySystem: false)
        #expect(bed.notes.contains("Dolby Atmos objects aren't rendered here: the song's 5.1 bed plays."))
    }

    @Test("Bluetooth is never said to be the file's own samples")
    func bluetooth() {
        let headset = dac(rates: [48_000], bits: 16)
        let forecast = RouteForecast.device(source: pcm(44_100, 16), plan: FormatPlanner.plan(source: pcm(44_100, 16), device: headset), link: .bluetooth)
        #expect(!forecast.unchanged)
        #expect(forecast.notes.first?.hasPrefix("Bluetooth") == true)
    }
}
