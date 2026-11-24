//
// Vespertine Remote: Sources, the Macs, SMB shares and folders the library is made of, each with whether it is in the
// library and how it is doing (connected, reading its songs, can't be reached), and where new ones are added.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

/// What the Sources screen may change.
nonisolated enum SourceRules {
    /// A source can be turned on any time; turned off only while another one stays on: something has to be the library.
    static func canSwitch(_ id: String, on: Bool, inUse: [String]) -> Bool { on || inUse.contains { $0 != id } }
}

/// The line under a source's name on Sources: how it is doing, in a few words.
/// On the main actor, as the share status it reads is.
enum SourceLine {
    /// A Mac: connected or connecting while it is open; otherwise how it could be reached.
    static func mac(_ phase: RemoteSession.Phase?, onThisNetwork: Bool, address: RemoteAddress?) -> String {
        switch phase {
        case .connected?: return String(localized: "Connected")
        case .connecting?: return String(localized: "Connecting…")
        default: break
        }
        if onThisNetwork { return String(localized: "On this network") }
        if let address {
            return address.kind == .tailscale ? String(localized: "By Tailscale: \(address.host)") : String(localized: "By address: \(address.host)")
        }
        return String(localized: "Not on this network")
    }

    /// A share or a folder: its songs being read (with the count so far), why it can't be used, or how many songs it has.
    /// Not open (turned off), a share says where it is and a folder says nothing.
    static func library(_ status: ShareStatus?, closed: String?) -> String? {
        guard let status else { return closed }
        if case .scanning(let songs) = status.scan {
            return String(localized: "Reading tags") + " · " + String(localized: "\(songs) found", comment: "Files found so far while scanning")
        }
        if let trouble = status.trouble { return trouble }
        return String(localized: "\(status.songs) songs")
    }
}

/// The Sources tab (a page of the sidebar on an iPad).
struct SourcesView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pairing: DiscoveredMac?
    @State private var scanning = false
    @State private var connection: SavedPairing?
    @State private var addingShare = false
    @State private var sheet: SourceSheet?
    @State private var choosingFolder = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.pairings) { saved in
                        row(id: saved.serverID, name: saved.name, symbol: SavedPairing.symbol(portable: saved.portable),
                            line: SourceLine.mac(model.openMac(saved.serverID)?.phase, onThisNetwork: model.discovery.mac(serverID: saved.serverID) != nil,
                                                 address: saved.address),
                            info: Text("Connection for “\(saved.name)”")) { connection = saved }
                            .swipeActions { Button("Forget", role: .destructive) { model.forget(saved) } }
                    }
                    ForEach(model.shares) { share in
                        row(id: share.id, name: share.name, symbol: "externaldrive.connected.to.line.below",
                            line: SourceLine.library(model.statuses[share.id], closed: share.address.display),
                            info: Text("Settings for “\(share.name)”")) { sheet = .share(share) }
                            .swipeActions { Button("Forget", role: .destructive) { model.forget(share) } }
                    }
                    ForEach(model.shownFolders) { folder in
                        row(id: folder.id, name: folder.name, symbol: folder.isOwn ? "tray.full" : "folder",
                            line: SourceLine.library(model.statuses[folder.id], closed: nil),
                            info: Text("Settings for “\(folder.name)”")) { sheet = .folder(folder) }
                            .swipeActions {
                                // The app's own folder is emptied in Files, where its music can be seen.
                                if !folder.isOwn { Button("Forget", role: .destructive) { model.forget(folder) } }
                            }
                    }
                } footer: {
                    Text("Everything turned on here is in your Library. Turn one off to take its music out of the Library without forgetting it.")
                }
                Section("Add") {
                    ForEach(model.unpairedMacs) { mac in
                        Button { pairing = mac } label: { Label(mac.name, systemImage: SavedPairing.symbol(portable: mac.portable)) }
                    }
                    Button { scanning = true } label: { Label("Scan the Pairing Code", systemImage: "qrcode.viewfinder") }
                    Button { addingShare = true } label: { Label("Add an SMB Share", systemImage: "externaldrive.badge.plus") }
                        .accessibilityIdentifier("sources-add-share")
                    Button { choosingFolder = true } label: { Label("Add a Folder from Files", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("sources-add-folder")
                }
                if let error = model.pairingError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .obsidianList()
            .readablePane(maxWidth: 760)
            .accessibilityIdentifier("sources")
            .onChange(of: model.unpairedMacs.count, initial: true) { model.searchChanged() }
            .navigationTitle("Sources")
            .toolbar {
                // On an iPad's wide window the gear is in the window's own bar.
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel(Text("Settings"))
                    }
                }
            }
            .sheet(item: $pairing) { mac in CodeEntryView(mac: mac).withoutMiniPlayer() }
            .sheet(item: $connection) { saved in MacConnectionView(serverID: saved.serverID).withoutMiniPlayer() }
            .sheet(isPresented: $addingShare) { ShareEditView().withoutMiniPlayer() }
            .sheet(item: $sheet) { which in SourceSheetView(which: which).withoutMiniPlayer() }
            .sheet(isPresented: $showingSettings) { SettingsView().withoutMiniPlayer() }
            .sheet(isPresented: $scanning) {
                PairingScannerSheet { link in
                    scanning = false
                    model.pair(link: link)
                }
                .withoutMiniPlayer()
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.add(folderAt: url) }
            }
        }
    }

    /// A source: its name and how it is doing, its settings, and the switch that puts it in the library or takes it out.
    private func row(id: String, name: String, symbol: String, line: String?, info: Text, open: @escaping () -> Void) -> some View {
        let on = model.isInUse(id)
        return HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(on ? Palette.brass : Palette.text3).rowIconColumn()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.serif(.body, weight: .medium)).foregroundStyle(on ? Palette.text : Palette.text2)
                if let line, !line.isEmpty {
                    Text(verbatim: line).font(.caption).foregroundStyle(Palette.text2)
                        // Two lines: a reason it can't be used is a sentence.
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                }
            }
            Spacer(minLength: 8)
            Button(action: open) { Image(systemName: "info.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel(info)
            Toggle(isOn: Binding(get: { model.isInUse(id) }, set: { model.setInLibrary(id, $0) })) { Text(verbatim: name) }
                .labelsHidden()
                .tint(Palette.brass)
                .disabled(!SourceRules.canSwitch(id, on: !on, inUse: model.inUse))
                .accessibilityIdentifier("source-switch")
        }
        .accessibilityIdentifier("source-row")
    }
}

