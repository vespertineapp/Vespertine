//
// Vespertine: listing the shares a server offers, as "Add a Share" does once the name and password work: the server's
// share service (MS-SRVS NetrShareEnum) asked over its IPC$ pipe. Against conversations recorded with Samba 4.19, which
// offers "music", "archive" (with a comment), a hidden "hidden$" and its own IPC$; only the first two are for music.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

@Suite struct SMBShareListTests {
    @Test(arguments: ["smb311shares", "smb311gcmshares", "smb302shares"]) func theServersSharesAreListed(name: String) throws {
        let recording = try #require(SMBRecordings.all[name])
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        let shares = try SMBShareList.fetch(on: connection, server: "127.0.0.1", credentials: recordedAccount)
        #expect(shares == [SMBShareInfo(name: "archive", comment: "Old rips"), SMBShareInfo(name: "music", comment: "")])
        #expect(transport.mismatch == nil)
        #expect(transport.finished)
    }

    @Test func aGuestIsListedTheSharesTooWhereTheServerAllows() throws {
        let recording = try #require(SMBRecordings.all["smb311guestshares"])
        let connection = SMBConnection(transport: ReplayTransport(recording), options: recordedOptions)
        let shares = try SMBShareList.fetch(on: connection, server: "127.0.0.1", credentials: SMBCredentials(name: "", password: ""))
        #expect(shares.map(\.name) == ["archive", "music"])
    }

    @Test func theAnswerIsReadAsTheShareServiceWritesIt() throws {
        // NetrShareEnum's answer at level 1, as MS-SRVS 2.2.4.23 and NDR lay it out: a disk share, a printer, IPC$
        // (special), a hidden disk share and one whose name and comment are odd lengths (each string is padded to four bytes).
        var w = ByteWriter()
        w.u32(1); w.u32(1)                              // level, the union's arm
        w.u32(0x20000); w.u32(5); w.u32(0x20004)        // the container, its count, its array
        w.u32(5)                                        // the array's size
        let entries: [(String, UInt32, String)] = [("music", 0, ""), ("printer", 1, "Laser"), ("IPC$", 0x8000_0003, "IPC Service"),
                                                   ("hidden$", 0, ""), ("Hi-Res Music", 0, "FLAC and DSD")]
        for (index, _) in entries.enumerated() { w.u32(UInt32(0x20008 + index * 8)); w.u32(entries[index].1); w.u32(UInt32(0x2000c + index * 8)) }
        func string(_ text: String) {
            let units = Array(text.utf16) + [0]
            w.u32(UInt32(units.count)); w.u32(0); w.u32(UInt32(units.count))
            for unit in units { w.u16(unit) }
            if units.count % 2 == 1 { w.u16(0) }
        }
        for entry in entries { string(entry.0); string(entry.2) }
        w.u32(5)                                        // total entries
        w.u32(0)                                        // no resume handle
        w.u32(0)                                        // success
        let shares = try SMBShareList.parse(w.bytes)
        #expect(shares == [SMBShareInfo(name: "Hi-Res Music", comment: "FLAC and DSD"), SMBShareInfo(name: "music", comment: "")])
        // An error from the service (access denied) is said, not taken for an empty list.
        var refused = ByteWriter()
        refused.u32(1); refused.u32(1); refused.u32(0); refused.u32(0); refused.u32(0); refused.u32(5)
        #expect(throws: SMBError.accessDenied) { _ = try SMBShareList.parse(refused.bytes) }
        // Cut short: refused as malformed.
        #expect(throws: SMBError.malformed) { _ = try SMBShareList.parse(Array(w.bytes.prefix(60))) }
    }
}
