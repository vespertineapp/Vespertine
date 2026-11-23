//
// Vespertine: keeping music in the background goes through iOS's background tasks: their identifiers must be in Info.plist
// (or iOS refuses them at run time, with nothing on screen), and the continued one must sit under a wildcard that starts
// with the app's own bundle identifier. And a kept DSD file reads through the player's byte source as KeptDSD makes it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemote

@MainActor
@Suite struct KeepInBackgroundTests {
    @Test func theBackgroundTasksAreAllowedByInfoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let permitted = try #require(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        #expect(permitted.contains(KeepInBackground.overnightID))
        let bundle = try #require(Bundle.main.bundleIdentifier)
        let wildcard = try #require(permitted.first { $0.hasSuffix(".*") })
        #expect(wildcard.hasPrefix(bundle + "."))
        #expect(KeepInBackground.continuedID.hasPrefix(String(wildcard.dropLast(1))))
        #expect(KeepInBackground.overnightID.hasPrefix(bundle + "."))
        // Background processing is declared for the overnight task; audio is there for music that plays, not for this.
        let modes = try #require(info["UIBackgroundModes"] as? [String])
        #expect(modes.contains("processing") && modes.contains("audio"))
    }
}
