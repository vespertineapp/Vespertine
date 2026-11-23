//
// Vespertine: the output list's forecast: for the song loaded now, what each output would be sent ("24-bit / 48 kHz FLAC,
// stereo (source 24/192)"), from the same decisions playback makes. With no song loaded there is nothing to forecast and
// the rows show what they always did.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAirPlay
import VespertineAudio
import VespertineLibrary
import VespertineUPnP

extension Track {
    /// The song's format as the library knows it (the engine's own probe says the same once the song plays).
    var forecastFormat: SourceFormat {
        SourceFormat(encoding: isDSD ? .dsd : isLossless ? .pcm : .lossy, codec: codec, sampleRate: sampleRate, bitDepth: isDSD ? nil : bitDepth, channels: max(1, channels))
    }
}

@MainActor
extension AppModel {
    /// The song a forecast is for: the one playing or loaded, with its format as the engine read it when it has.
    var forecastSong: (format: SourceFormat, item: PlayableItem)? {
        guard let current = player.current else { return nil }
        return (player.signalPath?.source ?? current.track.forecastFormat, current.item)
    }

    func forecast(for renderer: RendererDevice) -> RouteForecast? {
        guard let song = forecastSong else { return nil }
        return RendererForecast.forecast(format: song.format, item: song.item, renderer: renderer, chain: settings.rendererSettings(uid: renderer.uid))
    }
}

/// The forecast for a network player: the decision its playback would make (`RendererMode.decide`), from what it
/// advertises, its limits (a Sonos's, S1 or S2) and the listener's own chain for it.
enum RendererForecast {
    static func forecast(format: SourceFormat, item: PlayableItem, renderer: RendererDevice, chain: RendererSettings) -> RouteForecast {
        RouteForecast.renderer(item: item, url: item.url, source: format, settings: chain, capabilities: renderer.capabilities,
                               limits: renderer.limits, homeTheater: renderer.sonos?.isHomeTheater == true)
    }
}

@MainActor
extension AppModel {

    func forecast(for receiver: AirPlayDevice) -> RouteForecast? {
        guard let song = forecastSong, receiver.isSupported else { return nil }
        // What every receiver takes. One that takes more (an Apple TV 4K) says so only once a session is open, and the
        // signal path then says what was sent.
        let format = AirPlayWish(sourceRate: song.format.sampleRate, wantsDepth: false).format(accepted: [])
        return RouteForecast.airPlay(source: song.format, rate: format.sampleRate, bits: format.bitDepth)
    }

    func forecast(for device: OutputDevice) -> RouteForecast? {
        guard let song = forecastSong else { return nil }
        let engine = settings.engineSettings()
        let bitstream = engine.bitstreamDeviceUIDs.contains(device.uid)
        var plan = FormatPlanner.plan(source: song.format, device: device.planningCapabilities, policy: engine.ratePolicies[device.uid] ?? .matchSource,
                                      spatial: engine.spatialMode(for: device), bitstream: bitstream, spatializeStereo: engine.spatializesStereo(for: device),
                                      dsdToPCMForRoom: engine.convertsDSDForRoom(device), dsdToPCMForTransitions: engine.transitions.avoidsUnmixableModes)
        // The plan asks for the deepest integer format; a device that only mixes in float still carries 24 bits exactly.
        if plan.physicalBitDepth > 24, (song.format.bitDepth ?? 24) <= 24 { plan.physicalBitDepth = song.format.bitDepth ?? 24 }
        let link: RouteForecast.DeviceLink = switch device.profile.kind {
        case .bluetooth, .airPodsMaxBluetooth: .bluetooth
        case .airPlay: .systemAirPlay
        default: .wired
        }
        return RouteForecast.device(source: song.format, plan: plan, link: link, atmosBySystem: engine.atmosBySystem)
    }
}

enum OutputForecastText {
    /// The forecast line under an output's name: "Will play 24-bit / 48 kHz FLAC, stereo (source 24/192)"; for a player that
    /// can't be sent the song, why (a whole sentence of its own), never "Will play".
    static func willPlay(_ forecast: RouteForecast) -> String {
        if let refusal = forecast.refusal { return refusal }
        return String(localized: "Will play \(forecast.line)", comment: "Output list: what the song loaded now would be played as on this output; %@ is e.g. “24-bit / 48 kHz FLAC, stereo (source 24/192)”.")
    }
}
