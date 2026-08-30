import AgentSshMacOS
import SwiftUI

/// Exception-based alternative to the dashboard: silent about what
/// needs no attention, loud about what needs to be fixed.
///
/// "Dark cockpit" principle — when nothing is wrong the view is almost
/// empty, and when something is wrong the whole surface reorganizes
/// around the problem, grouped by how urgently it needs the user, with
/// the resolving action on every row.
///
/// Reads the persistent attention inbox rather than live monitor state,
/// so a finding survives a disconnect and a restart, and a host nobody is
/// currently connected to can still be represented honestly.
struct AgentPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @ObservedObject private var inbox = AttentionInboxIngest.shared

    /// Open Server Doctor for a tab (owned by `ContentView`).
    var onDiagnose: ((TerminalTab) -> Void)? = nil
    /// Activate a host's workspace and leave the Agent view.
    var onOpenHost: ((UUID) -> Void)? = nil

    /// The watermark as it stood when this visit began. Pinned, because
    /// opening the panel marks the inbox seen: counting against the live
    /// watermark would zero the "N new" badge in the same frame that
    /// first drew it, so the user would never see what arrived.
    @State private var visitWatermark: Date?
    @State private var hasMarkedSeen = false

    /// Snooze choices. An hour is the "I'm on it" case; the longer ones
    /// exist so a genuine "not this week" does not have to be re-dismissed
    /// every hour, which is how a feed teaches people to ignore it.
    private enum SnoozeChoice: String, CaseIterable, Identifiable {
        case hour, tomorrow, week

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hour: return "1 hour"
            case .tomorrow: return "Tomorrow"
            case .week: return "1 week"
            }
        }

        func until(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .hour:
                return now.addingTimeInterval(60 * 60)
            case .tomorrow:
                // Tomorrow morning, not next midnight: at 23:30 the next
                // midnight is half an hour away, which would make this
                // option shorter than the "1 hour" above it. Floored
                // against that hour so the ladder can never invert.
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                let morning = calendar.date(
                    bySettingHour: 8, minute: 0, second: 0, of: tomorrow
                ) ?? calendar.startOfDay(for: tomorrow)
                return max(morning, now.addingTimeInterval(60 * 60))
            case .week:
                return now.addingTimeInterval(7 * 24 * 60 * 60)
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .materialBackground(.contentBackground, blendingMode: .withinWindow)
        .onAppear {
            // Only once per mount: a re-appear (tab switch back) must not
            // discard the watermark this visit is still counting against.
            guard !hasMarkedSeen else { return }
            hasMarkedSeen = true
            visitWatermark = inbox.snapshot.lastSeenAt
            inbox.markSeen()
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let snapshot = inbox.snapshot
        let sections = snapshot.tierSections(now: now)
        let snoozed = snapshot.snoozedItems(now: now)

        VStack(spacing: 0) {
            header(snapshot: snapshot, now: now)
            Divider()

            if sections.isEmpty {
                quietState(now: now)
            } else {
                sectionList(sections, now: now)
            }

            if !snoozed.isEmpty || !snapshot.resolvedItems().isEmpty {
                footer(snapshot: snapshot, now: now)
            }
        }
    }

    // MARK: - Header

    private func header(snapshot: AttentionInboxSnapshot, now: Date) -> some View {
        let active = snapshot.activeItems(now: now)
        let newCount = snapshot.newItems(now: now, since: visitWatermark).count

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent")
                    .font(MidnightMacDesign.FontToken.title)
                Label(
                    "watching \(watchedHosts.count) host\(watchedHosts.count == 1 ? "" : "s")",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if newCount > 0 {
                Text("\(newCount) new")
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.18))
                    )
                    .help("Appeared since you last opened this view")
            }

            if let worst = snapshot.worstTier(now: now) {
                Label(
                    "\(active.count) need\(active.count == 1 ? "s" : "") you",
                    systemImage: worst.symbol
                )
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(worst.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Quiet state

    /// The common case. Deliberately near-empty — but never silently so:
    /// the subtitle carries the evidence for the silence, because "we
    /// checked and found nothing" and "nothing has checked" look identical
    /// on an empty screen and mean opposite things.
    private func quietState(now: Date) -> some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.green.opacity(0.75))

            Text("Nothing needs you.")
                .font(MidnightMacDesign.FontToken.title)

            Text(quietEvidence(now: now))
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            hostDots(watchedHosts, now: now)
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    /// The evidence line. Names how many hosts were checked and how long
    /// ago, using the oldest check so the claim is never rosier than the
    /// least-recently-checked host.
    private func quietEvidence(now: Date) -> String {
        let hosts = watchedHosts
        guard !hosts.isEmpty else {
            return "No connected hosts to watch. Connect a server and the Agent starts checking it."
        }

        let checks = hosts.compactMap { inbox.lastCheckedAt[$0.profile.id] }
        let plural = hosts.count == 1 ? "" : "s"

        guard checks.count == hosts.count, let oldest = checks.min() else {
            let pending = hosts.count - checks.count
            return "\(hosts.count) host\(plural) connected · \(pending) not checked yet"
        }
        return "All \(hosts.count) host\(plural) checked \(relativeAge(of: oldest, now: now)) · nothing needs you"
    }

    // MARK: - Sections

    private func sectionList(
        _ sections: [(tier: AttentionTier, items: [AttentionItem])],
        now: Date
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.tier) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section.tier, count: section.items.count)
                        ForEach(section.items) { item in
                            itemRow(item, now: now)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ tier: AttentionTier, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: tier.symbol)
                    .foregroundStyle(tier.color)
                Text(tier.displayName)
                    .font(MidnightMacDesign.FontToken.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(tier.sectionExplanation)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: AttentionItem, now: Date) -> some View {
        let isUrgent = item.tier.isUrgent

        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.tier.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    tierTag(item.tier)

                    Text(item.hostName)
                        .font(MidnightMacDesign.FontToken.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text("· \(item.title)")
                        .font(MidnightMacDesign.FontToken.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    stalenessMark(item, now: now)

                    Text(relativeAge(of: item.firstSeen, now: now))
                        .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(item.detail)
                    .font(isUrgent
                        ? MidnightMacDesign.FontToken.title
                        : MidnightMacDesign.FontToken.subheadline)
                    .foregroundStyle(item.tier.textColor)
                    .lineLimit(3)

                if !item.whyItMatters.isEmpty {
                    Text(item.whyItMatters)
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if !item.safeNextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(item.safeNextSteps.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "arrow.turn.down.right")
                                .font(MidnightMacDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                actionRow(item)
            }
        }
        .padding(isUrgent ? 16 : 12)
        .background(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                .fill(item.tier.color.opacity(isUrgent ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                .stroke(item.tier.color.opacity(isUrgent ? 0.4 : 0.2), lineWidth: 1)
        )
    }

    private func tierTag(_ tier: AttentionTier) -> some View {
        Text(tier.tagText)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(tier.textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.xsmall)
                    .fill(tier.color.opacity(0.12))
            )
    }

    /// Marks an item whose producer has not confirmed it recently. A
    /// persisted finding about a host nobody is watching is still worth
    /// showing — but never as though it were just observed.
    @ViewBuilder
    private func stalenessMark(_ item: AttentionItem, now: Date) -> some View {
        if item.freshness(now: now) == .stale {
            Label(
                "last checked \(relativeAge(of: item.lastCheckedAt, now: now))",
                systemImage: "clock.arrow.circlepath"
            )
            .font(MidnightMacDesign.FontToken.caption)
            .foregroundStyle(.tertiary)
            .help("Nothing has re-checked this recently — it may already be fixed.")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionRow(_ item: AttentionItem) -> some View {
        let tab = tab(for: item)

        HStack(spacing: 8) {
            if item.sourceKind == .connection, let tab {
                Button {
                    Task { await tabsStore.reconnect(tabId: tab.id) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let onOpenHost, let tab {
                Button {
                    onOpenHost(tab.id)
                } label: {
                    Label("Open Host", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if tab == nil,
                      let profile = ConnectionStoreManager.shared.connection(withId: item.profileId)
            {
                // The inbox outlives its tabs on purpose, so a finding
                // about a host you are not connected to is normal. Without
                // this the only remaining actions would be the two that
                // hide the card — an inspection dead end.
                Button {
                    Task { await tabsStore.openConnection(profile) }
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reconnect to \(profile.name) to look into this")
            }

            if let onDiagnose,
               let tab,
               tab.status == .connected,
               tab.effectiveKind.supportsTerminal
            {
                Button {
                    onDiagnose(tab)
                } label: {
                    Label("Server Doctor", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Button("Mark handled") {
                inbox.resolve(item.id)
            }
            .buttonStyle(.plain)
            .font(MidnightMacDesign.FontToken.caption)
            .foregroundStyle(.tertiary)
            .help("Hide this until it clears, comes back, or gets worse. Undo from “Handled” at the bottom.")

            Menu("Snooze") {
                ForEach(SnoozeChoice.allCases) { choice in
                    Button(choice.label) {
                        inbox.snooze(item.id, until: choice.until(from: Date()))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(MidnightMacDesign.FontToken.caption)
            .foregroundStyle(.tertiary)
            .help("Hide this for a while. It comes back if it gets worse.")
        }
    }

    // MARK: - Footer (snoozed)

    private func footer(snapshot: AttentionInboxSnapshot, now: Date) -> some View {
        let snoozed = snapshot.snoozedItems(now: now)
        let handled = snapshot.resolvedItems()

        return VStack(spacing: 8) {
            Divider()

            if !snoozed.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snoozed) { item in
                            hiddenRow(
                                item,
                                // Saying when it returns is the difference
                                // between snoozing and losing something.
                                note: snapshot.snoozedUntil[item.id].map {
                                    "back \(relativeFuture(of: $0, now: now))"
                                },
                                actionTitle: "Unsnooze"
                            ) { inbox.unsnooze(item.id) }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(snoozed.count) snoozed")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
            }

            if !handled.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(handled) { item in
                            hiddenRow(item, note: nil, actionTitle: "Undo") {
                                inbox.unresolve(item.id)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(handled.count) handled")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 10)
    }

    private func hiddenRow(
        _ item: AttentionItem,
        note: String?,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.tier.symbol)
                .foregroundStyle(.tertiary)
            Text("\(item.hostName) · \(item.title): \(item.detail)")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let note {
                Text("· \(note)")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func hostDots(_ tabs: [TerminalTab], now: Date) -> some View {
        HStack(spacing: 14) {
            ForEach(tabs) { tab in
                Button {
                    onOpenHost?(tab.id)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(hostDotColor(tab, now: now))
                            .frame(width: 6, height: 6)
                        Text(tab.profile.name)
                            .font(MidnightMacDesign.FontToken.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(hostDotHelp(tab, now: now))
                .accessibilityLabel(hostDotHelp(tab, now: now))
            }
        }
    }

    /// Green only where the claim is backed by a recent check. A host
    /// nothing has polled yet gets a hollow dot rather than borrowing the
    /// reassurance of one that was actually looked at.
    private func hostDotColor(_ tab: TerminalTab, now: Date) -> Color {
        guard let checked = inbox.lastCheckedAt[tab.profile.id] else {
            return .secondary.opacity(0.35)
        }
        return now.timeIntervalSince(checked) > 5 * 60
            ? .secondary.opacity(0.35)
            : .green.opacity(0.45)
    }

    private func hostDotHelp(_ tab: TerminalTab, now: Date) -> String {
        guard let checked = inbox.lastCheckedAt[tab.profile.id] else {
            return "\(tab.profile.name) — not checked yet. Click to open."
        }
        return "\(tab.profile.name) — checked \(relativeAge(of: checked, now: now)). Click to open."
    }

    // MARK: - Helpers

    private var watchedHosts: [TerminalTab] {
        tabsStore.connectedSSHTabs
    }

    /// The live tab backing an item, if any. The inbox is profile-keyed
    /// precisely so an item outlives its tab, so every tab-shaped action
    /// has to tolerate not finding one.
    private func tab(for item: AttentionItem) -> TerminalTab? {
        tabsStore.tabs.first { $0.profile.id == item.profileId }
    }

    /// How long until a future moment, for "back in 20 min".
    private func relativeFuture(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        switch seconds {
        case ..<60: return "in under a minute"
        case ..<3600: return "in \(seconds / 60) min"
        case ..<86400: return "in \(seconds / 3600) h"
        default: return "in \(seconds / 86400) d"
        }
    }

    private func relativeAge(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }
}
