import AgentSshMacOS
import Foundation

/// Feeds the persistent attention inbox from the app's live finding
/// producers. One instance owns all writing so slices stay consistent:
///
/// - metric / advisory issues arrive through `AgentTriageStore.ingest`
///   (both the hidden pollers and the dashboard funnel through it),
/// - connection state arrives through `AgentTriageStore.syncTabs`,
/// - Server Doctor and Security Patch verdicts are reconciled from their
///   persisted summary stores — on a throttle from tab syncs (which also
///   covers app launch) and immediately when a scan writes a new summary.
///
/// The inbox is profile-keyed while the triage pipeline is tab-keyed, so
/// this class also owns the tab → profile mapping, refreshed on every tab
/// sync. Writes are skipped when a slice is unchanged and was written
/// recently — metrics poll every 3 s and the inbox is a persisted file,
/// not a hot path.
///
/// Freshness: while any host is polling, every slice (including the
/// event-driven connection and scan slices, re-driven from the poll path)
/// is rewritten at least once per `unchangedRewriteInterval`, keeping
/// `lastObserved` within the fleet-health 5 min staleness contract. With
/// no connected host nothing polls, nothing rewrites, and items going
/// stale is the honest signal that nothing is checking.
@MainActor
final class AttentionInboxIngest {
    static let shared = AttentionInboxIngest()

    /// How long an unchanged slice may go without a refreshing write.
    private static let unchangedRewriteInterval: TimeInterval = 60
    /// Scan summaries change rarely; tab-sync-driven reconciles are
    /// throttled, and scan completions bypass the throttle.
    private static let scanSyncInterval: TimeInterval = 60

    private let inbox: AttentionInboxStore
    private let doctorSummaries: ServerDoctorSummaryStore
    private let patchSummaries: @MainActor () -> [SecurityPatchHostSummary]

    private var tabProfiles: [UUID: (profileId: String, hostName: String)] = [:]
    private var sliceSignatures: [String: (signature: Int, writtenAt: Date)] = [:]
    private var lastScanSync: Date?
    /// Last tab list seen, so the poll path can re-drive the event-driven
    /// connection/scan slices between tab-status changes.
    private var lastTabs: [TerminalTab] = []
    private var lastEventSliceRefresh: Date?

    init(
        inbox: AttentionInboxStore = .shared,
        doctorSummaries: ServerDoctorSummaryStore = ServerDoctorSummaryStore(),
        patchSummaries: @escaping @MainActor () -> [SecurityPatchHostSummary] = {
            Array(SecurityPatchMonitorSummaryStore.shared.summaries.values)
        }
    ) {
        self.inbox = inbox
        self.doctorSummaries = doctorSummaries
        self.patchSummaries = patchSummaries
    }

    // MARK: Triage pipeline (metrics, advisories)

    /// Mirror one tab's current metric/advisory triage issues into the
    /// inbox. Receives the full post-clear set for the tab, so absence
    /// clears here exactly as it does in the triage store. Tabs whose
    /// profile is not known yet (first poll racing the first tab sync)
    /// are skipped — the next poll lands.
    func recordTriage(_ issues: [TriageIssue], tabId: UUID, now: Date = Date()) {
        // Connection and scan slices have no poller of their own — ride
        // this one so their unchanged rewrites (and failed-write retries)
        // happen while any host is being watched.
        refreshEventDrivenSlicesIfDue(now: now)

        guard let (profileId, hostName) = tabProfiles[tabId] else { return }

        for kind: TriageIssue.Kind in [.metric, .advisory] {
            let items = issues
                .filter { $0.kind == kind }
                .compactMap { attentionItem(from: $0, profileId: profileId, hostName: hostName) }
            ingestIfChanged(
                items,
                source: kind == .metric ? .metric : .advisory,
                profileId: profileId,
                now: now
            )
        }
    }

    // MARK: Tabs (connection state, profile mapping, launch sweep)

    /// Refresh the tab → profile mapping, mirror per-profile connection
    /// state, and opportunistically reconcile scan summaries (throttled —
    /// this also populates the inbox at launch, when the first tab sync
    /// happens before any scan runs).
    func syncTabs(_ tabs: [TerminalTab], now: Date = Date()) {
        tabProfiles = Dictionary(
            tabs.map { ($0.id, ($0.profile.id, $0.profile.name)) },
            uniquingKeysWith: { first, _ in first }
        )
        lastTabs = tabs
        syncConnections(tabs, now: now)
        syncScanSummariesIfDue(now: now)
    }

    private func refreshEventDrivenSlicesIfDue(now: Date) {
        if let lastEventSliceRefresh,
           now.timeIntervalSince(lastEventSliceRefresh) < Self.unchangedRewriteInterval
        {
            return
        }
        lastEventSliceRefresh = now
        syncConnections(lastTabs, now: now)
        syncScanSummariesIfDue(now: now)
    }

