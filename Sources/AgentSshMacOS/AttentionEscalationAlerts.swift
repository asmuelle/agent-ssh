import Foundation

/// One interruption the inbox has earned the right to make.
public struct AttentionEscalationAlert: Equatable, Identifiable, Sendable {
    public var itemId: String
    public var profileId: String
    public var hostName: String
    public var tier: AttentionTier
    public var title: String
    public var body: String
    /// Stable per item, so a repeat alert *replaces* the existing banner
    /// instead of stacking a second one for the same problem.
    public var notificationIdentifier: String

    public var id: String { itemId }

    public init(
        itemId: String,
        profileId: String,
        hostName: String,
        tier: AttentionTier,
        title: String,
        body: String,
        notificationIdentifier: String
    ) {
        self.itemId = itemId
        self.profileId = profileId
        self.hostName = hostName
        self.tier = tier
        self.title = title
        self.body = body
        self.notificationIdentifier = notificationIdentifier
    }
}

/// Decides when the attention inbox may interrupt the user.
///
/// The whole value of a quiet inbox is that a notification means
/// something, so the bar is deliberately high and purely edge-triggered:
/// only a *rise* into `actNow` qualifies. A finding that is merely still
/// bad has already been seen and never re-interrupts; a finding that
/// calms down is not news either. Rate limiting on top means a flapping
/// host cannot turn one problem into a stream of banners.
///
/// Pure and synchronous by design — this is the policy, and delivery is
/// somebody else's job.
public enum AttentionEscalationEvaluator {
    /// Shortest gap between two alerts about the same item.
    public static let defaultRepeatInterval: TimeInterval = 15 * 60

    /// The tier that has earned the right to interrupt. Everything below
    /// it belongs in the panel, where the user looks on their own terms.
    public static let interruptingTier: AttentionTier = .actNow

    /// Sources whose findings are already announced by another path, and
    /// which must therefore stay silent here.
    ///
    /// A tab going `.error` is published as a `.down` widget-monitor
    /// snapshot and announced by `WidgetMonitorAlertEvaluator`, *and*
    /// becomes an act-now connection item. Alerting on both would ship
    /// two banners, with different identifiers, for one event — the exact
    /// noise the inbox exists to remove. The panel still shows it; only
    /// the second interruption is suppressed.
    public static let sourcesAnnouncedElsewhere: Set<AttentionSourceKind> = [.connection]

    public static func decide(
        previousTiers: [String: AttentionTier],
        current: [AttentionItem],
        now: Date,
        lastAlertedAt: [String: Date] = [:],
        minimumRepeatInterval: TimeInterval = AttentionEscalationEvaluator.defaultRepeatInterval,
        excludedSources: Set<AttentionSourceKind> = AttentionEscalationEvaluator.sourcesAnnouncedElsewhere
    ) -> [AttentionEscalationAlert] {
        current.compactMap { item in
            // Hysteresis first: an item still inside its confirmation
            // window is not yet allowed to be loud anywhere.
            guard item.isConfirmed(now: now),
                  item.tier >= interruptingTier,
                  !excludedSources.contains(item.sourceKind)
            else { return nil }

            // Edge, not level: something must have changed for the worse.
            let previous = previousTiers[item.id]
            guard previous == nil || previous! < item.tier else { return nil }

            if let alerted = lastAlertedAt[item.id],
               now.timeIntervalSince(alerted) < minimumRepeatInterval
            {
                return nil
            }

            return AttentionEscalationAlert(
                itemId: item.id,
                profileId: item.profileId,
                hostName: item.hostName,
                tier: item.tier,
                title: "\(item.hostName): \(item.title)",
                body: body(for: item),
                notificationIdentifier: "attention-escalation:\(item.id)"
            )
        }
    }

    /// What the banner says. Leads with the observation, then the reason
    /// it matters and the safest first move — a tier name on its own
    /// tells an inexperienced admin nothing they can act on.
    private static func body(for item: AttentionItem) -> String {
        var lines = [item.detail]
        if !item.whyItMatters.isEmpty {
            lines.append(item.whyItMatters)
        }
        if let firstStep = item.safeNextSteps.first {
            lines.append(firstStep)
        }
        return lines.joined(separator: "\n\n")
    }
}
