//
// Vespertine: the forecast for a network player comes from the decision playback makes for it (RendererMode.decide): what
// the player advertises, its limits and the listener's own processing. A player that takes nothing Vespertine could send
// is never promised a format.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

private func pcm(_ rate: Double, _ bits: Int? = 24, channels: Int = 2, codec: String = "FLAC") -> SourceFormat {
    SourceFormat(encoding: .pcm, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
}

@Suite("The forecast follows playback's own decision")
struct RouteForecastDecisionTests {
    let flac = PlayableItem(url: URL(fileURLWithPath: "/tmp/song.flac"))
    let wav = PlayableItem(url: URL(fileURLWithPath: "/tmp/song.wav"))
    let sonosSink = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/wav:*,http-get:*:audio/mpeg:*")

    private func forecast(_ item: PlayableItem, _ source: SourceFormat, sink: String?, limits: StreamLimits? = nil,
                          settings: RendererSettings = .init()) -> RouteForecast {
        RouteForecast.renderer(item: item, url: item.url, source: source, settings: settings,
                               capabilities: sink.map { RendererCapabilities.parse(sink: $0) } ?? .init(), limits: limits)
    }

    @Test("A player that takes neither the file nor FLAC is told it can't play the song, not promised a format")
    func acceptsNothing() {
        for limits in [nil, StreamLimits.sonos] {
            let refused = forecast(flac, pcm(44_100, 16), sink: "http-get:*:audio/x-ms-wma:*", limits: limits)
            #expect(refused.refusal == "The player doesn't take FLAC, so this song can't be sent to it processed.")
            #expect(!refused.unchanged)
            #expect(refused.line == refused.refusal)
            #expect(!refused.line.contains("FLAC, stereo"))
        }
    }

    @Test("A player that lists FLAC but not the file's own type gets FLAC with the same samples, not the file")
    func notTheFilesType() {
        let sent = forecast(wav, pcm(44_100, 16, codec: "WAV"), sink: "http-get:*:audio/flac:*")
        #expect(sent.line == "24-bit / 44.1 kHz FLAC, stereo")
        #expect(sent.unchanged)
        #expect(sent.refusal == nil)
        // A player that lists nothing (it didn't answer) is left to refuse what it can't play, as playback does.
        #expect(forecast(wav, pcm(44_100, 16, codec: "WAV"), sink: nil).line == "16-bit / 44.1 kHz WAV, stereo, the file as it is")
    }

    @Test("A rate the player says it doesn't take is named under the forecast, as in the signal path")
    func statedLimit() {
        let over = forecast(flac, pcm(96_000), sink: "http-get:*:audio/flac;rate=48000:*")
        #expect(over.line == "24-bit / 96 kHz FLAC, stereo, the file as it is")
        #expect(over.notes == [CapabilityWarning.rateAboveMaximum(source: 96_000, max: 48_000).message])
    }

    @Test("The listener's own processing makes FLAC, at the player's word length: 24-bit, 16-bit on Sonos S1")
    func listenersProcessing() {
        let volume = RendererSettings(digitalVolumeDB: -6)
        #expect(forecast(flac, pcm(96_000, 16), sink: "http-get:*:audio/flac:*", settings: volume).line == "24-bit / 96 kHz FLAC, stereo (source 16/96)")
        #expect(RouteForecast.renderer(item: flac, url: flac.url, source: pcm(44_100, 16), settings: volume, capabilities: sonosSink, limits: .sonosS1).line
            == "16-bit / 44.1 kHz FLAC, stereo (source 16/44.1)")
        let gained = PlayableItem(url: flac.url, replayGainDB: -3)
        #expect(RouteForecast.renderer(item: gained, url: gained.url, source: pcm(44_100, 16), settings: .init(), capabilities: sonosSink, limits: .sonos).line
            == "24-bit / 44.1 kHz FLAC, stereo (source 16/44.1)")
    }

    @Test("Sonos within and past its limits reads as before, now through the decision")
    func sonos() {
        #expect(RouteForecast.renderer(item: flac, url: flac.url, source: pcm(192_000), settings: .init(), capabilities: sonosSink, limits: .sonos).line
            == "24-bit / 48 kHz FLAC, stereo (source 24/192)")
        #expect(RouteForecast.renderer(item: flac, url: flac.url, source: pcm(44_100, 16), settings: .init(), capabilities: sonosSink, limits: .sonos).line
            == "16-bit / 44.1 kHz FLAC, stereo, the file as it is")
        #expect(RouteForecast.renderer(item: flac, url: flac.url, source: pcm(48_000), settings: .init(), capabilities: sonosSink, limits: .sonosS1).line
            == "16-bit / 48 kHz FLAC, stereo (source 24/48)")
    }
}
