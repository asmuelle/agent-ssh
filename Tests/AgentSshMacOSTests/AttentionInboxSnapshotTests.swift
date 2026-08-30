import Foundation
import Testing
@testable import AgentSshMacOS

/// The snapshot is the read model the UI renders from: one file read
/// produces a value the view can query repeatedly per frame without
/// touching disk. These tests pin its query semantics, which the store
/// delegates to, so both paths can never drift apart.
struct AttentionInboxSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    private func item(
        sourceKind: AttentionSourceKind = .serverDoctor,
        sourceId: String = "verdict",
        tier: AttentionTier = .fixThisWeek,
        profileId: String = "profile-1",
        firstSeen: Date? = nil
    ) -> AttentionItem {
        AttentionItem(
            profileId: profileId,
            sourceKind: sourceKind,
            sourceId: sourceId,
            hostName: "web-1",
            tier: tier,
            title: "Disk almost full",
            detail: "/var is at 91%.",
            firstSeen: firstSeen ?? t0,
            lastObserved: firstSeen ?? t0
        )
    }

    @Test("Active items exclude unconfirmed, snoozed, and resolved")
    func activeFiltering() {
        let confirmed = item(sourceId: "confirmed")
        let unconfirmed = item(sourceKind: .metric, sourceId: "cpu", firstSeen: t0.addingTimeInterval(-1))
        let snoozed = item(sourceId: "snoozed")
        let resolved = item(sourceId: "resolved")

        let snapshot = AttentionInboxSnapshot(
            items: [confirmed, unconfirmed, snoozed, resolved],
            snoozedUntil: [snoozed.id: t0.addingTimeInterval(3_600)],
            resolutions: [resolved.id: AttentionResolution(resolvedAt: t0, tierAtResolution: .fixThisWeek)]
        )

        #expect(snapshot.activeItems(now: t0).map(\.sourceId) == ["confirmed"])
        #expect(snapshot.snoozedItems(now: t0).map(\.sourceId) == ["snoozed"])
        #expect(snapshot.resolvedItems().map(\.sourceId) == ["resolved"])
    }

    @Test("Ordering is tier-desc, then oldest first, then id — stable under the cursor")
    func ordering() {
        let older = t0.addingTimeInterval(-500)
        let snapshot = AttentionInboxSnapshot(items: [
            item(sourceId: "fyi", tier: .fyi),
            item(sourceId: "urgent", tier: .actNow),
            item(sourceId: "old-week", tier: .fixThisWeek, firstSeen: older),
            item(sourceId: "new-week", tier: .fixThisWeek),
            item(sourceId: "decide", tier: .needsDecision),
        ])
        #expect(snapshot.activeItems(now: t0).map(\.sourceId)
            == ["urgent", "decide", "old-week", "new-week", "fyi"])
    }

    @Test("Tier sections list every non-empty tier, most urgent first")
    func tierSections() {
        let snapshot = AttentionInboxSnapshot(items: [
            item(sourceId: "a", tier: .fyi),
            item(sourceId: "b", tier: .actNow),
            item(sourceId: "c", tier: .actNow),
        ])
        let sections = snapshot.tierSections(now: t0)
        #expect(sections.map(\.tier) == [.actNow, .fyi])
        #expect(sections.first?.items.map(\.sourceId) == ["b", "c"])
    }

    @Test("New items respect the watermark and count escalation reactivations")
    func newItems() {
        let seen = item(sourceId: "seen")
        let reactivated = item(sourceId: "reactivated")
        let snapshot = AttentionInboxSnapshot(
            items: [seen, reactivated],
            reactivatedAt: [reactivated.id: t0.addingTimeInterval(100)],
            lastSeenAt: t0.addingTimeInterval(50)
        )
        #expect(snapshot.newItems(now: t0.addingTimeInterval(200)).map(\.sourceId) == ["reactivated"])
    }

    @Test("With no watermark every visible item is new")
    func newItemsWithoutWatermark() {
        let snapshot = AttentionInboxSnapshot(items: [item()])
        #expect(snapshot.newItems(now: t0).count == 1)
    }

    @Test("Worst tier drives a single at-a-glance badge, nil when quiet")
    func worstTier() {
        #expect(AttentionInboxSnapshot(items: []).worstTier(now: t0) == nil)
        let snapshot = AttentionInboxSnapshot(items: [
            item(sourceId: "a", tier: .fyi),
            item(sourceId: "b", tier: .needsDecision),
        ])
        #expect(snapshot.worstTier(now: t0) == .needsDecision)
    }

    @Test("Items for one profile are addressable — the panel groups by host")
    func profileFiltering() {
        let snapshot = AttentionInboxSnapshot(items: [
            item(sourceId: "a", profileId: "p1"),
            item(sourceId: "b", profileId: "p2"),
        ])
        #expect(snapshot.activeItems(now: t0, profileId: "p2").map(\.sourceId) == ["b"])
        #expect(snapshot.profileIdsNeedingAttention(now: t0) == ["p1", "p2"])
    }

    /// The panel pins the watermark it opened with, so marking the inbox
    /// seen cannot erase the badge in the frame that drew it.
    @Test("An explicit watermark is honoured over the stored one")
    func newItemsAgainstPinnedWatermark() {
        let old = item(sourceId: "old", firstSeen: t0)
        let fresh = item(sourceId: "fresh", firstSeen: t0.addingTimeInterval(100))
        // Stored watermark says "you have seen everything".
        let snapshot = AttentionInboxSnapshot(
            items: [old, fresh],
            lastSeenAt: t0.addingTimeInterval(200)
        )
        #expect(snapshot.newItems(now: t0.addingTimeInterval(300)).isEmpty)

        // Pinned to the start of the visit, the newer item is still new.
        #expect(snapshot.newItems(
            now: t0.addingTimeInterval(300),
            since: t0.addingTimeInterval(50)
        ).map(\.sourceId) == ["fresh"])
    }

    @Test("A nil pinned watermark means a first-ever visit: everything counts")
    func nilWatermarkCountsEverything() {
        let snapshot = AttentionInboxSnapshot(items: [item()], lastSeenAt: t0)
        #expect(snapshot.newItems(now: t0.addingTimeInterval(10), since: nil).count == 1)
    }
}
