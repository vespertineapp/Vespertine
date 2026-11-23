//
// Vespertine: what a song would be played as on an output, said before it is chosen: "24-bit / 48 kHz FLAC, stereo
// (source 24/192)". One line per output in the output list, made from the same decisions playback makes (the format
// planner for a device, the stream table for a network player, AirPlay's format choice), so the list can't promise what
// playback then doesn't do. Surround and Dolby Atmos get a sentence of their own wherever they don't arrive as they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public struct RouteForecast: Sendable, Hashable {
    /// What arrives: "24-bit / 48 kHz FLAC, stereo".
    public var sent: String
    /// The song's own format, short ("24/192", "DSD64", "24/96 5.1"), when what arrives isn't it; nil when it is.
    public var source: String?
    /// What happens to surround or Dolby Atmos on this output, and anything else worth a sentence; often empty.
    public var notes: [String]

    public init(sent: String, source: String? = nil, notes: [String] = []) {
        self.sent = sent
        self.source = source
        self.notes = notes
    }

    /// The samples arrive as they are in the file.
    public var unchanged: Bool { source == nil }

    /// "24-bit / 48 kHz FLAC, stereo (source 24/192)".
    public var line: String {
        guard let source else { return sent }
        return String(localized: "\(sent) (source \(source))", comment: "Output list: what a song will be played as on this output, then its own format in brackets, e.g. “24-bit / 48 kHz FLAC, stereo (source 24/192)”.")
    }

    // MARK: Words

    static func isAtmos(_ source: SourceFormat) -> Bool { source.codec.localizedCaseInsensitiveContains("Atmos") }

    /// "24-bit / 48 kHz", or "48 kHz" for a stream with no word length.
    static func format(rate: Double, bits: Int?) -> String {
        bits.map { String(localized: "\($0)-bit / \(SampleRate.format(rate)) kHz", comment: "A format: word length and sample rate.") }
            ?? String(localized: "\(SampleRate.format(rate)) kHz", comment: "A format: sample rate only.")
    }

    /// "stereo", "mono", "5.1".
    static func layout(_ channels: Int) -> String {
        switch channels {
        case 1: String(localized: "mono", comment: "One channel, lowercase, at the end of a format line.")
        case 2: String(localized: "stereo", comment: "Two channels, lowercase, at the end of a format line.")
        default: ChannelLayouts.name(channels: channels)
        }
    }

    /// The song's own format, short: "24/192", "DSD64", "AAC 44.1"; with its layout when `withLayout` ("24/96 5.1").
    static func short(_ source: SourceFormat, withLayout: Bool) -> String {
        if isAtmos(source) { return "Dolby Atmos" }
        var text = source.dsdName ?? source.bitDepth.map { "\($0)/\(SampleRate.format(source.sampleRate))" }
            ?? "\(source.codec) \(SampleRate.format(source.sampleRate))"
        if withLayout { text += " " + layout(source.channels) }
        return text
    }

    // MARK: Network players

    /// A network player that pulls a file from Vespertine. `limits`: what it takes beyond its own list (a Sonos); nil for a
    /// player sent the file as it is. `mime`: the file's type when the whole file can be handed over. `processed`: the
    /// listener's own equalizer, room correction, volume or ReplayGain is on for it, so a 24-bit FLAC is made either way.
    public static func renderer(source: SourceFormat, mime: String?, limits: StreamLimits?, processed: Bool = false, homeTheater: Bool = false) -> RouteForecast {
        let fitted = limits.map { StreamNegotiation.plan(source: source, mime: mime, limits: $0) }
        var notes: [String] = []
        if let limits, source.channels > limits.maxChannels {
            notes.append(isAtmos(source)
                ? String(localized: "Dolby Atmos can't be sent to \(limits.playerKind) from a computer: the song's 5.1 bed is folded to stereo.", comment: "%@ is a kind of network player (Sonos).")
                : String(localized: "Surround can't be sent to \(limits.playerKind) from a computer: the song is folded to stereo.", comment: "%@ is a kind of network player (Sonos)."))
        }
        if homeTheater {
            notes.append(String(localized: "The room's surround speakers play two-channel music the way the Sonos app's Music Playback setting says: Ambient or Full.", comment: "A Sonos home theater room (soundbar with surrounds) playing stereo music. “Music Playback”, “Ambient” and “Full” are the Sonos app's own words."))
        }
        if let fitted, !fitted.original {
            let sent = "\(format(rate: fitted.sampleRate, bits: fitted.bitDepth)) FLAC, \(layout(fitted.channels))"
            // The same samples in another file is not a change worth the song's own format in brackets, unless the chain is on.
            let changed = fitted.changesSamples || processed
            return RouteForecast(sent: sent, source: changed ? short(source, withLayout: fitted.channels != source.channels) : nil, notes: notes)
        }
        let rate = source.encoding == .dsd ? source.sampleRate / 8 : source.sampleRate
        if processed || mime == nil {
            // Decoded and sent as 24-bit FLAC at its own rate (DSD as PCM).
            let sent = "\(format(rate: rate, bits: 24)) FLAC, \(layout(source.channels))"
            return RouteForecast(sent: sent, source: processed || source.encoding == .dsd ? short(source, withLayout: false) : nil, notes: notes)
        }
        let own = source.dsdName ?? format(rate: source.sampleRate, bits: source.bitDepth)
        return RouteForecast(sent: String(localized: "\(own) \(source.codec), \(layout(source.channels)), the file as it is", comment: "Output list: a network player is sent the original file. %1$@ is a format (24-bit / 96 kHz), %2$@ a codec (FLAC), %3$@ a layout (stereo)."),
                             notes: notes)
    }

    // MARK: AirPlay

    /// An AirPlay receiver: Apple Lossless at `rate` and `bits` (16-bit / 44.1 kHz unless the receiver takes more), stereo.
    public static func airPlay(source: SourceFormat, rate: Int, bits: Int, processed: Bool = false) -> RouteForecast {
        let same = !processed && source.encoding == .pcm && source.channels <= 2 && Int(source.sampleRate.rounded()) == rate
            && (source.bitDepth ?? 99) <= bits
        var notes: [String] = []
        if source.channels > 2 {
            notes.append(isAtmos(source)
                ? String(localized: "AirPlay from Vespertine carries two channels: no Dolby Atmos; the song's 5.1 bed is folded to stereo.")
                : String(localized: "AirPlay from Vespertine carries two channels: the song is folded to stereo."))
        }
        return RouteForecast(sent: "\(format(rate: Double(rate), bits: bits)) ALAC, \(layout(2))",
                             source: same ? nil : short(source, withLayout: source.channels > 2), notes: notes)
    }

    // MARK: Devices

    /// What kind of link a Core Audio device is, where it matters to what arrives.
    public enum DeviceLink: Sendable, Hashable {
        case wired
        /// Bluetooth: macOS encodes everything again (AAC or SBC) whatever is sent to it.
        case bluetooth
        /// The system's own AirPlay output: macOS encodes and sends it.
        case systemAirPlay
    }

    /// A Core Audio device, from the plan the engine's own planner makes for it. `atmosBySystem`: Dolby Atmos is handed to
    /// macOS to render for this output (the default).
    public static func device(source: SourceFormat, plan: OutputPlan, link: DeviceLink = .wired, atmosBySystem: Bool = true) -> RouteForecast {
        var notes: [String] = []
        switch link {
        case .bluetooth: notes.append(String(localized: "Bluetooth: macOS compresses everything again on the way (AAC or SBC), so it is never lossless."))
        case .systemAirPlay: notes.append(String(localized: "The Mac's own AirPlay output: macOS sends it as 16-bit / 44.1 kHz or 48 kHz stereo."))
        case .wired: break
        }
        switch plan.mode {
        case .dop:
            return RouteForecast(sent: String(localized: "\(source.dsdName ?? "DSD") as DSD (DoP), untouched", comment: "Output list: a DSD song goes to the DAC as DSD. %@ is DSD64, DSD128…"), notes: notes)
        case .bitstream:
            return RouteForecast(sent: String(localized: "\(source.codec) \(layout(source.channels)), sent untouched for the receiver to decode", comment: "Output list: Dolby or DTS frames go to an AV receiver as they are. %1$@ is the codec, %2$@ the layout (5.1)."), notes: notes)
        case .pcm: break
        }
        if isAtmos(source), atmosBySystem, link == .wired {
            notes.append(String(localized: "Dolby Atmos: macOS renders the objects for this output, as it does for Apple Music."))
            return RouteForecast(sent: String(localized: "Dolby Atmos, rendered by macOS", comment: "Output list: a Dolby Atmos song is handed to macOS's own renderer."), notes: notes)
        }
        let outputs = plan.deviceChannels
        let sent = "\(format(rate: plan.deviceSampleRate, bits: plan.physicalBitDepth > 0 ? plan.physicalBitDepth : nil)), \(layout(outputs))"
        if source.channels > 2 {
            if plan.spatial != .off {
                notes.append(String(localized: "Surround is rendered for these headphones with Spatial Audio."))
            } else if outputs >= source.channels {
                notes.append(String(localized: "Surround: every channel goes to its own speaker."))
            } else {
                notes.append(String(localized: "Surround is folded to \(layout(outputs)): this output has \(outputs) channels.", comment: "%1$@ is a layout (stereo), %2$lld a channel count."))
            }
            if isAtmos(source) { notes.append(String(localized: "Dolby Atmos objects aren't rendered here: the song's 5.1 bed plays.")) }
        }
        let changed = plan.resamples || plan.dsdConvertedToPCM || (source.channels > 2 && outputs < source.channels) || plan.spatial != .off
            || (source.bitDepth ?? 0) > plan.physicalBitDepth && plan.physicalBitDepth > 0 || link != .wired
        return RouteForecast(sent: sent, source: changed ? short(source, withLayout: source.channels > 2) : nil, notes: notes)
    }
}
