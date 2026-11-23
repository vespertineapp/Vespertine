//
// Vespertine: network players (UPnP AV / OpenHome renderers) as outputs, behind Settings › Playback › Network Players (Sonos and UPnP, beta), off by
// default. The model exists only while the switch is on; until then nothing is searched for and no port is open.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio
import VespertineUPnP

@Observable
@MainActor
final class RendererOutputModel {
    @ObservationIgnored let service: RendererService
    private(set) var renderers: [RendererDevice] = []
    /// The first search hasn't answered yet.
    private(set) var searching = true
    private(set) var failure: String?
    /// The renderer playback goes to, and its control, while one is the chosen output.
    @ObservationIgnored private(set) var playback: RendererPlayback?
    /// The chosen player's own volume, 0…1, where Vespertine sets it (a Sonos room); nil when it has none Vespertine sets,
    /// or it hasn't answered yet.
    private(set) var playerVolume: Double?
    @ObservationIgnored private var volumeControl: (uid: String, description: DeviceDescription, isGroup: Bool, control: any RendererVolume)?
    @ObservationIgnored private var volumeSend: Task<Void, Never>?
    @ObservationIgnored private var volumeWatch: Task<Void, Never>?
    /// Called when the list of renderers changes.
    @ObservationIgnored var onChange: (() -> Void)?
    /// A renderer that is never listed: this Mac's own receiver (Receive from Other Apps), which would only play to itself.
    @ObservationIgnored var hiddenUDN: String? { didSet { if hiddenUDN != oldValue { renderers.removeAll { $0.description.udn == hiddenUDN } } } }

    init(service: RendererService = RendererService()) {
        self.service = service
        service.discovery.onChange = { [weak self] list in
            Task { @MainActor in
                guard let self else { return }
                let list = list.filter { $0.description.udn != self.hiddenUDN }
                let changed = self.renderers != list
                self.renderers = list
                self.searching = false
                if changed { self.onChange?() }
            }
        }
    }

    func start() {
        // Asked for in order on this thread; the service applies the changes one after the other (a quick off-on can't race).
        service.want(true)
        Task { [service] in
            await service.settled()
            if service.isEnabled, let error = service.lastError { failure = error.localizedDescription }
            // A search takes a few seconds; after that "Searching…" gives way to the list, even an empty one.
            try? await Task.sleep(for: .seconds(4))
            searching = false
        }
    }

    func stop() {
        playback?.shutdown()
        playback = nil
        watchVolume(of: nil)
        service.want(false)
        renderers = []
    }

