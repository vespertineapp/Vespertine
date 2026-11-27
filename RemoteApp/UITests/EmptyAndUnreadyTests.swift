// Run serially, on an explicitly selected simulator. No network or real pairing required.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest

/// Pages with nothing on them say so, and a row that can't be chosen says why: a blank page under a search field, and an
/// output in the warning colour with no reason, both looked broken.
@MainActor
final class EmptyAndUnreadyTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testOnThisDeviceSaysWhenNothingIsKept() {
        // The demo keeps nothing.
        app.launchArguments = ["-VTDemo", "YES", "-VTScreen", "kept", "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
        app.launch()

        XCTAssertTrue(element("kept-lists").waitForExistence(timeout: 15))
        XCTAssertTrue(element("kept-empty").waitForExistence(timeout: 5), "an empty shelf says how to keep something")
    }

    func testAnOutputThatCantBeChosenSaysWhy() {
        app.launchArguments = ["-VTDemo", "YES", "-VTScreen", "output", "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Play On"].waitForExistence(timeout: 15))
        let group = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Speaker group'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertTrue(group.label.hasSuffix("Not connected"), "the demo's speaker group says why it can't be chosen: \(group.label)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