/// The page a share's or a folder's ⓘ opens.
enum SourceSheet: Identifiable {
    case share(SavedShare)
    case folder(SavedFolder)

    var id: String {
        switch self {
        case .share(let share): share.id
        case .folder(let folder): folder.id
        }
    }
}

struct SourceSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let which: SourceSheet
    @State private var editing: SavedShare?

    var body: some View {
        NavigationStack {
            List {
                switch which {
                case .share(let share):
                    ShareStatusSection(share: share)
                    Section {
                        Button("Connection") { editing = share }
                    }
                case .folder(let folder):
                    FolderStatusSection(folder: folder)
                }
            }
            .obsidianList()
            .navigationTitle(Text(verbatim: name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { ShareEditView(editing: $0) }
        }
    }

    private var name: String {
        switch which {
        case .share(let share): share.name
        case .folder(let folder): folder.name
        }
    }
}

struct ShareStatusSection: View {
    @Environment(RemoteAppModel.self) private var model
    let share: SavedShare

    /// The share the songs come from: where it is, whether it answers, what the last scan found, and scanning again.
    var body: some View {
        let status = model.statuses[share.id] ?? ShareStatus()
        Section {
            LabeledContent("SMB Share", value: share.address.display)
            LabeledContent("Connection") {
                HStack(spacing: 6) {
                    Circle().fill(status.reachable == false ? Palette.text3 : Palette.brass).frame(width: 7, height: 7)
                    Text(status.reachable == false ? String(localized: "Not connected") : ShareWording.network(share.address))
                }
            }
            LabeledContent("Songs", value: status.songs.formatted())
            if status.needTheMac > 0 {
                if status.needs.isEmpty {
                    LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                } else {
                    NavigationLink {
                        MacNeededView(needs: status.needs)
                    } label: {
                        LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                    }
                    .accessibilityIdentifier("share-mac-needed")
                }
            }
            if status.unreadable > 0 {
                LabeledContent("Files that couldn’t be read", value: status.unreadable.formatted())
            }
            if let scanned = status.scanned {
                LabeledContent("Last scanned", value: scanned.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                model.rescan(share.id)
            } label: {
                HStack {
                    Text("Scan Again")
                    Spacer()
                    if status.scan.isRunning { ProgressView() }
                }
            }
            .disabled(status.scan.isRunning)
            .accessibilityIdentifier("share-rescan")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let trouble = status.trouble { Text(trouble) }
                Text("A scan reads only new and changed files, and runs by itself once a day when the share is opened. This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; DTS, TrueHD and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
            }
        }
    }
}

struct FolderStatusSection: View {
    @Environment(RemoteAppModel.self) private var model
    let folder: SavedFolder

    /// The folder the songs come from: what the last look found, looking again, and choosing the folder again.
    var body: some View {
        let status = model.statuses[folder.id] ?? ShareStatus()
        Section {
            LabeledContent("Folder", value: folder.name)
            LabeledContent("Songs", value: status.songs.formatted())
            if status.needTheMac > 0 {
                if status.needs.isEmpty {
                    LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                } else {
                    NavigationLink {
                        MacNeededView(needs: status.needs)
                    } label: {
                        LabeledContent("Files that need the Mac", value: status.needTheMac.formatted())
                    }
                    .accessibilityIdentifier("folder-mac-needed")
                }
            }
            if status.unreadable > 0 {
                LabeledContent("Files that couldn’t be read", value: status.unreadable.formatted())
            }
            if let scanned = status.scanned {
                LabeledContent("Last scanned", value: scanned.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                model.rescan(folder.id)
            } label: {
                HStack {
                    Text("Scan Again")
                    Spacer()
                    if status.scan.isRunning { ProgressView() }
                }
            }
            .disabled(status.scan.isRunning)
            .accessibilityIdentifier("folder-rescan")
            if !folder.isOwn { ChooseFolderAgainButton(folder: folder) }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let trouble = status.trouble { Text(trouble) }
                if folder.isOwn {
                    Text("Music you open in Vespertine from another app is copied into Vespertine’s folder in the Files app and stays there until you delete it in Files. You can put music there yourself, too.")
                } else {
                    Text("Vespertine looks at the folder each time it is opened and reads only new and changed files. The music stays where it is; nothing is copied.")
                }
                Text("This device opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files itself; DTS, TrueHD and other formats need Vespertine on a Mac to convert them, so they aren’t listed here.")
            }
        }
    }
}
