//
// Vespertine: resampling a 44.1 kHz track for a device that lacks 44.1 kHz must not add delayed copies of the sound.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clicks go through the engine's own offline chain (GoldenRender: planner, decoder, Decoding's converter, ring, the I/O
// proc's render) and the output is searched for anything that is not each click's own short ringing: a copy later on (an
// echo), sound on a channel that should be silent, or the wrong number of frames. The devices are a plain 48 kHz-only
// stereo DAC and the Bose Companion 5 as it enumerates ("Bose USB Audio": one USB full-speed stream, 48 kHz only, 16-bit,
// 2 to 6 channels in L R C LFE Ls Rs order; its DSP runs at a fixed 48 kHz frame clock).
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Resampling adds no echo")
struct ResampleEchoTests {
    /// A 48 kHz-only device whose one stream offers `channels` (each a physical format) at `bits`.
    static func device(_ name: String, bits: [Int], channels: [Int], speakers: Int? = nil) -> GoldenRender.Device {
        let formats = channels.flatMap { ch in
            bits.map { PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: $0, isInteger: true, isMixable: true, channels: ch) }
        }
        let widest = channels.max() ?? 2
        return GoldenRender.Device(name: name,
                                   capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: formats, outputChannels: widest,
                                                                    supportsDoP: false, speakerLayoutChannels: speakers),
                                   streamChannels: widest, bufferFrames: 512)
    }

    static let devices: [GoldenRender.Device] = [
        device("48 kHz stereo DAC", bits: [16, 24], channels: [2]),
        // Bose Companion 5, as its service manual and owner's guide describe it.
        device("Bose USB Audio (6 ch)", bits: [16], channels: [6]),
        device("Bose USB Audio (2 or 6 ch)", bits: [16], channels: [2, 6]),
        // The owner's guide has the user pick "5.1 surround" in Audio MIDI Setup's Configure Speakers.
        device("Bose USB Audio, 5.1 configured", bits: [16], channels: [2, 6], speakers: 6),
    ]

    /// Plays `samples` (per channel) through `device` and returns the device's Float32 words, per device channel.
    static func play(_ samples: [[Int32]], bits: Int, rate: Int, device: GoldenRender.Device) throws -> [[Float]] {
        let url = try GoldenCases.wav("echo-\(rate)-\(bits).wav", samples, bits: bits, rate: rate)
        let out = try GoldenRender.render([GoldenCases.item(url)], device: device)
        #expect(out.sessions.count == 1)
        let session = try #require(out.sessions.first)
        #expect(session.plan.deviceSampleRate == 48_000)
        #expect(session.plan.resamples)
        let n = session.streamChannels
        return (0..<n).map { c in (0..<session.frames).map { Float(bitPattern: session.words[$0 * n + c]) } }
    }

    /// Clicks every `spacing` frames (odd, so they land at every phase of the 4096-frame chunks and 512-frame buffers).
    static func clicks(frames: Int, spacing: Int, first: Int, amplitude: Int32) -> (samples: [[Int32]], at: [Int]) {
        let at = Array(stride(from: first, to: frames - spacing / 2, by: spacing))
        var s = [Int32](repeating: 0, count: frames)
        for i in at { s[i] = amplitude }
        // The right channel's clicks are inverted: a channel copied onto the other would show up as a sign error.
        return ([s, s.map { -$0 }], at)
    }

    @Test("A 16-bit 44.1 kHz click train on a 48 kHz-only output comes out once per click, on its own channel",
          arguments: devices.indices)
    func clicksOnce(device index: Int) throws {
        let device = Self.devices[index]
        let rate = 44_100
        let frames = rate * 3
        let (samples, at) = Self.clicks(frames: frames, spacing: 3_001, first: 1_000, amplitude: 16_384)
        let out = try Self.play(samples, bits: 16, rate: rate, device: device)
        let ratio = 48_000.0 / Double(rate)
        // Every source frame comes out once: no more frames than the song at 48 kHz (a duplicated buffer adds some).
        let expectedFrames = Double(frames) * ratio
        #expect(abs(Double(out[0].count) - expectedFrames) < 64, "\(device.name): \(out[0].count) frames, expected \(expectedFrames)")

        // The resampler's own impulse response: the energy within ±`ring` frames of the first click.
        let ring = 160
        let positions = at.map { Double($0) * ratio }
        for c in 0..<2 {
            let ch = out[c]
            let sign: Float = c == 0 ? 1 : -1
            // Each click: where its energy is, and that its sum has the right sign.
            var delay: Int?
            for p in positions {
                let centre = Int(p.rounded())
                let window = max(0, centre - ring)..<min(ch.count, centre + ring)
                let peak = window.max { abs(ch[$0]) < abs(ch[$1]) }!
                let d = peak - centre
                if delay == nil { delay = d }
                #expect(abs(d - delay!) <= 1, "\(device.name) ch \(c): click at \(centre) peaks \(d) frames off (first was \(delay!))")
                #expect(ch[peak] * sign > 0.3, "\(device.name) ch \(c): click at \(centre) peaks at \(ch[peak])")
            }
            // Anything outside every click's ringing is an echo (or a buffer played twice).
            var inside = [Bool](repeating: false, count: ch.count)
            for p in positions {
                let centre = Int(p.rounded()) + (delay ?? 0)
                for i in max(0, centre - ring)..<min(ch.count, centre + ring) { inside[i] = true }
            }
            var clickEnergy: Double = 0, strayEnergy: Double = 0, worst: Float = 0, worstAt = 0
            for (i, v) in ch.enumerated() {
                if inside[i] { clickEnergy += Double(v * v) } else {
                    strayEnergy += Double(v * v)
                    if abs(v) > worst { worst = abs(v); worstAt = i }
                }
            }
            // -60 dB relative to the clicks, and no single stray sample above -66 dBFS.
            #expect(strayEnergy < clickEnergy * 1e-6, "\(device.name) ch \(c): stray energy \(strayEnergy) vs clicks \(clickEnergy)")
            #expect(worst < 0.0005, "\(device.name) ch \(c): \(worst) at frame \(worstAt), away from every click")
        }
        // The other device channels carry nothing: stereo stays on L and R.
        for c in 2..<out.count {
            let loudest = out[c].map(abs).max() ?? 0
            #expect(loudest == 0, "\(device.name): channel \(c + 1) carries \(loudest)")
        }
    }

    @Test("A 44.1 kHz sine resampled to 48 kHz comes out undistorted (residual after fitting the ideal sine)",
          arguments: devices.indices)
    func sineClean(device index: Int) throws {
        let device = Self.devices[index]
        let rate = 44_100
        let frames = rate * 2
        let f = 1_000.0
        let left: [Int32] = (0..<frames).map { Int32((sin(2 * .pi * f * Double($0) / Double(rate)) * 16_000).rounded()) }
        let out = try Self.play([left, left], bits: 16, rate: rate, device: device)
        // Fit the ideal 48 kHz sine (amplitude and phase) in the steady middle and measure what is left.
        let ch = out[0]
        let range = 24_000..<(ch.count - 24_000)
        var ss: Double = 0, sc: Double = 0
        for i in range {
            let w = 2 * .pi * f * Double(i) / 48_000
            ss += Double(ch[i]) * sin(w); sc += Double(ch[i]) * cos(w)
        }
        let a = 2 * ss / Double(range.count), b = 2 * sc / Double(range.count)
        var residual: Double = 0, signal: Double = 0
        for i in range {
            let w = 2 * .pi * f * Double(i) / 48_000
            let ideal = a * sin(w) + b * cos(w)
            residual += pow(Double(ch[i]) - ideal, 2); signal += ideal * ideal
        }
        let snr = 10 * log10(signal / max(residual, 1e-30))
        // 16-bit source: about 90 dB at best. Garbled frames (a wrong stride, a buffer written twice) show as a much larger residual.
        #expect(snr > 80, "\(device.name): sine to residual \(snr) dB")
    }
}
