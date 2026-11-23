//
// Vespertine: keeping music while the app is in the background. iOS gives the app a background task (on iOS 26 and later
// one the person started by choosing Keep on This Device, which shows its progress; on any version one overnight on power
// and Wi-Fi). A run says how far along it is, ends when nothing is left, and gives the time back when it can't move (no
// connection, no room, cellular data off) rather than holding on to it. Nothing here plays sound to stay awake.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertinePhonePlayer

@Suite struct KeepingRunTests {
    @Test func progressCountsWholeSongsAndThePartOfTheOneArriving() {
        var run = KeepingRun(remaining: 4)
        #expect(run.units == 400)
        #expect(run.completed(remaining: 4, fraction: nil) == 0)
        #expect(run.completed(remaining: 4, fraction: 0.5) == 50)
        #expect(run.completed(remaining: 2, fraction: 0.25) == 225)
        // More was chosen meanwhile: the whole grows, what is done stays done.
        run.noteMore(remaining: 5, completed: 225)
        #expect(run.units == 725)
    }

    @Test func aRunEndsWhenNothingIsLeft() {
        var run = KeepingRun(remaining: 2)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(run.step(remaining: 2, idle: false, now: start) == .working)
        #expect(run.step(remaining: 0, idle: true, now: start + 5) == .finished)
    }

    @Test func aRunThatCantMoveGivesItsTimeBackAfterAMinute() {
        var run = KeepingRun(remaining: 3)
        let start = Date(timeIntervalSince1970: 1000)
        // Idle with songs left: the connection went, or the room ran out. A moment of it is allowed (between songs).
        #expect(run.step(remaining: 3, idle: true, now: start) == .working)
        #expect(run.step(remaining: 3, idle: true, now: start + 30) == .working)
        // It moved again: the clock starts over.
        #expect(run.step(remaining: 2, idle: false, now: start + 40) == .working)
        #expect(run.step(remaining: 2, idle: true, now: start + 50) == .working)
        #expect(run.step(remaining: 2, idle: true, now: start + 109) == .working)
        #expect(run.step(remaining: 2, idle: true, now: start + 111) == .stalled)
    }
}
