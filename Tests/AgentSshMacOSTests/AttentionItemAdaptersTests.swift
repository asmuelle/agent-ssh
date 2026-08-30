import Foundation
import Testing
@testable import AgentSshMacOS

struct ServerDoctorAttentionAdapterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func makeSummary(
        severity: ServerDoctorSeverity,
        findingCount: Int = 3,
        generatedAt: Date? = nil
    ) -> ServerDoctorHostSummary {
        ServerDoctorHostSummary(
            profileId: "profile-1",
            hostLabel: "web-1",
            headline: "Disk almost full on /var; two services are failing.",
            overallSeverity: severity,
            topFindingTitle: "Disk almost full",
            findingCount: findingCount,
            generatedAt: generatedAt ?? now,
            narratedOnDevice: false
        )
    }

    @Test("A warning verdict becomes one fix-this-week item carrying the headline")
    func warningVerdictBecomesItem() {
        let items = makeSummary(severity: .warning).attentionItems(now: now)
        #expect(items.count == 1)
        #expect(items.first?.id == "profile-1:server-doctor:verdict:Disk almost full")
        #expect(items.first?.tier == .fixThisWeek)
        #expect(items.first?.detail == "Disk almost full on /var; two services are failing.")
        #expect(items.first?.title == "Disk almost full")
        #expect(items.first?.hostName == "web-1")
    }

    @Test("A critical verdict is act-now")
    func criticalVerdictIsActNow() {
        #expect(makeSummary(severity: .critical).attentionItems(now: now).first?.tier == .actNow)
    }

    @Test("A healthy (info) verdict produces no item — quiet by default")
    func infoVerdictProducesNothing() {
        #expect(makeSummary(severity: .info).attentionItems(now: now).isEmpty)
    }

    @Test("An unknown verdict with findings needs the user's decision; without findings it stays quiet")
    func unknownVerdictAmbiguityRule() {
        #expect(makeSummary(severity: .unknown, findingCount: 2).attentionItems(now: now).first?.tier == .needsDecision)
        #expect(makeSummary(severity: .unknown, findingCount: 0).attentionItems(now: now).isEmpty)
    }

    @Test("A stale verdict produces no item — old news must not masquerade as current")
    func staleVerdictProducesNothing() {
        let old = now.addingTimeInterval(-ServerDoctorSummaryStore.staleAfter - 1)
        #expect(makeSummary(severity: .critical, generatedAt: old).attentionItems(now: now).isEmpty)
    }
}

struct SecurityPatchAttentionAdapterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func makeSummary(
        badge: SecurityPatchHostBadge,
        severity: SecurityPatchSeverity,
        profileId: String? = "profile-1",
        scannedAt: Date? = Date(timeIntervalSince1970: 2_000_000)
    ) -> SecurityPatchHostSummary {
        SecurityPatchHostSummary(
            connectionId: "conn-1",
            profileId: profileId,
            hostLabel: "web-1",
            badge: badge,
            severity: severity,
            summary: "5 security updates pending.",
            scannedAt: scannedAt,
            securityUpdateCount: 5,
            totalUpdateCount: 12,
            rebootRequired: false
        )
    }

    @Test("A secure, healthy scan produces no item")
    func secureScanProducesNothing() {
        #expect(makeSummary(badge: .secure, severity: .info).attentionItems(now: now).isEmpty)
    }

    @Test("A critical scan (e.g. CISA KEV match) is act-now")
    func criticalScanIsActNow() {
        let items = makeSummary(badge: .critical, severity: .critical).attentionItems(now: now)
        #expect(items.count == 1)
        #expect(items.first?.id == "profile-1:security-patch:patches:critical")
        #expect(items.first?.tier == .actNow)
        #expect(items.first?.detail == "5 security updates pending.")
    }

    @Test("Pending security updates are fix-this-week")
    func securityUpdatesAreFixThisWeek() {
        let items = makeSummary(badge: .securityUpdates, severity: .high).attentionItems(now: now)
        #expect(items.first?.tier == .fixThisWeek)
        #expect(items.first?.title == SecurityPatchHostBadge.securityUpdates.displayName)
    }

    @Test("Plain updates with no security impact are FYI")
    func plainUpdatesAreFYI() {
        #expect(makeSummary(badge: .updatesAvailable, severity: .info).attentionItems(now: now).first?.tier == .fyi)
    }

    @Test("An indeterminate scan needs the user's decision")
    func unknownScanNeedsDecision() {
        #expect(makeSummary(badge: .unknown, severity: .unknown).attentionItems(now: now).first?.tier == .needsDecision)
    }

    @Test("A judged severity behind an unknown badge titles with the finding, not 'Unknown'")
    func judgedSeverityBehindUnknownBadge() {
        let items = makeSummary(badge: .unknown, severity: .high).attentionItems(now: now)
        #expect(items.first?.tier == .fixThisWeek)
        #expect(items.first?.title == "5 security updates pending.")
    }

    @Test("A scan older than a day produces no item — old news must not masquerade as current")
    func staleScanProducesNothing() {
        let old = now.addingTimeInterval(-SecurityPatchHostSummary.attentionStaleAfter - 1)
        #expect(makeSummary(badge: .critical, severity: .critical, scannedAt: old).attentionItems(now: now).isEmpty)
    }

    @Test("No profile id, unsupported host, or never-scanned all stay quiet", arguments: [
        (SecurityPatchHostBadge.critical, SecurityPatchSeverity.critical, nil, Date(timeIntervalSince1970: 2_000_000)),
        (.unsupported, .unknown, "profile-1", Date(timeIntervalSince1970: 2_000_000)),
        (.unknown, .unknown, "profile-1", nil),
    ] as [(SecurityPatchHostBadge, SecurityPatchSeverity, String?, Date?)])
    func ineligibleSummariesProduceNothing(
        badge: SecurityPatchHostBadge,
        severity: SecurityPatchSeverity,
        profileId: String?,
        scannedAt: Date?
    ) {
        let summary = makeSummary(badge: badge, severity: severity, profileId: profileId, scannedAt: scannedAt)
        #expect(summary.attentionItems(now: now).isEmpty)
    }
}
