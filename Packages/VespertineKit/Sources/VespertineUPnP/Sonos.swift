//
// Vespertine: what is particular to a Sonos system among network players. Every Sonos speaker answers a search, but a room
// is what plays: the surrounds and the Sub of a home theater and the second speaker of a stereo pair are parts of a room,
// and rooms grouped together are led by one of them (the coordinator), the only one that takes transport commands. The
// system says how it is arranged in ZoneGroupTopology's GetZoneGroupState; this reads it. Its volume is its own
// (RenderingControl, or GroupRenderingControl for several rooms), and never touches the samples.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Which Sonos software a speaker runs. S2 takes FLAC and Apple Lossless up to 24-bit from a music library, S1 up to 16-bit.
public enum SonosGeneration: Sendable, Hashable {
    case s1, s2
    /// It doesn't say: treated as S1, whose limits every Sonos plays.
    case unknown

    /// From a description's `swGen` ("1", "2"), else its display version (S1 ends at 11.x; S2 began at 12.0).
    public init(swGen: String?, displayVersion: String?) {
        switch swGen?.trimmingCharacters(in: .whitespaces) {
        case "1": self = .s1; return
        case "2": self = .s2; return
        default: break
        }
        let major = displayVersion?.trimmingCharacters(in: .whitespaces).split(separator: ".").first.flatMap { Int($0) }
        switch major {
        case let m? where m >= 12: self = .s2
        case let m? where m >= 1: self = .s1
        default: self = .unknown
        }
    }
}

/// How a Sonos system is arranged right now.
public struct SonosTopology: Sendable, Hashable {
    public struct Member: Sendable, Hashable {
        /// "RINCON_…": the speaker's id, as in its UDN.
        public var uuid: String
        public var roomName: String
        public var location: URL?
        /// Not a room of its own: a surround, a Sub, the second speaker of a pair.
        public var invisible: Bool
        /// Who plays which channels in a home theater ("RINCON_A:LF,RF;RINCON_B:SW;RINCON_C:LR;RINCON_D:RR"); nil elsewhere.
        public var homeTheaterMap: String?
        /// Who plays which side of a stereo pair ("RINCON_A:LF,LF;RINCON_B:RF,RF"); nil elsewhere.
        public var pairMap: String?
    }

    public struct Group: Sendable, Hashable {
        /// The id of the room that leads the group.
        public var coordinator: String
        /// Rooms and their parts, every speaker once.
        public var members: [Member]
    }

    public var groups: [Group]

    /// The arrangement in a GetZoneGroupState answer's `ZoneGroupState`; nil when it holds no group.
    public static func parse(_ xml: String) -> SonosTopology? {
        let delegate = TopologyParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        guard parser.parse(), !delegate.groups.isEmpty else { return nil }
        return SonosTopology(groups: delegate.groups)
    }

    /// The speaker's id in a UDN: "uuid:RINCON_347E5C0CF1E401400_MR" is "RINCON_347E5C0CF1E401400".
    public static func uuid(udn: String) -> String? {
        var text = udn.hasPrefix("uuid:") ? String(udn.dropFirst(5)) : udn
        guard text.hasPrefix("RINCON_") else { return nil }
        for suffix in ["_MR", "_MS"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }

    /// What the speaker with `uuid` is in this arrangement; nil when the system doesn't list it.
    public func zone(uuid: String) -> SonosZone? {
        for group in groups {
            guard let member = group.members.first(where: { $0.uuid == uuid }) else { continue }
            let rooms = group.members.filter { !$0.invisible }
            let lead = rooms.first { $0.uuid == group.coordinator }
            // The coordinator's room first, then the others by name.
            let names = (lead.map { [$0.roomName] } ?? []) + rooms.filter { $0.uuid != group.coordinator }.map(\.roomName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let map = member.homeTheaterMap.map(Self.channels) ?? [:]
            let others = map.filter { $0.key != uuid }
            return SonosZone(uuid: uuid, roomName: member.roomName, isRoom: !member.invisible, isCoordinator: group.coordinator == uuid,
                             groupRooms: names,
                             surrounds: others.values.filter { $0.contains("LR") || $0.contains("RR") }.count,
                             hasSub: others.values.contains { $0.contains("SW") },
                             isStereoPair: member.pairMap.map { Self.channels($0).count > 1 } ?? false)
        }
        return nil
    }

    /// "A:LF,RF;B:SW" as speaker → channels.
    static func channels(_ map: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for part in map.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            out[String(pair[0]), default: []] += pair[1].split(separator: ",").map(String.init)
        }
        return out
    }
}

private final class TopologyParser: NSObject, XMLParserDelegate {
    var groups: [SonosTopology.Group] = []
    private var current: SonosTopology.Group?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "ZoneGroup":
            current = SonosTopology.Group(coordinator: a["Coordinator"] ?? "", members: [])
        case "ZoneGroupMember", "Satellite":
            guard let uuid = a["UUID"], !uuid.isEmpty else { return }
            // A satellite is part of the room it is listed under, whatever it says of itself.
            let member = SonosTopology.Member(uuid: uuid, roomName: a["ZoneName"] ?? "", location: a["Location"].flatMap { URL(string: $0) },
                                              invisible: name == "Satellite" || a["Invisible"] == "1",
                                              homeTheaterMap: a["HTSatChanMapSet"].flatMap { $0.isEmpty ? nil : $0 },
                                              pairMap: a["ChannelMapSet"].flatMap { $0.isEmpty ? nil : $0 })
            current?.members.append(member)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "ZoneGroup", let group = current {
            if !group.members.isEmpty { groups.append(group) }
            current = nil
        }
    }
}

