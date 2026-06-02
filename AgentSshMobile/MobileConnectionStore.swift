import Foundation

@MainActor
final class MobileConnectionStore: ObservableObject {
    @Published private(set) var connections: [MobileConnectionProfile] = []
    @Published var lastError: String?

    private let fileManager = FileManager.default

    private var storeURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("agent-ssh", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    func load() {
        let url = storeURL
        guard fileManager.fileExists(atPath: url.path) else {
            connections = []
            lastError = syncShortcutServers()
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let store = try decoder.decode(MobileConnectionStoreData.self, from: data)
            connections = store.connections
            lastError = syncShortcutServers()
        } catch {
            lastError = "Could not load saved connections: \(error.localizedDescription)"
        }
    }

    func upsert(_ profile: MobileConnectionProfile) {
        if let index = connections.firstIndex(where: { $0.id == profile.id }) {
            let previous = connections[index]
            if previous.keychainAccount != profile.keychainAccount {
                MobileKeychainManager.shared.deleteCredentials(for: previous)
            }
            connections[index] = profile
            if previous.sshKeyReference != profile.sshKeyReference {
                deleteUnusedKeyReference(previous.sshKeyReference)
            }
        } else {
            connections.append(profile)
        }
        save()
    }

    func delete(_ profile: MobileConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        MobileKeychainManager.shared.deleteCredentials(for: profile)
        deleteUnusedKeyReference(profile.sshKeyReference)
        save()
    }

    func markConnected(_ profile: MobileConnectionProfile) {
        var updated = profile
        updated.lastConnected = Date()
        upsert(updated)
    }

    func exportConnectionsCSV() -> String {
        ConnectionCSVCodec.encode(profiles: connections.map { $0.connectionProfile })
    }

    func previewCSVImport(url: URL) throws -> ConnectionCSVImportPlan {
        let csv = try String(contentsOf: url, encoding: .utf8)
        return try ConnectionCSVImportPlanner.plan(
            existing: connections.map { $0.connectionProfile },
            csv: csv
        )
    }

    func applyCSVImport(_ plan: ConnectionCSVImportPlan) {
        let existingById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        let imported = ConnectionCSVImportPlanner.apply(
            plan,
            to: connections.map { $0.connectionProfile }
        )
        connections = imported.map { shared in
            MobileConnectionProfile(sharedProfile: shared, preserving: existingById[shared.id])
        }
        save()
    }

    func makeCloudSyncSnapshot(
        terminalSettings: SyncedTerminalSettingsRecord? = nil,
        generatedAt: Date = Date()
    ) throws -> CloudSyncSnapshot {
        let integrations = try PlatformIntegrationStore().load()
        return CloudSyncSnapshot(
            generatedAt: generatedAt,
            profiles: connections.map {
                SyncedConnectionProfileRecord(profile: $0.connectionProfile, updatedAt: generatedAt)
            },
            snippets: integrations.snippets.filter(\.syncEnabled),
            terminalSettings: terminalSettings
        )
    }

    @discardableResult
    func publishCloudSync(
        terminalSettings: SyncedTerminalSettingsRecord? = nil,
        store: CloudSyncStore = CloudSyncStore()
    ) throws -> CloudSyncMergeReport {
        let local = try makeCloudSyncSnapshot(terminalSettings: terminalSettings)
        let existing = try store.loadLatest() ?? .empty
        let (merged, report) = CloudSyncMergeEngine.merge(local: existing, incoming: local)
        try store.save(merged)
        return report
    }

    @discardableResult
    func applyLatestCloudSync(
        store: CloudSyncStore = CloudSyncStore()
    ) throws -> (report: CloudSyncMergeReport, terminalSettings: SyncedTerminalSettingsRecord?) {
        guard let snapshot = try store.loadLatest() else {
            throw MobileConnectionStoreError.noSyncSnapshot
        }
        return try applyCloudSyncSnapshot(snapshot)
    }

    @discardableResult
    func applyCloudSyncSnapshot(
        _ snapshot: CloudSyncSnapshot
    ) throws -> (report: CloudSyncMergeReport, terminalSettings: SyncedTerminalSettingsRecord?) {
        var report = CloudSyncMergeReport()
        let existingById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        var byId = existingById

        for record in snapshot.profiles {
            let shared = record.connectionProfile(preserving: existingById[record.id]?.connectionProfile)
            let updated = MobileConnectionProfile(sharedProfile: shared, preserving: existingById[record.id])
            if let existing = byId[record.id] {
                if existing == updated {
                    report.skippedProfiles += 1
                } else {
                    byId[record.id] = updated
                    report.updatedProfiles += 1
                }
            } else {
                byId[record.id] = updated
                report.insertedProfiles += 1
            }
        }

        for tombstone in snapshot.tombstones where tombstone.collection == .profile {
            if let removed = byId.removeValue(forKey: tombstone.recordId) {
                MobileKeychainManager.shared.deleteCredentials(for: removed)
                deleteUnusedKeyReference(removed.sshKeyReference)
                report.deletedRecords += 1
            }
        }

        connections = byId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try mergeSyncedSnippets(snapshot.snippets, tombstones: snapshot.tombstones, report: &report)
        save()
        return (report, snapshot.terminalSettings)
    }

    private func save() {
        do {
            let url = storeURL
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(MobileConnectionStoreData(connections: connections))
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            lastError = syncShortcutServers()
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
        }
    }

    private func mergeSyncedSnippets(
        _ incoming: [SharedSnippetRecord],
        tombstones: [CloudSyncTombstoneRecord],
        report: inout CloudSyncMergeReport
    ) throws {
        let store = PlatformIntegrationStore()
        var data = try store.load()
        var byId = Dictionary(uniqueKeysWithValues: data.snippets.map { ($0.id, $0) })

        for snippet in incoming {
            if tombstones.contains(where: {
                $0.collection == .snippet && $0.recordId == snippet.id && $0.deletedAt >= snippet.updatedAt
            }) {
                report.skippedSnippets += 1
                continue
            }
            if let existing = byId[snippet.id] {
                if snippet.updatedAt > existing.updatedAt {
                    byId[snippet.id] = snippet
                    report.updatedSnippets += 1
                } else {
                    report.skippedSnippets += 1
                }
            } else {
                byId[snippet.id] = snippet
                report.insertedSnippets += 1
            }
        }

        for tombstone in tombstones where tombstone.collection == .snippet {
            if byId.removeValue(forKey: tombstone.recordId) != nil {
                report.deletedRecords += 1
            }
        }

        data.snippets = byId.values.sorted { $0.updatedAt > $1.updatedAt }
        try store.save(data)
    }

    private func syncShortcutServers() -> String? {
        do {
            let store = PlatformIntegrationStore()
            var data = try store.load()
            data.shortcutServers = connections.map { profile in
                ShortcutServerRecord(
                    id: profile.id,
                    name: profile.name,
                    host: profile.host,
                    port: profile.port,
                    username: profile.username,
                    kind: profile.kind.rawValue,
                    supportsTerminal: profile.kind.supportsTerminal,
                    folder: profile.folder,
                    tags: profile.tags,
                    lastConnected: profile.lastConnected,
                    updatedAt: Date()
                )
            }
            try store.save(data)
            return nil
        } catch {
            return "Could not update Shortcuts server index: \(error.localizedDescription)"
        }
    }

    private func deleteUnusedKeyReference(_ reference: MobileSSHKeyReference?) {
        guard let reference else { return }
        let stillUsed = connections.contains { $0.sshKeyReference == reference }
        if !stillUsed {
            MobileSSHKeyVault.shared.deleteKey(for: reference)
        }
    }
}

enum MobileConnectionStoreError: LocalizedError {
    case noSyncSnapshot

