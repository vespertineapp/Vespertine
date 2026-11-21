//
// Vespertine: a DoP choice made with the switch or the test is saved, read back after a relaunch, and follows the DAC
// to another USB port.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

@Suite("DoP choices survive a relaunch and a reconnect", .serialized) @MainActor
struct DoPChoiceAppTests {
    /// A DAC on no list with no USB serial number: the third field of its UID is the USB location, new in every port.
    private let portA = "AppleUSBAudioEngine:Nobody:Mystery DAC:1100000:2"
    private let portB = "AppleUSBAudioEngine:Nobody:Mystery DAC:2100000:2"

    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-dop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A suite named by absolute path keeps its plist in `root`, so nothing is left in ~/Library/Preferences.
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("The switch turned on is still on after a relaunch, in the same port and in another")
    func switchSurvivesRelaunch() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.isDoPOn(portA))
        settings.setDoP(true, for: portA)
        #expect(settings.isDoPOn(portA))

        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(relaunched.isDoPOn(portA))
        #expect(relaunched.isDoPOn(portB))
        #expect(relaunched.engineSettings().dopDeviceUIDs.contains(portA))
    }

    @Test("A passed DoP test is still on after a relaunch and a reconnect in another port")
    func testSurvivesRelaunchAndReconnect() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        AppSettings(defaults: defaults, dataDirectory: root).recordDoPTest(.music, for: portA)

        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(relaunched.isDoPOn(portB))
        #expect(DoPDefaults.resolve(on: relaunched.dopDeviceUIDs, off: relaunched.dopOffDeviceUIDs,
                                    connectedDevices: [DoPDeviceIdentity(uid: portB)]).contains(portB))
        #expect(DoPSetupHint.decide(identity: DoPDeviceIdentity(uid: portB), transport: .usb,
                                    capabilities: DeviceCapabilities(sampleRates: [44_100, 176_400, 352_800], physicalFormats: [],
                                                                     outputChannels: 2, supportsDoP: false),
                                    on: relaunched.dopDeviceUIDs, off: relaunched.dopOffDeviceUIDs,
                                    list: DoPDACListStore.shared.list) == .none)
    }

    @Test("Turned off in the new port, it stays off after a relaunch, in every port")
    func offInNewPortWins() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setDoP(true, for: portA)
        settings.setDoP(false, for: portB)
        #expect(settings.dopDeviceUIDs.isEmpty)

        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!relaunched.isDoPOn(portA))
        #expect(!relaunched.isDoPOn(portB))
    }
}
