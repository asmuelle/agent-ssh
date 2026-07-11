import Foundation

public enum SharedAppStorageConfiguration {
    public static let appGroupIdentifier = "group.com.agent-ssh.agent-ssh"
    public static let integrationsFileName = "platform-integrations.json"
    public static let backgroundOperationsFileName = "background-ssh-operations.json"
    public static let portForwardRuntimeFileName = "port-forward-runtime.json"
    public static let liveActivitySnapshotsFileName = "live-activity-snapshots.json"
    public static let watchStatusSnapshotFileName = "watch-status-snapshot.json"
    public static let cloudServerInventoryFileName = "cloud-server-inventory.json"
    public static let offlineCacheManifestFileName = "offline-sftp-cache-manifest.json"
    public static let cloudSyncSnapshotFileName = "cloud-sync-snapshot.json"
    public static let serverDoctorSummariesFileName = "server-doctor-summaries.json"
    public static let operationalAuditFileName = "operational-audit.json"
    public static let fleetHealthFileName = "fleet-health.json"
    public static let offlineCacheDirectoryName = "offline-sftp-cache"
    public static let shortcutDownloadsDirectoryName = "shortcut-downloads"
    public static let stagedUploadsDirectoryName = "staged-uploads"
}

// MARK: - Durable operational audit

public enum OperationalAuditActor: String, Codable, Sendable {
    case user
    case app
    case agent
    case automation
}

public enum OperationalAuditOutcome: String, Codable, Sendable {
    case observed
    case pending
    case approved
    case denied
    case succeeded
    case failed
    case unknown
}

public struct OperationalAuditRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var profileId: String?
    public var connectionId: String?
    public var actor: OperationalAuditActor
    public var action: String
    public var title: String
    public var detail: String
    public var command: String?
    public var outcome: OperationalAuditOutcome
    public var exitCode: Int?
    public var systemImage: String
    public var severity: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        profileId: String? = nil,
        connectionId: String? = nil,
        actor: OperationalAuditActor,
        action: String,
        title: String,
        detail: String,
        command: String? = nil,
        outcome: OperationalAuditOutcome,
        exitCode: Int? = nil,
        systemImage: String = "circle",
        severity: String = "info"
    ) {
        self.id = id
        self.date = date
        self.profileId = profileId
        self.connectionId = connectionId
        self.actor = actor
        self.action = action
        self.title = title
        self.detail = detail
        self.command = command
        self.outcome = outcome
        self.exitCode = exitCode
        self.systemImage = systemImage
        self.severity = severity
    }

    public func redacted() -> OperationalAuditRecord {
        var copy = self
        copy.title = ServerDoctorRedactor.redact(title, preset: .balanced).text
        copy.detail = ServerDoctorRedactor.redact(detail, preset: .balanced).text
        copy.command = command.map {
            ServerDoctorRedactor.redact($0, preset: .balanced).text
        }
        return copy
    }
}

private struct OperationalAuditLedger: Codable, Sendable {
    var schemaVersion = 1
    var events: [OperationalAuditRecord]
}

/// Atomic JSON-backed event ledger shared by the macOS and iOS app surfaces.
/// Invalid data fails closed to an empty history; new writes replace it with a
/// valid, redacted ledger rather than propagating corrupt or secret-bearing data.
public final class OperationalAuditStore: @unchecked Sendable {
    private let backing: SharedJSONFileStore<OperationalAuditLedger>
    private let maxEvents: Int
    private let lock = NSLock()

    public init(
        directoryURL: URL? = nil,
        maxEvents: Int = 2_000
    ) {
        self.backing = SharedJSONFileStore(
            fileName: SharedAppStorageConfiguration.operationalAuditFileName,
            directoryURL: directoryURL
        )
        self.maxEvents = max(1, maxEvents)
    }

    public func load() -> [OperationalAuditRecord] {
        lock.withLock {
            (try? backing.load())?.events ?? []
        }
    }

    @discardableResult
    public func append(_ event: OperationalAuditRecord) throws -> OperationalAuditRecord {
        try lock.withLock {
            let sanitized = event.redacted()
            var events = (try? backing.load())?.events ?? []
            events.insert(sanitized, at: 0)
            if events.count > maxEvents {
                events.removeLast(events.count - maxEvents)
            }
            try backing.save(OperationalAuditLedger(events: events))
            return sanitized
        }
    }

    public func clear() throws {
        try lock.withLock {
            try backing.save(OperationalAuditLedger(events: []))
        }
    }
}

public enum SharedJSONFileStoreError: LocalizedError, Equatable {
    case appGroupContainerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "App Group container is unavailable for \(identifier)."
        }
    }
}

public final class SharedJSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    private let appGroupIdentifier: String
    private let fileName: String
    private let fileManager: FileManager
    private let directoryOverride: URL?

    public init(
        appGroupIdentifier: String = SharedAppStorageConfiguration.appGroupIdentifier,
        fileName: String,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileName = fileName
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
    }

    public var fileURL: URL {
        get throws {
            try directoryURL().appendingPathComponent(fileName)
        }
    }

    public func load() throws -> Value? {
        let url = try fileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Value.self, from: data)
    }

    public func load(default defaultValue: @autoclosure () -> Value) throws -> Value {
        try load() ?? defaultValue()
    }

    public func save(_ value: Value) throws {
        let target = try fileURL
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try Self.encoder.encode(value)
        let temporaryURL = target
            .deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: temporaryURL, options: [.atomic])
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(
                    target,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func directoryURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride
        }
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedJSONFileStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        return url
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
