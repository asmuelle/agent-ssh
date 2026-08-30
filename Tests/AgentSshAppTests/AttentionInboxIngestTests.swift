@testable import AgentSshApp
import AgentSshMacOS
import Foundation
import Testing

/// Covers the adapter layer feeding the persistent attention inbox:
/// connection state judged per profile, metric/advisory mirroring from
/// the triage pipeline, and reconciliation of the Server Doctor /
/// Security Patch summary stores including clear-on-absence.
@MainActor
struct AttentionInboxIngestTests {
    private final class PatchSummariesBox {
        var summaries: [SecurityPatchHostSummary] = []
    }

    private final class EscalationBox {
        var delivered: [AttentionEscalationAlert] = []
    }

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private let directory: URL
    private let inbox: AttentionInboxStore
    private let doctorStore: ServerDoctorSummaryStore
    private let patchBox = PatchSummariesBox()
    private let escalationBox = EscalationBox()
    private let ingest: AttentionInboxIngest

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-ingest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = AttentionInboxStore(directoryURL: directory)
        doctorStore = ServerDoctorSummaryStore(directoryURL: directory)
        let box = patchBox
        let escalations = escalationBox
        ingest = AttentionInboxIngest(
            inbox: inbox,
            doctorSummaries: doctorStore,
            patchSummaries: { box.summaries },
            deliverEscalations: { escalations.delivered.append(contentsOf: $0) }
        )
    }

    private func makeTab(
        id: UUID = UUID(),
        profileId: String = "profile-1",
        name: String = "web-01",
        status: TerminalConnectionStatus = .connected
    ) -> TerminalTab {
        TerminalTab(
            id: id,
            profile: ConnectionProfile(id: profileId, name: name, host: "example.com", username: "root"),
            sessionId: "abc12345",
            connectionId: "root@example.com:22#abc12345",
            ptyGeneration: 0,
            title: name,
            order: 0,
            themeOverride: nil,
            status: status
        )
    }

    // MARK: Connection state

    @Test("A dropped profile surfaces, an errored one escalates, a reconnect clears")
    func connectionLifecycle() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId, status: .disconnected)], now: t0)
        var items = inbox.allItems()
        #expect(items.map(\.id) == ["profile-1:connection:status"])
        #expect(items.first?.tier == .fixThisWeek)

        ingest.syncTabs([makeTab(id: tabId, status: .error)], now: t0.addingTimeInterval(10))
        items = inbox.allItems()
        #expect(items.first?.tier == .actNow)
        #expect(items.first?.detail == "Connection error")

        ingest.syncTabs([makeTab(id: tabId, status: .connected)], now: t0.addingTimeInterval(20))
        #expect(inbox.allItems().isEmpty)
    }

    @Test("A profile with one live tab is reachable — a second dropped tab is not a host problem")
    func mixedTabsSameProfileStayQuiet() {
        ingest.syncTabs(
            [makeTab(status: .connected), makeTab(status: .disconnected)],
            now: t0
        )
        #expect(inbox.allItems().isEmpty)
    }

    @Test("A closed tab's profile clears its connection item")
    func closedTabClearsConnectionItem() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId, status: .disconnected)], now: t0)
        #expect(inbox.allItems().count == 1)

        ingest.syncTabs([], now: t0.addingTimeInterval(10))
        #expect(inbox.allItems().isEmpty)
    }

    // MARK: Triage pipeline

    private func triageIssue(
        tabId: UUID,
        signal: String = "cpu",
        severity: DashboardHealthIssue.Severity = .critical,
        kind: TriageIssue.Kind = .metric
    ) -> TriageIssue {
        TriageIssue(
            id: "\(tabId.uuidString):\(signal)",
            tabId: tabId,
            hostName: "web-01",
            title: "CPU",
            detail: "97.0%",
            icon: "cpu",
            severity: severity,
            kind: kind,
            firstSeen: t0
        )
    }

    @Test("Metric and advisory issues mirror into profile-keyed slices and clear on absence")
    func triageIssuesMirrorAndClear() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)

        ingest.recordTriage(
            [
                triageIssue(tabId: tabId, signal: "cpu", severity: .critical, kind: .metric),
                triageIssue(tabId: tabId, signal: "ufw-inactive", severity: .warning, kind: .advisory),
            ],
            tabId: tabId,
            now: t0
        )

        let ids = inbox.allItems().map(\.id).sorted()
        #expect(ids == ["profile-1:advisory:ufw-inactive", "profile-1:metric:cpu"])
        let cpu = inbox.allItems().first { $0.sourceId == "cpu" }
        #expect(cpu?.tier == .actNow)
        let ufw = inbox.allItems().first { $0.sourceId == "ufw-inactive" }
        #expect(ufw?.tier == .fixThisWeek)

        ingest.recordTriage([], tabId: tabId, now: t0.addingTimeInterval(10))
        #expect(inbox.allItems().isEmpty)
    }

    @Test("Issues for a tab with no known profile are skipped, not misfiled")
    func unknownTabSkipped() {
        let tabId = UUID()
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        #expect(inbox.allItems().isEmpty)
    }

    // MARK: Scan summaries

    @Test("A doctor verdict appears in the inbox and clears when the summary goes away")
    func doctorSummaryReconciles() throws {
        try doctorStore.upsert(ServerDoctorHostSummary(
            profileId: "profile-1",
            hostLabel: "web-01",
            headline: "Disk almost full on /var.",
            overallSeverity: .warning,
            topFindingTitle: "Disk almost full",
            findingCount: 1,
            generatedAt: t0,
            narratedOnDevice: false
        ))
        ingest.syncScanSummaries(now: t0)
        #expect(inbox.allItems().map(\.id) == ["profile-1:server-doctor:verdict:Disk almost full"])

        try doctorStore.remove(profileId: "profile-1")
        ingest.syncScanSummaries(now: t0.addingTimeInterval(120))
        #expect(inbox.allItems().isEmpty)
    }

    @Test("A patch scan appears in the inbox and clears when it goes secure")
    func patchSummaryReconciles() {
        patchBox.summaries = [SecurityPatchHostSummary(
            connectionId: "conn-1",
            profileId: "profile-1",
            hostLabel: "web-01",
            badge: .critical,
            severity: .critical,
            summary: "Actively exploited CVE in installed packages.",
            scannedAt: t0
        )]
        ingest.syncScanSummaries(now: t0)
        let items = inbox.allItems()
        #expect(items.map(\.id) == ["profile-1:security-patch:patches:critical"])
        #expect(items.first?.tier == .actNow)

        patchBox.summaries = [SecurityPatchHostSummary(
            connectionId: "conn-1",
            profileId: "profile-1",
            hostLabel: "web-01",
            badge: .secure,
            severity: .info,
            summary: "Everything up to date.",
            scannedAt: t0.addingTimeInterval(120)
        )]
        ingest.syncScanSummaries(now: t0.addingTimeInterval(120))
        #expect(inbox.allItems().isEmpty)
    }

    // MARK: Write economy and failure retry

    @Test("Unchanged slices skip the write inside the window and refresh after it")
    func writeSkipWindow() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)

        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        #expect(inbox.allItems().first?.lastObserved == t0)

        // Same identity and tier 10 s later: skipped, lastObserved holds.
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0.addingTimeInterval(10))
        #expect(inbox.allItems().first?.lastObserved == t0)

        // Past the window: the unchanged rewrite refreshes lastObserved.
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0.addingTimeInterval(70))
        #expect(inbox.allItems().first?.lastObserved == t0.addingTimeInterval(70))
    }

    @Test("A failed write is not remembered as written — the next identical call retries")
    func failedWriteRetries() throws {
        let blockedDir = directory.appendingPathComponent("blocked-inbox")
        // A plain file where the store's directory should be makes every
        // save throw until the path is repaired.
        try Data().write(to: blockedDir)
        let blockedInbox = AttentionInboxStore(directoryURL: blockedDir)
        let blockedIngest = AttentionInboxIngest(
            inbox: blockedInbox,
            doctorSummaries: doctorStore,
            patchSummaries: { [] }
        )

        let tabId = UUID()
        blockedIngest.syncTabs([makeTab(id: tabId, status: .disconnected)], now: t0)
        #expect(blockedInbox.allItems().isEmpty)

        // Repair the path; the identical observation must retry, not be
        // skipped as already-written.
        try FileManager.default.removeItem(at: blockedDir)
        try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        blockedIngest.syncTabs([makeTab(id: tabId, status: .disconnected)], now: t0.addingTimeInterval(5))
        #expect(blockedInbox.allItems().map(\.id) == ["profile-1:connection:status"])
    }

    // MARK: End-to-end through the triage store

    @Test("AgentTriageStore feeds the inbox through both of its ingestion paths")
    func triageStoreIntegration() {
        let store = AgentTriageStore(inboxIngest: ingest)
        let tab = makeTab(status: .connected)
        store.syncTabs([tab], now: t0)

        store.ingest(
            snapshot: DashboardHealthSnapshot(
                id: tab.id.uuidString,
                hostName: tab.profile.name,
                issues: [DashboardHealthIssue(
                    id: "cpu",
                    title: "web-01: CPU",
                    detail: "97.0%",
                    icon: "cpu",
                    severity: .critical
                )]
            ),
            tabId: tab.id,
            now: t0
        )
        #expect(inbox.allItems().map(\.id) == ["profile-1:metric:cpu"])
        // The triage store strips the "<host>: " prefix before the hook.
        #expect(inbox.allItems().first?.title == "CPU")

        store.ingest(
            snapshot: DashboardHealthSnapshot(id: tab.id.uuidString, hostName: tab.profile.name, issues: []),
            tabId: tab.id,
            now: t0.addingTimeInterval(10)
        )
        #expect(inbox.allItems().isEmpty)

        store.syncTabs([makeTab(id: tab.id, status: .disconnected)], now: t0.addingTimeInterval(20))
        #expect(inbox.allItems().map(\.id) == ["profile-1:connection:status"])
    }

    // MARK: Published read side

    @Test("The published snapshot tracks writes, so the panel needs no file read")
    func snapshotRepublishedOnWrite() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)
        #expect(ingest.snapshot.items.isEmpty)

        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        #expect(ingest.snapshot.items.map(\.sourceId) == ["cpu"])

        ingest.recordTriage([], tabId: tabId, now: t0.addingTimeInterval(10))
        #expect(ingest.snapshot.items.isEmpty)
    }

    @Test("A poll records when the host was last checked — the evidence behind a quiet inbox")
    func lastCheckedRecorded() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)
        #expect(ingest.lastCheckedAt["profile-1"] == nil)

        ingest.recordTriage([], tabId: tabId, now: t0.addingTimeInterval(30))
        #expect(ingest.lastCheckedAt["profile-1"] == t0.addingTimeInterval(30))
    }

    @Test("User actions on the inbox republish immediately")
    func userActionsRepublish() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        let id = "profile-1:metric:cpu"

        ingest.resolve(id, now: t0.addingTimeInterval(20))
        #expect(ingest.snapshot.activeItems(now: t0.addingTimeInterval(30)).isEmpty)

        ingest.markSeen(now: t0.addingTimeInterval(40))
        #expect(ingest.snapshot.lastSeenAt == t0.addingTimeInterval(40))
    }

    // MARK: Escalation notifications

    @Test("A doctor verdict arriving at act-now interrupts once, not on every refresh")
    func escalationNotifiesOnce() throws {
        try doctorStore.upsert(ServerDoctorHostSummary(
            profileId: "profile-1",
            hostLabel: "web-01",
            headline: "Disk is full; two services stopped.",
            overallSeverity: .critical,
            topFindingTitle: "Disk full",
            findingCount: 2,
            generatedAt: t0,
            narratedOnDevice: false
        ))
        ingest.syncScanSummaries(now: t0)
        #expect(escalationBox.delivered.map(\.hostName) == ["web-01"])

        // Same verdict re-observed: already announced, stays quiet.
        ingest.syncScanSummaries(now: t0.addingTimeInterval(120))
        #expect(escalationBox.delivered.count == 1)
    }

    @Test("A dropped connection does not interrupt — the monitor alert path already does")
    func connectionDoesNotDoubleNotify() {
        ingest.syncTabs([makeTab(status: .error)], now: t0)
        #expect(ingest.snapshot.items.map(\.sourceKind) == [.connection])
        #expect(escalationBox.delivered.isEmpty)
    }

    /// Regression: the escalation baseline used to be recorded from every
    /// persisted item, including ones still inside their hysteresis
    /// window. A metric that debuts straight at act-now — a disk already
    /// at 97% when you connect — was therefore marked "already known"
    /// before it was ever eligible to alert, and never notified at all.
    @Test("A metric that debuts at act-now still alerts once its hysteresis elapses")
    func metricDebutingAtActNowStillAlerts() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)

        // Inside the 12 s confirmation window: not yet loud anywhere.
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        #expect(escalationBox.delivered.isEmpty)

        // Past it, the same unchanged finding must interrupt exactly once.
        let confirmed = t0.addingTimeInterval(70)
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: confirmed)
        #expect(escalationBox.delivered.map(\.itemId) == ["profile-1:metric:cpu"])

        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: confirmed.addingTimeInterval(70))
        #expect(escalationBox.delivered.count == 1)
    }

    @Test("Pruning through the ingest republishes, so a deleted host leaves the panel")
    func pruneRepublishes() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        #expect(ingest.snapshot.items.count == 1)

        ingest.prune(keepingProfileIds: [])
        #expect(ingest.snapshot.items.isEmpty)
    }

    @Test("Undo restores a handled item to the active list")
    func unresolveRestores() {
        let tabId = UUID()
        ingest.syncTabs([makeTab(id: tabId)], now: t0)
        ingest.recordTriage([triageIssue(tabId: tabId)], tabId: tabId, now: t0)
        let id = "profile-1:metric:cpu"
        let later = t0.addingTimeInterval(30)

        ingest.resolve(id, now: later)
        #expect(ingest.snapshot.activeItems(now: later).isEmpty)

        ingest.unresolve(id)
        #expect(ingest.snapshot.activeItems(now: later).map(\.id) == [id])
    }
}
