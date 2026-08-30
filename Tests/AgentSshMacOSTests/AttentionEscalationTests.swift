import Foundation
import Testing
@testable import AgentSshMacOS

/// Notifications are the one place the inbox is allowed to interrupt, so
/// the bar is transitions only: a finding that is merely *still* bad has
/// already been seen and must never re-interrupt.
struct AttentionEscalationTests {
    private let t0 = Date(timeIntervalSince1970: 7_000_000)

    private func item(
        sourceId: String = "disk-full",
        tier: AttentionTier = .actNow,
        firstSeen: Date? = nil
    ) -> AttentionItem {
        AttentionItem(
            profileId: "profile-1",
            sourceKind: .serverDoctor,
            sourceId: sourceId,
            hostName: "web-1",
            tier: tier,
            title: "Disk almost full",
            detail: "/var is at 97%.",
            firstSeen: firstSeen ?? t0,
            lastObserved: firstSeen ?? t0
        )
    }

    @Test("A finding arriving straight at act-now alerts")
    func newActNowAlerts() {
        let alerts = AttentionEscalationEvaluator.decide(
            previousTiers: [:],
            current: [item()],
            now: t0
        )
        #expect(alerts.map(\.itemId) == ["profile-1:server-doctor:disk-full"])
        #expect(alerts.first?.hostName == "web-1")
    }

    @Test("The same finding still act-now on the next pass does not re-alert")
    func steadyStateStaysQuiet() {
        let existing = item()
        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: [existing.id: .actNow],
            current: [existing],
            now: t0.addingTimeInterval(60)
        ).isEmpty)
    }

    @Test("A rise into act-now alerts; a fall out of it does not")
    func onlyRisesAlert() {
        let escalated = item(tier: .actNow)
        #expect(!AttentionEscalationEvaluator.decide(
            previousTiers: [escalated.id: .fixThisWeek],
            current: [escalated],
            now: t0
        ).isEmpty)

        let calmed = item(tier: .fixThisWeek)
        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: [calmed.id: .actNow],
            current: [calmed],
            now: t0
        ).isEmpty)
    }

    @Test("Tiers below act-now never interrupt, however they arrived", arguments: [
        AttentionTier.needsDecision, .fixThisWeek, .fyi,
    ])
    func quietTiersNeverAlert(tier: AttentionTier) {
        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: [:],
            current: [item(tier: tier)],
            now: t0
        ).isEmpty)
    }

    @Test("An unconfirmed item does not alert before its hysteresis window")
    func unconfirmedDoesNotAlert() {
        let fresh = AttentionItem(
            profileId: "profile-1",
            sourceKind: .metric,
            sourceId: "cpu",
            hostName: "web-1",
            tier: .actNow,
            title: "CPU",
            detail: "99%",
            firstSeen: t0,
            lastObserved: t0
        )
        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [fresh], now: t0.addingTimeInterval(5)
        ).isEmpty)
        #expect(!AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [fresh], now: t0.addingTimeInterval(12)
        ).isEmpty)
    }

    @Test("A re-escalation inside the repeat window is suppressed, outside it alerts")
    func repeatWindow() {
        let flapping = item()
        let common = (previous: [flapping.id: AttentionTier.fixThisWeek], current: [flapping])

        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: common.previous,
            current: common.current,
            now: t0.addingTimeInterval(60),
            lastAlertedAt: [flapping.id: t0],
            minimumRepeatInterval: 900
        ).isEmpty)

        #expect(!AttentionEscalationEvaluator.decide(
            previousTiers: common.previous,
            current: common.current,
            now: t0.addingTimeInterval(900),
            lastAlertedAt: [flapping.id: t0],
            minimumRepeatInterval: 900
        ).isEmpty)
    }

    @Test("The notification identifier is stable per item, so a re-alert replaces rather than stacks")
    func stableIdentifier() {
        let first = AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [item()], now: t0
        ).first
        let later = AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [item()], now: t0.addingTimeInterval(10_000)
        ).first
        #expect(first?.notificationIdentifier == later?.notificationIdentifier)
        #expect(first?.notificationIdentifier.contains("profile-1:server-doctor:disk-full") == true)
    }

    @Test("The alert body leads with the host and what to do, not the tier name")
    func bodyIsActionable() {
        var withGuidance = item()
        withGuidance.whyItMatters = "A full disk stops new logins and can corrupt databases."
        let alert = AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [withGuidance], now: t0
        ).first
        #expect(alert?.title.contains("web-1") == true)
        #expect(alert?.body.contains("A full disk stops new logins") == true)
    }

    /// A dropped tab is already announced by the widget-monitor alert
    /// path; a second banner for the same event is what makes people
    /// mute an app.
    @Test("Connection failures stay silent here — another path already announces them")
    func connectionSourceDoesNotDoubleNotify() {
        let dropped = AttentionItem(
            profileId: "profile-1",
            sourceKind: .connection,
            sourceId: "status",
            hostName: "web-1",
            tier: .actNow,
            title: "Connection",
            detail: "Connection error",
            firstSeen: t0,
            lastObserved: t0
        )
        #expect(AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [dropped], now: t0
        ).isEmpty)

        // Still alertable when a caller deliberately opts in.
        #expect(!AttentionEscalationEvaluator.decide(
            previousTiers: [:], current: [dropped], now: t0, excludedSources: []
        ).isEmpty)
    }
}
