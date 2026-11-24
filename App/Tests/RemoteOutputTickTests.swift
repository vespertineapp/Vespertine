import Foundation
import Testing
import VespertineRemoteProtocol
@testable import Vespertine

/// A phone's list of the Mac's outputs ticks the output the Mac plays to now. With the chosen DAC unplugged and a receiver
/// standing in for it, the phone ticked the DAC and said it was waiting for it, while Now Playing named the receiver
/// (TestFlight tf-1269c12fc7).
@Suite("Remote: the output that plays is the one ticked")
struct RemoteOutputTickTests {
    @Test("With the chosen output unplugged and another standing in, the one standing in is ticked")
    func standInIsTicked() {
        #expect(RemoteOutputRows.ticked(chosen: "fiio-ka15", standIn: "tx-nr717") == "tx-nr717")
        let row = RemoteOutputRows.missing(uid: "fiio-ka15", name: "FIIO KA15", group: false, network: false, standIn: "TX-NR717")
        #expect(!row.selected)
        #expect(!row.ready)
        #expect(row.uid == "fiio-ka15")
        #expect(row.detail.contains("TX-NR717"))
        #expect(!row.detail.contains("WAITING"))
    }

    @Test("With nothing standing in, the chosen output keeps the tick and waits for it")
    func waitingKeepsTheChoice() {
        #expect(RemoteOutputRows.ticked(chosen: "fiio-ka15", standIn: nil) == "fiio-ka15")
        let row = RemoteOutputRows.missing(uid: "fiio-ka15", name: "FIIO KA15", group: false, network: false, standIn: nil)
        #expect(row.selected)
        #expect(row.detail.contains("WAITING"))
        #expect(row.kind == .device)
        #expect(RemoteOutputRows.missing(uid: "bar", name: "Bar 118", group: true, network: false, standIn: nil).kind == .speakerGroup)
    }

    @Test("A network player that doesn't answer keeps the tick: nothing plays in its place")
    func networkKeepsTheChoice() {
        let row = RemoteOutputRows.missing(uid: "upnp:1", name: "Family Room", group: false, network: true, standIn: nil)
        #expect(row.selected)
        #expect(row.detail.contains("NOT RESPONDING"))
    }

    @Test("Following the Mac's sound output ticks System Default; a connected choice ticks itself")
    func ordinaryChoices() {
        #expect(RemoteOutputRows.ticked(chosen: nil, standIn: nil) == nil)
        #expect(RemoteOutputRows.ticked(chosen: "tx-nr717", standIn: nil) == "tx-nr717")
    }

    @Test("Only a missing device is stood in for, by the output that plays now or would play next")
    func whoStandsIn() {
        // The live output (what Now Playing names) stands in for an unplugged DAC.
        #expect(AppModel.standIn("TX-NR717", chosenMissing: true, networkChosen: false, groupChosen: false) == "TX-NR717")
        // A connected choice has nothing standing in for it, whatever played last.
        #expect(AppModel.standIn("TX-NR717", chosenMissing: false, networkChosen: false, groupChosen: false) == nil)
        // A network player or a speaker group that is missing has nothing in its place.
        #expect(AppModel.standIn("MacBook Pro Speakers", chosenMissing: true, networkChosen: true, groupChosen: false) == nil)
        #expect(AppModel.standIn("MacBook Pro Speakers", chosenMissing: true, networkChosen: false, groupChosen: true) == nil)
        // Waiting for it: nothing plays.
        #expect(AppModel.standIn(String?.none, chosenMissing: true, networkChosen: false, groupChosen: false) == nil)
    }
}
