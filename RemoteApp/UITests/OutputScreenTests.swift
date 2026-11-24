// Run serially, on an explicitly selected simulator. No network or real pairing required.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest

/// The Output screen: the Mac / This iPhone switch is the one place to choose who plays, and the list under it shows only
/// the outputs of whoever plays. A "This iPhone" row among the Mac's outputs said the opposite of the switch
/// (TestFlight tf-14dc80248f).
@MainActor
final class OutputScreenTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testMacPlayingListsOnlyTheMacsOutputs() {
        // The demo's pretend Mac plays, so nothing makes a sound.
        app.launchArguments = ["-VTDemo", "YES", "-VTScreen", "output", "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
        app.launch()

        let mac = element("play-mode-mac")
        XCTAssertTrue(mac.waitForExistence(timeout: 15))
        XCTAssertTrue(mac.isSelected, "the switch says the Mac plays")
        XCTAssertFalse(element("play-mode-device").isSelected)
        // The Mac's outputs, the demo DAC ticked; no row for this device among them.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Desk DAC'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(element("output-this-device").exists, "no This iPhone row while the Mac plays")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Plays through this device'")).count, 0)

        // The switch moves who plays, and the list follows it both ways.
        element("play-mode-device").tap()
        XCTAssertTrue(element("output-this-device").waitForExistence(timeout: 10))
        XCTAssertTrue(element("play-mode-device").isSelected)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Desk DAC'")).firstMatch.exists)
        element("play-mode-mac").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Desk DAC'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(element("play-mode-mac").isSelected)
        XCTAssertFalse(element("output-this-device").exists)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
}
