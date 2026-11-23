//
// Vespertine: a song rendered for a network renderer's processed stream, with no device: the engine's own pieces in the
// engine's order (FormatPlanner at the source rate → SourceOpener's decoder → Decoding.convertChunk, ReplayGain included →
// the ring → nrt_context_render_interleaved with room correction, the equalizer, digital volume and TPDF dither at 24 bits),
// as GoldenRender runs them in the tests. What comes out is the 24-bit stream the FLAC encoder gets.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineRT
import Foundation

public final class NetworkRender: @unchecked Sendable {
    /// What the stream is planned for.
    public enum Target: Sendable, Hashable {
        /// A renderer's processed FLAC: the source's rate (DSD as PCM), 24 bits, the source's channels.
        case sourceRate24
        /// AirPlay: 44.1 kHz, 16 bits, at most two channels (resampled, downmixed and DSD→PCM by the engine's own converter).
        case airPlay
        /// AirPlay to a receiver that takes another format: the same, at `sampleRate` and `bitDepth` (16 or 24).
        case airPlayStream(sampleRate: Int, bitDepth: Int)
        /// A renderer that takes less than the source has (a Sonos: 48 kHz, two channels): `bitDepth` bits (24, or 16 for a
        /// Sonos S1) at exactly `sampleRate`, at most `channels` channels, resampled, folded down and DSD→PCM by the engine's
        /// own converter.
        case fixed(sampleRate: Double, channels: Int, bitDepth: Int = 24)

        /// The one rate and word length of an AirPlay target; nil for a renderer's stream.
        var airPlay: (rate: Double, bits: Int)? {
            switch self {
            case .sourceRate24, .fixed: return nil
            case .airPlay: return (rate: 44_100, bits: 16)
            case .airPlayStream(let sampleRate, let bitDepth): return (rate: Double(sampleRate), bits: bitDepth == 24 ? 24 : 16)
            }
        }
    }

    /// What comes out: PCM at the plan's rate (the source's own for PCM, 44.1 kHz for AirPlay), at the target's word length,
    /// the source's channels (at most two for AirPlay).
    public let format: SourceFormat
    /// The plan the engine's planner made for the target (resampling, DSD→PCM, channels).
    public let plan: OutputPlan
    /// The source as probed.
    public var source: SourceFormat { probed.format }
    public var decoderName: String { probed.decoderName }
    /// The chain itself adds TPDF dither at the target's word length (gain, equalizer or room correction change the samples).
    public let chainDithers: Bool
    /// `next` adds TPDF dither itself: a stream shorter than 24 bits whose samples the chain didn't dither and that aren't
    /// already whole values at that length (a deeper source, a resampled, folded or DSD one, a lossy one, ReplayGain applied).
    let quantiserDithers: Bool
    private var dither = TPDFDither(seed: UInt64.random(in: 1...UInt64.max))
    private let probed: ProbedSource
    private let decoding: Decoding
    private let ring: OpaquePointer
    private let context: OpaquePointer
    private let channels: Int
    private var scratch: [Float] = []
    public private(set) var finished = false
    public private(set) var error: Error?

    static let chunkFrames: AVAudioFrameCount = 4096

