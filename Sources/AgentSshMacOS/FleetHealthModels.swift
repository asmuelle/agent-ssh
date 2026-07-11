import Foundation

public enum FleetHostHealthState: String, Codable, CaseIterable, Sendable {
    case healthy
    case warning
    case critical
    case unknown
}

public enum FleetObservationFreshness: String, Codable, Sendable {
    case fresh
    case stale
}

public struct FleetHostHealthRecord: Codable, Identifiable, Equatable, Sendable {
    public var profileId: String
    public var hostName: String
    public var state: FleetHostHealthState
    public var summary: String
    public var observedAt: Date

    public var id: String { profileId }

    public init(
        profileId: String,
        hostName: String,
        state: FleetHostHealthState,
        summary: String,
        observedAt: Date = Date()
    ) {
        self.profileId = profileId
        self.hostName = hostName
        self.state = state
        self.summary = summary
        self.observedAt = observedAt
    }

    public func freshness(
        now: Date = Date(),
        staleAfter: TimeInterval = 5 * 60
    ) -> FleetObservationFreshness {
        now.timeIntervalSince(observedAt) > staleAfter ? .stale : .fresh
    }
}

private struct FleetHostHealthIndex: Codable, Sendable {
    var schemaVersion = 1
    var records: [FleetHostHealthRecord]
}

/// Latest known health for every saved profile. This intentionally stores one
/// bounded snapshot per host; the durable audit ledger owns the event history.
public final class FleetHostHealthStore: @unchecked Sendable {
    private let backing: SharedJSONFileStore<FleetHostHealthIndex>
    private let lock = NSLock()

    public init(directoryURL: URL? = nil) {
        backing = SharedJSONFileStore(
            fileName: SharedAppStorageConfiguration.fleetHealthFileName,
            directoryURL: directoryURL
        )
    }

    public func load() -> [String: FleetHostHealthRecord] {
        lock.withLock {
            let records = (try? backing.load())?.records ?? []
            return Dictionary(uniqueKeysWithValues: records.map { ($0.profileId, $0) })
        }
    }

    public func record(_ record: FleetHostHealthRecord) throws {
        try lock.withLock {
            var records = (try? backing.load())?.records ?? []
            records.removeAll { $0.profileId == record.profileId }
            records.append(record)
            try backing.save(FleetHostHealthIndex(records: records))
        }
    }

    public func prune(keepingProfileIds: [String]) throws {
        try lock.withLock {
            let kept = Set(keepingProfileIds)
            let records = ((try? backing.load())?.records ?? [])
                .filter { kept.contains($0.profileId) }
            try backing.save(FleetHostHealthIndex(records: records))
        }
    }
}
