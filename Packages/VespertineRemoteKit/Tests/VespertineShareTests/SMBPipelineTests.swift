//
// Vespertine: reading a file with several requests on the line at once, and reading ahead of a song as it plays. Against a
// made-up server whose answers take a set time to come back and a set time to send (a round trip and a bandwidth), on a
// clock of its own, so how long a read took is the same on every run and on any machine: the times below are the line's,
// not the computer's.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// An SMB server after sign-in that has one file, answering CREATE, CLOSE and READ. Each answer leaves the server once the
/// answers before it have been sent, takes `bytes / bandwidth` to send and half a round trip to arrive; asking takes the
/// other half. Time only passes when the client waits for an answer.
final class LatencyServer: SMBTransport, @unchecked Sendable {
    struct Line {
        var roundTrip: Double
        /// Bytes a second.
        var bandwidth: Double
    }

    let file: [UInt8]
    var line: Line
    /// What the server lets the client have outstanding, in credits, and what it grants with each answer.
    var creditLimit = 512
    var grant = 64
    /// Answers sent in an order of the server's own: each pair swapped.
    var reorder = false

    private(set) var now: Double = 0
    private(set) var reads = 0
    private(set) var mostInFlight = 0
    /// Requests that asked for more credits than the client had.
    private(set) var overdrawn = 0
    /// Every READ as (offset, length), in the order asked.
    private(set) var asked: [(offset: Int64, length: Int)] = []
    private var balance: Int
    private var serverFree: Double = 0
    private var answers: [(ready: Double, bytes: [UInt8])] = []
    private var held: (ready: Double, bytes: [UInt8])?
    private var pending: [UInt8] = []
    private var taken = 0
    private var inFlight = 0

    init(file: [UInt8], line: Line, credits: Int = 64) {
        self.file = file
        self.line = line
        balance = credits
    }

    func send(_ bytes: [UInt8]) throws {
        let message = Array(bytes.dropFirst(4))
        let r = ByteReader(message)
        let charge = max(1, Int(try r.u16(6)))
        let command = try r.u16(12), id = try r.u64(24)
        if charge > balance { overdrawn += 1 }
        balance -= charge
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        let arrives = now + line.roundTrip / 2
        var body = ByteWriter()
        var status: UInt32 = 0
        switch command {
        case 5:                                         // CREATE
            body.u16(89); body.u16(0); body.u32(1)
            for _ in 0..<4 { body.u64(SMBConnection.fileTime(Date(timeIntervalSince1970: 1_700_000_000))) }
            body.u64(UInt64(file.count)); body.u64(UInt64(file.count)); body.u32(0x80); body.u32(0)
            body.raw([UInt8](repeating: 7, count: 16)); body.u32(0); body.u32(0)
        case 6:                                         // CLOSE
            body.u16(60); body.zeros(58)
        case 8:                                         // READ
            reads += 1
            let length = Int(try r.u32(64 + 4)), offset = Int(try r.u64(64 + 8))
            asked.append((Int64(offset), length))
            if length > charge * 65536 { overdrawn += 1 }
            if offset >= file.count {
                status = 0xC000_0011
                body.u16(9); body.zeros(7)
            } else {
                let piece = file[offset..<min(file.count, offset + length)]
                body.u16(17); body.u8(0x50); body.u8(0); body.u32(UInt32(piece.count)); body.u32(0); body.u32(0)
                body.raw(Array(piece))
            }
        default:
            status = 0xC000_0002
            body.u16(9); body.zeros(7)
        }
        var header = ByteWriter()
        header.raw([0xfe, 0x53, 0x4d, 0x42]); header.u16(64); header.u16(0); header.u32(status); header.u16(command)
        let granted = max(0, min(grant, creditLimit - balance))
        balance += granted
        header.u16(UInt16(granted)); header.u32(1); header.u32(0); header.u64(id); header.u32(0); header.u32(1); header.u64(1); header.zeros(16)
        let answer = header.bytes + body.bytes
        let start = max(arrives, serverFree)
        serverFree = start + Double(answer.count) / line.bandwidth
        let framed = [0, UInt8(answer.count >> 16 & 0xff), UInt8(answer.count >> 8 & 0xff), UInt8(answer.count & 0xff)] + answer
        let entry = (ready: serverFree + line.roundTrip / 2, bytes: framed)
        if reorder {
            if let first = held {
                answers.append(entry)
                answers.append(first)
                held = nil
            } else {
                held = entry
            }
        } else {
            answers.append(entry)
        }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        while pending.count - taken < count {
            if answers.isEmpty, let last = held {
                answers.append(last)
                held = nil
            }
            guard !answers.isEmpty else { throw SMBError.timedOut }
            let next = answers.removeFirst()
            now = max(now, next.ready)
            inFlight -= 1
            pending.removeFirst(taken)
            taken = 0
            pending += next.bytes
        }
        defer { taken += count }
        return Array(pending[taken..<(taken + count)])
    }

