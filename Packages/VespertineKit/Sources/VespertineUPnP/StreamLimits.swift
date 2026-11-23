//
// Vespertine: what a network player takes that it doesn't say in its own format list, and what a song becomes to fit it.
// A Sonos lists FLAC and never says "up to 48 kHz, two channels"; sent more, it refuses the song or plays nothing. So the
// limits are written down here, per kind of player, and the choice of what to send is one pure table: the original file
// when it fits, else 24-bit FLAC at the nearest rate the player takes, with every change named.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public struct StreamLimits: Sendable, Hashable {
    /// The highest PCM rate it plays.
    public var maxSampleRate: Double
    public var maxChannels: Int
    /// The file types it plays as they are (normalised MIME types), each with the deepest word it takes in that type.
    /// Lossy types are listed with 0: a lossy file has no word length.
    public var originals: [String: Int]
    /// Codecs it doesn't decode even inside a file type it reads (Opus in Ogg).
    public var unreadCodecs: [String] = []
    /// It wants a file whose length it is told: a processed stream is finished before it is offered, not sent as it grows.
    public var wholeFiles: Bool
    /// What the limits are called in a sentence: "Sonos".
    public var playerKind: String

    public init(maxSampleRate: Double, maxChannels: Int, originals: [String: Int], wholeFiles: Bool, playerKind: String, unreadCodecs: [String] = []) {
        self.unreadCodecs = unreadCodecs
        self.maxSampleRate = maxSampleRate
        self.maxChannels = maxChannels
        self.originals = originals
        self.wholeFiles = wholeFiles
        self.playerKind = playerKind
    }

    /// Sonos S2, from Sonos's own list for a music library: mono or stereo, up to 48 kHz; FLAC and Apple Lossless up to
    /// 24-bit, WAV and AIFF 16-bit; MP3, AAC and Ogg Vorbis (docs/output-routes.md has the sources).
    public static let sonos = StreamLimits(maxSampleRate: 48_000, maxChannels: 2,
                                           originals: ["audio/flac": 24, "audio/mp4": 24, "audio/wav": 16, "audio/aiff": 16,
                                                       "audio/mpeg": 0, "audio/ogg": 0],
                                           wholeFiles: true, playerKind: "Sonos", unreadCodecs: ["Opus"])
}

/// One thing that happens to a song on its way to a player that can't take it as it is.
public enum StreamChange: Sendable, Hashable {
    case resampled(from: Double, to: Double)
    case downmixed(from: Int, to: Int)
    /// DSD played as PCM ("DSD64").
    case dsdToPCM(String)
    /// A longer word than the stream holds (32-bit sent as 24-bit).
    case wordLength(from: Int, to: Int)
    /// The same samples in another file type (24-bit WAV as FLAC; a file type the player doesn't read).
    case repacked(from: String)

    /// The samples the player gets are no longer the file's own.
    public var changesSamples: Bool {
        if case .repacked = self { return false }
        return true
    }

    /// A whole sentence for the signal path and the output list, naming the player's kind ("Sonos").
    public func message(player: String) -> String {
        switch self {
        case .resampled(let from, let to):
            String(localized: "\(player) plays up to \(SampleRate.format(to)) kHz here, so this \(SampleRate.format(from)) kHz song is resampled to \(SampleRate.format(to)) kHz.",
                   comment: "%1$@ is a kind of network player (Sonos); the numbers are sample rates in kHz.")
        case .downmixed(let from, let to):
            to == 2
                ? String(localized: "\(player) takes two-channel music only, so this song's \(from) channels are folded down to stereo.",
                         comment: "%1$@ is a kind of network player (Sonos); %2$lld is a number of channels.")
                : CapabilityWarning.channelsAboveMaximum(source: from, max: to).message
        case .dsdToPCM(let name):
            String(localized: "\(player) doesn't play DSD, so this \(name) song is converted to PCM.", comment: "%1$@ is a kind of network player (Sonos); %2$@ is DSD64, DSD128…")
        case .wordLength(let from, let to):
            String(localized: "\(player) takes up to \(to)-bit, so this \(from)-bit song is sent as \(to)-bit.", comment: "%1$@ is a kind of network player (Sonos).")
        case .repacked(let from):
            String(localized: "\(player) doesn't read this \(from) file as it is, so the same samples are sent as FLAC.", comment: "%1$@ is a kind of network player (Sonos); %2$@ is a file type such as WAV.")
        }
    }