    var errorDescription: String? {
        switch self {
        case .noSyncSnapshot:
            return "No iCloud sync snapshot is available yet."
        }
    }
}

private extension MobileConnectionProfile {
    var connectionProfile: ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.connectionAuthMethod,
            kind: kind.connectionKind,
            folderPath: folder,
            sshKeyReference: sshKeyReference?.connectionKeyReference,
            createdAt: createdAt,
            lastConnected: lastConnected,
            favorite: favorite,
            tags: tags,
            color: color,
            notes: notes,
            networkOptions: networkOptions
        )
    }

    init(sharedProfile: ConnectionProfile, preserving existing: MobileConnectionProfile? = nil) {
        self.init(
            id: sharedProfile.id,
            name: sharedProfile.name,
            host: sharedProfile.host,
            port: sharedProfile.port,
            username: sharedProfile.username,
            authMethod: MobileAuthMethod(sharedProfile.authMethod),
            kind: MobileConnectionKind(sharedProfile.kind),
            sshKeyReference: existing?.sshKeyReference ?? MobileSSHKeyReference(sharedProfile.sshKeyReference),
            createdAt: existing?.createdAt ?? sharedProfile.createdAt,
            lastConnected: [existing?.lastConnected, sharedProfile.lastConnected].compactMap { $0 }.max(),
            favorite: sharedProfile.favorite,
            folder: sharedProfile.folderPath,
            tags: sharedProfile.tags,
            color: sharedProfile.color,
            notes: sharedProfile.notes,
            networkOptions: sharedProfile.networkOptions
        )
    }
}

private extension MobileAuthMethod {
    init(_ authMethod: AuthMethod) {
        switch authMethod {
        case .password: self = .password
        case .publicKey: self = .publicKey
        }
    }

    var connectionAuthMethod: AuthMethod {
        switch self {
        case .password: return .password
        case .publicKey: return .publicKey
        }
    }
}

private extension MobileConnectionKind {
    init(_ kind: ConnectionKind) {
        switch kind {
        case .ssh: self = .ssh
        case .sftp: self = .sftp
        }
    }

    var connectionKind: ConnectionKind {
        switch self {
        case .ssh: return .ssh
        case .sftp: return .sftp
        }
    }
}

private extension MobileSSHKeyReference {
    init?(_ reference: SSHKeyReference?) {
        guard let reference else { return nil }
        switch reference {
        case .plainPath(let path):
            self = .plainPath(path)
        case .importedVaultKey(let id):
            self = .vaultKey(id: id)
        case .generatedVaultKey(let id):
            self = .generatedVaultKey(id: id)
        case .advancedAuthIdentity(let id):
            self = .advancedAuthIdentity(id: id)
        case .securityScopedBookmark, .agent:
            return nil
        }
    }

    var connectionKeyReference: SSHKeyReference {
        switch self {
        case .plainPath(let path):
            return .plainPath(path)
        case .vaultKey(let id):
            return .importedVaultKey(id: id)
        case .generatedVaultKey(let id):
            return .generatedVaultKey(id: id)
        case .advancedAuthIdentity(let id):
            return .advancedAuthIdentity(id: id)
        }
    }
}
