//
// Vespertine Remote: Play On ticks where the music plays and names it on its button; and the slider for this
// device's volume stays under the finger, sets the system's volume, and lets go when iOS reports the level.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemote

@MainActor
@Suite struct PlayOnChoosing {
    @Test func setupsTwoCardsTurnASideOnOrOffAndTheLastOneStaysOn() {
        #expect(PlaySides.both.toggling(mac: true) == .device)
        #expect(PlaySides.both.toggling(mac: false) == .mac)
        #expect(PlaySides.mac.toggling(mac: false) == .both)
        #expect(PlaySides.device.toggling(mac: true) == .both)
        #expect(PlaySides.mac.toggling(mac: true) == .mac)
        #expect(PlaySides.device.toggling(mac: false) == .device)
    }

    @Test func choosingTheSideLeftOutBringsBothBack() {
        #expect(PlaySides.including(.mac, thisDevice: true) == .both)
        #expect(PlaySides.including(.device, thisDevice: false) == .both)
        #expect(PlaySides.including(.mac, thisDevice: false) == .mac)
        #expect(PlaySides.including(.device, thisDevice: true) == .device)
        #expect(PlaySides.including(.both, thisDevice: true) == .both)
        #expect(PlaySides.both.hasMac && PlaySides.both.hasDevice)
        #expect(!PlaySides.mac.hasDevice && !PlaySides.device.hasMac)
    }

    @Test func oneTickSaysWhereTheMusicPlays() {
        // The Mac plays: its chosen output is ticked, this device isn't.
        #expect(PlayOnRules.macChecked(selected: true, playsHere: false))
        #expect(!PlayOnRules.deviceChecked(playsHere: false))
        // This device plays: it is ticked, and the Mac's chosen output no longer is, though the Mac keeps the choice.
        #expect(PlayOnRules.deviceChecked(playsHere: true))
        #expect(!PlayOnRules.macChecked(selected: true, playsHere: true))
        // An output the Mac didn't choose is never ticked.
        #expect(!PlayOnRules.macChecked(selected: false, playsHere: false))
    }

    @Test func thisDeviceCanBeChosenWhenTheMacCanSendSongsOrTheSongsAreHere() {
        #expect(PlayOnRules.canChooseDevice(canPlayHere: true, share: false))
        #expect(!PlayOnRules.canChooseDevice(canPlayHere: false, share: false))
        #expect(PlayOnRules.canChooseDevice(canPlayHere: false, share: true))
    }

    @Test func aShareOrFolderListsNoMacOutputs() {
        #expect(PlayOnRules.listsMac(share: false))
        #expect(!PlayOnRules.listsMac(share: true))
    }

    @Test func theButtonNamesTheOutputInUse() {
        func name(_ playsHere: Bool, route: String? = nil, output: String? = nil) -> String {
            PlayOnRules.shownName(playsHere: playsHere, route: route, macOutput: output, macName: "Studio Mac mini", device: "This iPhone")
        }
        #expect(name(false, output: "Desk DAC") == "Desk DAC")
        #expect(name(false) == "Studio Mac mini")
        #expect(name(false, output: "") == "Studio Mac mini")
        #expect(name(true, route: "AirPods Max", output: "Desk DAC") == "AirPods Max")
        #expect(name(true) == "This iPhone")
        #expect(PlayOnRules.symbol(playsHere: true, pad: true) == "ipad")
        #expect(PlayOnRules.symbol(playsHere: true, pad: false) == "iphone")
        #expect(PlayOnRules.symbol(playsHere: false, pad: false) == PlayOnRules.symbol(playsHere: false, pad: true))
    }

    @Test func playOnHasNoTabOfItsOwnOnAPhone() {
        #expect(RemoteDestination.output.compactTab == .nowPlaying)
        #expect(RemoteDestination.starting(at: "output") == .output)
        #expect(RemoteDestination.output.title == String(localized: "Play On"))
    }
}

