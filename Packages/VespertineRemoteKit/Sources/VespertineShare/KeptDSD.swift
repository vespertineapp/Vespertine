//
// Vespertine: a DSD song kept on the phone as its own file (DSF or DSDIFF), played as the share plays it: each time it is
// opened, as DoP frames for a DAC that takes them or as PCM no higher than the output runs (`DSDRendering`), made from the
// kept file as it is read. So the kept copy is the original, whatever the phone is plugged into the day it plays.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public final class KeptDSD: @unchecked Sendable {
    /// What the player is given: the same form, size and frames as the share would open the song in.
    public let descriptor: StreamDescriptor
    private let rendering: DSDRendering
    private let handle: FileHandle
    private let lock = NSLock()

    /// The kept file at `file` as the player can read it, for an output that runs at up to `maxSampleRate` and takes DoP up
    /// to the carrier rate `dop`. nil: not a DSD file the phone plays (surround, DST, not DSD at all).
    public static func open(_ file: URL, maxSampleRate: Double?, dop: Double?) throws -> KeptDSD? {
        let handle = try FileHandle(forReadingFrom: file)
        let size = Int64(try handle.seekToEnd())
        func fetch(_ offset: Int64, _ length: Int) throws -> Data {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        }
        guard let tags = try? SongTagReader.read(name: file.lastPathComponent, size: size, read: fetch), let layout = tags.dsd, layout.playsHere,
              let rendering = DSDRendering.plan(layout, maxSampleRate: maxSampleRate, dop: dop) else {
            try? handle.close()
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let descriptor = StreamDescriptor(stream: 0, kind: .pcm, byteSize: rendering.byteSize, format: ShareMac.delivered(rendering), frames: rendering.frames,
                                          tag: ShareMac.tag(rendering, size: size, modified: modified), chunkSize: RemoteProtocol.defaultChunkSize,
                                          dsdRate: rendering.form == .dop ? tags.sampleRate : nil)
        return KeptDSD(descriptor: descriptor, rendering: rendering, handle: handle)
    }

    private init(descriptor: StreamDescriptor, rendering: DSDRendering, handle: FileHandle) {
        self.descriptor = descriptor
        self.rendering = rendering
        self.handle = handle
    }

    deinit { try? handle.close() }

    /// Up to `length` bytes of what the player reads, from `offset`: fewer only at the end.
    public func read(offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            try rendering.read(offset: offset, length: length) { at, count in
                try handle.seek(toOffset: UInt64(at))
                return try handle.read(upToCount: count) ?? Data()
            }
        }
    }
}
