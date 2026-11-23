//
// Vespertine: one stretch of keeping music while the app is in the background, as iOS's background task sees it: how far
// along it is (a hundred units a song, so the song arriving counts in part), whether it is done, and whether it has stopped
// moving for long enough (no connection, no room, cellular data off) that the time should be given back to iOS rather than
// held. The app keeps the device awake for this only through the background tasks iOS offers; it never plays silence.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct KeepingRun: Sendable, Equatable {
    public enum Step: Equatable, Sendable {
        case working
        /// Nothing is left to keep.
        case finished
        /// Songs are left but nothing has moved for `patience`: the time goes back to iOS.
        case stalled
    }

    /// The whole run, in hundredths of a song.
    public private(set) var units: Int64
    private var total: Int
    private var idleSince: Date?
    public let patience: TimeInterval

    /// A run that starts with `remaining` songs to keep.
    public init(remaining: Int, patience: TimeInterval = 60) {
        total = max(0, remaining)
        units = Int64(total) * 100
        self.patience = patience
    }

    /// How much of the run is done with `remaining` songs left and the one arriving `fraction` of the way in.
    public func completed(remaining: Int, fraction: Double?) -> Int64 {
        let done = Int64(max(0, total - remaining)) * 100
        return min(units, done + Int64(((fraction ?? 0) * 100).rounded(.down)))
    }

    /// More was chosen while it runs: the whole grows by it, what is done stays done.
    public mutating func noteMore(remaining: Int, completed: Int64) {
        units = completed + Int64(max(0, remaining)) * 100
        total = max(0, remaining) + Int(completed / 100)
    }

    /// Where the run is, looked at `now`: `idle` when the keeper isn't fetching anything.
    public mutating func step(remaining: Int, idle: Bool, now: Date) -> Step {
        if remaining == 0 { return .finished }
        guard idle else {
            idleSince = nil
            return .working
        }
        let since = idleSince ?? now
        idleSince = since
        return now.timeIntervalSince(since) > patience ? .stalled : .working
    }
}
