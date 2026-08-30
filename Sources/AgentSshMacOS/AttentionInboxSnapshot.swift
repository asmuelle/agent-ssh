import Foundation

/// An immutable read model of the whole inbox at one instant.
///
/// The panel re-renders on a one-second timeline and asks several
/// questions per frame (what is active, what is snoozed, which hosts are
/// quiet). Answering each of those from `AttentionInboxStore` would mean
/// a file read per question per second, so the store hands out one
/// snapshot and every query below is pure and in-memory.
///
/// The store's own queries delegate here too, so the persisted path and
/// the rendered path can never drift apart.
public struct AttentionInboxSnapshot: Equatable, Sendable {
    public var items: [AttentionItem]
    public var snoozedUntil: [String: Date]
    public var resolutions: [String: AttentionResolution]
    public var reactivatedAt: [String: Date]
    /// When the user last looked at the inbox — the "N new" watermark.
    public var lastSeenAt: Date?

    public init(
        items: [AttentionItem] = [],
        snoozedUntil: [String: Date] = [:],
        resolutions: [String: AttentionResolution] = [:],
        reactivatedAt: [String: Date] = [:],
        lastSeenAt: Date? = nil
    ) {
        self.items = items
        self.snoozedUntil = snoozedUntil
        self.resolutions = resolutions
        self.reactivatedAt = reactivatedAt
        self.lastSeenAt = lastSeenAt
    }

    // MARK: Visibility

    /// What the inbox shows: confirmed, unsnoozed, unresolved — most
    /// urgent tier first, oldest first within a tier, so the list does
    /// not reshuffle under the user's cursor.
    public func activeItems(now: Date, profileId: String? = nil) -> [AttentionItem] {
        items
            .filter {
                (profileId == nil || $0.profileId == profileId)
                    && $0.isConfirmed(now: now)
                    && !isSnoozed($0.id, now: now)
                    && resolutions[$0.id] == nil
            }
            .sorted(by: Self.displayOrder)
    }

    public func snoozedItems(now: Date) -> [AttentionItem] {
        items
            .filter {
                $0.isConfirmed(now: now)
                    && isSnoozed($0.id, now: now)
                    && resolutions[$0.id] == nil
            }
            .sorted(by: Self.displayOrder)
    }

    public func resolvedItems() -> [AttentionItem] {
        items
            .filter { resolutions[$0.id] != nil }
            .sorted(by: Self.displayOrder)
    }

    public func isSnoozed(_ id: String, now: Date) -> Bool {
        guard let until = snoozedUntil[id] else { return false }
        return until > now
    }

    /// Active items that became *visible* after the user last looked.
    /// Visibility, not ingestion, is the comparison: the user cannot have
    /// seen an item still inside its confirmation window, and an item
    /// escalation woke from a snooze or resolution became visible then.
    public func newItems(now: Date) -> [AttentionItem] {
        newItems(now: now, since: lastSeenAt)
    }

    /// The same question against an explicit watermark. The panel pins
    /// the watermark it found on open and keeps counting against it for
    /// the whole visit — otherwise marking the inbox seen would erase the
    /// "N new" badge in the same frame that showed it.
    public func newItems(now: Date, since watermark: Date?) -> [AttentionItem] {
        guard let watermark else { return activeItems(now: now) }
        return activeItems(now: now).filter { visibleSince($0) > watermark }
    }

    private func visibleSince(_ item: AttentionItem) -> Date {
        let confirmedAt = item.firstSeen.addingTimeInterval(item.sourceKind.confirmationDelay)
        return max(confirmedAt, reactivatedAt[item.id] ?? .distantPast)
    }

    // MARK: Grouping

    /// One section per non-empty tier, most urgent first. The panel
    /// renders these as headed groups so "act now" can never be read as
    /// just another row in a long list.
    public func tierSections(now: Date) -> [(tier: AttentionTier, items: [AttentionItem])] {
        let active = activeItems(now: now)
        return AttentionTier.allCases
            .sorted(by: >)
            .compactMap { tier in
                let matching = active.filter { $0.tier == tier }
                return matching.isEmpty ? nil : (tier, matching)
            }
    }

    /// The most urgent visible tier, or nil when nothing needs the user —
    /// the single at-a-glance signal for badges.
    public func worstTier(now: Date) -> AttentionTier? {
        activeItems(now: now).map(\.tier).max()
    }

    /// Profiles with at least one visible item, sorted for stable display.
    public func profileIdsNeedingAttention(now: Date) -> [String] {
        Array(Set(activeItems(now: now).map(\.profileId))).sorted()
    }

    // MARK: Ordering

    static func displayOrder(_ lhs: AttentionItem, _ rhs: AttentionItem) -> Bool {
        if lhs.tier != rhs.tier {
            return lhs.tier > rhs.tier
        }
        if lhs.firstSeen != rhs.firstSeen {
            return lhs.firstSeen < rhs.firstSeen
        }
        return lhs.id < rhs.id
    }
}
