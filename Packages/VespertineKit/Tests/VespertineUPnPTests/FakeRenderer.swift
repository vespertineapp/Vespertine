//
// Vespertine: a network renderer for the tests, on 127.0.0.1. It serves a description and service descriptions, runs
// OpenHome Playlist/Time/Product or UPnP AV as a small state machine, records every SOAP call, and fetches each URI it
// is told to play, so a test can compare the bytes it got with the source file.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineUPnP

final class FakeRenderer: @unchecked Sendable {
    enum Kind { case openHome, av(setNext: Bool) }

    struct Call: Hashable { var service: String; var action: String; var arguments: [String: String] }

    let kind: Kind
    var sink = "http-get:*:audio/flac:*,http-get:*:audio/x-flac:*,http-get:*:audio/wav:*,http-get:*:audio/L16;rate=48000;channels=2:*"
    private let lock = NSLock()
    private var server: HTTPServer!
    private(set) var port: UInt16 = 0

    // State, under `lock`.
    private var _calls: [Call] = []
    private var playlist: [(id: Int, uri: String)] = []
    private var nextID = 1
    private var currentID = 0
    private var avCurrent: String?
    private var avNext: String?
    private var state = "Stopped"        // OpenHome words; AV maps them
    private var seconds = 0
    private var _fetched: [String: Data] = [:]
    private var failures: [String: (code: Int, times: Int)] = [:]
    private var sourceIndex = 0          // starts on the radio, as a real one may
    private var _ignoresPlay = false
    /// Takes a song and says yes to Play, but never plays it (a song it can't fetch or decode).
    var ignoresPlay: Bool {
        get { lock.withLock { _ignoresPlay } }
        set { lock.withLock { _ignoresPlay = newValue } }
    }

    /// A Sonos speaker: its room's name. The description is then a ZonePlayer with the renderer inside it, as a Sonos's is,
    /// and it answers for how its system is arranged (`zoneGroupState`) and for its volume.
    var sonosRoom: String?
    var sonosModel = "Sonos Playbar"
    /// The speaker's software, as its description states it: `swGen` 2 and a display version of 12 or later are S2, `swGen`
    /// 1 and 11.x are S1. Empty: a description that says neither.
    var sonosSoftware: [(String, String)] = [("swGen", "2"), ("displayVersion", "16.1")]
    /// What GetZoneGroupState answers.
    var zoneGroupState = ""
    /// The Music Playback setting of a room with surrounds: "0" ambient, "1" full; nil for a room without.
    var surroundMode: String?
    private var _volume = 20
    private var _muted = false
    var volume: Int { lock.withLock { _volume } }
    var muted: Bool { lock.withLock { _muted } }

    /// Its UDN; by default one of its own. Two fakes with the same one are the same renderer at two addresses.
    private let udn: String?

    init(kind: Kind, udn: String? = nil) async throws {
        self.kind = kind
        self.udn = udn
        server = HTTPServer { [weak self] request in self?.handle(request) ?? .status(503) }
        port = try await server.start()
    }

    func stop() { server.stop() }

    var location: URL { URL(string: "http://127.0.0.1:\(port)/description.xml")! }
    var calls: [Call] { lock.withLock { _calls } }
    var actions: [String] { calls.map(\.action) }
    var playlistURIs: [String] { lock.withLock { playlist.map(\.uri) } }
    var nextURI: String? { lock.withLock { avNext } }
    var currentURI: String? {
        lock.withLock {
            switch kind {
            case .openHome: playlist.first { $0.id == currentID }?.uri
            case .av: avCurrent
            }
        }
    }
    var transportState: String { lock.withLock { state } }
    var selectedSource: Int { lock.withLock { sourceIndex } }

    func setPosition(_ s: Int) { lock.withLock { seconds = s } }
    /// Stop pressed on the player itself: it stops where it is.
    func stopOnDevice() { lock.withLock { state = "Stopped" } }
    /// The next call of `action` fails with UPnP error `code`.
    func fail(_ action: String, code: Int, times: Int = 1) { lock.withLock { failures[action] = (code, times) } }
    /// `action` answers again.
    func succeed(_ action: String) { lock.withLock { failures[action] = nil } }

