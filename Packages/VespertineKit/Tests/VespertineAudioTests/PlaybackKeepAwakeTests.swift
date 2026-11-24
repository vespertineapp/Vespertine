//
// Vespertine: what playing music keeps awake (the Mac, and the display for HDMI and DisplayPort outputs), and that the
// assertions are taken and let go of as playback starts, pauses and waits for its output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit.pwr_mgt
import Testing
@testable import VespertineAudio

@Suite("Keeping the Mac awake while music plays")
struct PlaybackKeepAwakeTests {
    /// Records what would have been asked of IOKit.
    final class FakeAssertions: PowerAssertions {
        var held: [UInt32: String] = [:]
        var userActivity = 0
        var refuse = false
        private var next: UInt32 = 1

        func create(_ type: String, reason: String) -> UInt32? {
            guard !refuse else { return nil }
            defer { next += 1 }
            held[next] = type
            return next
        }

        func release(_ id: UInt32) {
            #expect(held[id] != nil, "released an assertion that wasn't held")
            held[id] = nil
        }

        func declareUserActivity(reason: String) { userActivity += 1 }

        var types: Set<String> { Set(held.values) }
    }

    private let system = kIOPMAssertPreventUserIdleSystemSleep
    private let display = kIOPMAssertPreventUserIdleDisplaySleep

    @Test("Only HDMI and DisplayPort outputs need the display", arguments: [
        (Transport.hdmi, true), (.displayPort, true), (.usb, false), (.builtIn, false), (.bluetooth, false), (.bluetoothLE, false),
        (.airPlay, false), (.thunderbolt, false), (.pci, false), (.aggregate, false), (.virtual, false), (.unknown, false),
    ])
    func displayTransports(transport: Transport, needsDisplay: Bool) {
        #expect(KeepAwake.needsDisplay(transport) == needsDisplay)
    }

    @Test("Playing keeps the Mac awake on every output, and the display too on HDMI")
    func playing() {
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: .usb) == .system)
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: .builtIn) == .system)
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: nil) == .system)
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: .hdmi) == .systemAndDisplay)
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: .displayPort) == .systemAndDisplay)
    }

    @Test("With the display setting off, HDMI keeps only the Mac awake")
    func displaySettingOff() {
        #expect(KeepAwake.needed(playing: true, waited: nil, transport: .hdmi, keepDisplay: false) == .system)
        #expect(KeepAwake.needed(playing: false, waited: 5, transport: .displayPort, keepDisplay: false) == .system)
        #expect(KeepAwake.needed(playing: false, waited: nil, transport: .hdmi, keepDisplay: false) == .nothing)
    }

    @Test("Paused or stopped keeps nothing awake")
    func notPlaying() {
        for transport: Transport? in [.hdmi, .usb, nil] {
            #expect(KeepAwake.needed(playing: false, waited: nil, transport: transport) == .nothing)
        }
    }

    @Test("Waiting for an output that went away keeps it awake for ten minutes, then lets go")
    func waiting() {
        #expect(KeepAwake.needed(playing: false, waited: 0, transport: .hdmi) == .systemAndDisplay)
        #expect(KeepAwake.needed(playing: false, waited: 599, transport: .hdmi) == .systemAndDisplay)
        #expect(KeepAwake.needed(playing: false, waited: 599, transport: .usb) == .system)
        #expect(KeepAwake.needed(playing: false, waited: KeepAwake.waitLimit, transport: .hdmi) == .nothing)
        // Playing again after a long wait: kept awake as for any song.
        #expect(KeepAwake.needed(playing: true, waited: 3600, transport: .hdmi) == .systemAndDisplay)
    }

    @Test("Play, pause and play again on HDMI: both assertions taken, both let go, the display woken each time it is needed")
    func hdmiCycle() {
        let fake = FakeAssertions()
        let keeper = PlaybackKeepAwake(assertions: fake)
        keeper.set(.systemAndDisplay)
        #expect(fake.types == [system, display])
        #expect(fake.userActivity == 1)
        #expect(keeper.holdsLevel)
        keeper.set(.systemAndDisplay)
        #expect(fake.held.count == 2)
        #expect(fake.userActivity == 1, "setting the same level again changes nothing")
        keeper.set(.nothing)
        #expect(fake.held.isEmpty)
        #expect(keeper.holdsLevel)
        keeper.set(.systemAndDisplay)
        #expect(fake.types == [system, display])
        #expect(fake.userActivity == 2)
    }

    @Test("Moving from HDMI to a USB DAC mid-song lets the display sleep and keeps the Mac awake")
    func outputChange() {
        let fake = FakeAssertions()
        let keeper = PlaybackKeepAwake(assertions: fake)
        keeper.set(.systemAndDisplay)
        let systemID = fake.held.first { $0.value == system }?.key
        keeper.set(.system)
        #expect(fake.types == [system])
        #expect(fake.held.first?.key == systemID, "the Mac's assertion is kept, not taken again")
        keeper.set(.systemAndDisplay)
        #expect(fake.types == [system, display])
        #expect(fake.userActivity == 2)
    }

    @Test("A USB DAC never touches the display")
    func usbOnly() {
        let fake = FakeAssertions()
        let keeper = PlaybackKeepAwake(assertions: fake)
        keeper.set(.system)
        #expect(fake.types == [system])
        #expect(fake.userActivity == 0)
        keeper.set(.nothing)
        #expect(fake.held.isEmpty)
    }

    @Test("Going away while held lets everything go")
    func deinitReleases() {
        let fake = FakeAssertions()
        do {
            let keeper = PlaybackKeepAwake(assertions: fake)
            keeper.set(.systemAndDisplay)
            #expect(fake.held.count == 2)
        }
        #expect(fake.held.isEmpty)
    }

    @Test("An assertion macOS refuses is reported as not held")
    func refused() {
        let fake = FakeAssertions()
        fake.refuse = true
        let keeper = PlaybackKeepAwake(assertions: fake)
        keeper.set(.system)
        #expect(!keeper.holdsLevel)
        keeper.set(.nothing)
        #expect(keeper.holdsLevel)
    }

    @Test("The real assertions are taken and let go (pmset lists them while held)")
    func realAssertions() {
        let keeper = PlaybackKeepAwake(assertions: SystemPowerAssertions())
        keeper.set(.system)
        #expect(keeper.holdsLevel)
        keeper.set(.nothing)
        #expect(keeper.holdsLevel)
    }
}
