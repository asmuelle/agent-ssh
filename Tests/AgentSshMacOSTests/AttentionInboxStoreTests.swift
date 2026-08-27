import Foundation
import Testing
@testable import AgentSshMacOS

struct AttentionInboxStoreTests {
    private let directory: URL
    private let store: AttentionInboxStore
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-inbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AttentionInboxStore(directoryURL: directory)
    }

    private func makeItem(
        profileId: String = "profile-1",
        sourceKind: AttentionSourceKind = .metric,
        sourceId: String = "cpu",
        tier: AttentionTier = .fixThisWeek,
        firstSeen: Date? = nil
    ) -> AttentionItem {
        AttentionItem(
            profileId: profileId,
            sourceKind: sourceKind,
            sourceId: sourceId,
            hostName: "web-1",
            tier: tier,
            title: "High CPU",
            detail: "CPU above 85%.",
            firstSeen: firstSeen ?? t0,
            lastObserved: firstSeen ?? t0
        )
    }

    // MARK: Ingestion

    @Test("Re-ingesting the same issue preserves firstSeen and updates lastObserved")
    func reingestionPreservesFirstSeen() throws {
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        let later = t0.addingTimeInterval(60)
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: later)

        let items = store.allItems()
        #expect(items.count == 1)
        #expect(items.first?.firstSeen == t0)
        #expect(items.first?.lastObserved == later)
    }

    @Test("Issues absent from the latest snapshot clear immediately, including their snooze")
    func clearOnAbsence() throws {
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        try store.snooze("profile-1:metric:cpu", until: t0.addingTimeInterval(3_600))
        try store.ingest([], source: .metric, profileId: "profile-1", now: t0.addingTimeInterval(30))

        #expect(store.allItems().isEmpty)

        // The issue coming back later is a new occurrence: fresh firstSeen, no snooze.
        let t2 = t0.addingTimeInterval(120)
        try store.ingest([makeItem(firstSeen: t2)], source: .metric, profileId: "profile-1", now: t2)
        #expect(store.allItems().first?.firstSeen == t2)
        #expect(!store.isSnoozed("profile-1:metric:cpu", now: t2))
    }

    @Test("Ingestion only replaces items of its own profile and source")
    func ingestionScopedToProfileAndSource() throws {
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        try store.ingest(
            [makeItem(profileId: "profile-2", sourceId: "memory")],
            source: .metric, profileId: "profile-2", now: t0
        )
        try store.ingest(
            [makeItem(sourceKind: .serverDoctor, sourceId: "disk-full")],
            source: .serverDoctor, profileId: "profile-1", now: t0
        )

        // Empty metric snapshot for profile-1 clears only that slice.
        try store.ingest([], source: .metric, profileId: "profile-1", now: t0)
        let remaining = store.allItems().map(\.id).sorted()
        #expect(remaining == ["profile-1:server-doctor:disk-full", "profile-2:metric:memory"])
    }

    @Test("Items from a foreign profile or source are ignored, not adopted")
    func ingestionFiltersMismatchedItems() throws {
        try store.ingest(
            [makeItem(profileId: "other"), makeItem(sourceKind: .journal, sourceId: "flood")],
            source: .metric, profileId: "profile-1", now: t0
        )
        #expect(store.allItems().isEmpty)
    }

    @Test("Duplicate ids in one batch collapse (last wins) and never poison later ingests")
    func duplicateIdsInOneBatchCollapse() throws {
        var first = makeItem(sourceKind: .sshAlgorithm, sourceId: "hmac-sha1", tier: .fyi)
        var second = makeItem(sourceKind: .sshAlgorithm, sourceId: "hmac-sha1", tier: .fixThisWeek)
        first.detail = "client-to-server"
        second.detail = "server-to-client"
        try store.ingest([first, second], source: .sshAlgorithm, profileId: "profile-1", now: t0)

        let items = store.allItems()
        #expect(items.count == 1)
        #expect(items.first?.tier == .fixThisWeek)

        // The regression that motivated this: any later ingest, for any
        // slice, must not trap on a duplicate-key rebuild.
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        #expect(store.allItems().count == 2)
    }

    // MARK: Confirmation and visibility

    @Test("Metric items stay invisible until their confirmation window passes")
    func confirmationHidesFreshMetrics() throws {
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        #expect(store.activeItems(now: t0.addingTimeInterval(5)).isEmpty)
        #expect(store.activeItems(now: t0.addingTimeInterval(12)).count == 1)
    }

    // MARK: Snooze

    @Test("A snoozed item leaves the active list and returns after expiry")
    func snoozeLifecycle() throws {
        let item = makeItem(sourceKind: .serverDoctor, sourceId: "disk-full")
        try store.ingest([item], source: .serverDoctor, profileId: "profile-1", now: t0)
        let id = "profile-1:server-doctor:disk-full"

        try store.snooze(id, until: t0.addingTimeInterval(3_600))
        #expect(store.activeItems(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(store.snoozedItems(now: t0.addingTimeInterval(60)).map(\.id) == [id])
        #expect(store.activeItems(now: t0.addingTimeInterval(3_601)).map(\.id) == [id])

        try store.snooze(id, until: t0.addingTimeInterval(7_200))
        try store.unsnooze(id)
        #expect(store.activeItems(now: t0.addingTimeInterval(60)).map(\.id) == [id])
    }

    // MARK: Resolve

    @Test("Resolving hides an item even while its condition persists")
    func resolveHidesWhileConditionPersists() throws {
        let item = makeItem(sourceKind: .sshAlgorithm, sourceId: "hmac-sha1")
        try store.ingest([item], source: .sshAlgorithm, profileId: "profile-1", now: t0)
        let id = "profile-1:ssh-algorithm:hmac-sha1"

        try store.resolve(id, now: t0.addingTimeInterval(10))
        #expect(store.activeItems(now: t0.addingTimeInterval(20)).isEmpty)
        #expect(store.resolvedItems().map(\.id) == [id])

        // Same finding, same tier, re-observed: stays resolved.
        try store.ingest([item], source: .sshAlgorithm, profileId: "profile-1", now: t0.addingTimeInterval(60))
        #expect(store.activeItems(now: t0.addingTimeInterval(70)).isEmpty)
    }

    @Test("A resolved item reactivates when its tier escalates")
    func resolveClearedOnEscalation() throws {
        var item = makeItem(sourceKind: .securityPatch, sourceId: "updates", tier: .fixThisWeek)
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t0)
        let id = item.id
        try store.resolve(id, now: t0.addingTimeInterval(10))

        item.tier = .actNow
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t0.addingTimeInterval(60))
        #expect(store.activeItems(now: t0.addingTimeInterval(70)).map(\.id) == [id])
        #expect(store.resolvedItems().isEmpty)
    }

    @Test("An issue that clears and reappears starts unresolved")
    func resolutionDropsWithTheItem() throws {
        let item = makeItem(sourceKind: .serverDoctor, sourceId: "disk-full")
        try store.ingest([item], source: .serverDoctor, profileId: "profile-1", now: t0)
        try store.resolve(item.id, now: t0.addingTimeInterval(10))
        try store.ingest([], source: .serverDoctor, profileId: "profile-1", now: t0.addingTimeInterval(20))

        let t2 = t0.addingTimeInterval(300)
        try store.ingest([makeItem(sourceKind: .serverDoctor, sourceId: "disk-full", firstSeen: t2)],
                         source: .serverDoctor, profileId: "profile-1", now: t2)
        #expect(store.activeItems(now: t2.addingTimeInterval(1)).map(\.id) == [item.id])
    }

    @Test("Escalation wakes a snoozed item and counts it as new")
    func escalationWakesSnooze() throws {
        var item = makeItem(sourceKind: .securityPatch, sourceId: "updates", tier: .fixThisWeek)
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t0)
        try store.markSeen(now: t0.addingTimeInterval(5))
        try store.snooze(item.id, until: t0.addingTimeInterval(86_400))

        // Same tier re-observed: snooze holds.
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t0.addingTimeInterval(60))
        #expect(store.activeItems(now: t0.addingTimeInterval(70)).isEmpty)

        // Escalated past the tier the user snoozed at: snooze wakes.
        item.tier = .actNow
        let t2 = t0.addingTimeInterval(120)
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t2)
        #expect(store.activeItems(now: t2.addingTimeInterval(1)).map(\.id) == [item.id])
        #expect(store.newItems(now: t2.addingTimeInterval(1)).map(\.id) == [item.id])
    }

    @Test("An item reactivated by escalation counts as new for the watermark")
    func reactivationCountsAsNew() throws {
        var item = makeItem(sourceKind: .securityPatch, sourceId: "kev", tier: .fixThisWeek)
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t0)
        try store.markSeen(now: t0.addingTimeInterval(10))
        try store.resolve(item.id, now: t0.addingTimeInterval(20))

        item.tier = .actNow
        let t2 = t0.addingTimeInterval(3_600)
        try store.ingest([item], source: .securityPatch, profileId: "profile-1", now: t2)

        #expect(store.activeItems(now: t2.addingTimeInterval(1)).map(\.id) == [item.id])
        #expect(store.newItems(now: t2.addingTimeInterval(1)).map(\.id) == [item.id])

        // Looking at the inbox absorbs the reactivation.
        try store.markSeen(now: t2.addingTimeInterval(10))
        #expect(store.newItems(now: t2.addingTimeInterval(20)).isEmpty)
    }

    // MARK: Seen watermark

    @Test("newItems counts what became visible since the user last looked")
    func seenWatermark() throws {
        let doctor = makeItem(sourceKind: .serverDoctor, sourceId: "disk-full")
        try store.ingest([doctor], source: .serverDoctor, profileId: "profile-1", now: t0)

        // Never looked: everything visible is new.
        #expect(store.newItems(now: t0.addingTimeInterval(1)).count == 1)

        try store.markSeen(now: t0.addingTimeInterval(10))
        #expect(store.newItems(now: t0.addingTimeInterval(11)).isEmpty)

        // A metric item ingested before markSeen but confirmed after it is still "new":
        // the user cannot have seen what was not yet visible.
        let metric = makeItem(firstSeen: t0.addingTimeInterval(5))
        try store.ingest([metric], source: .metric, profileId: "profile-1", now: t0.addingTimeInterval(5))
        try store.markSeen(now: t0.addingTimeInterval(8))
        #expect(store.newItems(now: t0.addingTimeInterval(30)).map(\.id) == [metric.id])
    }

    // MARK: Ordering

    @Test("Active items sort by tier, then age, then id — no reshuffling underfoot")
    func displayOrdering() throws {
        let older = t0.addingTimeInterval(-100)
        let items = [
            makeItem(sourceKind: .serverDoctor, sourceId: "fyi-note", tier: .fyi),
            makeItem(sourceKind: .serverDoctor, sourceId: "disk-full", tier: .actNow),
            makeItem(sourceKind: .serverDoctor, sourceId: "old-warning", tier: .fixThisWeek, firstSeen: older),
            makeItem(sourceKind: .serverDoctor, sourceId: "new-warning", tier: .fixThisWeek),
        ]
        try store.ingest(items, source: .serverDoctor, profileId: "profile-1", now: t0)
        let ordered = store.activeItems(now: t0.addingTimeInterval(1)).map(\.sourceId)
        #expect(ordered == ["disk-full", "old-warning", "new-warning", "fyi-note"])
    }

    // MARK: Persistence

    @Test("Items, snoozes, resolutions, and the watermark survive a store restart")
    func persistenceAcrossInstances() throws {
        let cpu = makeItem()
        let disk = makeItem(sourceKind: .serverDoctor, sourceId: "disk-full")
        try store.ingest([cpu], source: .metric, profileId: "profile-1", now: t0)
        try store.ingest([disk], source: .serverDoctor, profileId: "profile-1", now: t0)
        try store.snooze(cpu.id, until: t0.addingTimeInterval(3_600))
        try store.resolve(disk.id, now: t0.addingTimeInterval(10))
        try store.markSeen(now: t0.addingTimeInterval(20))

        let reopened = AttentionInboxStore(directoryURL: directory)
        #expect(reopened.allItems().count == 2)
        #expect(reopened.isSnoozed(cpu.id, now: t0.addingTimeInterval(60)))
        #expect(reopened.resolvedItems().map(\.id) == [disk.id])
        #expect(reopened.newItems(now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test("Pruning to the saved profile list drops orphaned hosts")
    func pruneKeepsOnlyKnownProfiles() throws {
        try store.ingest([makeItem()], source: .metric, profileId: "profile-1", now: t0)
        try store.ingest([makeItem(profileId: "deleted")], source: .metric, profileId: "deleted", now: t0)
        try store.snooze("deleted:metric:cpu", until: t0.addingTimeInterval(3_600))

        try store.prune(keepingProfileIds: ["profile-1"])
        #expect(store.allItems().map(\.profileId) == ["profile-1"])
        #expect(!store.isSnoozed("deleted:metric:cpu", now: t0))
    }
}
