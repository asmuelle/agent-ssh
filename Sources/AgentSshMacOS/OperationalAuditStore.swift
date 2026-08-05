import Foundation

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