/// One Sonos speaker's place in the system.
public struct SonosZone: Sendable, Hashable {
    public var uuid: String
    public var roomName: String
    /// A room of its own (not a surround, a Sub or the second speaker of a pair).
    public var isRoom: Bool
    /// It leads its group: the one Vespertine talks to.
    public var isCoordinator: Bool
    /// The rooms that play together with it, its own included, the leading one first.
    public var groupRooms: [String]
    /// Surround speakers bonded to it (a home theater's rears).
    public var surrounds: Int
    public var hasSub: Bool
    public var isStereoPair: Bool

    public init(uuid: String, roomName: String, isRoom: Bool = true, isCoordinator: Bool = true, groupRooms: [String] = [], surrounds: Int = 0,
                hasSub: Bool = false, isStereoPair: Bool = false) {
        self.uuid = uuid
        self.roomName = roomName
        self.isRoom = isRoom
        self.isCoordinator = isCoordinator
        self.groupRooms = groupRooms
        self.surrounds = surrounds
        self.hasSub = hasSub
        self.isStereoPair = isStereoPair
    }

    /// It is listed as an output: a room that leads its group. The other rooms of the group play what it plays.
    public var isOutput: Bool { isRoom && isCoordinator }
    /// A soundbar with surrounds: Sonos's own "5.1" (or "5.0" without a Sub).
    public var isHomeTheater: Bool { surrounds > 0 }
    /// Several rooms play together.
    public var isGroup: Bool { groupRooms.count > 1 }

    /// "Living Room", or "Living Room + Kitchen" for rooms grouped together.
    public var displayName: String {
        groupRooms.isEmpty ? roomName : groupRooms.joined(separator: " + ")
    }

    /// "5.1", "5.0", "3.1", "stereo pair" as Sonos names the room's speakers; nil for a single speaker.
    public var speakerSetup: String? {
        if surrounds > 0 { return hasSub ? "5.1" : "5.0" }
        if hasSub { return isStereoPair ? "2.1" : "3.1" }
        return isStereoPair ? String(localized: "stereo pair", comment: "Two Sonos speakers set up as left and right.") : nil
    }
}

extension RendererDevice {
    /// A Sonos speaker (its UDN is `uuid:RINCON_…`, whatever the description's maker field says).
    public var isSonos: Bool { SonosTopology.uuid(udn: description.udn) != nil }

    /// What it takes beyond what its format list says; nil for a player that states its own limits (or none).
    /// A Sonos is held to S2's limits only when it says it runs S2; S1, or not saying, gets S1's (16-bit), which both play.
    public var limits: StreamLimits? {
        guard isSonos else { return nil }
        switch sonosGeneration {
        case .s2: return .sonos
        case .s1: return .sonosS1
        case .unknown: return .sonosUnknown
        }
    }

    /// S1 or S2, as the speaker's description says; `.unknown` for a speaker that doesn't say (and for other players).
    public var sonosGeneration: SonosGeneration {
        isSonos ? SonosGeneration(swGen: description.softwareGeneration, displayVersion: description.displayVersion) : .unknown
    }
}

