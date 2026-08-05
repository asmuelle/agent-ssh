import SwiftUI
import UIKit

// =============================================================================
// SSH identity UI (iOS) — create, inspect, and manage the named keypairs that
// `MobileSSHKeyVault` stores as shared identities.
//
// The app already generated a keypair per connection, auto-named after the
// host and garbage-collected once unreferenced. An identity is the opposite:
// named by the user, listed here, and reused by any number of connections.
// The create flow reports the new identity back through `onCreated` so the
// connection editor can select it immediately.
// =============================================================================

private let identityAccent = Color.accentColor

// MARK: - List

struct MobileSSHIdentityListView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when an identity is created or picked for the calling connection.
    /// Nil when the list is opened purely to manage keys.
    var onSelect: ((MobileSSHIdentity) -> Void)?

    @State private var identities: [MobileSSHIdentity] = []
    @State private var creating = false
    @State private var pendingDelete: MobileSSHIdentity?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("One key, many connections")
                                .font(.subheadline.weight(.semibold))
                            Text("An identity is an SSH keypair created on this device. Install its public key on a server once, then point any connection at it — instead of importing a key per connection.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(identityAccent)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Your identities") {
                    if identities.isEmpty {
                        Text("No identities yet. Create one and this device generates an Ed25519 keypair; the private key stays in the encrypted vault.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(identities) { identity in
                        NavigationLink {
                            MobileSSHIdentityDetailView(identityId: identity.id, onChange: reload)
                        } label: {
                            MobileSSHIdentityRow(identity: identity)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = identity
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if let onSelect {
                                Button {
                                    onSelect(identity)
                                    dismiss()
                                } label: {
                                    Label("Use for this connection", systemImage: "checkmark.circle")
                                }
                            }
                            if let publicKey = identity.publicKey {
                                Button {
                                    UIPasteboard.general.string = publicKey
                                } label: {
                                    Label("Copy public key", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("SSH Identities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Label("Create Identity", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $creating) {
                // Stay put after creating: the create sheet is showing the
                // public key the user still has to install on the server.
                MobileCreateSSHIdentityView { identity in
                    reload()
                    onSelect?(identity)
                }
            }
            .alert(item: $pendingDelete) { identity in
                deleteAlert(for: identity)
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        identities = MobileSSHKeyVault.shared.listIdentities()
    }

    private func deleteAlert(for identity: MobileSSHIdentity) -> Alert {
        // Be explicit that this is a local delete, not revocation: the server
        // keeps trusting the public key until it leaves authorized_keys.
        Alert(
            title: Text("Delete \"\(identity.name)\"?"),
            message: Text("The private key is removed from this device's vault and can't be recovered. To revoke access, also delete its line from ~/.ssh/authorized_keys on the server. Connections using it will fail until you pick another key."),
            primaryButton: .destructive(Text("Delete")) {
                MobileSSHKeyVault.shared.deleteIdentity(id: identity.id)
                reload()
            },
            secondaryButton: .cancel()
        )
    }
}

// MARK: - Row

struct MobileSSHIdentityRow: View {
    let identity: MobileSSHIdentity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 15))
                .foregroundStyle(identityAccent)
                .frame(width: 30, height: 30)
                .background(identityAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name)
                    .font(.subheadline.weight(.semibold))
                Text(identity.fingerprint ?? "Fingerprint unavailable")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct MobileSSHIdentityDetailView: View {
    let identityId: String
    var onChange: () -> Void

    @State private var identity: MobileSSHIdentity?
    @State private var name = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            if let identity {
                Section("Name") {
                    TextField("Identity name", text: $name)
                        .onSubmit(commitRename)
                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                MobileSSHPublicKeySection(identity: identity)

                Section("Details") {
                    LabeledContent("Source", value: identity.source)
                    LabeledContent(
                        "Created",
                        value: identity.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } else {
                Text("This identity was deleted.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(identity?.name ?? "Identity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: commitRename)
    }

    private func load() {
        identity = MobileSSHKeyVault.shared.identity(id: identityId)
        name = identity?.name ?? ""
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity, trimmed != identity.name else { return }
        do {
            try MobileSSHKeyVault.shared.renameIdentity(id: identity.id, to: trimmed)
            errorText = nil
            load()
            onChange()
        } catch {
            errorText = error.localizedDescription
            name = identity.name
        }
    }
}

// MARK: - Public key

struct MobileSSHPublicKeySection: View {
    let identity: MobileSSHIdentity

    @State private var copied = false

    var body: some View {
        Section("Public key") {
            if let publicKey = identity.publicKey {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(publicKey)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = publicKey
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: publicKey) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Append this line to ~/.ssh/authorized_keys on the server, then point a connection at this identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This imported key had no matching .pub file next to it, so the public half isn't available here. Use the .pub from wherever the key was created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Create

struct MobileCreateSSHIdentityView: View {
    @Environment(\.dismiss) private var dismiss

    var onCreated: (MobileSSHIdentity) -> Void

    private enum Mode: String, CaseIterable {
        case generate
        case importKey

        var displayName: String {
            switch self {
            case .generate:  return "Generate"
            case .importKey: return "Import"
            }
        }
    }

    @State private var mode: Mode = .generate
    @State private var name = ""
    @State private var errorText: String?
    @State private var created: MobileSSHIdentity?
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(created.name)
                                    .font(.subheadline.weight(.semibold))
                                Text("Next: copy the public key below and add it to ~/.ssh/authorized_keys on the server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    MobileSSHPublicKeySection(identity: created)
                } else {
                    Section {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Name, e.g. iPad — production", text: $name)
                            .textInputAutocapitalization(.words)
                    }

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Text(mode == .generate
                             ? "A new Ed25519 keypair is generated on this device. The private key goes into the encrypted vault and never leaves; you install the public half on your servers."
                             : "The key is stored in this device's encrypted vault and shared by every connection you point at this identity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(created == nil ? "New Identity" : "Identity Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(mode == .generate ? "Generate" : "Choose File…", action: submit)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private func submit() {
        switch mode {
        case .generate:
            do {
                let identity = try MobileSSHKeyVault.shared.createIdentity(name: name)
                errorText = nil
                created = identity
                onCreated(identity)
            } catch {
                errorText = error.localizedDescription
            }
        case .importKey:
            showingImporter = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let identity = try MobileSSHKeyVault.shared.importIdentity(name: name, from: url)
            errorText = nil
            created = identity
            onCreated(identity)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
