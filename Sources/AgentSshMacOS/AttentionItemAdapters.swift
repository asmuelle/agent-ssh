import Foundation

// MARK: - Server Doctor → attention inbox

public extension ServerDoctorHostSummary {
    /// The inbox item for this host's latest Server Doctor verdict, or
    /// nothing when the verdict is not worth the user's attention.
    ///
    /// Quiet-by-default rules, matching the sidebar badge: healthy (`info`)
    /// verdicts and verdicts past the summary staleness window produce no
    /// item — old news must not masquerade as current. The one addition to
    /// the sidebar policy is the ambiguity rule: an `unknown` verdict that
    /// still carries findings needs the user's decision rather than
    /// silence.
    func attentionItems(now: Date = Date()) -> [AttentionItem] {
        guard now.timeIntervalSince(generatedAt) < ServerDoctorSummaryStore.staleAfter else {
            return []
        }
        let isWorthAttention = overallSeverity >= .warning
            || (overallSeverity == .unknown && findingCount > 0)
        guard isWorthAttention else { return [] }

        // The top finding is part of the identity: a re-scan that surfaces
        // a materially different problem must be a NEW item, so a
        // resolution of the old problem can never silently swallow it —
        // the store retires the old id via clear-on-absence.
        return [AttentionItem(
            profileId: profileId,
            sourceKind: .serverDoctor,
            sourceId: "verdict:\(topFindingTitle ?? overallSeverity.rawValue)",
            hostName: hostLabel,
            tier: overallSeverity.attentionTier,
            title: topFindingTitle ?? "Server Doctor found issues",
            detail: headline,
            safeNextSteps: ["Open the Server Doctor report for the findings and safe next steps."],
            firstSeen: generatedAt
        )]
    }
}

// MARK: - Security Patch Monitor → attention inbox

public extension SecurityPatchHostSummary {
    /// The inbox item for this host's latest security patch scan, or
    /// nothing when there is nothing to act on.
    ///
    /// How long a patch scan may back an inbox item — mirrors the 24 h
    /// sidebar staleness window (`SecurityPatchMonitorCache.staleAfter`
    /// in the app target, which cannot be imported from here).
    static var attentionStaleAfter: TimeInterval { 60 * 60 * 24 }

    /// Quiet when: the summary has no stable profile id (the inbox is
    /// profile-keyed), the host's package manager is unsupported (nothing
    /// to act on), no scan has run yet or the last one is older than a
    /// day (the inbox's empty state owns "never/not recently checked" —
    /// old news must not masquerade as current), or the scan came back
    /// secure and healthy. An indeterminate scan that did run maps to
    /// "Needs your decision" — ambiguity is never silently filed away.
    func attentionItems(now: Date = Date()) -> [AttentionItem] {
        guard let profileId,
              badge != .unsupported,
              let scannedAt,
              now.timeIntervalSince(scannedAt) < Self.attentionStaleAfter,
              !(badge == .secure && severity == .info)
        else { return [] }

        // The badge is part of the identity so a resolved "updates
        // available" can never swallow a later "critical" — a badge
        // change is a new item, retiring the old one and its resolution.
        // A judged severity behind an .unknown badge (e.g. risky sshd
        // settings with no pending updates) titles with the scan's own
        // top-finding summary instead of a self-contradicting "Unknown".
        return [AttentionItem(
            profileId: profileId,
            sourceKind: .securityPatch,
            sourceId: "patches:\(badge.rawValue)",
            hostName: hostLabel,
            tier: severity.attentionTier,
            title: badge == .unknown && severity != .unknown ? summary : badge.displayName,
            detail: summary,
            safeNextSteps: ["Open the Security tab for the scan evidence and per-package details."],
            firstSeen: scannedAt
        )]
    }
}