    /// One connection item per profile, judged across all of its tabs: an
    /// errored tab is act-now; a profile with no live tab but a dropped
    /// one is worth a look; a profile with any connected or connecting
    /// tab is reachable, so a single stale tab is not a host problem.
    private func syncConnections(_ tabs: [TerminalTab], now: Date) {
        var tabsByProfile: [String: [TerminalTab]] = [:]
        for tab in tabs {
            tabsByProfile[tab.profile.id, default: []].append(tab)
        }

        let previousProfiles = Set(
            inbox.allItems()
                .filter { $0.sourceKind == .connection }
                .map(\.profileId)
        )

        for profileId in previousProfiles.union(tabsByProfile.keys) {
            let items = connectionItems(
                for: tabsByProfile[profileId] ?? [],
                profileId: profileId,
                now: now
            )
            ingestIfChanged(items, source: .connection, profileId: profileId, now: now)
        }
    }

    private func connectionItems(
        for tabs: [TerminalTab],
        profileId: String,
        now: Date
    ) -> [AttentionItem] {
        guard let hostName = tabs.first?.profile.name else { return [] }

        let hasError = tabs.contains { $0.status == .error }
        let hasLive = tabs.contains { $0.status == .connected || $0.status == .connecting }
        let hasDropped = tabs.contains { $0.status == .disconnected }

        let state: (tier: AttentionTier, detail: String)?
        if hasError {
            state = (.actNow, "Connection error")
        } else if !hasLive, hasDropped {
            state = (.fixThisWeek, "Disconnected")
        } else {
            state = nil
        }
        guard let state else { return [] }

        return [AttentionItem(
            profileId: profileId,
            sourceKind: .connection,
            sourceId: "status",
            hostName: hostName,
            tier: state.tier,
            title: "Connection",
            detail: state.detail,
            firstSeen: now,
            lastObserved: now
        )]
    }

    // MARK: Scan summaries (Server Doctor, Security Patch Monitor)

    func syncScanSummariesIfDue(now: Date = Date()) {
        if let lastScanSync, now.timeIntervalSince(lastScanSync) < Self.scanSyncInterval {
            return
        }
        syncScanSummaries(now: now)
    }

    /// Reconcile both scan-summary stores into the inbox: profiles with a
    /// noteworthy summary get its item, profiles whose summary went away
    /// (or went quiet) get their slice cleared.
    func syncScanSummaries(now: Date = Date()) {
        lastScanSync = now

        reconcile(
            source: .serverDoctor,
            itemsByProfile: Dictionary(
                doctorSummaries.loadQuietly().map { ($0.profileId, $0.attentionItems(now: now)) },
                uniquingKeysWith: { first, _ in first }
            ),
            now: now
        )
        reconcile(
            source: .securityPatch,
            itemsByProfile: Dictionary(
                patchSummaries().compactMap { summary in
                    summary.profileId.map { ($0, summary.attentionItems(now: now)) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            now: now
        )
    }

    private func reconcile(
        source: AttentionSourceKind,
        itemsByProfile: [String: [AttentionItem]],
        now: Date
    ) {
        let previousProfiles = Set(
            inbox.allItems()
                .filter { $0.sourceKind == source }
                .map(\.profileId)
        )
        for profileId in previousProfiles.union(itemsByProfile.keys) {
            ingestIfChanged(
                itemsByProfile[profileId] ?? [],
                source: source,
                profileId: profileId,
                now: now
            )
        }
    }

    // MARK: Helpers

    private func attentionItem(
        from issue: TriageIssue,
        profileId: String,
        hostName: String
    ) -> AttentionItem? {
        // Triage ids are "<tabId>:<signal>"; the signal alone is the
        // stable per-cause id the profile-keyed inbox needs.
        let prefix = "\(issue.tabId.uuidString):"
        guard issue.id.hasPrefix(prefix) else { return nil }
        let signal = String(issue.id.dropFirst(prefix.count))

        return AttentionItem(
            profileId: profileId,
            sourceKind: issue.kind == .metric ? .metric : .advisory,
            sourceId: signal,
            hostName: hostName,
            tier: issue.severity == .critical ? .actNow : .fixThisWeek,
            title: issue.title,
            detail: issue.detail,
            firstSeen: issue.firstSeen,
            lastObserved: issue.firstSeen
        )
    }

    /// Write one slice, skipping the write when its content is unchanged
    /// and was written recently. The signature covers identity and tier
    /// only — not display text like `detail`, which embeds live samples
    /// ("97.1%") that would defeat the skip on every poll; text freshness
    /// rides the periodic unchanged rewrite instead. An empty slice over
    /// an empty slice never rewrites at all. A failed write does not
    /// record its signature, so the producer's next call retries.
    private func ingestIfChanged(
        _ items: [AttentionItem],
        source: AttentionSourceKind,
        profileId: String,
        now: Date
    ) {
        let sliceKey = "\(profileId)|\(source.rawValue)"
        var hasher = Hasher()
        for item in items.sorted(by: { $0.id < $1.id }) {
            hasher.combine(item.id)
            hasher.combine(item.tier)
        }
        let signature = hasher.finalize()

        if let last = sliceSignatures[sliceKey], last.signature == signature {
            if items.isEmpty { return }
            if now.timeIntervalSince(last.writtenAt) < Self.unchangedRewriteInterval {
                return
            }
        }

        do {
            try inbox.ingest(items, source: source, profileId: profileId, now: now)
            sliceSignatures[sliceKey] = (signature, now)
        } catch {
            // Leave the recorded signature stale so the next producer
            // call retries; the on-disk inbox is never the only copy of
            // a live signal.
            sliceSignatures.removeValue(forKey: sliceKey)
        }
    }
}
