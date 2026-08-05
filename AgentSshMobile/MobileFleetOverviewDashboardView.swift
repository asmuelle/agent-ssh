import SwiftUI

/// Landing dashboard shown after auto-connect when at least one server is
/// connected. Surfaces a fleet summary, a "needs attention" section, and a grid
/// of live server tiles. Tiles are `NavigationLink`s; the parent supplies the
/// `NavigationStack` and `.navigationDestination(for: String.self)`.
struct MobileFleetOverviewDashboardView: View {
    let profiles: [MobileConnectionProfile]
    let onAddConnection: () -> Void

    @EnvironmentObject private var sessionStore: MobileSessionStore
    @EnvironmentObject private var healthStore: MobileServerHealthStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The row whose inline expansion is open.
    @State private var expandedProfileId: String?

    private let refreshInterval: Duration = .seconds(30)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.xlarge) {
                summaryHeader

                if items.isEmpty {
                    emptyState
                } else {
                    serversSection
                }
            }
            .padding()
        }
        .background(MidnightMobileDesign.ColorToken.groupedBackground)
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await healthStore.refresh(profiles: profiles, sessionStore: sessionStore)
        }
        .task {
            await healthStore.refresh(profiles: profiles, sessionStore: sessionStore)
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                if Task.isCancelled { break }
                await healthStore.refresh(profiles: profiles, sessionStore: sessionStore)
            }
        }
        .onChange(of: connectedSignature) { _, _ in
            Task { await healthStore.refresh(profiles: profiles, sessionStore: sessionStore) }
        }
    }

    // MARK: - Summary

    private var summaryHeader: some View {
        let connected = items.filter(\.isConnected).count
        let attention = items.filter { $0.severity.needsAttention }.count

        return VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.large) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline(attention: attention))
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if healthStore.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let lastUpdated {
                    // One fleet-wide refresh timestamp — mirrors the
                    // macOS dashboard toolbar.
                    Text("Updated \(lastUpdated.formatted(.dateTime.hour().minute().second()))")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: MidnightMobileDesign.Spacing.large) {
                summaryStat(value: "\(connected)", label: "Connected", color: .green)
                summaryStat(
                    value: "\(attention)",
                    label: "Need attention",
                    color: attention > 0 ? .orange : .secondary
                )
                summaryStat(value: "\(profiles.count)", label: "Configured", color: .secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidnightMobileDesign.ColorToken.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.large))
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(attention: Int) -> String {
        if attention == 0 { return "All systems nominal" }
        return "\(attention) server\(attention == 1 ? "" : "s") need attention"
    }

    // MARK: - Servers list

    /// Attention-sorted list: one row per server, worst first, with
    /// issues inline on the row. Tapping a row expands it in place —
    /// full issue list, disks, and meta, mirroring the macOS fleet
    /// table — and "Open server" in the expansion navigates to the
    /// detail page.
    private var serversSection: some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.large) {
            sectionTitle("Servers", systemImage: "server.rack")
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    serverEntry(item)
                }
            }
        }
    }

    /// One list entry: the tappable row plus its inline expansion,
    /// sharing one card background so they read as a unit.
    private func serverEntry(_ item: FleetItem) -> some View {
        let isExpanded = expandedProfileId == item.profile.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedProfileId = isExpanded ? nil : item.profile.id
                }
            } label: {
                serverRow(item, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                serverExpansion(item)
            }
        }
        .background(
            // Warm wash on rows that need attention so the healthy
            // majority reads as one quiet block.
            item.severity.needsAttention
                ? item.severity.color.opacity(0.10)
                : MidnightMobileDesign.ColorToken.secondaryGroupedBackground,
            in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium)
                .strokeBorder(item.severity.needsAttention ? item.severity.color.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    /// Compact list row: one host per line with aligned metric
    /// columns — easier to scan than cards once the fleet grows.
    private func serverRow(_ item: FleetItem, isExpanded: Bool = false) -> some View {
        HStack(spacing: MidnightMobileDesign.Spacing.large) {
            Circle().fill(item.statusColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.profile.name)
                    .font(MidnightMobileDesign.FontToken.headline)
                    .lineLimit(1)
                // Second line: warnings belong on the row they're
                // about. Healthy rows show the endpoint instead (iPad
                // only — on iPhone widths it would squeeze the metric
                // columns, and it lives on the detail page anyway).
                if let issue = item.issues.first {
                    HStack(spacing: 4) {
                        Image(systemName: issue.systemImage)
                        Text(
                            item.issues.count > 1
                                ? "\(issue.title) +\(item.issues.count - 1)"
                                : issue.title
                        )
                        .lineLimit(1)
                    }
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(item.severity.color)
                } else if horizontalSizeClass != .compact {
                    Text("\(item.profile.username)@\(item.profile.host):\(item.profile.port)")
                        .font(MidnightMobileDesign.FontToken.metadataMono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let sample = item.snapshot?.sample {
                rowMetric("CPU", percent: sample.cpuPercent)
                rowMetric("MEM", percent: sample.memoryPercent)
                rowMetric("DISK", percent: sample.primaryDisk?.usedPercent)
            } else {
                Text(item.statusLabel)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(item.statusColor)
                    .lineLimit(1)
                    .frame(
                        width: horizontalSizeClass == .compact ? 120 : 170,
                        alignment: .trailing
                    )
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Inline expansion under a row: every issue with its detail, disk
    /// fill levels, swap, a metadata line, and the navigation to the
    /// full server page. Mirrors the macOS fleet table's detail band
    /// at mobile scale.
    private func serverExpansion(_ item: FleetItem) -> some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.medium) {
            Divider()

            ForEach(item.issues) { issue in
                HStack(alignment: .top, spacing: MidnightMobileDesign.Spacing.medium) {
                    Image(systemName: issue.systemImage)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(issue.severity.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.title)
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                        Text(issue.detail)
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            Text(expansionMetaLine(item))
                .font(MidnightMobileDesign.FontToken.metadataMono)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let sample = item.snapshot?.sample {
                ForEach(sample.disks, id: \.mount) { disk in
                    HStack(spacing: MidnightMobileDesign.Spacing.medium) {
                        Text(disk.mount)
                            .font(MidnightMobileDesign.FontToken.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(bytes(disk.used)) / \(bytes(disk.total))")
                            .font(MidnightMobileDesign.FontToken.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", disk.usedPercent))
                            .font(MidnightMobileDesign.FontToken.captionStrong.monospacedDigit())
                            .foregroundStyle(metricColor(disk.usedPercent))
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                if sample.swapTotal > 0 {
                    HStack(spacing: MidnightMobileDesign.Spacing.medium) {
                        Text("Swap")
                            .font(MidnightMobileDesign.FontToken.caption)
                        Spacer()
                        Text("\(bytes(sample.swapUsed)) / \(bytes(sample.swapTotal))")
                            .font(MidnightMobileDesign.FontToken.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink(value: item.profile.id) {
                Label("Open server", systemImage: "arrow.right.circle")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private func expansionMetaLine(_ item: FleetItem) -> String {
        var parts = ["\(item.profile.username)@\(item.profile.host):\(item.profile.port)"]
        if let sample = item.snapshot?.sample {
            parts.append("up \(uptimeText(sample.uptimeSeconds))")
            parts.append(String(format: "load %.2f", sample.loadAverage1m))
        } else {
            parts.append(item.statusLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func uptimeText(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        if days > 0 { return "\(days)d" }
        let hours = seconds / 3_600
        if hours > 0 { return "\(hours)h" }
        return "\(seconds / 60)m"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// Fixed-width metric column so values line up across list rows.
    private func rowMetric(_ label: String, percent: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(percent.map { String(format: "%.0f%%", $0) } ?? "–")
                .font(MidnightMobileDesign.FontToken.captionStrong.monospacedDigit())
                .foregroundStyle(percent.map(metricColor) ?? Color(.tertiaryLabel))
        }
        .frame(width: 46, alignment: .trailing)
    }

    private func metricColor(_ percent: Double) -> Color {
        if percent >= MobileServerHealthThresholds.criticalPercent { return .red }
        if percent >= MobileServerHealthThresholds.warningPercent { return .orange }
        return .primary
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(MidnightMobileDesign.FontToken.headline)
    }

    private var emptyState: some View {
        VStack(spacing: MidnightMobileDesign.Spacing.large) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Connections Yet")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Add an SSH or SFTP connection and it will appear here.")
                .font(MidnightMobileDesign.FontToken.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAddConnection) {
                Label("Add Connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Derived model

    private var items: [FleetItem] {
        profiles
            .map { profile in
                FleetItem(
                    profile: profile,
                    sessionStatus: sessionStore.status(for: profile),
                    snapshot: healthStore.snapshot(for: profile.id)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
                if lhs.hotness != rhs.hotness { return lhs.hotness > rhs.hotness }
                return lhs.profile.name.localizedStandardCompare(rhs.profile.name) == .orderedAscending
            }
    }

    /// Most recent health-snapshot time across the fleet — shown once
    /// in the summary header instead of per tile.
    private var lastUpdated: Date? {
        items.compactMap { $0.snapshot?.updatedAt }.max()
    }

    private var connectedSignature: String {
        profiles
            .compactMap { profile -> String? in
                if case .connected = sessionStore.status(for: profile) { return profile.id }
                return nil
            }
            .sorted()
            .joined(separator: ",")
    }
}

/// View-model combining a profile's session state with its health snapshot.
private struct FleetItem: Identifiable {
    let profile: MobileConnectionProfile
    let sessionStatus: MobileSessionStatus
    let snapshot: MobileServerHealthSnapshot?

    var id: String { profile.id }

    var isConnected: Bool {
        if case .connected = sessionStatus { return true }
        return false
    }

    /// Overall severity: a failed session is critical; otherwise the health
    /// snapshot's severity (ok when not yet probed).
    var severity: MobileServerSeverity {
        if case .failed = sessionStatus { return .critical }
        return snapshot?.severity ?? .ok
    }

    /// Issues for the attention card: connection failure (if any) plus health issues.
    var issues: [MobileServerHealthIssue] {
        var result: [MobileServerHealthIssue] = []
        if case .failed(let message) = sessionStatus {
            result.append(
                MobileServerHealthIssue(
                    id: "connection",
                    title: "Connection failed",
                    detail: message,
                    severity: .critical,
                    systemImage: "wifi.slash"
                )
            )
        }
        result.append(contentsOf: snapshot?.issues ?? [])
        return result
    }

    var statusColor: Color {
        MidnightMobileDesign.statusColor(sessionStatus)
    }

    var statusLabel: String {
        switch sessionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .failed(let message): return message
        }
    }

    /// Tiebreaker within a sort rank: the server's peak metric
    /// percent, quantized to 5% steps so ordering stays stable
    /// across refresh ticks.
    var hotness: Double {
        guard let sample = snapshot?.sample else { return 0 }
        let peak = max(
            sample.cpuPercent,
            sample.memoryPercent,
            sample.primaryDisk?.usedPercent ?? 0
        )
        return (peak / 5).rounded() * 5
    }

    /// Sort: needs-attention first (critical, then warning), then healthy
    /// connected, connecting, and finally disconnected.
    var sortRank: Int {
        if case .failed = sessionStatus { return 0 }
        switch severity {
        case .critical: return 0
        case .warning: return 1
        case .ok: break
        }
        switch sessionStatus {
        case .connected: return 2
        case .connecting: return 3
        case .disconnected: return 4
        case .failed: return 0
        }
    }
}

extension MobileServerSeverity {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
