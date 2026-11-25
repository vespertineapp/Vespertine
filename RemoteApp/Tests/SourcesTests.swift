//
// Vespertine: the Sources screen: what can be turned on or off, and the line that says how each source is doing.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineShare
@testable import VespertineRemote

@MainActor
@Suite struct Sources {
    @Test func theLastSourceOnStaysOn() {
        // Something has to be the library: the only one on can't be turned off.
        #expect(!SourceRules.canSwitch("mac", on: false, inUse: ["mac"]))
        #expect(SourceRules.canSwitch("mac", on: false, inUse: ["mac", "nas"]))
        // Turning one on is always allowed, from nothing too.
        #expect(SourceRules.canSwitch("nas", on: true, inUse: ["mac"]))
        #expect(SourceRules.canSwitch("nas", on: true, inUse: []))
    }

    @Test func aMacSaysItIsConnectedOrHowItCouldBeReached() {
        let connected = SourceLine.mac(.connected, onThisNetwork: false, address: nil)
        let connecting = SourceLine.mac(.connecting, onThisNetwork: true, address: nil)
        let here = SourceLine.mac(nil, onThisNetwork: true, address: nil)
        let away = SourceLine.mac(.unreachable("gone"), onThisNetwork: false, address: nil)
        #expect(Set([connected, connecting, here, away]).count == 4)
        // Not open (turned off), it still says whether it could be reached.
        #expect(SourceLine.mac(nil, onThisNetwork: true, address: nil) == SourceLine.mac(.closed, onThisNetwork: true, address: nil))
    }

    @Test func aShareSaysItIsReadingWhatItFoundOrWhyItCantBeUsed() {
        // Turned off, a share says where it is, and a folder says nothing.
        #expect(SourceLine.library(nil, closed: "smb://nas.local/music") == "smb://nas.local/music")
        #expect(SourceLine.library(nil, closed: nil) == nil)
        var status = ShareStatus()
        status.songs = 14_982
        let done = SourceLine.library(status, closed: nil)
        #expect(done.map(digits)?.contains("14982") == true)
        // While it reads, the count so far shows, and goes up.
        status.scan = .scanning(songs: 2_314)
        let reading = SourceLine.library(status, closed: nil)
        #expect(reading.map(digits)?.contains("2314") == true)
        #expect(reading != done)
        // Can't be used: the reason, the same words as everywhere else.
        status.scan = .failed(.signInFailed)
        #expect(SourceLine.library(status, closed: nil) == status.trouble)
    }

    /// The digits of a line, whatever the locale groups them with.
    private func digits(_ text: String) -> String { String(text.filter(\.isNumber)) }
}
