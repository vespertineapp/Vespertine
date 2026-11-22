//
// Vespertine: the signal path as plain text, for pasting into a bug report, a forum post or a message.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The inspector's rows as they read on screen (title, what it does, its value, and whether it changes the signal), under the
// app and macOS versions and the status badges, followed by what the steps leave out but a report needs: how many channels
// the device's stream has and which of them Vespertine fills, the speaker setup, the number of streams and the I/O buffer.
//

import AppKit
import Foundation
import SwiftUI
import VespertineAudio

enum SignalPathText {
    /// The text that "Copy Signal Path" puts on the pasteboard.
    static func make(header: [String], steps: [SignalPathView.Step], output: String?, note: String?) -> String {
        var lines = header.filter { !$0.isEmpty }
        lines.append("")
        lines.append(String(localized: "Signal Path"))
        for step in steps {
            var line = "- \(step.title)"
            if !step.value.isEmpty { line += ": \(step.value)" }
            if !step.detail.isEmpty { line += " (\(step.detail))" }
            switch step.tone {
            case .good: line += " [untouched]"
            case .changed: line += " [changes the signal]"
            case .plain: break
            }
            lines.append(line)
        }
        if let output, !output.isEmpty { lines.append(output) }
        if let note, !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the device's stream carries: "Output stream: 6 channels, Vespertine fills 1-2 (L R); speaker setup L R C LFE Ls Rs;
    /// 1 stream; 512-frame buffer".
    static func outputLine(streamChannels: Int, sent: [String], speakers: [String], streams: Int, bufferFrames: Int) -> String {
        var parts: [String] = []
        let filled = sent.isEmpty ? "" : (sent.count == 1 ? "1" : "1-\(sent.count)") + " (\(sent.joined(separator: " ")))"
        parts.append("Output stream: \(streamChannels) channel\(streamChannels == 1 ? "" : "s")" + (filled.isEmpty ? "" : ", Vespertine fills \(filled)"))
        parts.append(speakers.isEmpty ? "no speaker setup" : "speaker setup \(speakers.joined(separator: " "))")
        if streams > 1 { parts.append("\(streams) streams") }
        if bufferFrames > 0 { parts.append("\(bufferFrames)-frame buffer") }
        return parts.joined(separator: "; ")
    }

    /// "Vespertine 1.2.2 (412) · macOS 15.1 (24B83)".
    static var versions: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        let os = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        return "Vespertine \(short)" + (build.map { " (\($0))" } ?? "") + " · macOS \(os)"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The copy button beside the "Signal Path" heading: a small icon that turns into a check for a moment once copied.
struct CopySignalPathButton: View {
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            SignalPathText.copy(text())
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(copied ? Palette.brassHi : Palette.text3)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Copies the signal path as text, for a bug report or a forum post"))
        .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy Signal Path"))
    }
}
