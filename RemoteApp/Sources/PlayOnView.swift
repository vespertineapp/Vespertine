//
// Vespertine Remote: Play On: one list that says who plays and through what. This device (its speaker, headphones,
// AirPlay or a DAC) and the Mac's outputs sit side by side; choosing one is choosing who plays. Each output's sound
// settings are a tap away under its ⓘ. It replaces the Mac / This iPhone switch and the Output tab.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

/// Who plays and through what: the rules the Play On list, its button and the tests share.
nonisolated enum PlayOnRules {
    /// This device's row is ticked while it plays.
    static func deviceChecked(playsHere: Bool) -> Bool { playsHere }
    /// A Mac output is ticked only while the Mac plays. The Mac keeps its choice while this device plays, but the music
    /// isn't there, and two ticks would say it plays in two places.
    static func macChecked(selected: Bool, playsHere: Bool) -> Bool { selected && !playsHere }
    /// This device can be chosen when the Mac can send it songs. A share or a folder always plays here.
    static func canChooseDevice(canPlayHere: Bool, share: Bool) -> Bool { share || canPlayHere }
    /// The Mac's outputs are listed for a Mac; a share or a folder has none.
    static func listsMac(share: Bool) -> Bool { !share }

    /// What the Play On button says: the output in use, or who plays while that isn't known yet.
    static func shownName(playsHere: Bool, route: String?, macOutput: String?, macName: String, device: String) -> String {
        func named(_ name: String?) -> String? { name.flatMap { $0.isEmpty ? nil : $0 } }
        return playsHere ? named(route) ?? device : named(macOutput) ?? macName
    }

    static func symbol(playsHere: Bool, pad: Bool) -> String {
        playsHere ? (pad ? "ipad" : "iphone") : "desktopcomputer"
    }
}

/// Where the music plays now, as a button that opens Play On: on Now Playing, and as a symbol in the mini player.
struct PlayOnButton: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    /// Only the symbol, for the mini player.
    var symbolOnly = false

    var body: some View {
        Button { model.showingPlayOn = true } label: {
            if symbolOnly {
                Image(systemName: symbol).font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
            } else {
                HStack(spacing: 8) {
                    Image(systemName: symbol).accessibilityHidden(true)
                    Text(verbatim: name).lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.text3).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Palette.text.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...RemoteLayout.bannerLargestText)
        .accessibilityLabel(Text("Play On"))
        .accessibilityValue(Text(verbatim: name))
        .accessibilityIdentifier(symbolOnly ? "play-on-mini" : "play-on")
    }

    private var playsHere: Bool { session.phone != nil }
    private var mac: RemoteSession { model.macSession ?? session }
    private var symbol: String { PlayOnRules.symbol(playsHere: playsHere, pad: UIDevice.current.userInterfaceIdiom == .pad) }
    private var name: String {
        PlayOnRules.shownName(playsHere: playsHere, route: session.phone?.route?.name, macOutput: session.player?.output,
                              macName: mac.server?.name ?? mac.pairing.name, device: PlayTarget.deviceName)
    }
}

nonisolated private enum PlayOnPage: Hashable { case device, mac }

