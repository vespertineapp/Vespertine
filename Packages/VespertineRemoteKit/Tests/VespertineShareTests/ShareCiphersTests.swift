//
// Vespertine: the ciphers SMB 3 encrypts with (AES-GCM and AES-CCM, 128- and 256-bit keys), against the vectors their own standards publish.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

@Suite struct ShareCiphersTests {
    // The GCM specification's own test cases 1 to 4 (McGrew and Viega, appendix B; SP 800-38D points to them).
    private static let gcmKey = "feffe9928665731c6d6a8f9467308308"
    private static let gcmNonce = "cafebabefacedbaddecaf888"
    private static let gcmMessage = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
    private static let gcmEncrypted = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"

    @Test(arguments: [false, true]) func gcmMatchesItsSpecification(plain: Bool) {
        let zeros = [UInt8](repeating: 0, count: 16), zeroNonce = [UInt8](repeating: 0, count: 12)
        let one = ShareCiphers.seal(.gcm, key: zeros, nonce: zeroNonce, [], aad: [], plain: plain)
        #expect(one.ciphertext.isEmpty && hex(one.tag) == "58e2fccefa7e3061367f1d57a4e7455a")
        let two = ShareCiphers.seal(.gcm, key: zeros, nonce: zeroNonce, zeros, aad: [], plain: plain)
        #expect(hex(two.ciphertext) == "0388dace60b6a392f328c2b971b2fe78" && hex(two.tag) == "ab6e47d42cec13bdf53a67b21257bddf")

        let key = unhex(Self.gcmKey), nonce = unhex(Self.gcmNonce), message = unhex(Self.gcmMessage)
        let three = ShareCiphers.seal(.gcm, key: key, nonce: nonce, message, aad: [], plain: plain)
        #expect(hex(three.ciphertext) == Self.gcmEncrypted && hex(three.tag) == "4d5c2af327cd64a62cf35abd2ba6fab4")
        // With extra data that is covered by the tag but not encrypted, and a message that doesn't fill its last block.
        let aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let four = ShareCiphers.seal(.gcm, key: key, nonce: nonce, Array(message.prefix(60)), aad: aad, plain: plain)
        #expect(hex(four.ciphertext) == String(Self.gcmEncrypted.prefix(120)) && hex(four.tag) == "5bc94fbc3221a5db94fae95ae7121a47")

        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, four, aad: aad, plain: plain) == Array(message.prefix(60)))
        var changed = four
        changed.ciphertext[7] ^= 0x80
        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, changed, aad: aad, plain: plain) == nil)
        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, four, aad: Array(aad.dropLast()), plain: plain) == nil)
    }

    @Test(arguments: [false, true]) func ccmMatchesRFC3610AndSP80038C(plain: Bool) {
        // RFC 3610, packet vector 1: a 13-byte nonce, an 8-byte tag, 8 bytes of header that stay readable.
        let packet = [UInt8](0..<0x1f)
        let first = ShareCiphers.ccm(key: [UInt8](0xc0..<0xd0), nonce: unhex("00000003020100a0a1a2a3a4a5"), Array(packet[8...]), aad: Array(packet[..<8]),
                                     tagLength: 8, opening: false, plain: plain)
        #expect(hex(first.ciphertext + first.tag) == "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0")

        // SP 800-38C, examples 1 and 2: 7- and 8-byte nonces, 4- and 6-byte tags.
        let key = [UInt8](0x40..<0x50)
        let one = ShareCiphers.ccm(key: key, nonce: unhex("10111213141516"), unhex("20212223"), aad: [UInt8](0..<8), tagLength: 4, opening: false, plain: plain)
        #expect(hex(one.ciphertext + one.tag) == "7162015b4dac255d")
        let two = ShareCiphers.ccm(key: key, nonce: unhex("1011121314151617"), [UInt8](0x20..<0x30), aad: [UInt8](0..<16), tagLength: 6, opening: false, plain: plain)
        #expect(hex(two.ciphertext + two.tag) == "d2a1f0e051ea5f62081a7792073d593d1fc64fbfaccd")

        // Opening gives the message back and the same tag.
        let opened = ShareCiphers.ccm(key: key, nonce: unhex("1011121314151617"), two.ciphertext, aad: [UInt8](0..<16), tagLength: 6, opening: true, plain: plain)
        #expect(opened.ciphertext == [UInt8](0x20..<0x30) && opened.tag == two.tag)
    }

    @Test func aes256MatchesFIPS197() {
        // FIPS 197, appendix C.3: the 256-bit example.
        let key = ShareDigests.AESKey([UInt8](0..<32))
        #expect(hex(ShareDigests.aesEncrypt(block: unhex("00112233445566778899aabbccddeeff"), key: key)) == "8ea2b7ca516745bfeafc49904b496089")
    }

    @Test(arguments: [false, true]) func gcm256MatchesItsSpecification(plain: Bool) {
        // The GCM specification's test cases 13 to 16: the same messages as 1 to 4, with 256-bit keys.
        let zeros = [UInt8](repeating: 0, count: 32), zeroNonce = [UInt8](repeating: 0, count: 12)
        let thirteen = ShareCiphers.seal(.gcm256, key: zeros, nonce: zeroNonce, [], aad: [], plain: plain)
        #expect(thirteen.ciphertext.isEmpty && hex(thirteen.tag) == "530f8afbc74536b9a963b4f1c4cb738b")
        let fourteen = ShareCiphers.seal(.gcm256, key: zeros, nonce: zeroNonce, Array(zeros.prefix(16)), aad: [], plain: plain)
        #expect(hex(fourteen.ciphertext) == "cea7403d4d606b6e074ec5d3baf39d18" && hex(fourteen.tag) == "d0d1c8a799996bf0265b98b5d48ab919")

        let key = unhex(Self.gcmKey + Self.gcmKey), nonce = unhex(Self.gcmNonce), message = unhex(Self.gcmMessage)
        let encrypted = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad"
        let fifteen = ShareCiphers.seal(.gcm256, key: key, nonce: nonce, message, aad: [], plain: plain)
        #expect(hex(fifteen.ciphertext) == encrypted && hex(fifteen.tag) == "b094dac5d93471bdec1a502270e3cc6c")
        let aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let sixteen = ShareCiphers.seal(.gcm256, key: key, nonce: nonce, Array(message.prefix(60)), aad: aad, plain: plain)
        #expect(hex(sixteen.ciphertext) == String(encrypted.prefix(120)) && hex(sixteen.tag) == "76fc6ece0f4e1768cddf8853bb2d551b")
        #expect(ShareCiphers.open(.gcm256, key: key, nonce: nonce, sixteen, aad: aad, plain: plain) == Array(message.prefix(60)))
        var changed = sixteen
        changed.ciphertext[0] ^= 1
        #expect(ShareCiphers.open(.gcm256, key: key, nonce: nonce, changed, aad: aad, plain: plain) == nil)
    }

    @Test func theCiphersSayTheirSizes() {
        #expect(ShareCiphers.Kind.gcm.keyLength == 16 && ShareCiphers.Kind.ccm.keyLength == 16)
        #expect(ShareCiphers.Kind.gcm256.keyLength == 32 && ShareCiphers.Kind.ccm256.keyLength == 32)
        #expect(ShareCiphers.Kind.gcm256.nonceLength == 12 && ShareCiphers.Kind.ccm256.nonceLength == 11)
        // MS-SMB2 2.2.3.1.2's numbers.
        #expect(ShareCiphers.Kind.ccm256.rawValue == 3 && ShareCiphers.Kind.gcm256.rawValue == 4)
    }

    @Test func theSystemsCiphersAndTheOnesWrittenHereAgree() {
        // On Apple's systems encryption uses the system's AES; elsewhere both sides of this are the same code.
        var seed: UInt64 = 7
        func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        for length in [0, 1, 15, 16, 17, 31, 32, 33, 64, 113, 1000, 65536 + 5] {
            for kind in [ShareCiphers.Kind.gcm, .ccm, .gcm256, .ccm256] {
                let key = bytes(kind.keyLength), nonce = bytes(kind.nonceLength), message = bytes(length), aad = bytes(32)
                let sealed = ShareCiphers.seal(kind, key: key, nonce: nonce, message, aad: aad)
                #expect(sealed == ShareCiphers.seal(kind, key: key, nonce: nonce, message, aad: aad, plain: true))
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, sealed, aad: aad) == message)
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, sealed, aad: aad, plain: true) == message)
                var changed = sealed
                changed.tag[0] ^= 1
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, changed, aad: aad) == nil)
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, changed, aad: aad, plain: true) == nil)
            }
        }
    }
}
