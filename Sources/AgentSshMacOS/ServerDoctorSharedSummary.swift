import Foundation

/// A compact, shareable result of the most recent Server Doctor diagnosis for a
/// host. Written by the app after a diagnosis and read by proactive surfaces
/// (sidebar badge, widgets, the Shortcuts extension, monitor notifications)
/// that must not — and cannot — re-run a live diagnosis themselves.
///
/// This carries no raw evidence and no redacted excerpts: only the headline the
/// user already saw in the report. It is safe to persist in the app group.
public struct ServerDoctorHostSummary: Codable, Equatable, Sendable, Identifiable {
    /// Stable connection-profile id (not an ephemeral session id), so the
    /// summary survives reconnects and can be matched to sidebar rows and
    /// Shortcuts server entities.
    public var profileId: String
    public var hostLabel: String
    /// One-line, plain-language summary. Either the model's narration or the
    /// heuristic report summary.
    public var headline: String
    public var overallSeverity: ServerDoctorSeverity
    public var topFindingTitle: String?
    public var findingCount: Int
    public var generatedAt: Date
    /// True when `headline` was produced by an on-device model rather than the
    /// deterministic heuristics. Lets surfaces label provenance honestly.
    public var narratedOnDevice: Bool

    public var id: String { profileId }

    public init(
        profileId: String,
        hostLabel: String,
        headline: String,
        overallSeverity: ServerDoctorSeverity,
        topFindingTitle: String? = nil,
        findingCount: Int,
        generatedAt: Date = Date(),
        narratedOnDevice: Bool
    ) {
        self.profileId = profileId
        self.hostLabel = hostLabel
        self.headline = headline
        self.overallSeverity = overallSeverity
        self.topFindingTitle = topFindingTitle
        self.findingCount = findingCount
        self.generatedAt = generatedAt
        self.narratedOnDevice = narratedOnDevice
    }
}

public struct ServerDoctorSummaryIndex: Codable, Equatable, Sendable {
    public var summaries: [ServerDoctorHostSummary]

    public init(summaries: [ServerDoctorHostSummary] = []) {
        self.summaries = summaries
    }
}

/// App-group-backed store of the latest per-host Server Doctor summaries.
public final class ServerDoctorSummaryStore: @unchecked Sendable {
    /// Drop summaries older than this so surfaces never present stale state as
    /// if it were current.
    public static let staleAfter: TimeInterval = 60 * 60 * 24 * 7

    private let backing: SharedJSONFileStore<ServerDoctorSummaryIndex>

    public init(
        appGroupIdentifier: String = SharedAppStorageConfiguration.appGroupIdentifier,
        fileName: String = SharedAppStorageConfiguration.serverDoctorSummariesFileName,
        directoryURL: URL? = nil
    ) {
        backing = SharedJSONFileStore(
            appGroupIdentifier: appGroupIdentifier,
            fileName: fileName,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> [ServerDoctorHostSummary] {
        try backing.load(default: ServerDoctorSummaryIndex()).summaries
    }

    /// Non-throwing convenience for surfaces where a read failure should simply
    /// mean "no summary yet" rather than an error.
    public func loadQuietly() -> [ServerDoctorHostSummary] {
        (try? load()) ?? []
    }

    public func summary(profileId: String, now: Date = Date()) -> ServerDoctorHostSummary? {
        loadQuietly().first {
            $0.profileId == profileId
                && now.timeIntervalSince($0.generatedAt) < Self.staleAfter
        }
    }

    public func upsert(_ summary: ServerDoctorHostSummary) throws {
        var index = try backing.load(default: ServerDoctorSummaryIndex())
        index.summaries.removeAll { $0.profileId == summary.profileId }
        index.summaries.append(summary)
        index.summaries.sort { $0.generatedAt > $1.generatedAt }
        try backing.save(index)
    }

    public func remove(profileId: String) throws {
        var index = try backing.load(default: ServerDoctorSummaryIndex())
        index.summaries.removeAll { $0.profileId == profileId }
        try backing.save(index)
    }
}
