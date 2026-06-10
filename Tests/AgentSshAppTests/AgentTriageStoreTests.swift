@testable import AgentSshApp
import AgentSshMacOS
import Foundation
import Testing

/// Covers the Agent view's triage rules: hysteresis (metric issues
/// must persist before going loud), immediate clearing, snooze, and
/// pruning of issues for closed / disconnected tabs.
@MainActor
struct AgentTriageStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeTab(
        id: UUID = UUID(),
        name: String = "web-01",
        status: TerminalConnectionStatus = .connected
    ) -> TerminalTab {
        TerminalTab(
            id: id,
            profile: ConnectionProfile(name: name, host: "example.com", username: "root"),
            sessionId: "abc12345",
            connectionId: "root@example.com:22#abc12345",
            ptyGeneration: 0,
            title: name,
            order: 0,
            themeOverride: nil,
            status: status
        )
    }

    private func snapshot(
        tab: TerminalTab,
        issues: [DashboardHealthIssue]
    ) -> DashboardHealthSnapshot {
        DashboardHealthSnapshot(
            id: tab.id.uuidString,
            hostName: tab.profile.name,
            issues: issues
        )
    }

    private func cpuIssue(host: String = "web-01") -> DashboardHealthIssue {
        DashboardHealthIssue(
            id: "cpu",
            title: "\(host): CPU",
            detail: "97.0%",
            icon: "cpu",
            severity: .critical
        )
    }

    private func ufwIssue(host: String = "web-01") -> DashboardHealthIssue {
        DashboardHealthIssue(
            id: "ufw-inactive",
            title: "\(host): UFW",
            detail: "Firewall inactive",
            icon: "shield.slash",
            severity: .warning
        )
    }

    // MARK: - Hysteresis

    @Test("metric issue stays silent until its confirmation delay passes")
    func metricIssueNeedsConfirmation() {
        let store = AgentTriageStore()
        let tab = makeTab()

        store.ingest(snapshot: snapshot(tab: tab, issues: [cpuIssue()]), tabId: tab.id, now: t0)

        #expect(store.confirmedIssues(now: t0).isEmpty)
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(11)).isEmpty)
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(12)).count == 1)
    }

    @Test("firstSeen survives re-ingestion so confirmation accumulates")
    func firstSeenSurvivesReingestion() {
        let store = AgentTriageStore()
        let tab = makeTab()

        store.ingest(snapshot: snapshot(tab: tab, issues: [cpuIssue()]), tabId: tab.id, now: t0)
        store.ingest(
            snapshot: snapshot(tab: tab, issues: [cpuIssue()]),
            tabId: tab.id,
            now: t0.addingTimeInterval(8)
        )

        // 12s after FIRST sighting, not after the second.
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(12)).count == 1)
    }

    @Test("issue absent from the next snapshot clears immediately")
    func issueClearsOnAbsence() {
        let store = AgentTriageStore()
        let tab = makeTab()

        store.ingest(snapshot: snapshot(tab: tab, issues: [cpuIssue()]), tabId: tab.id, now: t0)
        store.ingest(
            snapshot: snapshot(tab: tab, issues: []),
            tabId: tab.id,
            now: t0.addingTimeInterval(20)
        )

        #expect(store.confirmedIssues(now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test("status-prefixed snapshot issues are excluded — connection state comes from syncTabs")
    func snapshotStatusIssuesExcluded() {
        let store = AgentTriageStore()
        let tab = makeTab()
        let statusIssue = DashboardHealthIssue(
            id: "status:disconnected",
            title: "web-01: Connection",
            detail: "Disconnected",
            icon: "wifi.slash",
            severity: .warning
        )

        store.ingest(snapshot: snapshot(tab: tab, issues: [statusIssue]), tabId: tab.id, now: t0)

        #expect(store.confirmedIssues(now: t0.addingTimeInterval(60)).isEmpty)
    }

    // MARK: - Connection issues

    @Test("disconnected tab surfaces immediately as a warning")
    func disconnectedTabIsImmediate() {
        let store = AgentTriageStore()
        let tab = makeTab(status: .disconnected)

        store.syncTabs([tab], now: t0)

        let issues = store.confirmedIssues(now: t0)
        #expect(issues.count == 1)
        #expect(issues[0].severity == .warning)
        #expect(issues[0].kind == .connection)
    }

    @Test("errored tab surfaces as critical")
    func erroredTabIsCritical() {
        let store = AgentTriageStore()
        let tab = makeTab(status: .error)

        store.syncTabs([tab], now: t0)

        #expect(store.confirmedIssues(now: t0).first?.severity == .critical)
    }

    @Test("connecting and connected tabs stay quiet")
    func transientStatesStayQuiet() {
        let store = AgentTriageStore()

        store.syncTabs(
            [makeTab(status: .connecting), makeTab(status: .connected)],
            now: t0
        )

        #expect(store.confirmedIssues(now: t0).isEmpty)
    }

    @Test("reconnecting clears the connection issue")
    func reconnectClearsConnectionIssue() {
        let store = AgentTriageStore()
        var tab = makeTab(status: .disconnected)

        store.syncTabs([tab], now: t0)
        #expect(store.confirmedIssues(now: t0).count == 1)

        tab.status = .connected
        store.syncTabs([tab], now: t0.addingTimeInterval(5))
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(5)).isEmpty)
    }

    // MARK: - Pruning

    @Test("closing a tab prunes its issues and snoozes")
    func closingTabPrunes() {
        let store = AgentTriageStore()
        let tab = makeTab(status: .disconnected)

        store.syncTabs([tab], now: t0)
        let issueId = store.confirmedIssues(now: t0)[0].id
        store.snooze(issueId, for: 3600, now: t0)

        store.syncTabs([], now: t0.addingTimeInterval(1))

        #expect(store.candidates.isEmpty)
        #expect(store.snoozedUntil.isEmpty)
    }

    @Test("disconnect prunes the host's stale metric issues")
    func disconnectPrunesStaleMetrics() {
        let store = AgentTriageStore()
        var tab = makeTab()

        store.ingest(snapshot: snapshot(tab: tab, issues: [cpuIssue()]), tabId: tab.id, now: t0)
        tab.status = .disconnected
        store.syncTabs([tab], now: t0.addingTimeInterval(30))

        let issues = store.confirmedIssues(now: t0.addingTimeInterval(60))
        #expect(issues.count == 1)
        #expect(issues[0].kind == .connection)
    }

    // MARK: - Snooze

    @Test("snoozed issue moves out of confirmed and back after expiry")
    func snoozeRoundTrip() {
        let store = AgentTriageStore()
        let tab = makeTab(status: .disconnected)

        store.syncTabs([tab], now: t0)
        let issueId = store.confirmedIssues(now: t0)[0].id

        store.snooze(issueId, for: 3600, now: t0)
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(store.snoozedIssues(now: t0.addingTimeInterval(60)).count == 1)

        // Expires on its own…
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(3601)).count == 1)

        // …or explicitly.
        store.unsnooze(issueId)
        #expect(store.confirmedIssues(now: t0.addingTimeInterval(60)).count == 1)
    }

    // MARK: - Ordering and presentation

    @Test("critical issues sort before warnings")
    func criticalSortsFirst() {
        let store = AgentTriageStore()
        let tab = makeTab()

        store.ingest(
            snapshot: snapshot(tab: tab, issues: [ufwIssue(), cpuIssue()]),
            tabId: tab.id,
            now: t0
        )

        let issues = store.confirmedIssues(now: t0.addingTimeInterval(60))
        #expect(issues.count == 2)
        #expect(issues[0].severity == .critical)
        #expect(issues[1].severity == .warning)
    }

    @Test("host prefix is stripped from snapshot titles")
    func hostPrefixStripped() {
        let store = AgentTriageStore()
        let tab = makeTab()

        store.ingest(snapshot: snapshot(tab: tab, issues: [cpuIssue()]), tabId: tab.id, now: t0)

        #expect(store.confirmedIssues(now: t0.addingTimeInterval(60))[0].title == "CPU")
    }

    @Test("confirmedCount tracks ingestion for the strip badge")
    func confirmedCountTracksBadge() {
        let store = AgentTriageStore()
        let tab = makeTab(status: .disconnected)

        #expect(store.confirmedCount == 0)
        store.syncTabs([tab], now: t0)
        #expect(store.confirmedCount == 1)
        store.syncTabs([], now: t0.addingTimeInterval(1))
        #expect(store.confirmedCount == 0)
    }
}
