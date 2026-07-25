import SwiftUI

/// Landing dashboard shown after auto-connect when at least one server is
/// connected. Presents the fleet as a single transposed table — one row per
/// server (worst-first), columns for the key signals — instead of a separate
/// "needs attention" list plus a servers grid, which rendered every host twice.
/// Rows are `NavigationLink`s; the parent supplies the `NavigationStack` and
/// `.navigationDestination(for: String.self)`.
struct MobileFleetOverviewDashboardView: View {
    let profiles: [MobileConnectionProfile]
    let onAddConnection: () -> Void

    @EnvironmentObject private var sessionStore: MobileSessionStore
    @EnvironmentObject private var healthStore: MobileServerHealthStore
    @State private var expandedRows: Set<String> = []

    private let refreshInterval: Duration = .seconds(30)

    /// Server + CPU + Mem + Disk + Svc + Ports.
    private let columnCount = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.xlarge) {
                summaryHeader

                if items.isEmpty {
                    emptyState
                } else {
                    if let failure = crossFleetFailure {
                        crossFleetBanner(failure)
                    }
                    fleetTable
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

    // MARK: - Cross-fleet banner

    /// The service failing on the most hosts (≥2). For a fleet run by AI agents,
    /// "certbot is broken everywhere" is the headline that per-host cards bury.
    private var crossFleetFailure: (service: String, hosts: Int)? {
        var counts: [String: Int] = [:]
        for item in items {
            for service in Set(item.failedServices) {
                counts[service, default: 0] += 1
            }
        }
        guard let top = counts.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value }) else {
            return nil
        }
        return (top.key, top.value)
    }

    private func crossFleetBanner(_ failure: (service: String, hosts: Int)) -> some View {
        HStack(spacing: MidnightMobileDesign.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(failure.service) failing on \(failure.hosts) hosts")
                .font(MidnightMobileDesign.FontToken.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Fleet table

    private var fleetTable: some View {
        VStack(alignment: .leading, spacing: MidnightMobileDesign.Spacing.large) {
            sectionTitle("Fleet", systemImage: "server.rack")

            Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 0) {
                headerRow
                ForEach(items) { item in
                    Divider()
                    serverRow(item)
                    if expandedRows.contains(item.id), item.hasExpandableDetail {
                        detailBand(item)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(MidnightMobileDesign.ColorToken.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.large))
        }
    }

    private var headerRow: some View {
        GridRow {
            // The server column is the only greedy one — it takes the width left
            // over after the content-sized metric columns.
            headerLabel("Server", expands: true)
                .gridColumnAlignment(.leading)
            headerLabel("CPU")
            headerLabel("Mem")
            headerLabel("Disk")
            headerLabel("Svc")
            headerLabel("Ports")
        }
    }

    private func headerLabel(_ text: String, expands: Bool = false) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: expands ? .infinity : nil, alignment: expands ? .leading : .center)
            .padding(.vertical, 8)
    }

    private func serverRow(_ item: FleetItem) -> some View {
        GridRow {
            NavigationLink(value: item.profile.id) {
                HStack(spacing: 8) {
                    Circle().fill(item.tableDotColor).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.profile.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !item.isConnected {
                            Text(item.statusLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gridColumnAlignment(.leading)

            cpuCell(item)
            percentCell(item.sample?.memoryPercent)
            percentCell(item.sample?.primaryDisk?.usedPercent)
            countCell(count: item.failedServices.count, probed: item.sample != nil, tint: item.failedServices.count >= 5 ? .red : .orange, item: item, label: "failed services")
            countCell(count: item.openPorts.count, probed: item.sample != nil, tint: .orange, item: item, label: "open ports")
        }
    }

    private func cpuCell(_ item: FleetItem) -> some View {
        VStack(spacing: 1) {
            if let sample = item.sample {
                Text(percentString(sample.cpuPercent))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(metricColor(sample.cpuPercent))
                Text("load \(loadString(sample.loadAverage1m))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("–").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
    }

    private func percentCell(_ percent: Double?) -> some View {
        Group {
            if let percent {
                Text(percentString(percent))
                    .foregroundStyle(metricColor(percent))
            } else {
                Text("–").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 14, weight: .semibold).monospacedDigit())
        .padding(.vertical, 9)
    }

    /// A count cell for failed services / open ports. Non-zero renders a tappable
    /// pill that expands the detail band; zero renders a muted dash (or a fainter
    /// dash when the host hasn't been probed yet, so "0" and "unknown" differ).
    private func countCell(count: Int, probed: Bool, tint: Color, item: FleetItem, label: String) -> some View {
        Group {
            if count > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { toggleExpanded(item.id) }
                } label: {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) \(label) on \(item.profile.name), expand")
            } else {
                Text("–")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(probed ? .tertiary : .quaternary)
            }
        }
        .padding(.vertical, 9)
    }

    private func detailBand(_ item: FleetItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.failedServices.isEmpty {
                detailLine(
                    label: "Failed",
                    value: item.failedServices.joined(separator: ", "),
                    tint: item.failedServices.count >= 5 ? .red : .orange
                )
            }
            if !item.openPorts.isEmpty {
                detailLine(
                    label: "Open ports",
                    value: "\(item.openPorts.joined(separator: ", ")) · to anywhere",
                    tint: .orange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
    }

    private func detailLine(label: String, value: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Formatting

    private func percentString(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    private func loadString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func metricColor(_ percent: Double) -> Color {
        if percent >= MobileServerHealthThresholds.criticalPercent { return .red }
        if percent >= MobileServerHealthThresholds.warningPercent { return .orange }
        return .primary
    }

    private func toggleExpanded(_ id: String) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
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

    var sample: MobileServerResourceSample? { snapshot?.sample }

    var failedServices: [String] { snapshot?.failedServices ?? [] }

    var openPorts: [String] {
        if case .open(let ports)? = snapshot?.firewall { return ports }
        return []
    }

    var hasExpandableDetail: Bool { !failedServices.isEmpty || !openPorts.isEmpty }

    /// Dot color for the table: real health when connected, otherwise the
    /// session state — so a disconnected host never shows a healthy green dot.
    var tableDotColor: Color {
        switch sessionStatus {
        case .connected: return severity.color
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
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