@MainActor
@Suite struct DeviceVolumeSlider {
    @Test func theSliderShowsWhatIOSReportsUntilItIsDragged() {
        let volume = DeviceVolume()
        #expect(volume.shown(reported: 0.4) == 0.4)
        #expect(volume.shown(reported: nil) == 0)
        volume.drag(to: 0.7)
        #expect(volume.shown(reported: 0.4) == 0.7)
    }

    @Test func aLevelIOSNeverReportedIsNotShownAsZero() {
        let volume = DeviceVolume()
        #expect(volume.label(reported: nil) == "—")
        #expect(volume.label(reported: 0.3) == DeviceVolume.percent(0.3))
        volume.drag(to: 0.7)
        #expect(volume.label(reported: nil) == DeviceVolume.percent(0.7))
    }

    @Test func aDragSetsTheSystemVolumeAtEveryStep() {
        let volume = DeviceVolume()
        var set: [Double] = []
        volume.apply = { set.append($0) }
        volume.drag(to: 0.25)
        volume.drag(to: 0.5)
        volume.drag(to: 1.4)
        volume.drag(to: -.infinity)
        #expect(set == [0.25, 0.5, 1, 0])
    }

    @Test func reportsDuringADragAreOlderThanTheFinger() {
        let volume = DeviceVolume()
        volume.drag(to: 0.8)
        volume.reported(0.8)
        #expect(volume.held == 0.8)
    }

    @Test func theSliderLetsGoWhenIOSReportsTheLevelAskedFor() {
        let volume = DeviceVolume()
        volume.settle = .seconds(600)
        volume.drag(to: 0.8)
        volume.end()
        volume.reported(0.3)
        #expect(volume.held == 0.8)
        volume.reported(0.81)
        #expect(volume.held == nil)
        #expect(volume.shown(reported: 0.81) == 0.81)
    }

    @Test func theSliderLetsGoAfterAMomentWhenIOSNeverReportsTheLevel() async throws {
        let volume = DeviceVolume()
        volume.settle = .milliseconds(1)
        volume.drag(to: 0.6)
        volume.end()
        for _ in 0..<400 where volume.held != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(volume.held == nil)
    }

    @Test func aNewDragTakesOverFromAnEndedOne() async throws {
        let volume = DeviceVolume()
        volume.settle = .milliseconds(20)
        volume.drag(to: 0.6)
        volume.end()
        volume.drag(to: 0.2)
        try await Task.sleep(for: .milliseconds(80))
        #expect(volume.held == 0.2)
    }

    @Test func theLevelIsSaidAsAWholePercentage() {
        #expect(DeviceVolume.percent(0.624).filter(\.isNumber) == "62")
        #expect(DeviceVolume.percent(7).filter(\.isNumber) == "100")
        #expect(DeviceVolume.percent(.nan).filter(\.isNumber) == "0")
    }
}

@MainActor
@Suite struct NowPlayingOnAShortScreen {
    @Test func aShortUprightScreenIsTightAndATallOrWideOneIsNot() {
        #expect(RemoteLayout.playerIsTight(height: 520, columns: false))
        #expect(!RemoteLayout.playerIsTight(height: 700, columns: false))
        #expect(!RemoteLayout.playerIsTight(height: 320, columns: true))
    }

    @Test func aTightScreenGivesTheCoverAndTheGapsLessRoom() {
        let tight = RemoteLayout.coverSide(width: 320, height: 500, columns: false, tight: true)
        let roomy = RemoteLayout.coverSide(width: 320, height: 500, columns: false)
        #expect(tight < roomy)
        #expect(tight >= 120)
        #expect(RemoteLayout.playerSpacing(tight: true).parts < RemoteLayout.playerSpacing(tight: false).parts)
        #expect(RemoteLayout.playerSpacing(tight: true).controls < RemoteLayout.playerSpacing(tight: false).controls)
        #expect(RemoteLayout.playModeSwitchHeight(tight: true) < RemoteLayout.playModeSwitchHeight(tight: false))
    }
}
