import SwiftUI
import UniformTypeIdentifiers

struct MobileSecurityVaultView: View {
    let profiles: [MobileConnectionProfile]

    @EnvironmentObject private var keychainManager: MobileKeychainManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var advancedAuthStore = MobileAdvancedAuthenticationStore.shared

    @State private var exportDocument = MobileTextDocument()
    @State private var exporting = false
    @State private var secureEnclaveName = ""
    @State private var importingAdvancedIdentity: AdvancedIdentityImportMode?
    @State private var advancedAuthMessage: String?

    private enum AdvancedIdentityImportMode: Identifiable {
        case certificate
        case securityKey

        var id: String {
            switch self {
            case .certificate: return "certificate"
            case .securityKey: return "securityKey"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Vault") {
                    statusRow("Saved hosts", "\(profiles.count)", "server.rack")
                    statusRow("Public-key profiles", "\(profiles.filter { $0.authMethod == .publicKey }.count)", "key")
                    statusRow("Generated keys", "\(profiles.filter { $0.sshKeyReference?.isGenerated == true }.count)", "key.viewfinder")
                    statusRow("Vault unlocked", keychainManager.vaultUnlocked ? "Yes" : "No", "lock")
                }

                Section("Advanced Authentication") {
                    HStack {
                        TextField("Secure Enclave name", text: $secureEnclaveName)
                            .textInputAutocapitalization(.words)
                        Button {
                            generateSecureEnclaveIdentity()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(secureEnclaveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button {
                        importingAdvancedIdentity = .certificate
                    } label: {
                        Label("Import SSH Certificate", systemImage: "doc.badge.gearshape")
                    }

                    Button {
                        importingAdvancedIdentity = .securityKey
                    } label: {
                        Label("Import Security Key", systemImage: "key.radiowaves.forward")
                    }

                    if let advancedAuthMessage {
                        Text(advancedAuthMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !advancedAuthStore.identities.isEmpty {
                    Section("Advanced Identities") {
                        ForEach(advancedAuthStore.identities) { identity in
                            advancedIdentityRow(identity)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                advancedAuthStore.delete(advancedAuthStore.identities[index])
                            }
                        }
                    }
                }

                Section("Key References") {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(profile.sshKeyReference?.displayName ?? "No SSH key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let fingerprint = MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)?.fingerprint {
                                Text(fingerprint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section("Export") {
                    Button {
                        exportVaultSummary()
                    } label: {
                        Label("Export Redacted Vault Summary", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Security Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "agent-ssh-vault-summary.json"
            ) { _ in }
            .fileImporter(
                isPresented: Binding(
                    get: { importingAdvancedIdentity != nil },
                    set: { if !$0 { importingAdvancedIdentity = nil } }
                ),
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleAdvancedIdentityImport(result)
            }
        }
    }

    private func statusRow(_ title: String, _ value: String, _ systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func advancedIdentityRow(_ identity: AdvancedAuthIdentityRecord) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(identity.publicKeyFingerprint ?? identity.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: advancedIdentityIcon(identity.kind))
            }

            Spacer()

            if identity.kind == .secureEnclaveKey {
                Button {
                    testSecureEnclaveSigning(identity)
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func generateSecureEnclaveIdentity() {
        do {
            let identity = try MobileSecureEnclaveSSHIdentityStore.shared.generateIdentity(label: secureEnclaveName)
            advancedAuthStore.upsert(identity)
            secureEnclaveName = ""
            advancedAuthMessage = "Generated \(identity.displayName)."
        } catch {
            advancedAuthMessage = error.localizedDescription
        }
    }

    private func handleAdvancedIdentityImport(_ result: Result<[URL], Error>) {
        guard let mode = importingAdvancedIdentity else { return }
        importingAdvancedIdentity = nil

        do {
            guard let url = try result.get().first else { return }
            let identity: AdvancedAuthIdentityRecord
            switch mode {
            case .certificate:
                identity = try MobileSecureEnclaveSSHIdentityStore.shared.importSSHCertificate(from: url)
            case .securityKey:
                identity = try MobileSecureEnclaveSSHIdentityStore.shared.importSecurityKeyPublicKey(from: url)
            }
            advancedAuthStore.upsert(identity)
            advancedAuthMessage = "Imported \(identity.displayName)."
        } catch {
            advancedAuthMessage = error.localizedDescription
        }
    }

    private func testSecureEnclaveSigning(_ identity: AdvancedAuthIdentityRecord) {
        do {
            let signature = try MobileSecureEnclaveSSHIdentityStore.shared.signProbe(identity: identity)
            advancedAuthMessage = "Signing approved. Signature \(String(signature.prefix(16)))..."
        } catch {
            advancedAuthMessage = error.localizedDescription
        }
    }

    private func advancedIdentityIcon(_ kind: AdvancedAuthIdentityKind) -> String {
        switch kind {
        case .secureEnclaveKey: return "lock.shield.fill"
        case .securityKey: return "key.radiowaves.forward.fill"
        case .sshCertificate: return "doc.badge.gearshape.fill"
        case .certificateAuthority: return "building.columns.fill"
        }
    }

    private func exportVaultSummary() {
        let rows = profiles.map { profile -> [String: String] in
            let metadata = MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)
            return [
                "idHash": MobileDiagnosticsRedactor.hash(profile.id),
                "hostHash": MobileDiagnosticsRedactor.hash(profile.host),
                "authMethod": profile.authMethod.rawValue,
                "kind": profile.kind.rawValue,
                "hasSSHKey": profile.sshKeyReference == nil ? "false" : "true",
                "keySource": metadata?.source ?? "none",
                "fingerprint": metadata?.fingerprint ?? "",
            ]
        }
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "note": "This export is redacted and does not contain private keys or passwords.",
            "advancedAuthIdentityCount": advancedAuthStore.identities.count,
            "connections": rows,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        exportDocument = MobileTextDocument(text: String(data: data, encoding: .utf8) ?? "{}")
        exporting = true
    }
}
