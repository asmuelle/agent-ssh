import Foundation

/// A user's mark that an item was handled or accepted. Remembering the
/// tier at resolution lets an escalation reopen the conversation: "you
/// resolved this as fix-this-week, but it is now act-now".
public struct AttentionResolution: Codable, Equatable, Sendable {
    public var resolvedAt: Date
    public var tierAtResolution: AttentionTier

    public init(resolvedAt: Date, tierAtResolution: AttentionTier) {
        self.resolvedAt = resolvedAt
        self.tierAtResolution = tierAtResolution
    }
}

private struct AttentionInboxIndex: Codable, Sendable {
    var schemaVersion = 1
    var items: [AttentionItem] = []
    var snoozedUntil: [String: Date] = [:]
    var resolutions: [String: AttentionResolution] = [:]
    /// When an item became visible again after escalation woke it from a
    /// resolution or snooze — the watermark compares against this, not
    /// just `firstSeen`, so reactivations count as new.
    var reactivatedAt: [String: Date] = [:]
    /// When the user last looked at the inbox — the "N new since you last
    /// looked" watermark.
    var lastSeenAt: Date?
}

/// The persistent attention inbox: every finding source feeds it, the UI
/// reads one severity-tiered list from it.
///
/// Semantics are adopted from `AgentTriageStore` (stable ids, hysteresis
/// via per-source confirmation delays, clear-on-absence — going quiet fast
/// is part of being trustworthy) with two deliberate departures: items are
/// keyed by profile rather than tab so they survive disconnects and
/// restarts, and the index is persisted app-group-wide following the
/// `FleetHostHealthStore` pattern so the app and its widgets share one
/// inbox truth on each device.
///
/// Writing is single-process: app code goes through `shared` so one lock
/// serializes every read-modify-write; extensions treat the file as
/// read-only. Like the other shared stores, unreadable data fails open to
/// an empty index on the next write rather than blocking the inbox.
public final class AttentionInboxStore: @unchecked Sendable {
    public static let shared = AttentionInboxStore()

    private let backing: SharedJSONFileStore<AttentionInboxIndex>
    private let lock = NSLock()

    /// Use `shared` in app code; the injectable directory exists for tests.
    public init(directoryURL: URL? = nil) {
        backing = SharedJSONFileStore(
            fileName: SharedAppStorageConfiguration.attentionInboxFileName,
            directoryURL: directoryURL
        )
    }

    // MARK: Ingestion

