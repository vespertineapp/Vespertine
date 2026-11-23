//
// Vespertine: a kept song is checked before it counts as kept: its size, and for a FLAC file sent as it is, its samples
// against the MD5 its encoder wrote into it (FLAC's STREAMINFO). A song that didn't arrive whole is never kept as if it had.
// The FLAC files here are made by Core Audio's own encoder, which writes that MD5 (checked against the reference `flac -t`
// when these tests were written).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

/// A FLAC file of a few thousand frames of two tones, at `bits` per sample.
func madeFLAC(bits: Int, frames: Int = 12_000, rate: Double = 48_000) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID()).flac")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: bits]
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: rate, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let peak = Double(1 << (bits - 2))
    for i in 0..<frames {
        for channel in 0..<2 {
            let value = Int32(sin(Double(i) * 0.013 * Double(channel + 1)) * peak)
            buffer.int32ChannelData![channel][i] = value << (32 - bits)
        }
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
        try file.write(from: buffer)
    }
    return url
}

private func descriptor(for url: URL, bits: Int, kind: StreamKind = .original, container: String = "flac") throws -> StreamDescriptor {
    let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    return StreamDescriptor(stream: 1, kind: kind, byteSize: size,
                            format: StreamFormat(codec: container == "flac" ? "FLAC" : "WAV", container: container, sampleRate: 48_000, bitDepth: bits,
                                                 channels: 2, channelLabels: nil, lossless: true),
                            frames: 12_000, tag: "t", chunkSize: 1000)
}

@Suite struct KeptCheckTests {
    @Test(arguments: [16, 24]) func aWholeFLACPassesOnItsOwnMD5(bits: Int) throws {
        let url = try madeFLAC(bits: bits)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(KeptCheck.verify(url, descriptor: try descriptor(for: url, bits: bits)) == .whole(samplesChecked: true))
    }

    @Test func aFLACWithAByteChangedInItsAudioIsNotWhole() throws {
        let url = try madeFLAC(bits: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let described = try descriptor(for: url, bits: 24)
        var bytes = try Data(contentsOf: url)
        // A byte well inside the audio frames (the metadata is the first few hundred bytes).
        bytes[bytes.count - 2000] ^= 0x10
        try bytes.write(to: url)
        guard case .damaged = KeptCheck.verify(url, descriptor: described) else {
            Issue.record("a changed FLAC passed")
            return
        }
    }

    @Test func aFileOfTheWrongSizeIsNotWhole() throws {
        let url = try madeFLAC(bits: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        var described = try descriptor(for: url, bits: 16)
        described.byteSize += 1
        guard case .damaged = KeptCheck.verify(url, descriptor: described) else {
            Issue.record("a short file passed")
            return
        }
    }

    @Test func aFLACWhoseEncoderWroteNoMD5IsCheckedBySizeAlone() throws {
        let url = try madeFLAC(bits: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = try Data(contentsOf: url)
        // STREAMINFO's MD5: 16 bytes from byte 26 (after "fLaC", the block's header and 18 bytes of sizes and rates).
        bytes.replaceSubrange(26..<42, with: [UInt8](repeating: 0, count: 16))
        try bytes.write(to: url)
        #expect(KeptCheck.verify(url, descriptor: try descriptor(for: url, bits: 16)) == .whole(samplesChecked: false))
    }

    @Test func anythingButAnOriginalFLACIsCheckedBySize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 5000).write(to: url)
        #expect(KeptCheck.verify(url, descriptor: try descriptor(for: url, bits: 24, container: "wav")) == .whole(samplesChecked: false))
        // A FLAC the Mac made (a conversion) has its own MD5 too: checked the same way.
        let flac = try madeFLAC(bits: 24)
        defer { try? FileManager.default.removeItem(at: flac) }
        #expect(KeptCheck.verify(flac, descriptor: try descriptor(for: flac, bits: 24, kind: .flac)) == .whole(samplesChecked: true))
    }
}
#endif
