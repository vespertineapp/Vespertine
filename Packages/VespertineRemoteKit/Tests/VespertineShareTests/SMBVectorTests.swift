//
// Vespertine: SMB 3.1.1's digest of the opening messages, the keys made from it, the signature on the sign-in's last
// answer and both ciphers' encrypted messages, against the vectors Microsoft published (SMBVectors.swift says where).
// These are Windows talking to Windows, so they show the client's pieces agree with the protocol's own reference,
// not just with the Samba server the recorded conversations were made with.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

@Suite struct SMBVectorTests {
    @Test func theDigestOfTheOpeningMessagesMatches() {
        var digest = [UInt8](repeating: 0, count: 64)
        for step in SMBVectors.opening {
            digest = ShareDigests.sha512(digest + unhex(step.message))
            #expect(digest == unhex(step.digest))
        }
    }

    @Test func smb311KeysComeFromTheSessionKeyAndTheDigest() throws {
        let gcmDigest = unhex(try #require(SMBVectors.opening.last).digest)
        for (session, digest) in [(SMBVectors.gcm311, gcmDigest), (SMBVectors.ccm311, unhex(SMBVectors.ccmOpeningDigest))] {
            let key = unhex(session.sessionKey)
            #expect(hex(SMBConnection.derive(key, label: "SMBSigningKey", context: digest)) == session.signingKey)
            #expect(hex(SMBConnection.derive(key, label: "SMBC2SCipherKey", context: digest)) == session.sealKey)
            #expect(hex(SMBConnection.derive(key, label: "SMBS2CCipherKey", context: digest)) == session.openKey)
        }
    }

    @Test func aes256KeysAreTwiceAsLong() {
        // MS-SMB2 3.1.4.2: with AES-256 the cipher keys come out of the same derivation with L = 256, all 32 bytes of
        // HMAC-SHA-256 kept. The numbers were worked out apart from this code, with Python's hmac module.
        let key = [UInt8](0..<16), digest = [UInt8](0..<64)
        #expect(hex(SMBConnection.derive(key, label: "SMBC2SCipherKey", context: digest, bits: 256)) == "d09c44a545f554240ddf8ac2777570de0f590e402196d1006261f7448076384d")
        #expect(hex(SMBConnection.derive(key, label: "SMBS2CCipherKey", context: digest, bits: 256)) == "7a55e2deed408102591fdea4192f54895bd7e4c879d11927493898b42c8a9ccd")
        #expect(hex(SMBConnection.derive(key, label: "SMBC2SCipherKey", context: digest)) == "f1b6250ca4d9f8877e41071f59228ce4")
    }

    @Test func smb30KeysComeFromTheSessionKeyAlone() {
        let session = SMBVectors.ccm300, key = unhex(session.sessionKey)
        #expect(hex(SMBConnection.derive(key, label: "SMB2AESCMAC", context: "SmbSign")) == session.signingKey)
        #expect(hex(SMBConnection.derive(key, label: "SMB2AESCCM", context: "ServerIn ")) == session.sealKey)
        #expect(hex(SMBConnection.derive(key, label: "SMB2AESCCM", context: "ServerOut")) == session.openKey)
    }

    @Test func theLastSignInAnswerIsSignedWithTheDerivedKey() {
        for (session, answer) in [(SMBVectors.gcm311, SMBVectors.gcmSignedIn), (SMBVectors.ccm311, SMBVectors.ccmSignedIn)] {
            let message = unhex(answer)
            var unsigned = message
            unsigned.replaceSubrange(48..<64, with: [UInt8](repeating: 0, count: 16))
            #expect(ShareDigests.aesCMAC(key: unhex(session.signingKey), unsigned) == Array(message[48..<64]))
        }
    }

    @Test(arguments: [("gcm311", ShareCiphers.Kind.gcm), ("ccm311", .ccm), ("ccm300", .ccm)])
    func aRequestIsEncryptedAsWindowsEncryptedIt(name: String, cipher: ShareCiphers.Kind) throws {
        let session = try #require(["gcm311": SMBVectors.gcm311, "ccm311": SMBVectors.ccm311, "ccm300": SMBVectors.ccm300][name])
        let expected = unhex(session.writeSealed)
        // The nonce is the sender's to choose: Windows' own is taken from its message, everything else must come out the same.
        let sealed = SMBConnection.sealed(unhex(session.write), cipher: cipher, key: unhex(session.sealKey),
                                          nonceField: Array(expected[20..<36]), sessionID: session.sessionID)
        #expect(sealed == expected)
    }

    @Test(arguments: [("gcm311", ShareCiphers.Kind.gcm), ("ccm311", .ccm), ("ccm300", .ccm)])
    func anAnswerIsDecryptedAndAChangedOneRefused(name: String, cipher: ShareCiphers.Kind) throws {
        let session = try #require(["gcm311": SMBVectors.gcm311, "ccm311": SMBVectors.ccm311, "ccm300": SMBVectors.ccm300][name])
        let sealed = unhex(session.readAnswerSealed), key = unhex(session.openKey)
        #expect(try SMBConnection.opened(sealed, cipher: cipher, key: key, sessionID: session.sessionID) == unhex(session.readAnswer))
        // The file's contents are the last bytes of the answer: "Smb3 encryption testing".
        #expect(String(decoding: unhex(session.readAnswer).suffix(23), as: UTF8.self) == "Smb3 encryption testing")

        // One bit changed anywhere (the tag, the nonce, the size, the encrypted bytes) and the tag no longer fits.
        for index in [4, 20, 40, 52, sealed.count - 1] {
            var changed = sealed
            changed[index] ^= 0x01
            #expect(throws: SMBError.self) { _ = try SMBConnection.opened(changed, cipher: cipher, key: key, sessionID: session.sessionID) }
        }
        // The other direction's key, and an answer for another session, are refused too.
        #expect(throws: SMBError.badSignature) { _ = try SMBConnection.opened(sealed, cipher: cipher, key: unhex(session.sealKey), sessionID: session.sessionID) }
        #expect(throws: SMBError.malformed) { _ = try SMBConnection.opened(sealed, cipher: cipher, key: key, sessionID: session.sessionID + 1) }
    }
}