    /// The bytes fetched from `uri` once the fetch is complete (waits up to 10 s).
    func fetched(_ uri: String) async -> Data? {
        for _ in 0..<500 {
            if let data = lock.withLock({ _fetched[uri] }) { return data }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The song playing ends: the renderer moves to the next one, or stops.
    func advance() {
        let toFetch: String? = lock.withLock {
            seconds = 0
            switch kind {
            case .openHome:
                guard let index = playlist.firstIndex(where: { $0.id == currentID }), index + 1 < playlist.count else { state = "Stopped"; return nil }
                currentID = playlist[index + 1].id
                return playlist[index + 1].uri
            case .av(let setNext):
                if setNext, let next = avNext { avCurrent = next; avNext = nil; return next }
                state = "Stopped"
                return nil
            }
        }
        if let toFetch { fetch(toFetch) }
    }

    private func fetch(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            lock.withLock { _fetched[uri] = data }
        }
    }

    // MARK: HTTP

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/description.xml"): return xml(description)
        case ("GET", "/scpd/AVTransport.xml"):
            let setNext: Bool = if case .av(let s) = kind { s } else { true }
            return xml(scpd(["SetAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetPositionInfo", "GetTransportInfo"] + (setNext ? ["SetNextAVTransportURI"] : [])))
        case ("GET", let path) where path.hasPrefix("/scpd/"): return xml(scpd(["Placeholder"]))
        case ("POST", let path) where path.hasPrefix("/ctl/"):
            let service = String(path.dropFirst(5))
            let soapAction = (request.headers["soapaction"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let action = soapAction.components(separatedBy: "#").last ?? ""
            let arguments = SOAP.arguments(in: request.body, element: action) ?? [:]
            return control(service: service, type: soapAction.components(separatedBy: "#").first ?? "", action: action, arguments: arguments)
        default: return .status(404)
        }
    }

    private func xml(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/xml"), ("Content-Length", "\(text.utf8.count)")], body: .data(Data(text.utf8)))
    }

    private func control(service: String, type: String, action: String, arguments: [String: String]) -> HTTPResponse {
        var toFetch: String?
        let result: Result<[(String, String)], FakeFault> = lock.withLock {
            _calls.append(Call(service: service, action: action, arguments: arguments))
            if let failure = failures[action] {
                failures[action] = failure.times > 1 ? (failure.code, failure.times - 1) : nil
                return .failure(FakeFault(code: failure.code))
            }
            switch (service, action) {
            case ("ConnectionManager", "GetProtocolInfo"): return .success([("Source", ""), ("Sink", sink)])
            case ("ZoneGroupTopology", "GetZoneGroupState"): return .success([("ZoneGroupState", zoneGroupState)])
            case ("RenderingControl", "GetVolume"), ("GroupRenderingControl", "GetGroupVolume"): return .success([("CurrentVolume", String(_volume))])
            case ("RenderingControl", "SetVolume"), ("GroupRenderingControl", "SetGroupVolume"):
                _volume = Int(arguments["DesiredVolume"] ?? "") ?? _volume; return .success([])
            case ("RenderingControl", "GetMute"), ("GroupRenderingControl", "GetGroupMute"): return .success([("CurrentMute", _muted ? "1" : "0")])
            case ("RenderingControl", "SetMute"), ("GroupRenderingControl", "SetGroupMute"): _muted = arguments["DesiredMute"] == "1"; return .success([])
            case ("GroupRenderingControl", "SnapshotGroupVolume"): return .success([])
            case ("RenderingControl", "GetEQ"):
                guard arguments["EQType"] == "SurroundMode", let mode = surroundMode else { return .failure(FakeFault(code: 402)) }
                return .success([("CurrentValue", mode)])
            case ("Product", "SourceXml"):
                return .success([("Value", "<SourceList><Source><Name>Radio</Name><Type>Radio</Type><Visible>true</Visible></Source><Source><Name>Playlist</Name><Type>Playlist</Type><Visible>true</Visible></Source><Source><Name>Receiver</Name><Type>Receiver</Type><Visible>true</Visible></Source></SourceList>")])
            case ("Product", "SourceIndex"): return .success([("Value", String(sourceIndex))])
            case ("Product", "SetSourceIndex"): sourceIndex = Int(arguments["Value"] ?? "") ?? -1; return .success([])
            case ("Playlist", "DeleteAll"): playlist = []; currentID = 0; state = "Stopped"; return .success([])
            case ("Playlist", "Insert"):
                let after = Int(arguments["AfterId"] ?? "") ?? -1
                let id = nextID
                nextID += 1
                let at = after == 0 ? 0 : (playlist.firstIndex { $0.id == after }.map { $0 + 1 } ?? playlist.count)
                playlist.insert((id, arguments["Uri"] ?? ""), at: at)
                return .success([("NewId", String(id))])
            case ("Playlist", "DeleteId"):
                let id = Int(arguments["Value"] ?? "") ?? -1
                playlist.removeAll { $0.id == id }
                if currentID == id { currentID = 0; state = "Stopped" }
                return .success([])
            case ("Playlist", "SeekId"):
                currentID = Int(arguments["Value"] ?? "") ?? 0
                seconds = 0
                state = "Playing"
                toFetch = playlist.first { $0.id == currentID }?.uri
                return .success([])
            case ("Playlist", "Play"), ("AVTransport", "Play"):
                if _ignoresPlay { return .success([]) }
                if state == "Stopped", service == "AVTransport" { toFetch = avCurrent }
                state = "Playing"; return .success([])
            case ("Playlist", "Pause"), ("AVTransport", "Pause"): state = "Paused"; return .success([])
            case ("Playlist", "Stop"), ("AVTransport", "Stop"): state = "Stopped"; return .success([])
            case ("Playlist", "SeekSecondAbsolute"): seconds = Int(arguments["Value"] ?? "") ?? 0; return .success([])
            case ("Playlist", "Id"): return .success([("Value", String(currentID))])
            case ("Playlist", "TransportState"): return .success([("Value", state)])
            case ("Time", "Time"): return .success([("TrackCount", "1"), ("Duration", "200"), ("Seconds", String(seconds))])
            case ("AVTransport", "SetAVTransportURI"):
                avCurrent = arguments["CurrentURI"]; state = "Stopped"; seconds = 0; return .success([])
            case ("AVTransport", "SetNextAVTransportURI"):
                avNext = (arguments["NextURI"] ?? "").isEmpty ? nil : arguments["NextURI"]; return .success([])
            case ("AVTransport", "Seek"): seconds = Int(DIDLLite.seconds(arguments["Target"]) ?? 0); return .success([])
            case ("AVTransport", "GetTransportInfo"):
                let av = switch state { case "Playing": "PLAYING"; case "Paused": "PAUSED_PLAYBACK"; default: avCurrent == nil ? "NO_MEDIA_PRESENT" : "STOPPED" }
                return .success([("CurrentTransportState", av), ("CurrentTransportStatus", "OK"), ("CurrentSpeed", "1")])
            case ("AVTransport", "GetPositionInfo"):
                return .success([("Track", "1"), ("TrackDuration", "0:03:20"), ("TrackURI", avCurrent ?? ""),
                                 ("RelTime", DIDLLite.time(Double(seconds)).components(separatedBy: ".")[0])])
            default: return .failure(FakeFault(code: 401))
            }
        }
        if let toFetch { fetch(toFetch) }
        switch result {
        case .success(let args):
            let body = SOAP.response(serviceType: type, action: action, arguments: args)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("Content-Length", "\(body.count)")], body: .data(body))
        case .failure(let fault):
            let code = fault.code
            let body = SOAP.fault(code: code, description: code == 401 ? "Invalid Action" : "Fake failure")
            return HTTPResponse(status: 500, headers: [("Content-Type", "text/xml"), ("Content-Length", "\(body.count)")], body: .data(body))
        }
    }

    private func scpd(_ actions: [String]) -> String {
        "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><actionList>"
            + actions.map { "<action><name>\($0)</name></action>" }.joined() + "</actionList></scpd>"
    }

    private var description: String {
        func service(_ type: String, _ name: String) -> String {
            "<service><serviceType>\(type)</serviceType><serviceId>urn:x:serviceId:\(name)</serviceId><SCPDURL>/scpd/\(name).xml</SCPDURL>"
                + "<controlURL>/ctl/\(name)</controlURL><eventSubURL>/evt/\(name)</eventSubURL></service>"
        }
        var services = service("urn:schemas-upnp-org:service:AVTransport:1", "AVTransport")
            + service("urn:schemas-upnp-org:service:ConnectionManager:1", "ConnectionManager")
            + service("urn:schemas-upnp-org:service:RenderingControl:1", "RenderingControl")
        if case .openHome = kind {
            services += service("urn:av-openhome-org:service:Product:1", "Product") + service("urn:av-openhome-org:service:Playlist:1", "Playlist")
                + service("urn:av-openhome-org:service:Time:1", "Time") + service("urn:av-openhome-org:service:Info:1", "Info")
        }
        if let room = sonosRoom {
            // As a Sonos speaker describes itself: the speaker, with its media server and its renderer inside it.
            let own = udn ?? "uuid:RINCON_FAKE\(port)01400_MR"
            let speaker = String(own.dropLast(3))
            services += service("urn:schemas-upnp-org:service:GroupRenderingControl:1", "GroupRenderingControl")
            return "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
                + "<deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>127.0.0.1 - \(sonosModel)</friendlyName>"
                + "<manufacturer>Sonos, Inc.</manufacturer><modelNumber>S9</modelNumber><modelName>\(sonosModel)</modelName>"
                + "<roomName>\(room)</roomName><displayName>Playbar</displayName>"
                + sonosSoftware.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined() + "<UDN>\(speaker)</UDN>"
                + "<serviceList>\(service("urn:schemas-upnp-org:service:ZoneGroupTopology:1", "ZoneGroupTopology"))</serviceList><deviceList>"
                + "<device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>127.0.0.1 - \(sonosModel) Media Server</friendlyName>"
                + "<manufacturer>Sonos, Inc.</manufacturer><modelName>\(sonosModel)</modelName><UDN>\(speaker)_MS</UDN>"
                + "<serviceList>\(service("urn:schemas-upnp-org:service:ContentDirectory:1", "ContentDirectory"))</serviceList></device>"
                + "<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>\(room) - \(sonosModel) Media Renderer</friendlyName>"
                + "<manufacturer>Sonos, Inc.</manufacturer><modelName>\(sonosModel)</modelName><UDN>\(own)</UDN>"
                + "<serviceList>\(services)</serviceList></device></deviceList></device></root>"
        }
        return "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Fake Renderer</friendlyName>"
            + "<manufacturer>Tests</manufacturer><modelName>Fake</modelName><modelNumber>1</modelNumber><UDN>\(udn ?? "uuid:fake-\(port)")</UDN>"
            + "<serviceList>\(services)</serviceList></device></root>"
    }
}

struct FakeFault: Error { var code: Int }
