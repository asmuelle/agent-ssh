import Foundation
import Testing
@testable import AgentSshMacOS

struct AttentionTierTests {
    @Test("Tiers order by urgency: FYI < fix this week < needs decision < act now")
    func tierOrdering() {
        #expect(AttentionTier.fyi < .fixThisWeek)
        #expect(AttentionTier.fixThisWeek < .needsDecision)
        #expect(AttentionTier.needsDecision < .actNow)
        #expect(AttentionTier.allCases.max() == .actNow)
    }

    @Test("Raw values are stable identifiers, safe to persist")
    func tierRawValuesStable() {
        #expect(AttentionTier.actNow.rawValue == "act-now")
        #expect(AttentionTier.needsDecision.rawValue == "needs-decision")
        #expect(AttentionTier.fixThisWeek.rawValue == "fix-this-week")
        #expect(AttentionTier.fyi.rawValue == "fyi")
    }

    @Test("Every tier has a beginner-readable display name")
    func tierDisplayNames() {
        for tier in AttentionTier.allCases {
            #expect(!tier.displayName.isEmpty)
            #expect(!tier.displayName.contains("-"))
        }
    }
}

struct AttentionSeverityMappingTests {
    @Test("Server Doctor severities map onto the shared tier ramp", arguments: ServerDoctorSeverity.allCases)
    func doctorSeverityMapsExhaustively(severity: ServerDoctorSeverity) {
        let expected: AttentionTier
        switch severity {
        case .critical: expected = .actNow
        case .high, .warning: expected = .fixThisWeek
        case .info: expected = .fyi
        case .unknown: expected = .needsDecision
        }
        #expect(severity.attentionTier == expected)
    }

    @Test("Security Patch severities map onto the shared tier ramp", arguments: SecurityPatchSeverity.allCases)
    func patchSeverityMapsExhaustively(severity: SecurityPatchSeverity) {
        let expected: AttentionTier
        switch severity {
        case .critical: expected = .actNow
        case .high, .warning: expected = .fixThisWeek
        case .info: expected = .fyi
        case .unknown: expected = .needsDecision
        }
        #expect(severity.attentionTier == expected)
    }

    @Test("Ambiguity never lands silently in FYI")
    func unknownNeverMapsToFYI() {
        #expect(ServerDoctorSeverity.unknown.attentionTier != .fyi)
        #expect(SecurityPatchSeverity.unknown.attentionTier != .fyi)
    }

    @Test("Cross-source rank matches the sidebar's consolidated ramp")
    func attentionRankMatchesSidebarRamp() {
        #expect(ServerDoctorSeverity.critical.attentionRank == 4)
        #expect(ServerDoctorSeverity.high.attentionRank == 3)
        #expect(ServerDoctorSeverity.warning.attentionRank == 2)
        #expect(ServerDoctorSeverity.info.attentionRank == 1)
        #expect(ServerDoctorSeverity.unknown.attentionRank == 0)
        for severity in SecurityPatchSeverity.allCases {
            let doctorTwin = ServerDoctorSeverity(rawValue: severity.rawValue)
            #expect(severity.attentionRank == doctorTwin?.attentionRank)
        }
    }
}

struct AttentionItemTests {
    private func makeItem(
        sourceKind: AttentionSourceKind = .metric,
        firstSeen: Date = Date(timeIntervalSince1970: 0)
    ) -> AttentionItem {
        AttentionItem(
            profileId: "profile-1",
            sourceKind: sourceKind,
            sourceId: "cpu",
            hostName: "web-1",
            tier: .fixThisWeek,
            title: "High CPU",
            detail: "CPU has been above 85% for 10 minutes.",
            firstSeen: firstSeen,
            lastObserved: firstSeen
        )
    }

    @Test("Identity is composed from profile, source kind, and source id")
    func stableCompositeId() {
        #expect(makeItem().id == "profile-1:metric:cpu")
    }

    @Test("Metric items need 12s of persistence before confirmation, connection items none")
    func confirmationDelays() {
        let start = Date(timeIntervalSince1970: 100)
        let metric = makeItem(sourceKind: .metric, firstSeen: start)
        #expect(!metric.isConfirmed(now: start.addingTimeInterval(11)))
        #expect(metric.isConfirmed(now: start.addingTimeInterval(12)))

        let connection = makeItem(sourceKind: .connection, firstSeen: start)
        #expect(connection.isConfirmed(now: start))
    }

    @Test("Scan-based sources confirm immediately — a doctor verdict is not flappy")
    func scanSourcesConfirmImmediately() {
        let start = Date(timeIntervalSince1970: 100)
        for kind in [AttentionSourceKind.serverDoctor, .securityPatch, .sshAlgorithm] {
            #expect(makeItem(sourceKind: kind, firstSeen: start).isConfirmed(now: start))
        }
    }

    @Test("Freshness mirrors the fleet-health staleness contract")
    func freshnessUsesLastObserved() {
        let observed = Date(timeIntervalSince1970: 1_000)
        let item = makeItem(firstSeen: observed)
        #expect(item.freshness(now: observed.addingTimeInterval(60)) == .fresh)
        #expect(item.freshness(now: observed.addingTimeInterval(6 * 60)) == .stale)
    }

    @Test("Items round-trip through Codable")
    func codableRoundTrip() throws {
        var item = makeItem()
        item.whyItMatters = "A busy CPU slows every service on this host."
        item.safeNextSteps = ["Open the process list to see what is busy."]
        item.avoid = ["Do not reboot before looking — the cause will be lost."]
        item.evidence = ["load average: 8.12"]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AttentionItem.self, from: encoder.encode(item))
        #expect(decoded == item)
    }

    /// The pipeline rewrites every slice on a timer, so `lastObserved`
    /// alone would report a week-old scan as freshly checked.
    @Test("Freshness follows the producer's own observation, not the pipeline write")
    func freshnessPrefersProducerTime() {
        let scanned = Date(timeIntervalSince1970: 0)
        var item = makeItem(firstSeen: scanned)
        item.producerObservedAt = scanned
        item.lastObserved = scanned.addingTimeInterval(7 * 24 * 60 * 60)

        let now = item.lastObserved
        #expect(item.lastCheckedAt == scanned)
        #expect(item.freshness(now: now) == .stale)
    }

    @Test("Without a producer time, the pipeline write is the best available answer")
    func freshnessFallsBackToPipelineTime() {
        let item = makeItem(firstSeen: Date(timeIntervalSince1970: 1_000))
        #expect(item.lastCheckedAt == item.lastObserved)
    }
}
