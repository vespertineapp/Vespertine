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

    /// The player can't be sent this song at all (it takes neither the file nor FLAC): why, as a sentence. Nil otherwise.
    public var refusal: String?

    public init(sent: String, source: String? = nil, notes: [String] = [], refusal: String? = nil) {
        self.sent = sent
        self.source = source
        self.notes = notes
        self.refusal = refusal
    }

    /// The samples arrive as they are in the file (and the song can be sent at all).
    public var unchanged: Bool { source == nil && refusal == nil }

    /// "24-bit / 48 kHz FLAC, stereo (source 24/192)"; for a player that can't be sent the song, why.
    public var line: String {
        if let refusal { return refusal }
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

    /// A network player that pulls a file from Vespertine, from the very decision playback makes for it
    /// (`RendererMode.decide`): what the player advertises (`capabilities`), what it takes beyond its own list (`limits`, a
    /// Sonos; nil for a player sent the file as it is), and the listener's own equalizer, room correction, volume and
    /// ReplayGain (`settings`, the item's gain). `url`: the file playback would open for the item. A player that can be sent
    /// nothing gets a `refusal`, not a format.
    public static func renderer(item: PlayableItem, url: URL, source: SourceFormat, settings: RendererSettings, capabilities: RendererCapabilities,
                                limits: StreamLimits?, homeTheater: Bool = false) -> RouteForecast {
        var notes: [String] = []
        if let limits, source.channels > limits.maxChannels {
            notes.append(isAtmos(source)
                ? String(localized: "Dolby Atmos can't be sent to \(limits.playerKind) from a computer: the song's 5.1 bed is folded to stereo.", comment: "%@ is a kind of network player (Sonos).")
                : String(localized: "Surround can't be sent to \(limits.playerKind) from a computer: the song is folded to stereo.", comment: "%@ is a kind of network player (Sonos)."))
        }
        if homeTheater {
            notes.append(String(localized: "The room's surround speakers play two-channel music the way the Sonos app's Music Playback setting says: Ambient or Full.", comment: "A Sonos home theater room (soundbar with surrounds) playing stereo music. “Music Playback”, “Ambient” and “Full” are the Sonos app's own words."))
        }
        let decision = RendererMode.decide(item: item, url: url, source: source, settings: settings, capabilities: capabilities, limits: limits)
        switch decision {
        case .unplayable(let reason):
            return RouteForecast(sent: "", notes: notes, refusal: reason)
        case .passThrough(let mime):
            // What the player says it doesn't take is named, as the signal path names it once the song plays.
            // (A player that lists nothing is left to refuse what it can't play, as `decide` leaves it: nothing to name.)
            if !capabilities.entries.isEmpty { notes += capabilities.warnings(for: source, sending: mime).map(\.message) }
            let own = source.dsdName ?? format(rate: source.sampleRate, bits: source.bitDepth)
            return RouteForecast(sent: String(localized: "\(own) \(source.codec), \(layout(source.channels)), the file as it is", comment: "Output list: a network player is sent the original file. %1$@ is a format (24-bit / 96 kHz), %2$@ a codec (FLAC), %3$@ a layout (stereo)."),
                                 notes: notes)
        case .processed(let reasons):
            // The stream playback makes: to the player's limits when it has them (`NetworkRender.Target(_:limits:)`), else
            // 24-bit FLAC at the song's own rate (DSD as PCM) and channels.
            let rate: Double, bits: Int, channels: Int, fitChanges: Bool
            let whole = item.regionStartFrame == nil && item.regionFrameLength == nil && item.sacdArea == nil && item.dvd == nil
                && item.audioStream == nil && url.isFileURL
            if let limits {
                let fitted = StreamNegotiation.plan(source: source, mime: whole ? MediaType.mime(forExtension: url.pathExtension) : nil, limits: limits)
                rate = fitted.sampleRate
                bits = fitted.original ? limits.maxBitDepth : fitted.bitDepth ?? limits.maxBitDepth
                channels = fitted.channels
                fitChanges = fitted.changesSamples
            } else {
                rate = source.encoding == .dsd ? source.sampleRate / 8 : source.sampleRate
                bits = 24
                channels = source.channels
                fitChanges = source.encoding == .dsd
            }
            let listeners: [SignalPath.RendererStage.Processing] = [.roomCorrection, .equalizer, .volume, .replayGain]
            let changed = fitChanges || reasons.contains { listeners.contains($0) } || (source.bitDepth ?? 0) > bits
            let sent = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: bits, channels: channels)
            if !capabilities.entries.isEmpty { notes += capabilities.warnings(for: sent, sending: "audio/flac").map(\.message) }
            return RouteForecast(sent: "\(format(rate: rate, bits: bits)) FLAC, \(layout(channels))",
                                 source: changed ? short(source, withLayout: channels != source.channels) : nil, notes: notes)
        }
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