/// The list: this device, then the Mac's outputs. A tick is where the music plays; a tap anywhere else moves it there.
struct PlayOnView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession
    /// A sheet, with Done. In an iPad's sidebar it is a page of its own.
    var sheet = true
    @State private var feedback = CommandFeedback()
    @State private var path: [PlayOnPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    deviceRow
                } header: {
                    Text(verbatim: PlayTarget.deviceName)
                } footer: {
                    if mac.isConnected, !canChooseDevice { Text("Update Vespertine on the Mac to play here.") }
                }
                if PlayOnRules.listsMac(share: session.isShare) {
                    Section {
                        ForEach(Array((session.outputs?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                            macRow(output)
                        }
                    } header: {
                        Text(verbatim: macName)
                    } footer: {
                        Text("Choose one of these and Vespertine on the Mac plays there.")
                    }
                }
            }
            .obsidianList()
            .navigationTitle("Play On").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("play-on-done")
                    }
                }
            }
            .navigationDestination(for: PlayOnPage.self) { page in
                switch page {
                case .device: DeviceSoundView(session: session)
                case .mac: MacSoundView(session: session)
                }
            }
            .feedback(feedback)
            // The list that names the output reads it as it comes up, not from whatever was last heard.
            .onAppear { _ = session.phone?.readOutput?(.shown) }
        }
    }

    private var playsHere: Bool { session.phone != nil }
    private var canChooseDevice: Bool { PlayOnRules.canChooseDevice(canPlayHere: PlayTarget.shared.canPlayHere(session), share: session.isShare) }
    /// The Mac's own connection: the session itself, or the Mac among several libraries open as one.
    private var mac: RemoteSession { model.macSession ?? session }
    private var macName: String { mac.server?.name ?? mac.pairing.name }

    /// This device: where its sound goes now (the speaker, headphones, AirPlay or a DAC, as iOS names it), with the
    /// system's own list of those a tap away while it plays.
    private var deviceRow: some View {
        HStack(spacing: 4) {
            Button { PlayTarget.shared.choose(thisDevice: true) } label: {
                HStack {
                    Image(systemName: PlayOnRules.symbol(playsHere: true, pad: UIDevice.current.userInterfaceIdiom == .pad))
                        .rowIconColumn()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: session.phone?.route?.name ?? PlayTarget.deviceName)
                        if let rate = hereRate { Text(rate).font(.caption.monospaced()).foregroundStyle(Color.secondary) }
                    }
                    Spacer()
                    if PlayOnRules.deviceChecked(playsHere: playsHere) {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canChooseDevice)
            .opacity(canChooseDevice ? 1 : 0.45)
            .accessibilityAddTraits(playsHere ? .isSelected : [])
            .accessibilityIdentifier("output-this-device")
            if RoutePickerPlacement.shows(playsHere: playsHere) {
                RoutePickerButton().frame(width: 44, height: 44)
                    .accessibilityIdentifier("airplay")
            }
            if playsHere { infoButton(.device, name: PlayTarget.deviceName) }
        }
    }

    private func macRow(_ output: OutputSummary) -> some View {
        let checked = PlayOnRules.macChecked(selected: output.selected, playsHere: playsHere)
        return HStack(spacing: 4) {
            Button { choose(output.uid) } label: {
                HStack {
                    Image(systemName: icon(output.kind))
                        .rowIconColumn()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.name)
                        Text(output.detail).font(.caption.monospaced()).foregroundStyle(output.ready ? Color.secondary : Palette.copper)
                    }
                    Spacer()
                    if checked { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
            if checked { infoButton(.mac, name: output.name) }
        }
    }

    /// Choosing one of the Mac's outputs is choosing the Mac: this device stops, and the Mac plays there.
    private func choose(_ uid: String?) {
        if playsHere { PlayTarget.shared.choose(thisDevice: false) }
        feedback.run(session, .selectOutput(uid: uid))
    }

    /// ⓘ: the sound settings of the output that plays.
    private func infoButton(_ page: PlayOnPage, name: String) -> some View {
        Button { path.append(page) } label: {
            Image(systemName: "info.circle").font(.title3).foregroundStyle(Palette.brass)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Settings for “\(name)”"))
        .accessibilityIdentifier(page == .device ? "play-on-info-device" : "play-on-info-mac")
    }

    /// The rate this device's output runs at, when iOS says.
    private var hereRate: String? {
        guard let route = session.phone?.route, route.sampleRate > 0 else { return nil }
        return String(localized: "\(PhoneSignal.kilohertz(route.sampleRate)) kHz", comment: "Signal chip: a sample rate.")
    }

    private func icon(_ kind: OutputKind) -> String {
        switch kind {
        case .systemDefault: "speaker.wave.2"
        case .device: "hifispeaker"
        case .speakerGroup: "hifispeaker.2"
        }
    }
}

/// This device's sound: where it goes, Spatial Audio, ReplayGain, what reaches the output, and the DoP test.
struct DeviceSoundView: View {
    let session: RemoteSession

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                        .rowIconColumn()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hereName)
                        if let rate = hereRate { Text(rate).font(.caption.monospaced()).foregroundStyle(Color.secondary) }
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                if playsHere {
                    // Off, or Spatial Audio: iOS renders it, Fixed or Head Tracked as chosen in Control Center.
                    Picker("Surround on Headphones", selection: Binding(get: {
                        PlayTarget.pickerValue(PlayTarget.shared.surround)
                    }, set: { PlayTarget.shared.surround = $0 })) {
                        Text("Off").tag(SpatialModeChoice.off)
                        Text("Spatial Audio").tag(SpatialModeChoice.fixed)
                    }
                }
            } footer: {
                if session.isFolder {
                    Text("This device plays the songs from the folder itself, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                } else if session.isShare {
                    Text("This device reads the songs from the share itself and plays them, through its speaker, headphones or a DAC. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                } else {
                    Text("The Mac sends the songs and this device plays them, through its speaker, headphones or a DAC. The Mac’s own playback isn’t touched. Surround songs (5.1, 7.1, Dolby Atmos) go to iOS with all their channels, and iOS plays them as Spatial Audio on AirPods and Beats that have it on, as Apple Music does; choose Fixed or Head Tracked in Control Center (touch and hold the volume slider). Other headphones get Vespertine’s own fixed rendering. On speakers, or when this is Off, they’re folded to stereo.")
                }
            }
            if playsHere {
                Section {
                    Picker("ReplayGain", selection: Binding(get: { PlayTarget.shared.replayGain }, set: { PlayTarget.shared.replayGain = $0 })) {
                        Text("Off").tag(ReplayGainChoice.off)
                        Text("Track").tag(ReplayGainChoice.track)
                        Text("Album").tag(ReplayGainChoice.album)
                    }
                } footer: {
                    Text("Plays songs at a matched loudness, using the ReplayGain values in their files: Track for each song by itself, Album to keep an album’s quiet and loud songs as they are. Off, no sample is changed. A song without values, and DSD sent to a DAC as DoP, play unchanged either way.")
                }
            }
            if playsHere, let phone = session.phone, let signal = phone.signal {
                Section {
                    ForEach(PlayTarget.report(signal, route: phone.route, dop: phone.dopDACs, dsdAsPCM: phone.playback.dsdAsPCM), id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                } header: {
                    Text("What Reaches the Output")
                } footer: {
                    Text("Read back from iOS while the song plays, not assumed. Vespertine asks a DAC for each song’s own rate and, for surround, an interface for a channel per output (in the order L, R, C, LFE, back pair, side pair). iOS doesn’t tell apps an output’s bit depth. With the volume below 100%, a DAC doesn’t receive the song’s samples unchanged. On AirPods, iOS makes the two channels your ears get from the channels it was sent, so the output itself always has two.")
                }
            }
            if playsHere, !session.isDemo, let phone = session.phone, DoPGate.canTest(phone.route) {
                DoPSection(phone: phone, fromShare: session.isShare)
            }
        }
        .obsidianList()
        .navigationTitle(Text(verbatim: PlayTarget.deviceName)).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("device-sound")
        .onAppear { _ = session.phone?.readOutput?(.shown) }
    }

    private var playsHere: Bool { session.phone != nil }

    /// Where this device's sound goes now: the output's name as iOS gives it.
    private var hereName: String { session.phone?.route?.name ?? String(localized: "Plays through this device") }

    private var hereRate: String? {
        guard let route = session.phone?.route, route.sampleRate > 0 else { return nil }
        return String(localized: "\(PhoneSignal.kilohertz(route.sampleRate)) kHz", comment: "Signal chip: a sample rate.")
    }
}

