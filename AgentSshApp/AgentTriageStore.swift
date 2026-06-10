import AgentSshMacOS
import Foundation
import SwiftUI

// MARK: - Triage issue model

/// One thing that needs the user's attention in the Agent view.
///
/// Aggregated from two sources:
/// - the dashboard health pipeline (CPU / memory / disk / UFW /
///   monitor errors) via hidden `SystemMonitorView` pollers, and
/// - tab connection status straight from `TerminalTabsStore`.
struct TriageIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Tab is disconnected or errored. Binary, not flappy —
        /// confirmed immediately.
        case connection
        /// CPU / memory / disk threshold crossings. Flappy — must
        /// persist before the Agent view is allowed to be loud.
        case metric
        /// UFW exposure, monitor errors, unsupported OS. Slow-moving;
        /// short confirmation to absorb transient command failures.
        case advisory
    }

    let id: String
    let tabId: UUID
    let hostName: String
    let title: String
    let detail: String
    let icon: String
    let severity: DashboardHealthIssue.Severity
    let kind: Kind
    /// When this issue first appeared. Survives re-ingestion so both
    /// hysteresis and the "since …" narrative work.
    let firstSeen: Date

    /// Confirmation delay before the issue may surface. Prevents a
    /// one-sample CPU spike from crying wolf — silence the user can
    /// trust requires loudness the user can trust.
    var confirmationDelay: TimeInterval {
        switch kind {
        case .connection: return 0
        case .metric: return 12
        case .advisory: return 5
        }
    }

    func isConfirmed(now: Date) -> Bool {
        now.timeIntervalSince(firstSeen) >= confirmationDelay
    }
}

// MARK: - Store

/// Aggregates raw health signals into confirmed, snooze-aware triage
/// issues for the Agent view and the workspace-strip badge.
///
/// Candidates are keyed by stable issue id (`<tabId>:<signal>`), so
/// `firstSeen` survives every poll and snoozes survive reconnects
/// (tab ids are stable across reconnects).
@MainActor
final class AgentTriageStore: ObservableObject {
    static let shared = AgentTriageStore()

    @Published private(set) var candidates: [String: TriageIssue] = [:]
    @Published private(set) var snoozedUntil: [String: Date] = [:]
    /// Confirmed, unsnoozed issue count — drives the strip badge.
    /// Refreshed on every ingest/sync, so it lags a confirmation
    /// boundary by at most one poll interval.
    @Published private(set) var confirmedCount = 0

    /// Use `shared` in app code. Non-private so tests can build
    /// isolated instances.
    init() {}

    // MARK: Ingestion

    /// Replace the metric/advisory candidates for one host with the
    /// latest monitor snapshot. Connection issues are excluded here —
    /// they come from `syncTabs`, which also covers tabs the monitor
    /// can no longer reach.
    func ingest(snapshot: DashboardHealthSnapshot, tabId: UUID, now: Date = Date()) {
        let fresh = snapshot.issues.filter { !$0.id.hasPrefix("status:") }

        var next = candidates
        // Issues absent from the latest snapshot clear immediately —
        // going quiet fast is part of being trustworthy.
        for (id, candidate) in candidates
            where candidate.tabId == tabId && candidate.kind != .connection
        {
            if !fresh.contains(where: { triageIssueId(tabId: tabId, signal: $0.id) == id }) {
                next.removeValue(forKey: id)
            }
        }

        for issue in fresh {
            let id = triageIssueId(tabId: tabId, signal: issue.id)
            // Dashboard titles arrive as "<host>: <category>"; the Agent
            // view shows the host separately, so keep just the category.
            let hostPrefix = "\(snapshot.hostName): "
            let title = issue.title.hasPrefix(hostPrefix)
                ? String(issue.title.dropFirst(hostPrefix.count))
                : issue.title
            next[id] = TriageIssue(
                id: id,
                tabId: tabId,
                hostName: snapshot.hostName,
                title: title,
                detail: issue.detail,
                icon: issue.icon,
                severity: issue.severity,
                kind: kind(forSignal: issue.id),
                firstSeen: next[id]?.firstSeen ?? now
            )
        }

        candidates = next
        recount(now: now)
    }

