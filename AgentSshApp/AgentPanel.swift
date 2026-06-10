import AgentSshMacOS
import SwiftUI

/// Exception-based alternative to the dashboard: silent about what
/// needs no attention, loud about what needs to be fixed.
///
/// "Dark cockpit" principle — when nothing is wrong the view is almost
/// empty (one quiet line plus dim host dots), and when something is
/// wrong the whole surface reorganizes around the problem, sorted by
/// severity, with the resolving action on every row.
struct AgentPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @ObservedObject private var triage = AgentTriageStore.shared

    /// Open Server Doctor for a tab (owned by `ContentView`).
    var onDiagnose: ((TerminalTab) -> Void)? = nil
    /// Activate a host's workspace and leave the Agent view.
    var onOpenHost: ((UUID) -> Void)? = nil

    private static let snoozeInterval: TimeInterval = 60 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .materialBackground(.contentBackground, blendingMode: .withinWindow)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let issues = triage.confirmedIssues(now: now)
        let snoozed = triage.snoozedIssues(now: now)

        VStack(spacing: 0) {
            header(issueCount: issues.count)
            Divider()

            if issues.isEmpty {
                quietState(now: now)
            } else {
                issueList(issues, now: now)
            }

            if !snoozed.isEmpty || !issues.isEmpty {
                footer(issues: issues, snoozed: snoozed, now: now)
            }
        }
    }

    // MARK: - Header

    private func header(issueCount: Int) -> some View {
        HStack(spacing: 10) {
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

            if issueCount > 0 {
                Label(
                    "\(issueCount) issue\(issueCount == 1 ? "" : "s") need\(issueCount == 1 ? "s" : "") attention",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Quiet state

    /// The common case. Deliberately near-empty: no gauges, no green
    /// checkmark per host, no numbers — healthy metrics are noise here.
    private func quietState(now: Date) -> some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.green.opacity(0.75))

            Text("All quiet.")
                .font(MidnightMacDesign.FontToken.title)

            Text(quietSubtitle)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)

            hostDots(quietHosts(now: now))
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quietSubtitle: String {
        if watchedHosts.isEmpty {
            return "No connected hosts to watch."
        }
        return "\(watchedHosts.count) host\(watchedHosts.count == 1 ? "" : "s") connected · nothing needs you"
    }

    // MARK: - Issue list

    private func issueList(_ issues: [TriageIssue], now: Date) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(issues) { issue in
                    issueRow(issue, now: now)
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func issueRow(_ issue: TriageIssue, now: Date) -> some View {
        let isCritical = issue.severity == .critical

        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(issue.severity.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    severityTag(issue.severity)

                    Text(issue.hostName)
                        .font(MidnightMacDesign.FontToken.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text("· \(issue.title)")
                        .font(MidnightMacDesign.FontToken.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(relativeAge(of: issue.firstSeen, now: now))
                        .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Label(issue.detail, systemImage: issue.icon)
                    .font(isCritical
                        ? MidnightMacDesign.FontToken.title
                        : MidnightMacDesign.FontToken.subheadline)
                    .foregroundStyle(isCritical ? AnyShapeStyle(issue.severity.color) : AnyShapeStyle(.primary))
                    .lineLimit(2)

                actionRow(issue)
            }
        }
        .padding(isCritical ? 16 : 12)
        .background(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                .fill(issue.severity.color.opacity(isCritical ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                .stroke(issue.severity.color.opacity(isCritical ? 0.4 : 0.2), lineWidth: 1)
        )
    }

    private func severityTag(_ severity: DashboardHealthIssue.Severity) -> some View {
        Text(severity == .critical ? "CRITICAL" : "WARNING")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(severity.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.xsmall)
                    .fill(severity.color.opacity(0.12))
            )
    }

    @ViewBuilder
    private func actionRow(_ issue: TriageIssue) -> some View {
        let tab = tabsStore.tabs.first { $0.id == issue.tabId }

        HStack(spacing: 8) {
            if issue.kind == .connection {
                Button {
                    Task { await tabsStore.reconnect(tabId: issue.tabId) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let onOpenHost {
                Button {
                    onOpenHost(issue.tabId)
                } label: {
                    Label("Open Host", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

            Button("Snooze 1h") {
                triage.snooze(issue.id, for: Self.snoozeInterval)
            }
            .buttonStyle(.plain)
            .font(MidnightMacDesign.FontToken.caption)
            .foregroundStyle(.tertiary)
            .help("Hide this issue for an hour")
        }
    }

    // MARK: - Footer (quiet hosts + snoozed)

    @ViewBuilder
    private func footer(issues: [TriageIssue], snoozed: [TriageIssue], now: Date) -> some View {
        let quiet = quietHosts(now: now)

        VStack(spacing: 8) {
            Divider()

            if !issues.isEmpty && !quiet.isEmpty {
                HStack(spacing: 14) {
                    hostDots(quiet)
                    Text("\(quiet.count) host\(quiet.count == 1 ? "" : "s") healthy")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if !snoozed.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snoozed) { issue in
                            HStack(spacing: 8) {
                                Image(systemName: issue.icon)
                                    .foregroundStyle(.tertiary)
                                Text("\(issue.hostName) · \(issue.title): \(issue.detail)")
                                    .font(MidnightMacDesign.FontToken.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("Unsnooze") { triage.unsnooze(issue.id) }
                                    .buttonStyle(.plain)
                                    .font(MidnightMacDesign.FontToken.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
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
        }
        .padding(.bottom, 10)
    }

    private func hostDots(_ tabs: [TerminalTab]) -> some View {
        HStack(spacing: 14) {
            ForEach(tabs) { tab in
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(tab.profile.name)
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .onTapGesture(count: 2) { onOpenHost?(tab.id) }
                .help("Double-click to open \(tab.profile.name)")
            }
        }
    }

    // MARK: - Helpers

    private var watchedHosts: [TerminalTab] {
        tabsStore.connectedSSHTabs
    }

    /// Connected hosts with no confirmed issue — the ones the view
    /// stays silent about. Takes `now` from the enclosing TimelineView
    /// so the quiet set and the issue list are sampled at the same
    /// instant within a render frame.
    private func quietHosts(now: Date) -> [TerminalTab] {
        let loudTabIds = Set(
            triage.confirmedIssues(now: now).map(\.tabId)
        )
        return watchedHosts.filter { !loudTabIds.contains($0.id) }
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
