//
// Vespertine: whether a song that arrived to be kept arrived whole. Its size must be what the Mac or the share said; and a
// FLAC file carries the MD5 of its own samples (written by its encoder into STREAMINFO), so it is decoded and the samples
// compared with that: a byte changed anywhere in the audio is caught, however it happened (on the line, on the disk, in a
// range that was carried on from). Other formats have nothing of the kind and are checked by size.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AudioToolbox
import CryptoKit
import Foundation
import VespertineRemoteProtocol

public enum KeptCheck {
    public enum Result: Equatable, Sendable {
        /// `samplesChecked`: the samples matched the file's own MD5 (else only the size could be checked).
        case whole(samplesChecked: Bool)
        /// What is wrong, for the log.
        case damaged(String)
    }

    /// Checks `file` against what `descriptor` said of it. Decoding a long FLAC takes a moment: not on the main thread.
    public static func verify(_ file: URL, descriptor: StreamDescriptor) -> Result {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 else { return .damaged("no file") }
        guard size == descriptor.byteSize else { return .damaged("\(size) bytes where \(descriptor.byteSize) were expected") }
        guard descriptor.format.container.lowercased() == "flac", descriptor.dsdRate == nil, let info = streamInfo(file) else {
            return .whole(samplesChecked: false)
        }
        // An encoder that didn't work it out writes zeros; one at a depth Core Audio would scale on the way can't be compared.
        guard info.md5.contains(where: { $0 != 0 }), [8, 16, 24, 32].contains(info.bits) else { return .whole(samplesChecked: false) }
        guard let md5 = samplesMD5(file, bits: info.bits, channels: info.channels, frames: info.frames) else { return .damaged("doesn’t decode") }
        return md5 == info.md5 ? .whole(samplesChecked: true) : .damaged("its samples don’t match its MD5")
    }

    /// STREAMINFO: bits per sample, channels, frames and the MD5, from the first metadata block (FLAC format, 8.2).
    static func streamInfo(_ file: URL) -> (bits: Int, channels: Int, frames: Int64, md5: [UInt8])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 42), head.count == 42 else { return nil }
        let b = [UInt8](head)
        guard b[0..<4] == [0x66, 0x4c, 0x61, 0x43], b[4] & 0x7f == 0, Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7]) == 34 else { return nil }
        // From byte 18: 20 bits of sample rate, 3 of channels − 1, 5 of bits − 1, 36 of frames.
        let channels = Int(b[20] >> 1 & 0x07) + 1
        let bits = Int((b[20] & 0x01) << 4 | b[21] >> 4) + 1
        var frames = Int64(b[21] & 0x0f)
        for i in 22..<26 { frames = frames << 8 | Int64(b[i]) }
        return (bits, channels, frames, Array(b[26..<42]))
    }

    /// The MD5 of the file's samples as FLAC defines it: interleaved, signed, little-endian, in whole bytes per sample.
    private static func samplesMD5(_ file: URL, bits: Int, channels: Int, frames: Int64) -> [UInt8]? {
        var opened: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(file as CFURL, &opened) == noErr, let audio = opened else { return nil }
        defer { ExtAudioFileDispose(audio) }
        let bytes = bits / 8
        var client = AudioStreamBasicDescription(mSampleRate: 0, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(bytes * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytes * channels),
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0)
        // The file's own rate, so nothing is resampled.
        var native = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(audio, kExtAudioFileProperty_FileDataFormat, &size, &native) == noErr else { return nil }
        client.mSampleRate = native.mSampleRate
        guard ExtAudioFileSetProperty(audio, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
            return nil
        }
        var digest = Insecure.MD5()
        let chunkFrames = 16_384
        var buffer = [UInt8](repeating: 0, count: chunkFrames * bytes * channels)
        var total: Int64 = 0
        while true {
            var count = UInt32(chunkFrames)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count),
                                                                                    mData: raw.baseAddress))
                return ExtAudioFileRead(audio, &count, &list)
            }
            guard status == noErr else { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(Int(count) * bytes * channels))) }
            total += Int64(count)
        }
        // A file that stops short of the frames STREAMINFO says it has isn't whole.
        guard frames == 0 || total == frames else { return nil }
        return Array(digest.finalize())
    }
}
#endif
