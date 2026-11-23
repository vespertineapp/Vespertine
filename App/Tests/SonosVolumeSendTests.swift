//
// Vespertine: a Sonos volume change still on its way when the room is let go of, replaced by another output, or Network
// Players is switched off, isn't sent to the room after all.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
import VespertineUPnP
@testable import Vespertine

/// Records what it is told instead of telling a speaker.
private final class RecordingVolume: RendererVolume, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Int] = []
    var levels: [Int] { lock.withLock { sent } }
    func volume() async throws -> Int { 30 }
    func setVolume(_ level: Int) async throws { lock.withLock { sent.append(level) } }
    func isMuted() async throws -> Bool { false }
    func setMuted(_ muted: Bool) async throws {}
}

private final class SilentSearcher: SSDPSearching, @unchecked Sendable {
    func search(targets: [String], mx: Int, wait: TimeInterval) async -> [SSDPResponse] { [] }
}

@Suite("Sonos volume: a change on its way", .serialized) @MainActor
struct SonosVolumeSendTests {
    private func room(_ id: String) -> RendererDevice {
        let location = URL(string: "http://192.168.1.\(id.count + 20):1400/xml/device_description.xml")!
        let description = DeviceDescription(udn: "uuid:RINCON_\(id)01400_MR", friendlyName: id, manufacturer: "Sonos, Inc.", modelName: "Sonos One",
                                            location: location, services: [])
        return RendererDevice(description: description, kind: .av(gapless: true), capabilities: .init(), sonos: nil)
    }

    private func model(_ controls: [String: RecordingVolume]) -> RendererOutputModel {
        let model = RendererOutputModel(service: RendererService(discovery: RendererDiscovery(searcher: SilentSearcher())))
        model.makeVolume = { controls[$0.uid] }
        return model
    }

    /// Longer than the model's wait before it sends (120 ms), with room to spare on a loaded machine.
    private func outlast() async throws { try await Task.sleep(for: .milliseconds(600)) }

    @Test("Sent when the room stays chosen")
    func sentWhenKept() async throws {
        let a = RecordingVolume()
        let kitchen = room("KITCHEN")
        let model = model([kitchen.uid: a])
        model.watchVolume(of: kitchen)
        model.setPlayerVolume(0.42)
        for _ in 0..<100 where a.levels.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(a.levels == [42])
        model.watchVolume(of: nil)
    }

    @Test("Not sent once the room is let go of")
    func released() async throws {
        let a = RecordingVolume()
        let kitchen = room("KITCHEN")
        let model = model([kitchen.uid: a])
        model.watchVolume(of: kitchen)
        model.setPlayerVolume(0.42)
        model.watchVolume(of: nil)
        try await outlast()
        #expect(a.levels.isEmpty)
    }

    @Test("Not sent to the old room once another one is chosen")
    func replaced() async throws {
        let a = RecordingVolume(), b = RecordingVolume()
        let kitchen = room("KITCHEN"), den = room("DEN")
        let model = model([kitchen.uid: a, den.uid: b])
        model.watchVolume(of: kitchen)
        model.setPlayerVolume(0.42)
        model.watchVolume(of: den)
        try await outlast()
        #expect(a.levels.isEmpty)
        #expect(b.levels.isEmpty)
        model.watchVolume(of: nil)
    }

    @Test("Not sent once playback moves off network players")
    func outputLetGo() async throws {
        let a = RecordingVolume()
        let kitchen = room("KITCHEN")
        let model = model([kitchen.uid: a])
        model.watchVolume(of: kitchen)
        model.setPlayerVolume(0.42)
        #expect(model.playback(for: nil, settings: RendererSettings()) == nil)
        try await outlast()
        #expect(a.levels.isEmpty)
        model.watchVolume(of: nil)
    }

    @Test("Not sent once Network Players is switched off")
    func disabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-sonosvolume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let a = RecordingVolume()
        let kitchen = room("KITCHEN")
        let model = model([kitchen.uid: a])
        #expect(RendererSwitch.apply(true, to: settings, current: model) === model)
        model.watchVolume(of: kitchen)
        model.setPlayerVolume(0.42)
        #expect(RendererSwitch.apply(false, to: settings, current: model) == nil)
        try await outlast()
        #expect(a.levels.isEmpty)
    }
}