/// The Mac's sound for the output it plays to, and the Mac itself: its name, its Vespertine and how it is reached.
struct MacSoundView: View {
    @Environment(RemoteAppModel.self) private var model
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var editingConnection = false

    var body: some View {
        List {
            if let player = session.player, let sound = player.sound, !sound.isEmpty {
                MacSoundSection(session: session, sound: sound, output: player.output, feedback: feedback)
            }
            Section {
                LabeledContent("Mac", value: macName)
                if let version = mac.server?.appVersion, !version.isEmpty {
                    LabeledContent("Vespertine", value: version)
                }
                if !session.isDemo {
                    Button { editingConnection = true } label: {
                        LabeledContent("Connection") {
                            HStack(spacing: 6) {
                                Circle().fill(mac.isConnected ? Palette.brass : Palette.text3).frame(width: 7, height: 7)
                                Text(reach)
                            }
                        }
                    }
                    .foregroundStyle(Palette.text)
                }
            }
        }
        .obsidianList()
        .navigationTitle(Text(verbatim: macName)).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mac-sound")
        .feedback(feedback)
        .sheet(isPresented: $editingConnection) { MacConnectionView(serverID: mac.pairing.serverID).withoutMiniPlayer() }
    }

    private var mac: RemoteSession { model.macSession ?? session }
    private var macName: String { mac.server?.name ?? mac.pairing.name }

