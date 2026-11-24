//
// Vespertine: keeping the Mac, and for HDMI and DisplayPort outputs its display, awake while music plays.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit.pwr_mgt

/// What playing music needs kept awake.
///
/// An HDMI or DisplayPort output is a display's link: when macOS turns the display off, the link goes down, the receiver or TV
/// loses its signal and the output leaves Core Audio, so the music stops. The display stays on while those play. Every other
/// output (USB, the Mac's own, Bluetooth, AirPlay, a network player, a speaker group) only needs the Mac itself awake.
public enum KeepAwake: Equatable, Sendable {
    case nothing
    case system
    case systemAndDisplay

    /// How long an output that went away (playback waits for it and starts by itself when it is back) keeps the Mac awake.
    /// A receiver switched off at the end of the evening doesn't keep the screen on all night.
    public static let waitLimit: TimeInterval = 10 * 60

    /// Whether the output carries its sound on a display's link, which macOS drops when the display sleeps.
    public static func needsDisplay(_ transport: Transport) -> Bool { transport == .hdmi || transport == .displayPort }

    /// What to keep awake: while playing (a song started on this Mac, from the remote or from a control app alike), and while
    /// playback waits for its output to come back (for up to `waitLimit`). Nothing while paused or stopped.
    /// - Parameters:
    ///   - playing: the player is playing (buffering from a share counts: the song is meant to be heard).
    ///   - waited: how long playback has waited for its output, nil when it isn't waiting.
    ///   - transport: how the output is connected; nil when unknown.
    ///   - keepDisplay: the setting that keeps the display on for HDMI and DisplayPort (on unless turned off, say for an OLED
    ///     TV that shouldn't show the same picture for hours). Off, only the Mac is kept awake.
    public static func needed(playing: Bool, waited: TimeInterval?, transport: Transport?, keepDisplay: Bool = true) -> KeepAwake {
        let waiting = waited.map { $0 < waitLimit } ?? false
        guard playing || waiting else { return .nothing }
        return keepDisplay && transport.map(needsDisplay) == true ? .systemAndDisplay : .system
    }
}

/// The power assertions `PlaybackKeepAwake` holds: IOKit's, or a test's.
public protocol PowerAssertions: AnyObject {
    /// Holds an assertion of `type` (`kIOPMAssertPreventUserIdleSystemSleep`…). nil when macOS refused it.
    func create(_ type: String, reason: String) -> UInt32?
    func release(_ id: UInt32)
    /// Tells macOS the user is active: a display that is asleep wakes (and with it the HDMI or DisplayPort link).
    func declareUserActivity(reason: String)
}

/// IOKit's power assertions. They're listed by `pmset -g assertions`, under Vespertine, with their reasons.
public final class SystemPowerAssertions: PowerAssertions {
    public init() {}

    public func create(_ type: String, reason: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    public func release(_ id: UInt32) { IOPMAssertionRelease(id) }

    public func declareUserActivity(reason: String) {
        var id: IOPMAssertionID = 0
        // The display wakes now; the assertion that keeps it on is the display one, so this one goes at once.
        if IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess { IOPMAssertionRelease(id) }
    }
}

/// Holds the assertions for a `KeepAwake` level, changing only what differs from the last one set.
///
/// What macOS doesn't allow, it doesn't do: closing a MacBook's lid on battery sleeps it whatever is held (on power, with a
/// display connected, a closed MacBook stays awake, and an HDMI receiver counts as that display). Locking the screen doesn't
/// stop the music, and the assertions hold while it is locked.
public final class PlaybackKeepAwake {
    static let systemReason = "Vespertine is playing music"
    static let displayReason = "Vespertine is playing to an HDMI or DisplayPort output, which goes silent when the display sleeps"

    private let assertions: PowerAssertions
    private var systemID: UInt32?
    private var displayID: UInt32?
    public private(set) var level: KeepAwake = .nothing

    public init(assertions: PowerAssertions = SystemPowerAssertions()) { self.assertions = assertions }

    /// Whether exactly the assertions for `level` are held (macOS can refuse one).
    public var holdsLevel: Bool {
        switch level {
        case .nothing: systemID == nil && displayID == nil
        case .system: systemID != nil && displayID == nil
        case .systemAndDisplay: systemID != nil && displayID != nil
        }
    }

    public func set(_ new: KeepAwake) {
        guard new != level else { return }
        let wantsSystem = new != .nothing, wantsDisplay = new == .systemAndDisplay
        if wantsSystem, systemID == nil {
            systemID = assertions.create(kIOPMAssertPreventUserIdleSystemSleep, reason: Self.systemReason)
        } else if !wantsSystem, let id = systemID {
            assertions.release(id)
            systemID = nil
        }
        if wantsDisplay, displayID == nil {
            // Playing from the remote while the display is asleep: the link is down, so wake it. Playback waits for the
            // output and starts by itself once the receiver is back.
            assertions.declareUserActivity(reason: Self.displayReason)
            displayID = assertions.create(kIOPMAssertPreventUserIdleDisplaySleep, reason: Self.displayReason)
        } else if !wantsDisplay, let id = displayID {
            assertions.release(id)
            displayID = nil
        }
        level = new
    }

    deinit {
        if let systemID { assertions.release(systemID) }
        if let displayID { assertions.release(displayID) }
    }
}