    /// Replace the items of one (profile, source) slice with the latest
    /// observation. Items absent from `items` clear immediately, along
    /// with their snoozes and resolutions — a cleared-and-returned issue
    /// is a new occurrence, not a continuation. Present items keep their
    /// original `firstSeen`; `lastObserved` advances to `now`.
    ///
    /// Escalation wakes hidden items: a resolved item whose tier rises
    /// past its resolution tier reactivates, and a snoozed item whose tier
    /// rises past the tier it had when last observed wakes from its
    /// snooze. Either way the item counts as new for `newItems`.
    ///
    /// Items whose `profileId` or `sourceKind` do not match the declared
    /// slice are ignored (one producer may never write into another's
    /// slice), and duplicate ids within one batch collapse, last wins.
    public func ingest(
        _ items: [AttentionItem],
        source: AttentionSourceKind,
        profileId: String,
        now: Date = Date()
    ) throws {
        // Duplicate ids must never reach the index: a persisted duplicate
        // would corrupt every later lookup keyed by id.
        var incoming: [AttentionItem] = []
        var incomingIndexById: [String: Int] = [:]
        for item in items where item.sourceKind == source && item.profileId == profileId {
            if let existing = incomingIndexById[item.id] {
                incoming[existing] = item
            } else {
                incomingIndexById[item.id] = incoming.count
                incoming.append(item)
            }
        }

        try mutate { index in
            // Tolerant of duplicate ids in a previously-persisted index —
            // trapping here would make one bad file permanently fatal.
            let previousById = Dictionary(
                index.items.map { ($0.id, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            let incomingIds = Set(incoming.map(\.id))

            func belongsToSlice(_ id: String) -> Bool {
                previousById[id]?.profileId == profileId
                    && previousById[id]?.sourceKind == source
            }

            // Clear-on-absence for this slice only, with attached state.
            index.items.removeAll {
                $0.profileId == profileId && $0.sourceKind == source
            }
            for id in index.snoozedUntil.keys
                where belongsToSlice(id) && !incomingIds.contains(id)
            {
                index.snoozedUntil.removeValue(forKey: id)
            }
            for id in index.resolutions.keys
                where belongsToSlice(id) && !incomingIds.contains(id)
            {
                index.resolutions.removeValue(forKey: id)
            }
            for id in index.reactivatedAt.keys
                where belongsToSlice(id) && !incomingIds.contains(id)
            {
                index.reactivatedAt.removeValue(forKey: id)
            }

            for var item in incoming {
                let previous = previousById[item.id]
                item.firstSeen = previous?.firstSeen ?? item.firstSeen
                item.lastObserved = now
                if let resolution = index.resolutions[item.id],
                   item.tier > resolution.tierAtResolution
                {
                    index.resolutions.removeValue(forKey: item.id)
                    index.reactivatedAt[item.id] = now
                }
                if index.snoozedUntil[item.id] != nil,
                   let previous, item.tier > previous.tier
                {
                    index.snoozedUntil.removeValue(forKey: item.id)
                    index.reactivatedAt[item.id] = now
                }
                index.items.append(item)
            }
        }
    }

    /// Drop every item (and attached state) belonging to profiles that no
    /// longer exist, mirroring `FleetHostHealthStore.prune`.
    public func prune(keepingProfileIds: [String]) throws {
        let kept = Set(keepingProfileIds)
        try mutate { index in
            let removedIds = Set(
                index.items.filter { !kept.contains($0.profileId) }.map(\.id)
            )
            index.items.removeAll { !kept.contains($0.profileId) }
            for id in removedIds {
                index.snoozedUntil.removeValue(forKey: id)
                index.resolutions.removeValue(forKey: id)
                index.reactivatedAt.removeValue(forKey: id)
            }
        }
    }

    // MARK: Queries

    /// One immutable read of the whole inbox. The UI renders from this so
    /// a one-second render loop asks its questions in memory instead of
    /// re-reading the file for each one.
    public func snapshot() -> AttentionInboxSnapshot {
        let index = loadIndex()
        return AttentionInboxSnapshot(
            items: index.items,
            snoozedUntil: index.snoozedUntil,
            resolutions: index.resolutions,
            reactivatedAt: index.reactivatedAt,
            lastSeenAt: index.lastSeenAt
        )
    }

    /// Everything persisted, regardless of visibility. For debugging and
    /// adapters; the UI wants `activeItems`.
    public func allItems() -> [AttentionItem] {
        loadIndex().items
    }

    /// What the inbox shows: confirmed, unsnoozed, unresolved — most
    /// urgent tier first, oldest first within a tier, so the list does
    /// not reshuffle under the user's cursor.
    public func activeItems(now: Date = Date()) -> [AttentionItem] {
        snapshot().activeItems(now: now)
    }

    public func snoozedItems(now: Date = Date()) -> [AttentionItem] {
        snapshot().snoozedItems(now: now)
    }

    public func resolvedItems() -> [AttentionItem] {
        snapshot().resolvedItems()
    }

    public func isSnoozed(_ id: String, now: Date = Date()) -> Bool {
        snapshot().isSnoozed(id, now: now)
    }

    /// Active items that became *visible* after the user last looked.
    public func newItems(now: Date = Date()) -> [AttentionItem] {
        snapshot().newItems(now: now)
    }

    // MARK: Lifecycle

    public func snooze(_ id: String, until: Date) throws {
        try mutate { index in
            guard index.items.contains(where: { $0.id == id }) else { return }
            index.snoozedUntil[id] = until
        }
    }

    public func unsnooze(_ id: String) throws {
        try mutate { $0.snoozedUntil.removeValue(forKey: id) }
    }

    /// Mark an item handled/accepted. It stays out of the active list even
    /// while the condition persists, until it either clears (absence) or
    /// escalates past the tier it was resolved at.
    public func resolve(_ id: String, now: Date = Date()) throws {
        try mutate { index in
            guard let item = index.items.first(where: { $0.id == id }) else { return }
            index.resolutions[id] = AttentionResolution(
                resolvedAt: now,
                tierAtResolution: item.tier
            )
        }
    }

    public func unresolve(_ id: String) throws {
        try mutate { $0.resolutions.removeValue(forKey: id) }
    }

    /// Record that the user looked at the inbox — resets `newItems`.
    public func markSeen(now: Date = Date()) throws {
        try mutate { $0.lastSeenAt = now }
    }

    // MARK: Helpers

    private func loadIndex() -> AttentionInboxIndex {
        lock.withLock {
            (try? backing.load()) ?? AttentionInboxIndex()
        }
    }

    private func mutate(_ change: (inout AttentionInboxIndex) -> Void) throws {
        try lock.withLock {
            var index = (try? backing.load()) ?? AttentionInboxIndex()
            change(&index)
            try backing.save(index)
        }
    }
}