// MARK: - Volume

/// A player's own volume, 0 to 100, as its remote sets it. The samples Vespertine sends are not changed by it.
public protocol RendererVolume: Sendable {
    func volume() async throws -> Int
    func setVolume(_ level: Int) async throws
    func isMuted() async throws -> Bool
    func setMuted(_ muted: Bool) async throws
}

/// UPnP RenderingControl's Master channel: one player (for a Sonos home theater, the whole room: soundbar, surrounds, Sub).
public struct RenderingControlVolume: RendererVolume {
    let service: UPnPService
    let client: SOAPClient
    private static let instance = ("InstanceID", "0")
    private static let master = ("Channel", "Master")

    public init?(description: DeviceDescription, client: SOAPClient = SOAPClient()) {
        guard let service = description.service(.renderingControl) else { return nil }
        self.service = service
        self.client = client
    }

    public func volume() async throws -> Int {
        guard let level = Int(try await client.call(service, "GetVolume", [Self.instance, Self.master])["CurrentVolume"] ?? "") else { throw UPnPError.badResponse }
        return min(100, max(0, level))
    }

    public func setVolume(_ level: Int) async throws {
        _ = try await client.call(service, "SetVolume", [Self.instance, Self.master, ("DesiredVolume", String(min(100, max(0, level))))])
    }

    public func isMuted() async throws -> Bool {
        let value = try await client.call(service, "GetMute", [Self.instance, Self.master])["CurrentMute"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    public func setMuted(_ muted: Bool) async throws {
        _ = try await client.call(service, "SetMute", [Self.instance, Self.master, ("DesiredMute", muted ? "1" : "0")])
    }
}

/// How a Sonos home theater's surround speakers play two-channel music: the Sonos app's Music Playback setting.
public enum SonosSurroundMusic: String, Sendable, Hashable {
    /// Quiet, limited range (Sonos's default).
    case ambient
    /// Full range, as loud as the front.
    case full
}

extension RenderingControlVolume {
    /// The room's Music Playback setting, read (never set) from the sound bar; nil for a room without surrounds, or when it
    /// doesn't say.
    public func surroundMusic() async -> SonosSurroundMusic? {
        guard let value = try? await client.call(service, "GetEQ", [("InstanceID", "0"), ("EQType", "SurroundMode")])["CurrentValue"] else { return nil }
        switch value.trimmingCharacters(in: .whitespaces) {
        case "0": return .ambient
        case "1": return .full
        default: return nil
        }
    }
}

/// Sonos GroupRenderingControl: every room of a group at once, each keeping its level relative to the others, as the
/// Sonos app's group slider does.
public struct SonosGroupVolume: RendererVolume {
    let service: UPnPService
    let client: SOAPClient
    private static let instance = ("InstanceID", "0")

    public init?(description: DeviceDescription, client: SOAPClient = SOAPClient()) {
        guard let service = description.service(.groupRenderingControl) else { return nil }
        self.service = service
        self.client = client
    }

    public func volume() async throws -> Int {
        guard let level = Int(try await client.call(service, "GetGroupVolume", [Self.instance])["CurrentVolume"] ?? "") else { throw UPnPError.badResponse }
        return min(100, max(0, level))
    }

    public func setVolume(_ level: Int) async throws {
        // The rooms' levels relative to each other are taken first: without it the group's level is set from a stale picture.
        _ = try? await client.call(service, "SnapshotGroupVolume", [Self.instance])
        _ = try await client.call(service, "SetGroupVolume", [Self.instance, ("DesiredVolume", String(min(100, max(0, level))))])
    }

    public func isMuted() async throws -> Bool {
        let value = try await client.call(service, "GetGroupMute", [Self.instance])["CurrentMute"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    public func setMuted(_ muted: Bool) async throws {
        _ = try await client.call(service, "SetGroupMute", [Self.instance, ("DesiredMute", muted ? "1" : "0")])
    }
}

extension RendererDevice {
    /// The player's own volume, where Vespertine sets it: a Sonos room (its group's, when several rooms play together).
    /// nil for other players, whose volume Vespertine leaves alone.
    public func makeVolume(client: SOAPClient = SOAPClient()) -> (any RendererVolume)? {
        guard isSonos else { return nil }
        if sonos?.isGroup == true, let group = SonosGroupVolume(description: description, client: client) { return group }
        return RenderingControlVolume(description: description, client: client)
    }
}
