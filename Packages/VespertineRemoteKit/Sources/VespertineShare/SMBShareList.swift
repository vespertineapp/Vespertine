//
// Vespertine: the shares a server offers, so "Add a Share" can list them once the name and password work instead of
// asking for the share's name. Asked of the server's share service (MS-SRVS NetrShareEnum, level 1) over its IPC$ pipe
// in DCE/RPC, as Windows, macOS and smbclient ask it. Disk shares only: printers, IPC$ and the hidden shares whose names
// end in "$" are left out.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct SMBShareInfo: Equatable, Hashable, Sendable {
    public var name: String
    /// What the server's owner wrote about it; often empty.
    public var comment: String

    public init(name: String, comment: String) {
        self.name = name
        self.comment = comment
    }
}

public enum SMBShareList {
    /// Signs in to the server at `host` and lists its shares.
    public static func fetch(host: String, port: Int = 445, credentials: SMBCredentials, timeout: TimeInterval = 15) throws -> [SMBShareInfo] {
        let connection = SMBConnection(transport: try SocketTransport(host: host, port: port, timeout: timeout))
        defer { connection.disconnect() }
        return try fetch(on: connection, server: host, credentials: credentials)
    }

    /// On a connection not yet signed in: signs in, connects to IPC$ and asks.
    static func fetch(on connection: SMBConnection, server: String, credentials: SMBCredentials) throws -> [SMBShareInfo] {
        try connection.connect(server: server, share: "IPC$", credentials: credentials)
        let pipe = try connection.openService("srvsvc")
        defer { try? connection.close(pipe) }
        let bound = try answer(connection, pipe, bind())
        guard bound.first.count >= 3, bound.first[2] == 12, try bindAccepted(bound.first) else { throw SMBError.unsupported }
        let response = try answer(connection, pipe, request(server: server))
        return try parse(response.stub)
    }

    // MARK: DCE/RPC

    /// The share service's interface (4b324fc8-1670-01d3-1278-5a47bf6ee188, version 3.0) and NDR's transfer syntax
    /// (8a885d04-1ceb-11c9-9fe8-08002b104860, version 2), as DCE/RPC writes UUIDs.
    private static let service: [UInt8] = [0xc8, 0x4f, 0x32, 0x4b, 0x70, 0x16, 0xd3, 0x01, 0x12, 0x78, 0x5a, 0x47, 0xbf, 0x6e, 0xe1, 0x88]
    private static let ndr: [UInt8] = [0x04, 0x5d, 0x88, 0x8a, 0xeb, 0x1c, 0xc9, 0x11, 0x9f, 0xe8, 0x08, 0x00, 0x2b, 0x10, 0x48, 0x60]
    private static let fragmentSize = 4280

    private static func header(type: UInt8, length: Int, call: UInt32) -> ByteWriter {
        var w = ByteWriter()
        w.u8(5); w.u8(0); w.u8(type); w.u8(0x03)        // version 5.0, first and last fragment
        w.raw([0x10, 0, 0, 0])                          // little-endian, ASCII, IEEE floats
        w.u16(UInt16(length)); w.u16(0); w.u32(call)
        return w
    }

    static func bind() -> [UInt8] {
        var body = ByteWriter()
        body.u16(UInt16(fragmentSize)); body.u16(UInt16(fragmentSize)); body.u32(0)
        body.u8(1); body.u8(0); body.u16(0)             // one presentation context
        body.u16(0); body.u8(1); body.u8(0)
        body.raw(service); body.u16(3); body.u16(0)
        body.raw(ndr); body.u32(2)
        var w = header(type: 11, length: 16 + body.bytes.count, call: 1)
        w.raw(body.bytes)
        return w.bytes
    }

    /// Whether the bind's answer accepted the interface.
    private static func bindAccepted(_ ack: [UInt8]) throws -> Bool {
        let r = ByteReader(ack)
        let address = Int(try r.u16(24))
        let results = (26 + address + 3) / 4 * 4
        return try r.u8(results) >= 1 && r.u16(results + 4) == 0
    }