    /// The player's own volume for `device`: read now, and every few seconds while it stays the chosen one (the level is
    /// also changed from the Sonos app and the TV remote). nil lets go of it.
    func watchVolume(of device: RendererDevice?) {
        guard let device, let control = device.makeVolume() else {
            volumeControl = nil
            volumeWatch?.cancel()
            volumeWatch = nil
            playerVolume = nil
            return
        }
        // The same player, arranged as before: the watch that is running carries on.
        if let held = volumeControl, held.uid == device.uid, held.description == device.description, held.isGroup == (device.sonos?.isGroup == true) { return }
        volumeControl = (device.uid, device.description, device.sonos?.isGroup == true, control)
        volumeWatch?.cancel()
        playerVolume = nil
        volumeWatch = Task { [weak self] in
            while !Task.isCancelled {
                if let level = try? await control.volume() {
                    // Not while the listener's own change is still on its way: the slider would jump back.
                    if let self, self.volumeSend == nil, self.volumeControl?.uid == device.uid { self.playerVolume = Double(level) / 100 }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Sets the player's own volume (0…1). The slider moves at once; the player is told a moment after the last change, so a
    /// drag sends a few calls, not hundreds.
    func setPlayerVolume(_ level: Double) {
        guard let control = volumeControl?.control else { return }
        let level = min(1, max(0, level))
        playerVolume = level
        volumeSend?.cancel()
        volumeSend = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            try? await control.setVolume(Int((level * 100).rounded()))
            if !Task.isCancelled { self?.volumeSend = nil }
        }
    }

    /// Searches again (the output list opened).
    func refresh() { service.refresh() }

    func renderer(uid: String?) -> RendererDevice? {
        guard let uid, RendererDevice.isRendererUID(uid) else { return nil }
        return renderers.first { $0.uid == uid }
    }

    /// The playback for `device`, made once per renderer (nil: none chosen, or it isn't on the network now).
    /// `chosenUID`: the renderer chosen as the output, found or not. A search that misses it (multicast is the first thing a
    /// busy Wi-Fi network drops) doesn't end the music: while its playback has a song loaded and the renderer answers, the
    /// playback stays.
    func playback(for device: RendererDevice?, chosenUID: String? = nil, settings: RendererSettings) -> RendererPlayback? {
        guard let device else {
            if let playback, let chosenUID, playback.renderer.uid == chosenUID, playback.isEngaged {
                playback.update(settings: settings)
                return playback
            }
            playback?.shutdown()
            playback = nil
            return nil
        }
        // The same renderer at the same address, or one that is answering as it is: its playback carries on. So does one
        // that is starting a song: it goes to the renderer's new address by itself. Otherwise a renderer that came back
        // somewhere else (a new port after a restart, a new address from DHCP) gets a new one, to its new address.
        if let playback, playback.renderer.uid == device.uid,
           playback.renderer.description == device.description || playback.isEngaged || playback.isStarting {
            playback.update(settings: settings)
            return playback
        }
        playback?.shutdown()
        guard let transport = try? device.makeTransport() else { playback = nil; return nil }
        let made = RendererPlayback(renderer: device, transport: transport, media: service.media, processed: ProcessedStreamMaker())
        // Not answering where it was found (it restarted, or its address changed while it sat unused): looked for again.
        made.relocate = { [discovery = service.discovery] device in await discovery.relocate(device) }
        made.update(settings: settings)
        playback = made
        return made
    }
}

/// The Settings › Playback switch for network renderers, like Speaker Groups': its words, and what turning it on or off does.
@MainActor
enum RendererSwitch {
    static var title: String {
        String(localized: "Network Players (Sonos and UPnP, beta)", comment: "Settings › Playback: the switch that brings network players (Sonos rooms, and UPnP AV and OpenHome players such as moOde or a streamer) into the app as outputs. “Sonos”, “UPnP” and “beta” stay as they are in your language.")
    }

    static var explanation: String {
        String(localized: "Plays to Sonos rooms and other network players on your network (UPnP and OpenHome). Off, Vespertine doesn't look for them, opens no port for them, and plays as before.", comment: "Settings › Playback: the caption under the Network Players (Sonos and UPnP, beta) switch.")
    }

    /// Turns the feature on or off and answers the model that should exist now: `current` or a new, started one while on; nil off.
    static func apply(_ on: Bool, to settings: AppSettings, current: RendererOutputModel?, onChange: @escaping () -> Void = {},
                      make: () -> RendererOutputModel = { RendererOutputModel() }) -> RendererOutputModel? {
        settings.upnpRenderersFeature = on
        guard on else {
            current?.stop()
            return nil
        }
        if let current { return current }
        let model = make()
        model.onChange = onChange
        model.start()
        return model
    }

    /// Whether the chosen output survives the switch going to `on`: a renderer chosen as the output doesn't, once renderers are off.
    static func keepsOutput(_ uid: String?, turningOnTo on: Bool) -> Bool {
        on || !RendererDevice.isRendererUID(uid)
    }
}

extension AppSettings {
    /// What Vespertine applies for the renderer `uid`: its equalizer, room correction and, once unlocked, its volume.
    func rendererSettings(uid: String) -> RendererSettings {
        let engine = engineSettings()
        let volume = rendererVolumeUnlocked.contains(uid) ? Self.decibels(appVolumeLevel(for: uid)) : nil
        return RendererSettings(equalizer: engine.equalizers[uid], roomCorrection: engine.roomCorrections[uid], digitalVolumeDB: volume)
    }

    func setRendererVolumeUnlocked(_ unlocked: Bool, for uid: String) {
        if unlocked { rendererVolumeUnlocked.insert(uid) } else { rendererVolumeUnlocked.remove(uid) }
        // Locking again goes back to 100%, the original file.
        if !unlocked { setAppVolumeLevel(1, for: uid) }
    }
}
