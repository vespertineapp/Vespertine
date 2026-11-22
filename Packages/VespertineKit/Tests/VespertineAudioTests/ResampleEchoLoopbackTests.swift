//
// Vespertine: a 16-bit 44.1 kHz song resampled to 48 kHz by the real engine (PlaybackEngine, OutputSession, the HAL and the
// I/O proc) to the "Vespertine Loopback" virtual device, recorded back and compared with the offline render frame for frame.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_LOOPBACK_TESTS=1 swift test --filter ResampleEchoLoopback (needs the Vespertine Loopback device and audio
// input access for the test process). Nothing is audible: the device is virtual. The device takes 44.1 kHz, so the output is
// held at 48 kHz (a fixed rate), which plans exactly what "Match source" plans on a 48 kHz-only device.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Resample echo loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_LOOPBACK_TESTS"] == "1"))
struct ResampleEchoLoopbackTests {
    @Test("A 44.1 kHz click train resampled to 48 kHz reaches the device as the offline render, with nothing added")
    func resampledThroughTheEngine() throws {
        let output = try #require(LoopbackGuard.dedicatedDevice(in: DeviceQuery.outputDevices(dopEnabledUIDs: [])), "no Vespertine Loopback device")
        try #require(LoopbackGuard.refusal(output) == nil)
        #expect(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        let rate = 48_000.0
        let source = 44_100
        let (samples, _) = ResampleEchoTests.clicks(frames: source * 3, spacing: 3_001, first: 1_000, amplitude: 16_384)
        let url = try GoldenCases.wav("echo-loopback.wav", samples, bits: 16, rate: source)
        let item = PlayableItem(url: url)

        // The offline render of the same plan: a stereo device held at 48 kHz.
        let device = GoldenRender.Device(name: output.name, capabilities: DeviceCapabilities(
            sampleRates: GoldenDevices.rates, physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 192_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)],
            outputChannels: 2, supportsDoP: false), streamChannels: 2)
        var offlineSettings = GoldenRender.Settings()
        offlineSettings.ratePolicy = .fixed(rate)
        let offline = try GoldenRender.render([item], device: device, settings: offlineSettings)
        let session = try #require(offline.sessions.first)
        #expect(session.plan.resamples)
        let expected = session.words.map { Float(bitPattern: $0) }
        let expectedFrames = expected.count / 2

        var settings = EngineSettings()
        settings.exclusive = true
        settings.deviceUID = output.uid
        settings.deviceName = output.name
        settings.ratePolicies = [output.uid: .fixed(rate)]
        settings.spatialModes = [output.uid: .off]
        try? DeviceControl.setNominalRate(rate, on: output.id)
        let recorder = try LoopbackRecorder(device: output.id, rate: rate)
        try recorder.start()
        defer { recorder.restore() }

        let engine = PlaybackEngine()
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(item)
        let started = Date()
        var played = false, path: SignalPath?
        while Date().timeIntervalSince(started) < 3 + 10 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true; path = path ?? snap.signalPath }
            if played, snap.state == .stopped { break }
        }
        let tailEnd = Date().addingTimeInterval(0.4)
        while Date() < tailEnd { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        #expect(played)
        #expect(path?.plan.resamples == true && path?.applied.sampleRate == rate, "path: \(String(describing: path?.plan))")

        let captured = recorder.samples
        try #require(captured.count >= 2)
        let left = captured[0], right = captured[1]
        // Line up on the first click (the recording starts with silence), then compare every frame.
        let firstExpected = try #require((0..<expectedFrames).first { expected[$0 * 2] != 0 })
        let firstCaptured = try #require(left.indices.first { left[$0] != 0 }, "nothing was recorded")
        let start = firstCaptured - firstExpected
        var wrong = 0, first: Int?
        for f in 0..<expectedFrames {
            let i = start + f
            guard i >= 0, i < left.count else { wrong += 1; first = first ?? f; continue }
            if left[i] != expected[f * 2] || right[i] != expected[f * 2 + 1] { wrong += 1; first = first ?? f }
        }
        #expect(wrong == 0, "\(wrong) of \(expectedFrames) frames differ from the offline render, the first at \(first ?? -1)")
        // Nothing after the song: no buffer played again.
        let after = (start + expectedFrames)..<left.count
        let tail = after.isEmpty ? 0 : after.map { max(abs(left[$0]), abs(right[$0])) }.max() ?? 0
        #expect(tail == 0, "\(tail) after the song ended")
        #expect(recorder.discontinuityCount == 0)
    }
}
