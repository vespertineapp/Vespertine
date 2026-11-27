//
// Vespertine: adding an SMB share to play from, and changing one: its address, the account and the password.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineShare

/// A share in the list of Macs: where it is, in a line.
struct ShareRow: View {
    let share: SavedShare
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Palette.brass).rowIconColumn()
            VStack(alignment: .leading, spacing: 2) {
                Text(share.name).font(.serif(.body, weight: .medium)).foregroundStyle(Palette.text)
                Text(verbatim: share.address.display).font(.caption).foregroundStyle(Palette.text2)
                    .lineLimit(RemoteLayout.rowDetailLines(accessibilityText: typeSize.isAccessibilitySize)).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The form for a new share, or for one already added (`editing`).
struct ShareEditView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: SavedShare?
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var name = ""
    @State private var checking = false
    @State private var error: String?
    /// The server's shares, once only a server was typed and it listed them.
    @State private var offered: [SMBShareInfo]?
    @FocusState private var typing: Bool

    init(editing: SavedShare? = nil) {
        self.editing = editing
        _address = State(initialValue: editing?.address.display ?? "")
        _user = State(initialValue: editing?.address.user ?? "")
        _password = State(initialValue: editing?.password ?? "")
        _name = State(initialValue: editing?.name ?? "")
    }

    private var typed: ShareAddress? { ShareAddress(typed: address, user: user.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { page in
            Form {
                // What went wrong is the first thing on the page: at the end it sat under the keyboard, and Add looked
                // as if it had done nothing.
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            .id("share-error")
                            .accessibilityIdentifier("share-error")
                    }
                }
                Section {
                    TextField(String("smb://server/share/folder"), text: $address)
                        .focused($typing)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel(Text("SMB Share"))
                        .accessibilityIdentifier("share-address")
                } header: {
                    Text("SMB Share")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The server’s name or address, the share, and the folder the music is in if that isn’t the whole share. For example: smb://nas.local/music/Albums. To play away from home, use the server’s Tailscale name or address.")
                        Text("Or type only the server, like smb://nas.local, to choose from its shares.", comment: "Shown on the iPhone or iPad under the address field of the form that adds a network (SMB) share. Typing just the server’s name and pressing Add lists the shared folders the server offers. Keep “smb://nas.local” as an example in Latin letters.")
                    }
                }
                if let offered {
                    Section {
                        ForEach(offered, id: \.name) { share in
                            Button {
                                guard let server = ShareAddress(server: address, user: user.trimmingCharacters(in: .whitespaces)) else { return }
                                address = server.choosing(share.name).display
                                self.offered = nil
                                Task { await confirm() }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: share.name)
                                    if !share.comment.isEmpty {
                                        Text(verbatim: share.comment).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("share-offered-\(share.name)")
                        }
                    } header: {
                        Text("Choose a Share", comment: "Shown on the iPhone or iPad above the list of shared folders a network (SMB) server offers, after only the server’s name was typed in the form that adds a share. Tapping one adds it.")
                    }
                    .id("share-offered")
                }
                Section {
                    TextField("Account", text: $user)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($typing)
                        .accessibilityLabel(Text("Account"))
                        .accessibilityIdentifier("share-account")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($typing)
                        .accessibilityLabel(Text("Password"))
                        .accessibilityIdentifier("share-password")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The password is kept in the Keychain on this device and is sent only to this server.")
                        Text("To sign in as a guest, leave the account and password empty.")
                    }
                }
                Section {
                    TextField("Name", text: $name, prompt: Text(verbatim: typed.map(SavedShare.suggestedName) ?? String(localized: "Name")))
                        .focused($typing)
                        .accessibilityLabel(Text("Name"))
                        .accessibilityIdentifier("share-name")
                } footer: {
                    Text("Vespertine reads the songs’ tags from the share and keeps a list of them on this device. The first time takes a while for a large library; after that only new and changed files are read.")
                }
                if let editing {
                    Section {
                        Button("Forget This Share", role: .destructive) {
                            model.forget(editing)
                            dismiss()
                        }
                    }
                }
            }
            .obsidianList()
            .navigationTitle(editing == nil ? Text("Add a Share") : Text(verbatim: editing?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .solidTopEdge()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button(editing == nil ? LocalizedStringKey("Add") : LocalizedStringKey("Save")) { Task { await confirm() } }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("share-confirm")
                    }
                }
            }
            .interactiveDismissDisabled(checking)
            .onChange(of: error) { _, trouble in
                guard let trouble else { return }
                // The keyboard goes away and the page goes to the top, where the trouble is said; VoiceOver reads it.
                typing = false
                withAnimation { page.scrollTo("share-error", anchor: .top) }
                AccessibilityNotification.Announcement(trouble).post()
            }
            }
        }
    }

    /// Signs in to the share once before keeping it, so a wrong address or password is said here.
    private func confirm() async {
        if typed == nil, let server = ShareAddress(server: address, user: user.trimmingCharacters(in: .whitespaces)) {
            // Only a server: sign in and list its shares to choose from.
            checking = true
            error = nil
            let listed = await server.shares(password: password)
            checking = false
            switch listed {
            case .success(let shares) where !shares.isEmpty:
                offered = shares
                typing = false
            case .success, .failure(.accessDenied), .failure(.status), .failure(.unsupported), .failure(.malformed):
                error = String(localized: "This server didn’t list its shares. Type the share’s name as well, like smb://server/share.", comment: "Shown on the iPhone or iPad at the top of the form that adds a network (SMB) share, when only a server was typed and the server would not say which shared folders it has (or has none this account can see). Keep “smb://server/share” as an example in Latin letters.")
            case .failure(let trouble):
                error = ShareWording.trouble(trouble)
            }
            return
        }
        offered = nil
        guard let typed else {
            error = String(localized: "Type the server and the share, like smb://server/share.", comment: "Shown on the iPhone under the Add a Share form when the address typed has no server or no share name in it. Keep “smb://server/share” as an example in Latin letters.")
            typing = false
            return
        }
        let shown = name.trimmingCharacters(in: .whitespaces)
        var share = editing ?? SavedShare(name: "", address: typed, password: "")
        share.name = shown.isEmpty ? SavedShare.suggestedName(for: typed) : shown
        share.address = typed
        share.password = password
        checking = true
        error = nil
        let trouble = await share.check()
        checking = false
        if let trouble {
            error = ShareWording.trouble(trouble)
            return
        }
        model.save(share)
        dismiss()
    }
}