    func close() {}
}

/// A file's bytes: a pattern no two nearby megabytes share.
func patterned(_ count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { bytes in
        for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
    }
    return out
}

private let mebibyte = 1 << 20

@Suite struct SMBPipelineTests {
    /// A connection to `server` as if it had just signed in with SMB 3.1.1 (or `dialect`).
    private func signedIn(_ server: LatencyServer, dialect: UInt16 = 0x0311, maxRead: Int = 8 << 20, credits: Int = 64) -> SMBConnection {
        let connection = SMBConnection(transport: server)
        connection.signedInForTesting(dialect: dialect, maxRead: maxRead, credits: credits)
        return connection
    }

    @Test func aLongReadKeepsSeveralRequestsOnTheLine() throws {
        let file = patterned(16 * mebibyte)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.040, bandwidth: 12_500_000))
        let connection = signedIn(server)
        let handle = try connection.open("song.flac", folder: false)
        let start = server.now
        #expect(try connection.read(handle, offset: 0, length: file.count) == file)
        let pipelined = server.now - start
        #expect(server.mostInFlight >= 4)
        #expect(server.overdrawn == 0)

        // The same read one request at a time, as the client used to: every megabyte waits a whole round trip.
        let slow = LatencyServer(file: file, line: server.line)
        let oneAtATime = signedIn(slow)
        oneAtATime.readDepth = 1
        let slowHandle = try oneAtATime.open("song.flac", folder: false)
        let slowStart = slow.now
        #expect(try oneAtATime.read(slowHandle, offset: 0, length: file.count) == file)
        let waited = slow.now - slowStart
        #expect(slow.mostInFlight == 1)
        #expect(pipelined < waited * 0.85, "pipelined \(pipelined) s, one at a time \(waited) s")
    }

    @Test func noMoreIsAskedForThanTheServerGranted() throws {
        let file = patterned(6 * mebibyte + 12345)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.030, bandwidth: 50_000_000), credits: 20)
        server.creditLimit = 20
        server.grant = 20
        let connection = signedIn(server, credits: 20)
        let handle = try connection.open("song.flac", folder: false)
        #expect(try connection.read(handle, offset: 0, length: file.count) == file)
        #expect(server.overdrawn == 0)
    }

    @Test func answersInAnotherOrderAreMatchedToTheirRequests() throws {
        let file = patterned(5 * mebibyte + 3)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.020, bandwidth: 50_000_000))
        server.reorder = true
        let connection = signedIn(server)
        let handle = try connection.open("song.flac", folder: false)
        #expect(try connection.read(handle, offset: 0, length: file.count) == file)
        #expect(try connection.read(handle, offset: 1000, length: 3 * mebibyte) == Array(file[1000..<(1000 + 3 * mebibyte)]))
    }

    @Test func theEndOfTheFileEndsTheReadAndTheLineCarriesOn() throws {
        let file = patterned(2 * mebibyte + mebibyte / 2)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.020, bandwidth: 50_000_000))
        let connection = signedIn(server)
        let handle = try connection.open("song.flac", folder: false)
        // Asked for far more than there is: what there is, and the answers to requests past the end don't confuse what follows.
        #expect(try connection.read(handle, offset: 0, length: 8 * mebibyte) == file)
        #expect(try connection.read(handle, offset: Int64(mebibyte), length: 10) == Array(file[mebibyte..<(mebibyte + 10)]))
        #expect(try connection.read(handle, offset: Int64(file.count), length: 10) == [])
        try connection.close(handle)
    }

    @Test func smb202ReadsSixtyFourKilobytesARequestAndStillOverlapsThem() throws {
        let file = patterned(mebibyte + 77)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.030, bandwidth: 50_000_000))
        let connection = signedIn(server, dialect: 0x0202, maxRead: 65536)
        let handle = try connection.open("song.flac", folder: false)
        #expect(try connection.read(handle, offset: 0, length: file.count) == file)
        #expect(server.asked.allSatisfy { $0.length <= 65536 })
        #expect(server.mostInFlight >= 4)
    }

    @Test func aSongReadInSmallPiecesIsReadAhead() throws {
        // The player asks for 256 KB at a time, each after the last arrived. Read ahead, the line stays busy between them.
        let file = patterned(24 * mebibyte)
        let line = LatencyServer.Line(roundTrip: 0.050, bandwidth: 12_500_000)
        func play(_ connection: SMBConnection, _ server: LatencyServer) throws -> Double {
            let handle = try connection.open("song.flac", folder: false)
            let start = server.now
            var offset = 0
            while offset < file.count {
                let piece = try connection.read(handle, offset: Int64(offset), length: 256 * 1024)
                #expect(piece == Array(file[offset..<min(file.count, offset + 256 * 1024)]))
                if piece.isEmpty { break }
                offset += piece.count
            }
            return server.now - start
        }
        let server = LatencyServer(file: file, line: line)
        let ahead = try play(signedIn(server), server)
        let plain = LatencyServer(file: file, line: line)
        let old = signedIn(plain)
        old.readDepth = 1
        old.readAheadLimit = 0
        let waited = try play(old, plain)
        #expect(ahead < waited * 0.6, "read ahead \(ahead) s, without \(waited) s")
        #expect(server.overdrawn == 0)
    }

    @Test func aJumpDropsWhatWasReadAheadAndReadsFromTheNewPlace() throws {
        let file = patterned(12 * mebibyte)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.020, bandwidth: 50_000_000))
        let connection = signedIn(server)
        let handle = try connection.open("song.flac", folder: false)
        for index in 0..<6 {
            let at = index * 256 * 1024
            #expect(try connection.read(handle, offset: Int64(at), length: 256 * 1024) == Array(file[at..<(at + 256 * 1024)]))
        }
        // A seek forward, then back, then a folder listing in between: each read is still the right bytes.
        let far = 9 * mebibyte + 5
        #expect(try connection.read(handle, offset: Int64(far), length: 300_000) == Array(file[far..<(far + 300_000)]))
        #expect(try connection.read(handle, offset: 10, length: 20) == Array(file[10..<30]))
        try connection.close(handle)
        let again = try connection.open("song.flac", folder: false)
        #expect(try connection.read(again, offset: 0, length: 100) == Array(file[0..<100]))
        #expect(server.overdrawn == 0)
    }

    @Test func tagsReadInSmallPiecesAreNotReadFarAhead() throws {
        // A library scan reads a few small pieces of each file one after the other. Reading ahead grows with how much has
        // been read in a row, so a scan doesn't fetch megabytes of every song.
        let file = patterned(40 * mebibyte)
        let server = LatencyServer(file: file, line: .init(roundTrip: 0.020, bandwidth: 50_000_000))
        let connection = signedIn(server)
        let handle = try connection.open("song.flac", folder: false)
        var offset = 0
        for _ in 0..<4 {
            _ = try connection.read(handle, offset: Int64(offset), length: 8192)
            offset += 8192
        }
        try connection.close(handle)
        let fetched = server.asked.reduce(0) { $0 + $1.length }
        #expect(fetched < 512 * 1024, "fetched \(fetched) bytes for 32 KB of tags")
    }
}
