//
// Vespertine: pass-through or processed. A song goes to a renderer as its original file's bytes only when nothing would
// change its samples and the renderer takes the file as it is; otherwise Vespertine decodes it, runs its own chain and
// sends 24-bit FLAC at the source rate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// What Vespertine applies for a renderer.
public struct RendererSettings: Sendable, Equatable {
    public var equalizer: EQPreset?
    public var roomCorrection: RoomCorrectionPlayback?
    /// nil: the volume is locked at 100% (the renderer's own volume is left alone).
    public var digitalVolumeDB: Double?

    public init(equalizer: EQPreset? = nil, roomCorrection: RoomCorrectionPlayback? = nil, digitalVolumeDB: Double? = nil) {
        self.equalizer = equalizer
        self.roomCorrection = roomCorrection
        self.digitalVolumeDB = digitalVolumeDB
    }

    /// The equalizer that changes something; nil otherwise.
    public var activeEqualizer: EQPreset? { equalizer.flatMap { $0.isFlat ? nil : $0 } }
    public var activeRoomCorrection: RoomCorrectionPlayback? { roomCorrection.flatMap { $0.isFlat ? nil : $0 } }
    public var activeVolumeDB: Double? { digitalVolumeDB.flatMap { $0 == 0 ? nil : $0 } }
}

public enum RendererModeDecision: Sendable, Equatable {
    /// The original bytes, as `mime`.
    case passThrough(mime: String)
    /// Decoded, processed, sent as 24-bit FLAC; why.
    case processed([SignalPath.RendererStage.Processing])
    /// Neither can be sent: the reason.
    case unplayable(String)
}

public enum RendererMode {
    /// `renderer` capabilities with no entries (GetProtocolInfo failed or answered nothing) accept everything: the renderer
    /// is left to refuse what it can't play.
    ///
    /// `limits`: what the player takes beyond what it lists (a Sonos: 48 kHz, two channels). A song past them is never sent
    /// as its file: it is processed, and the reasons name what was done to fit it (`StreamNegotiation.plan`).
    public static func decide(item: PlayableItem, url: URL, source: SourceFormat?, settings: RendererSettings,
                              capabilities: RendererCapabilities, limits: StreamLimits? = nil) -> RendererModeDecision {
        var reasons: [SignalPath.RendererStage.Processing] = []
        if settings.activeRoomCorrection != nil { reasons.append(.roomCorrection) }
        if settings.activeEqualizer != nil { reasons.append(.equalizer) }
        if settings.activeVolumeDB != nil { reasons.append(.volume) }
        if let gain = item.replayGainDB, gain != 0 { reasons.append(.replayGain) }
        let accepts: (String) -> Bool = { capabilities.entries.isEmpty || capabilities.accepts(mime: $0) }
        let wholeFile = item.regionStartFrame == nil && item.regionFrameLength == nil && item.sacdArea == nil && item.dvd == nil
            && item.audioStream == nil && url.isFileURL
        let mime = MediaType.mime(forExtension: url.pathExtension)
        // DSD is passed through only as a file the renderer lists; it can't be processed into FLAC without becoming PCM.
        let fitted: StreamPlan? = if let limits, let source { StreamNegotiation.plan(source: source, mime: wholeFile ? mime : nil, limits: limits) } else { nil }
        if reasons.isEmpty, wholeFile, let mime, accepts(mime), fitted?.original ?? true { return .passThrough(mime: mime) }
        // What fitting the song to the player does to it, after what the listener asked for.
        if let fitted, !fitted.original {
            for step in fitted.changes.map(\.processing) where !reasons.contains(step) && (step != .format || reasons.isEmpty) { reasons.append(step) }
        }
        if reasons.isEmpty { reasons.append(.format) }
        guard accepts("audio/flac") else {
            return .unplayable(String(localized: "The player doesn't take FLAC, so this song can't be sent to it processed.", comment: "Error for a network renderer."))
        }
        return .processed(reasons)
    }
}
