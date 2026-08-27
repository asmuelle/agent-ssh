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

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private let directory: URL
    private let inbox: AttentionInboxStore
    private let doctorStore: ServerDoctorSummaryStore
    private let patchBox = PatchSummariesBox()
    private let ingest: AttentionInboxIngest

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-ingest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = AttentionInboxStore(directoryURL: directory)
        doctorStore = ServerDoctorSummaryStore(directoryURL: directory)
        let box = patchBox
        ingest = AttentionInboxIngest(
            inbox: inbox,
            doctorSummaries: doctorStore,
            patchSummaries: { box.summaries }
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
}