    /// NetrShareEnum (operation 15) for `server`, level 1, everything at once.
    static func request(server: String) -> [UInt8] {
        var stub = ByteWriter()
        let name = Array("\\\\\(server)".utf16) + [0]
        stub.u32(0x0002_0000)
        stub.u32(UInt32(name.count)); stub.u32(0); stub.u32(UInt32(name.count))
        for unit in name { stub.u16(unit) }
        if name.count % 2 == 1 { stub.u16(0) }
        stub.u32(1); stub.u32(1)                        // level 1, and the union's arm
        stub.u32(0x0002_0004); stub.u32(0); stub.u32(0) // a container with nothing in it yet
        stub.u32(0xFFFF_FFFF)                           // as much as there is
        stub.u32(0x0002_0008); stub.u32(0)              // resume from the start
        var body = ByteWriter()
        body.u32(UInt32(stub.bytes.count)); body.u16(0); body.u16(15)
        body.raw(stub.bytes)
        var w = header(type: 0, length: 16 + body.bytes.count, call: 2)
        w.raw(body.bytes)
        return w.bytes
    }

    /// Sends `pdu` and reads the whole answer: every fragment, each read on until the pipe has no more of it. `first` is
    /// the first fragment as it came; `stub` the answer's data from all of them.
    private static func answer(_ connection: SMBConnection, _ pipe: SMBHandle, _ pdu: [UInt8]) throws -> (first: [UInt8], stub: [UInt8]) {
        var (buffer, more) = try connection.transceive(pipe, pdu)
        var first: [UInt8]?
        var stub: [UInt8] = []
        while true {
            // A whole fragment in the buffer: its length is in its header.
            func whole() throws -> Bool { try buffer.count >= 16 && buffer.count >= Int(ByteReader(buffer).u16(8)) }
            while try !whole() {
                guard more || buffer.count > 0 else { throw SMBError.malformed }
                let next = try connection.readService(pipe)
                guard !next.output.isEmpty else { throw SMBError.malformed }
                buffer += next.output
                more = next.more
            }
            let r = ByteReader(buffer)
            let length = Int(try r.u16(8)), flags = try r.u8(3), type = try r.u8(2)
            guard length >= 16 else { throw SMBError.malformed }
            let fragment = try r.slice(0, length)
            buffer.removeFirst(length)
            if first == nil { first = fragment }
            switch type {
            case 2:                                     // a response: its data after 8 more bytes of header
                stub += try ByteReader(fragment).slice(24, length - 24 - Int(try r.u16(10)))
            case 3:                                     // a fault
                throw SMBError.status(try ByteReader(fragment).u32(24))
            case 12, 13:                                // the bind accepted or refused
                return (fragment, [])
            default:
                throw SMBError.malformed
            }
            if flags & 0x02 != 0 { return (first ?? fragment, stub) }
        }
    }

    // MARK: NDR

    /// The shares in NetrShareEnum's answer, disk shares only, sorted by name as people read them.
    static func parse(_ stub: [UInt8]) throws -> [SMBShareInfo] {
        let r = ByteReader(stub)
        var at = 0
        func u32() throws -> UInt32 {
            at = (at + 3) / 4 * 4
            defer { at += 4 }
            return try r.u32(at)
        }
        func string() throws -> String {
            _ = try u32()
            _ = try u32()
            let count = Int(try u32())
            let bytes = try r.slice(at, count * 2)
            at += count * 2
            var text = String(utf16LE: bytes)
            while text.hasSuffix("\0") { text.removeLast() }
            return text
        }
        guard try u32() == 1, try u32() == 1 else { throw SMBError.malformed }
        var found: [(name: String, type: UInt32, comment: String)] = []
        if try u32() != 0 {
            let count = Int(try u32())
            if try u32() != 0 {
                guard Int(try u32()) == count, count < 100_000 else { throw SMBError.malformed }
                var entries: [(name: Bool, type: UInt32, comment: Bool)] = []
                for _ in 0..<count { entries.append((try u32() != 0, try u32(), try u32() != 0)) }
                for entry in entries {
                    let name = entry.name ? try string() : ""
                    let comment = entry.comment ? try string() : ""
                    found.append((name, entry.type, comment))
                }
            }
        }
        _ = try u32()                                   // total entries
        if try u32() != 0 { _ = try u32() }             // resume handle
        let status = try u32()
        guard status == 0 else { throw status == 5 ? SMBError.accessDenied : SMBError.status(status) }
        return found.filter { $0.type & 0xFFFF == 0 && $0.type & 0x8000_0000 == 0 && !$0.name.isEmpty && !$0.name.hasSuffix("$") }
            .map { SMBShareInfo(name: $0.name, comment: $0.comment) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