    /// The signal path's own word for it.
    public var processing: SignalPath.RendererStage.Processing {
        switch self {
        case .resampled: .resampled
        case .downmixed: .downmix
        case .dsdToPCM: .dsdToPCM
        case .wordLength: .dithered
        case .repacked: .format
        }
    }
}

/// What a song is sent as.
public struct StreamPlan: Sendable, Hashable {
    /// The original file's bytes go; nothing below applies.
    public var original: Bool
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    /// Why it isn't the original, in the order they happen; empty for the original.
    public var changes: [StreamChange]

    public var changesSamples: Bool { changes.contains(where: \.changesSamples) }
}

public enum StreamNegotiation {
    /// The rates a stream is made at.
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// The rate a song at `rate` (a DSD song's rate as PCM) is sent at to a player that takes up to `max`: its own when
    /// that fits; else the highest the player takes that divides it exactly (192 → 48, 176.4 → 44.1: no fractional
    /// resampling); else the highest it takes.
    public static func rate(for rate: Double, max: Double) -> Double {
        if rate <= max + 0.5 { return rate }
        let allowed = rates.filter { $0 <= max + 0.5 }
        guard let top = allowed.max() else { return max }
        let exact = allowed.filter { candidate in
            let times = (rate / candidate).rounded()
            return abs(rate - times * candidate) <= 0.5
        }
        return exact.max() ?? top
    }

    /// What `source` is sent as to a player with `limits`. `mime`: the file's type when the whole file could be handed
    /// over as it is (nil: a part of a file, a disc image, a type with no name on the network).
    public static func plan(source: SourceFormat, mime: String?, limits: StreamLimits) -> StreamPlan {
        var changes: [StreamChange] = []
        let dsd = source.encoding == .dsd
        // DSD becomes PCM at an eighth of its rate (352.8 kHz for DSD64) before anything else is decided.
        let pcmRate = dsd ? source.sampleRate / 8 : source.sampleRate
        if dsd { changes.append(.dsdToPCM(source.dsdName ?? "DSD")) }
        let rate = Self.rate(for: pcmRate, max: limits.maxSampleRate)
        // A DSD song's rate as PCM is the converter's choice, not the file's: only PCM is said to be resampled.
        if !dsd, abs(rate - pcmRate) > 0.5 { changes.append(.resampled(from: pcmRate, to: rate)) }
        let channels = min(max(1, source.channels), limits.maxChannels)
        if channels < source.channels { changes.append(.downmixed(from: source.channels, to: channels)) }
        if let bits = source.bitDepth, bits > 24 { changes.append(.wordLength(from: bits, to: 24)) }
        if changes.isEmpty {
            let type = mime.map(MediaType.normalise)
            let readable = !limits.unreadCodecs.contains { source.codec.localizedCaseInsensitiveContains($0) }
            if let type, readable, let deepest = limits.originals[type], source.encoding == .lossy || (source.bitDepth ?? 0) <= deepest {
                return StreamPlan(original: true, sampleRate: source.sampleRate, bitDepth: source.bitDepth, channels: source.channels, changes: [])
            }
            changes.append(.repacked(from: type.map(MediaType.shortName) ?? source.codec))
        }
        return StreamPlan(original: false, sampleRate: rate, bitDepth: 24, channels: channels, changes: changes)
    }
}

extension NetworkRender.Target {
    /// The stream a plan that isn't the original asks for.
    public init(_ plan: StreamPlan) {
        self = .fixed(sampleRate: plan.sampleRate, channels: plan.channels)
    }
}
