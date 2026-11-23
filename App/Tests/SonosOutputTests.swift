//
// Vespertine: a Sonos room in the output list: its second line, its notes, and the format the forecast takes from the library.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
import VespertineUPnP
@testable import Vespertine

@Suite("Sonos in the output list") @MainActor
struct SonosOutputTests {
    /// A Playbar room; `swGen` "2" is S2, "1" S1, nil a speaker that doesn't say.
    private func room(_ zone: SonosZone?, swGen: String? = "2") -> RendererDevice {
        let location = URL(string: "http://192.168.1.20:1400/xml/device_description.xml")!
        let description = DeviceDescription(udn: "uuid:RINCON_BAR01400_MR", friendlyName: "Living Room", manufacturer: "Sonos, Inc.", modelName: "Sonos Playbar",
                                            location: location, services: [], softwareGeneration: swGen)
        return RendererDevice(description: description, kind: .av(gapless: true), capabilities: .init(), sonos: zone)
    }

    @Test("The second line says what Sonos takes, and the room's speakers when it has more than one")
    func detail() {
        #expect(RendererText.detail(room(nil)) == "SONOS · UP TO 24/48 · STEREO")
        let theater = SonosZone(uuid: "RINCON_BAR01400", roomName: "Living Room", groupRooms: ["Living Room"], surrounds: 2, hasSub: true)
        #expect(RendererText.detail(room(theater)) == "SONOS · 5.1 · UP TO 24/48 · STEREO")
        #expect(room(theater).name == "Living Room")
    }

    @Test("An S1 room, and one that doesn't say which it runs, is said to take up to 16-bit, everywhere it is described")
    func s1() {
        for swGen in ["1", nil] {
            let s1 = room(nil, swGen: swGen)
            #expect(RendererText.detail(s1) == "SONOS · UP TO 16/48 · STEREO")
            #expect(RendererText.highestFormat(s1) == "16-bit / 48 kHz, 2 channels (Sonos's own limit)")
            #expect(RendererText.sonosNotes(s1).first?.hasPrefix("Sonos plays two-channel music up to 16-bit / 48 kHz") == true)
            #expect(RendererText.sonosNotes(s1).first?.contains("16-bit FLAC") == true)
        }
        let s2 = room(nil)
        #expect(RendererText.highestFormat(s2) == "24-bit / 48 kHz, 2 channels (Sonos's own limit)")
        #expect(RendererText.sonosNotes(s2).first?.contains("24-bit FLAC") == true)
    }

    @Test("A room with surrounds is told where the Sonos app decides how they play music; a plain room isn't")
    func notes() {
        let theater = SonosZone(uuid: "RINCON_BAR01400", roomName: "Living Room", groupRooms: ["Living Room"], surrounds: 2, hasSub: true)
        #expect(RendererText.sonosNotes(room(theater)).contains { $0.contains("Music Playback") })
        #expect(!RendererText.sonosNotes(room(nil)).contains { $0.contains("Music Playback") })
        #expect(RendererText.sonosNotes(room(nil)).contains { $0.contains("No surround and no Dolby Atmos") })
        let grouped = SonosZone(uuid: "RINCON_BAR01400", roomName: "Living Room", groupRooms: ["Living Room", "Kitchen"])
        #expect(room(grouped).name == "Living Room + Kitchen")
        #expect(RendererText.sonosNotes(room(grouped)).contains { $0.contains("whole group") })
    }

    @Test("The forecast reads a song's format from the library: DSD has no word length, a lossy file isn't PCM")
    func libraryFormat() {
        var track = Track.transient(location: "/nowhere/a.flac", title: "A", artist: "B", album: "C", duration: 60)
        track.codec = "FLAC"; track.isLossless = true; track.isDSD = false; track.sampleRate = 192_000; track.bitDepth = 24; track.channels = 2
        #expect(track.forecastFormat == SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 2))
        #expect(RouteForecast.renderer(source: track.forecastFormat, mime: "audio/flac", limits: .sonos).line == "24-bit / 48 kHz FLAC, stereo (source 24/192)")
        track.codec = "DSF"; track.isDSD = true; track.sampleRate = 2_822_400; track.bitDepth = 1
        #expect(track.forecastFormat.encoding == .dsd)
        #expect(track.forecastFormat.bitDepth == nil)
        track.codec = "MP3"; track.isDSD = false; track.isLossless = false; track.sampleRate = 44_100; track.bitDepth = nil
        #expect(track.forecastFormat.encoding == .lossy)
    }
}
