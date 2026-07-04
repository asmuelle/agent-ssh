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

    private let refreshInterval: Duration = .seconds(30)
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.xlarge) {
                summaryHeader

                if items.isEmpty {
                    emptyState
                } else {
                    attentionSection
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
                Spacer()
                if healthStore.isRefreshing {
                    ProgressView().controlSize(.small)
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

    // MARK: - Needs attention

    @ViewBuilder
    private var attentionSection: some View {
        let flagged = items.filter { $0.severity.needsAttention }

        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.large) {
            sectionTitle("Needs Attention", systemImage: "exclamationmark.triangle.fill")

            if flagged.isEmpty {
                Label("Every connected server is healthy.", systemImage: "checkmark.circle.fill")
                    .font(MidnightMobileDesign.FontToken.subheadline)
                    .foregroundStyle(.green)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium))
            } else {
                ForEach(flagged) { item in
                    NavigationLink(value: item.profile.id) {
                        attentionCard(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func attentionCard(_ item: FleetItem) -> some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.medium) {
            HStack(spacing: MidnightMobileDesign.Spacing.medium) {
                Circle().fill(item.severity.color).frame(width: 10, height: 10)
                Text(item.profile.name)
                    .font(MidnightMobileDesign.FontToken.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            }

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
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidnightMobileDesign.ColorToken.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium)
                .strokeBorder(item.severity.color.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Servers grid

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.large) {
            sectionTitle("Servers", systemImage: "server.rack")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(value: item.profile.id) {
                        serverTile(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func serverTile(_ item: FleetItem) -> some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.medium) {
            HStack(spacing: MidnightMobileDesign.Spacing.medium) {
                Circle().fill(item.statusColor).frame(width: 10, height: 10)
                Text(item.profile.name)
                    .font(MidnightMobileDesign.FontToken.headline)
                    .lineLimit(1)
                Spacer()
                if item.profile.favorite {
                    Image(systemName: "star.fill")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.yellow)
                }
            }

            Text("\(item.profile.username)@\(item.profile.host):\(item.profile.port)")
                .font(MidnightMobileDesign.FontToken.metadataMono)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let sample = item.snapshot?.sample {
                metricsRow(sample)
            } else {
                Text(item.statusLabel)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(item.statusColor)
                    .lineLimit(2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(MidnightMobileDesign.ColorToken.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium)
                .strokeBorder(item.severity.needsAttention ? item.severity.color.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private func metricsRow(_ sample: MobileServerResourceSample) -> some View {
        HStack(spacing: MidnightMobileDesign.Spacing.large) {
            miniMetric("CPU", percent: sample.cpuPercent)
            miniMetric("MEM", percent: sample.memoryPercent)
            if let disk = sample.primaryDisk {
                miniMetric("DISK", percent: disk.usedPercent)
            }
        }
    }

    private func miniMetric(_ label: String, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(String(format: "%.0f%%", percent))
                .font(MidnightMobileDesign.FontToken.captionStrong.monospacedDigit())
                .foregroundStyle(metricColor(percent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                return lhs.profile.name.localizedStandardCompare(rhs.profile.name) == .orderedAscending
            }
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
