// Run serially, on an explicitly selected simulator. No network or real pairing required.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest

/// Play On: one list for who plays and through what. This device and the Mac's outputs sit side by side, one tick says
/// where the music plays, and a tap on another row moves it there. It opens from Now Playing and the mini player, and
/// replaces the Mac / This iPhone switch and the Output tab.
@MainActor
final class PlayOnTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testOneTickSaysWhereTheMusicPlaysAndATapMovesIt() {
        // The demo's pretend Mac is chosen and nothing is played, so nothing makes a sound.
        app.launchArguments = ["-VTDemo", "YES", "-VTScreen", "output", "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Play On"].waitForExistence(timeout: 15))
        let desk = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Desk DAC'")).firstMatch
        let here = element("output-this-device")
        XCTAssertTrue(desk.waitForExistence(timeout: 10))
        XCTAssertTrue(here.exists, "this device is listed beside the Mac's outputs")
        XCTAssertTrue(desk.isSelected, "the Mac plays through its chosen output")
        XCTAssertFalse(here.isSelected)
        XCTAssertTrue(element("play-on-info-mac").exists)
        XCTAssertFalse(element("play-on-info-device").exists)

        // This device: it takes the tick, and the Mac's output gives it up.
        here.tap()
        XCTAssertTrue(element("play-on-info-device").waitForExistence(timeout: 10))
        XCTAssertTrue(here.isSelected)
        XCTAssertFalse(desk.isSelected)
        XCTAssertFalse(element("play-on-info-mac").exists)

        // Its ⓘ is this device's sound.
        element("play-on-info-device").tap()
        XCTAssertTrue(element("device-sound").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // One of the Mac's outputs: the music moves back to the Mac.
        XCTAssertTrue(desk.waitForExistence(timeout: 5))
        desk.tap()
        XCTAssertTrue(element("play-on-info-mac").waitForExistence(timeout: 10))
        XCTAssertTrue(desk.isSelected)
        XCTAssertFalse(here.isSelected)
        element("play-on-info-mac").tap()
        XCTAssertTrue(element("mac-sound").waitForExistence(timeout: 5))
    }

    func testPlayOnOpensFromNowPlayingAndTheMiniPlayer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The phone's tab layout.")
        app.launchArguments = ["-VTDemo", "YES", "-VTPlay", "YES", "-VTScreen", "nowPlaying", "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
        app.launch()

        // On Now Playing: the button names the Mac's output the music plays through.
        let button = element("play-on")
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertTrue((button.value as? String ?? "").hasPrefix("Desk DAC"), "the button names the output: \(String(describing: button.value))")
        XCTAssertFalse(element("play-mode").exists, "no Mac / This iPhone switch")
        button.tap()
        XCTAssertTrue(app.navigationBars["Play On"].waitForExistence(timeout: 5))
        element("play-on-done").tap()
        XCTAssertFalse(app.navigationBars["Play On"].waitForExistence(timeout: 2))

        // No Output tab; the mini player opens the same list.
        XCTAssertFalse(app.tabBars.buttons["Output"].exists)
        app.tabBars.buttons["Library"].tap()
        let mini = element("play-on-mini")
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertTrue(app.navigationBars["Play On"].waitForExistence(timeout: 5))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
}