    /// The rates a renderer stream may run at (DSD becomes PCM at the planner's rate within them).
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    public init(item: PlayableItem, url: URL, equalizer: EQPreset?, roomCorrection: RoomCorrectionPlayback?, digitalVolumeDB: Double?,
                startSeconds: TimeInterval = 0, target: Target = .sourceRate24) throws {
        let probed = try SourceOpener.probe(url, area: item.sacdArea, dvd: item.dvd, audioStream: item.audioStream)
        let source = probed.format
        let airPlay = target.airPlay
        let isAirPlay = airPlay != nil
        var fixed: (rate: Double, channels: Int, bits: Int)?
        if case .fixed(let sampleRate, let most, let depth) = target { fixed = (sampleRate, max(1, most), depth == 16 ? 16 : 24) }
        let bits = airPlay?.bits ?? fixed?.bits ?? 24
        let channels = isAirPlay ? min(2, max(1, source.channels)) : min(max(1, source.channels), fixed?.channels ?? .max)
        let rates = airPlay.map { [$0.rate] } ?? fixed.map { [$0.rate] } ?? Self.rates
        // AirPlay is always a stereo stream (a mono song is carried on both); a renderer's stream keeps a mono song mono.
        let outputs = isAirPlay ? 2 : channels
        let device = DeviceCapabilities(sampleRates: rates,
                                        physicalFormats: [PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: bits, isInteger: true, isMixable: true,
                                                                         channels: outputs)],
                                        outputChannels: outputs, supportsDoP: false)
        var plan = FormatPlanner.plan(source: source, device: device, policy: .matchSource)
        plan.integerSamples = false
        guard plan.mode == .pcm, let ring = nrt_ring_create(OutputSession.ringFrames(rate: plan.deviceSampleRate, channels: plan.channels, seconds: 4), UInt32(plan.channels)) else {
            throw SourceOpenerError.unsupported(url)
        }
        guard let context = nrt_context_create(ring, 8192) else {
            nrt_ring_destroy(ring)
            throw SourceOpenerError.unsupported(url)
        }
        self.ring = ring
        self.context = context
        self.probed = probed
        self.channels = plan.channels
        self.plan = plan
        let rate = plan.deviceSampleRate
        format = SourceFormat(encoding: .pcm, codec: isAirPlay ? "ALAC" : "FLAC", sampleRate: rate, bitDepth: bits, channels: plan.channels)
        do {
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
            if startSeconds > 0 {
                let frame = AVAudioFramePosition(startSeconds * plan.decodedSampleRate)
                if frame < decoder.length { try decoder.seek(to: frame) }
            }
            let applied = AppliedFormat(sampleRate: rate, physicalBitDepth: bits, physicalIsInteger: true, virtualChannels: plan.channels,
                                        exclusive: false, bufferFrames: 512)
            let path = SignalPath(source: source, decoderName: probed.decoderName, plan: plan, applied: applied, deviceName: "", deviceUID: "",
                                  deviceProfile: .networkRenderer(protocolName: ""), volume: .fixed, replayGainDB: item.replayGainDB)
            decoding = try Decoding(item: item, probed: probed, decoder: decoder, path: path, chunk: Self.chunkFrames,
                                    layout: OutputSession.routeLayout(plan: plan, speakers: nil))
        } catch {
            nrt_context_destroy(context)
            nrt_ring_destroy(ring)
            throw error
        }
        // PlaybackEngine.applyGain, with the stream's word length (24 bits; for AirPlay, the stream's own).
        let db = digitalVolumeDB ?? 0
        nrt_context_set_gain(context, db == 0 ? 1.0 : pow(10, db / 20), UInt32(bits))
        let eq = equalizer.flatMap { $0.isFlat ? nil : $0 }
        let sections = eq?.sections(sampleRate: rate) ?? []
        sections.withUnsafeBufferPointer { nrt_context_set_eq(context, $0.baseAddress, UInt32($0.count), eq?.preampGain ?? 1) }
        let room = roomCorrection.flatMap { $0.isFlat || !$0.applies(channels: plan.channels) ? nil : $0 }
        RoomCorrectionPlayback.install(room, on: context, sampleRate: rate, channelCount: plan.channels)
        RoomCorrectionPlayback.installFilters(room?.impulseTaps(sampleRate: rate, channelCount: plan.channels), on: context)
        chainDithers = db != 0 || !sections.isEmpty || room != nil
        // Only a renderer's own stream is quantised here (AirPlay's frames do their own); a 24-bit one never needs it.
        // ReplayGain is applied by the decoding (`Decoding.convertChunk`, before the chain), so the chain doesn't dither for
        // it: a gain that changes the samples counts as re-quantising them, as a deeper source or a resampler does.
        let replayGainApplied = (item.replayGainDB ?? 0) != 0 && plan.mode == .pcm
        let requantised = source.encoding != .pcm || (source.bitDepth ?? 32) > bits || plan.resamples || plan.channels < source.channels
            || replayGainApplied
        quantiserDithers = !isAirPlay && bits < 24 && !chainDithers && requantised
    }

    deinit {
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
    }

    /// Up to `maxFrames` interleaved frames, each sample a value of the stream's word length in an Int32 (24-bit:
    /// −8388608…8388607; 16-bit: −32768…32767), with TPDF dither where `quantiserDithers`; empty at the end.
    public func next(maxFrames: Int = 4096) -> [Int32] {
        let rendered = nextFloats(maxFrames: maxFrames)
        let full = Double(Int64(1) << Int64((format.bitDepth ?? 24) - 1))
        var out = [Int32](repeating: 0, count: rendered.count)
        for i in rendered.indices {
            let x = Double(rendered[i]) * full
            let v = (quantiserDithers ? x + dither.next() : x).rounded()
            out[i] = Int32(min(max(v, -full), full - 1))
        }
        return out
    }

    /// Up to `maxFrames` interleaved frames as the chain renders them (Float, full scale ±1); empty at the end. The caller
    /// quantises them to the target's word length.
    public func nextFloats(maxFrames: Int = 4096) -> [Float] {
        while Int(nrt_ring_readable(ring)) < maxFrames, !decoding.finished {
            guard Int(nrt_ring_writable(ring)) >= Int(Self.chunkFrames) else { break }
            let chunk = decoding.convertChunk()
            if chunk.frames > 0, let data = chunk.data { _ = nrt_ring_write(ring, data, chunk.frames) }
            if chunk.ended {
                decoding.finished = true
                if let e = chunk.error { error = e }
            }
        }
        let n = min(Int(nrt_ring_readable(ring)), maxFrames)
        guard n > 0 else { finished = true; return [] }
        if scratch.count < n * channels { scratch = [Float](repeating: 0, count: n * channels) }
        scratch.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, UInt32(n), UInt32(channels)) }
        return Array(scratch.prefix(n * channels))
    }
}

/// TPDF dither of ±1 LSB (the sum of two uniform ±½), from a small fast generator (xorshift64*).
struct TPDFDither {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    private mutating func unit() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
    }
    mutating func next() -> Double { unit() + unit() - 1 }
}
