//
// Vespertine: a DoP choice (the switch or the test's answer) stays with its DAC in any USB port.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A FiiO KA15 has no USB serial number, so the third field of its Core Audio UID is its USB location, which is different
/// in every port. These are the UIDs one KA15 had on one MacBook Pro (2026-11-21): DoP was turned on twice, in two ports,
/// and the third port asked again.
private let ka15PortA = "AppleUSBAudioEngine:FIIO:FIIO KA15:1100000:2"
private let ka15PortB = "AppleUSBAudioEngine:FIIO:FIIO KA15:100000:2"
private let ka15PortC = "AppleUSBAudioEngine:FIIO:FIIO KA15:2100000:2"
private let mystery = "AppleUSBAudioEngine:Nobody:Mystery DAC:1100000:1"
private let mysteryElsewhere = "AppleUSBAudioEngine:Nobody:Mystery DAC:3200000:1"

private let emptyList = try! DoPDACList.decode(Data(#"{"schema":1,"revision":1,"dacs":[],"makers":[]}"#.utf8))

private func caps(dop: Bool = false) -> DeviceCapabilities {
    let rates: [Double] = [44_100, 48_000, 96_000, 176_400, 192_000, 352_800, 384_000]
    let formats = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: true, isMixable: false, channels: 2)]
    return DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop)
}

@Suite("DoP choices follow the DAC across USB ports")
struct DoPChoicePersistenceTests {
    @Test("The port-independent key drops only the serial or location field")
    func key() {
        #expect(DoPDeviceIdentity(uid: ka15PortA).portIndependentKey == DoPDeviceIdentity(uid: ka15PortC).portIndependentKey)
        #expect(DoPDeviceIdentity(uid: ka15PortA).isSameOutput(as: ka15PortB))
        #expect(!DoPDeviceIdentity(uid: ka15PortA).isSameOutput(as: mystery))
        // Another interface of the same DAC, another model, and non-USB UIDs stay apart.
        #expect(!DoPDeviceIdentity(uid: ka15PortA).isSameOutput(as: "AppleUSBAudioEngine:FIIO:FIIO KA15:1100000:1"))
        #expect(!DoPDeviceIdentity(uid: ka15PortA).isSameOutput(as: "AppleUSBAudioEngine:FIIO:FiiO K11:1100000:2"))
        #expect(DoPDeviceIdentity(uid: "BuiltInSpeakerDevice").portIndependentKey == nil)
        #expect(!DoPDeviceIdentity(uid: "BuiltInSpeakerDevice").isSameOutput(as: "BuiltInHeadphoneDevice"))
    }

    @Test("DoP turned on in one port is on after a reconnect in another port, and no test is offered again")
    func reconnectKeepsOn() {
        var choices = DoPChoices(on: [], off: [])
        choices.record(.music, for: mystery)
        let elsewhere = DoPDeviceIdentity(uid: mysteryElsewhere)
        #expect(DoPDefaults.isEnabled(elsewhere, on: choices.on, off: choices.off, list: emptyList))
        #expect(DoPDefaults.resolve(on: choices.on, off: choices.off, connectedDevices: [elsewhere], list: emptyList).contains(mysteryElsewhere))
        #expect(DoPSetupHint.decide(identity: elsewhere, transport: .usb, capabilities: caps(), on: choices.on, off: choices.off,
                                    list: emptyList) == .none)
    }

    @Test("A KA15 saved with DoP on in two old ports has it on in a third")
    func ka15ThirdPort() {
        let on: Set<String> = [ka15PortA, ka15PortB]
        let now = DoPDeviceIdentity(uid: ka15PortC)
        #expect(DoPDefaults.isEnabled(now, on: on, off: [], list: emptyList))
        #expect(DoPDefaults.resolve(on: on, off: [], connectedDevices: [now], list: emptyList).contains(ka15PortC))
    }

    @Test("A hiss answer or an off in one port keeps DoP off in another")
    func offFollowsToo() {
        var choices = DoPChoices(on: [], off: [])
        choices.record(.hiss, for: mystery)
        let elsewhere = DoPDeviceIdentity(uid: mysteryElsewhere)
        #expect(!DoPDefaults.isEnabled(elsewhere, on: choices.on, off: choices.off, list: emptyList))
        #expect(DoPSetupHint.decide(identity: elsewhere, transport: .usb, capabilities: caps(), on: choices.on, off: choices.off,
                                    list: emptyList) == .none)
    }

    @Test("The newest choice replaces older ones for the same DAC, so it is never in both sets")
    func newestWins() {
        var choices = DoPChoices(on: [ka15PortA, ka15PortB, mystery], off: [])
        choices.set(false, for: ka15PortC)
        #expect(choices.on == [mystery])
        #expect(choices.off == [ka15PortC])
        #expect(!DoPDefaults.isEnabled(DoPDeviceIdentity(uid: ka15PortA), on: choices.on, off: choices.off, list: emptyList))
        choices.set(true, for: ka15PortB)
        #expect(choices.on == [mystery, ka15PortB])
        #expect(choices.off.isEmpty)
        #expect(DoPDefaults.isEnabled(DoPDeviceIdentity(uid: ka15PortC), on: choices.on, off: choices.off, list: emptyList))
    }

    @Test("A choice for this exact UID still wins over one saved for the same DAC in another port")
    func exactFirst() {
        let here = DoPDeviceIdentity(uid: ka15PortA)
        #expect(DoPDefaults.isEnabled(here, on: [ka15PortA], off: [ka15PortB], list: emptyList))
        #expect(!DoPDefaults.isEnabled(here, on: [ka15PortB], off: [ka15PortA], list: emptyList))
    }

    @Test("The FiiO KA15 is on the bundled known-DoP list, by name and by USB ID, in any port")
    func ka15Listed() {
        let list = DoPDACList.bundled
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: ka15PortC))?.id == "fiio-ka15")
        #expect(list.knownDAC(for: DoPDeviceIdentity(uid: "AppleUSBAudioEngine:Other:Name:1:1", usbVendorID: 0x2972, usbProductID: 0x0104))?.id == "fiio-ka15")
        #expect(DoPDefaults.isEnabled(DoPDeviceIdentity(uid: ka15PortC), on: [], off: [], list: list))
    }
}