    /// How the Mac is reached now.
    private var reach: String {
        guard mac.isConnected else { return String(localized: "Not connected") }
        return mac.reach.map(NowPlayingView.reachName) ?? String(localized: "On this network")
    }
}

/// DSD on a DAC plugged into this device: whether it is sent as DSD (DoP), and the short listening test that decides.
/// Nothing is assumed from the DAC's name: it gets DoP only after you heard the test sound as music on it.
private struct DoPSection: View {
    let phone: PhoneRemote
    /// The songs come from a share, read by this device itself: it, not a Mac, converts DSD when the DAC takes no DoP.
    let fromShare: Bool
    @State private var probe: DoPProbe

    init(phone: PhoneRemote, fromShare: Bool = false) {
        self.phone = phone
        self.fromShare = fromShare
        _probe = State(initialValue: DoPProbe(remote: phone))
    }

    var body: some View {
        Section {
            if let status { Text(status).foregroundStyle(Color.secondary) }
            // The chord was heard with iOS's volume below the top: that volume changes nothing this DAC gets.
            if !probe.isBusy, DoPGate.level(phone.output, dacs: phone.dopDACs) == .dac {
                Text(verbatim: PlayTarget.volumeOnDAC).foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("dop-volume-on-dac")
            }
            // Which rates this DAC played the chord at: there whether or not a song is playing.
            if !probe.isBusy {
                ForEach(PlayTarget.dopRows(phone.dopDACs, route: phone.route), id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
            Button { probe.run() } label: {
                HStack {
                    Text("Test DoP")
                    if probe.isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(probe.isBusy)
            .accessibilityIdentifier("dop-test")
            .alert("What did you hear?", isPresented: Binding(get: { probe.phase == .asking }, set: { if !$0, probe.phase == .asking { probe.cancel() } })) {
                Button("Music") { probe.answer(.music) }
                Button("Hiss or noise") { probe.answer(.noise) }
                // Silence is its own answer: it is never kept as a failed test.
                Button("Heard nothing") { probe.answer(.nothing) }
                Button("Play again") { probe.answer(.again) }
                Button("Cancel", role: .cancel) { probe.cancel() }
            } message: {
                // The chord is played at each rate in turn: which one the question is about, as the DAC's display names it.
                Text(verbatim: PlayTarget.dopRate(carrier: probe.carrier))
            }
        } header: {
            Text("Play DSD natively?")
        } footer: {
            if fromShare {
                Text("DSD is converted to PCM on this device unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test. If you hear no chord while the volume is below 100%, set it to 100%, then test again.")
            } else {
                Text("DSD is converted to PCM on the Mac unless this DAC takes DSD over PCM (DoP). A short, quiet test can tell: it plays a soft chord as DSD and asks what you heard. Music stops for the test. If you hear no chord while the volume is below 100%, set it to 100%, then test again.")
            }
        }
        .onDisappear { if probe.isBusy { probe.cancel() } }
    }

    /// What the test is doing, how it ended, or what this DAC's answer was.
    private var status: String? {
        switch probe.phase {
        case .preparing, .playing:
            return String(localized: "Playing a short, quiet test…", comment: "DoP test sheet while the test sound plays.")
        case .failed(.changed):
            return String(localized: "The test stopped because an audio device changed. Nothing was saved.", comment: "DoP test ended early: an output was plugged in or out, or the default output changed.")
        case .failed:
            return String(localized: "The test couldn't play as DoP on this output, so nothing was saved.", comment: "DoP test ended early: the engine didn't send the test sound as DoP.")
        case .answered(let ending):
            // A run that ended with nothing to keep says so, and what to do.
            if let words = PlayTarget.dopEnding(ending, carrier: probe.carrier) { return words }
        case .idle, .asking:
            break
        }
        return PlayTarget.dopResult(phone.dopDACs, output: phone.output)
    }
}

/// The files on the share that this device can't open by itself, by what they are: DTS, TrueHD, DSD in surround…
struct MacNeededView: View {
    let needs: [MacNeed.Count]

    var body: some View {
        List {
            Section {
                ForEach(needs, id: \.need) { count in
                    LabeledContent {
                        Text(verbatim: count.files.formatted())
                    } label: {
                        Text(verbatim: count.need.label)
                    }
                }
            } footer: {
                Text("This device can’t open these files by itself, so they aren’t in its library. Vespertine on a Mac can open them: add them to the Mac’s library, then play them there or from the Mac on this device.")
            }
        }
        .obsidianList()
        .navigationTitle("Files that need the Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}