    /// Sync connection-status issues from the live tab list, and prune
    /// candidates belonging to closed tabs or to hosts whose monitor
    /// has gone away (a disconnected host's stale metrics would
    /// otherwise linger forever).
    func syncTabs(_ tabs: [TerminalTab], now: Date = Date()) {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        var next = candidates
        for (id, candidate) in candidates {
            guard let tab = tabsById[candidate.tabId] else {
                next.removeValue(forKey: id)
                continue
            }
            if candidate.kind != .connection, tab.status != .connected {
                next.removeValue(forKey: id)
            }
        }

        for tab in tabs {
            let id = triageIssueId(tabId: tab.id, signal: "status")
            switch tab.status {
            case .disconnected, .error:
                next[id] = TriageIssue(
                    id: id,
                    tabId: tab.id,
                    hostName: tab.profile.name,
                    title: "Connection",
                    detail: tab.status == .error ? "Connection error" : "Disconnected",
                    icon: tab.status == .error ? "exclamationmark.circle.fill" : "wifi.slash",
                    severity: tab.status == .error ? .critical : .warning,
                    kind: .connection,
                    firstSeen: next[id]?.firstSeen ?? now
                )
            case .connected, .connecting:
                // `.connecting` is transient (or a reconnect already in
                // flight) — neither needs the user.
                next.removeValue(forKey: id)
            }
        }

        candidates = next
        snoozedUntil = snoozedUntil.filter { id, _ in next[id] != nil }
        recount(now: now)
    }

    // MARK: Queries

    /// Confirmed, unsnoozed issues — critical first, oldest first
    /// within a severity, so the list doesn't reshuffle under the
    /// user's cursor.
    func confirmedIssues(now: Date) -> [TriageIssue] {
        candidates.values
            .filter { $0.isConfirmed(now: now) && !isSnoozed($0.id, now: now) }
            .sorted(by: Self.displayOrder)
    }

    func snoozedIssues(now: Date) -> [TriageIssue] {
        candidates.values
            .filter { $0.isConfirmed(now: now) && isSnoozed($0.id, now: now) }
            .sorted(by: Self.displayOrder)
    }

    func isSnoozed(_ id: String, now: Date) -> Bool {
        guard let until = snoozedUntil[id] else { return false }
        return until > now
    }

    // MARK: Snooze

    func snooze(_ id: String, for interval: TimeInterval, now: Date = Date()) {
        snoozedUntil[id] = now.addingTimeInterval(interval)
        recount(now: now)
    }

    func unsnooze(_ id: String) {
        snoozedUntil.removeValue(forKey: id)
        recount(now: Date())
    }

    // MARK: Helpers

    private func recount(now: Date) {
        confirmedCount = confirmedIssues(now: now).count
    }

    private func triageIssueId(tabId: UUID, signal: String) -> String {
        "\(tabId.uuidString):\(signal)"
    }

    private func kind(forSignal signal: String) -> TriageIssue.Kind {
        if signal == "cpu" || signal == "memory" || signal.hasPrefix("disk:") {
            return .metric
        }
        return .advisory
    }

    private static func displayOrder(_ lhs: TriageIssue, _ rhs: TriageIssue) -> Bool {
        if lhs.severity.rawValue != rhs.severity.rawValue {
            return lhs.severity.rawValue > rhs.severity.rawValue
        }
        if lhs.firstSeen != rhs.firstSeen {
            return lhs.firstSeen < rhs.firstSeen
        }
        return lhs.id < rhs.id
    }
}

// MARK: - Hidden pollers

/// Headless `SystemMonitorView` per connected SSH host, mounted in
/// the detail column's background so triage data (and the strip
/// badge) stay fresh whether or not the Agent view is open. Reuses
/// the exact polling pipeline the dashboard renders visibly, but via
/// `headless: true` so no chart/table UI is built — a zero-sized
/// `opacity(0)` monitor still pays full SwiftUI layout and Swift
/// Charts rendering on every poll, which made the whole app feel
/// sluggish once a few hosts were connected.
struct AgentTriagePollers: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    /// The dashboard mounts its own monitors (which also feed the
    /// triage store), so skip ours while it's open to avoid polling
    /// every host twice.
    let isSuspended: Bool

    var body: some View {
        if !isSuspended {
            ZStack {
                ForEach(tabsStore.connectedSSHTabs) { tab in
                    SystemMonitorView(
                        connectionId: tab.connectionId,
                        connectionLabel: tab.profile.name,
                        profileId: tab.profile.id,
                        sshPort: tab.profile.port,
                        profile: tab.profile,
                        connectionStatus: tab.status,
                        isActive: true,
                        dashboardMode: true,
                        dashboardIdentity: tab.id.uuidString,
                        onDashboardHealthChange: { snapshot in
                            AgentTriageStore.shared.ingest(snapshot: snapshot, tabId: tab.id)
                        },
                        headless: true
                    )
                    .id(tab.id)
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
