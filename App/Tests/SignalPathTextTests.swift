//
// Vespertine: "Copy Signal Path" puts the path on the pasteboard as plain text that reads like the inspector.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Testing
@testable import Vespertine

@Suite("Copy Signal Path")
struct SignalPathTextTests {
    @Test("Each step is one line, in order, with its value, what it does and whether it changes the signal")
    func steps() {
        let text = SignalPathText.make(
            header: ["Vespertine 1.2.2 (100) · macOS 15.1", "CONVERTED · EXCLUSIVE · 16 / 48"],
            steps: [
                .init(title: "Source", detail: "FLAC · lossless · stereo", value: "16-bit · 44.1 kHz"),
                .init(title: "Sample rate converter", detail: "Apple mastering-quality SRC", value: "44.1 → 48 kHz", tone: .changed),
                .init(title: "Volume", detail: "DAC hardware control", value: "unity · 0.0 dB", tone: .good),
                .init(title: "Bose USB Audio", detail: "", value: "16-bit · 48 kHz"),
            ],
            output: SignalPathText.outputLine(streamChannels: 6, sent: ["L", "R"], speakers: [], streams: 1, bufferFrames: 512),
            note: "This device doesn't offer 44.1 kHz.")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == [
            "Vespertine 1.2.2 (100) · macOS 15.1",
            "CONVERTED · EXCLUSIVE · 16 / 48",
            "",
            String(localized: "Signal Path"),
            "- Source: 16-bit · 44.1 kHz (FLAC · lossless · stereo)",
            "- Sample rate converter: 44.1 → 48 kHz (Apple mastering-quality SRC) [changes the signal]",
            "- Volume: unity · 0.0 dB (DAC hardware control) [untouched]",
            "- Bose USB Audio: 16-bit · 48 kHz",
            "Output stream: 6 channels, Vespertine fills 1-2 (L R); no speaker setup; 512-frame buffer",
            "This device doesn't offer 44.1 kHz.",
            "",
        ])
    }

    @Test("The output line names the stream's channels, the ones Vespertine fills, the speaker setup and extra streams")
    func outputLine() {
        #expect(SignalPathText.outputLine(streamChannels: 2, sent: ["L", "R"], speakers: [], streams: 1, bufferFrames: 512)
            == "Output stream: 2 channels, Vespertine fills 1-2 (L R); no speaker setup; 512-frame buffer")
        #expect(SignalPathText.outputLine(streamChannels: 6, sent: ["L", "R"], speakers: ["L", "R", "C", "LFE", "Ls", "Rs"], streams: 1, bufferFrames: 0)
            == "Output stream: 6 channels, Vespertine fills 1-2 (L R); speaker setup L R C LFE Ls Rs")
        #expect(SignalPathText.outputLine(streamChannels: 1, sent: ["M"], speakers: [], streams: 2, bufferFrames: 256)
            == "Output stream: 1 channel, Vespertine fills 1 (M); no speaker setup; 2 streams; 256-frame buffer")
    }

    @Test("The versions line names the app and macOS")
    func versions() {
        #expect(SignalPathText.versions.hasPrefix("Vespertine "))
        #expect(SignalPathText.versions.contains(" · macOS "))
    }
}
