import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension SystemMonitorView {
    // MARK: - Content

    @ViewBuilder
    var content: some View {
        if connectionId == nil {
            placeholder(
                icon: "network.slash",
                message: "Open a terminal session to see live host stats."
            )
        } else if let unsupportedOs {
            placeholder(
                icon: "questionmark.circle",
                message: "Host OS \"\(unsupportedOs)\" isn't supported yet — only Linux and macOS hosts are recognised."
            )
        } else if let error {
            placeholder(icon: "exclamationmark.triangle", message: error)
        } else if let stats {
            statsBody(stats)
        } else {
            ProgressView("Loading host stats…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats body

    @ViewBuilder
    func statsBody(_ stats: FfiSystemStats) -> some View {
        if dashboardMode {
            dashboardStatsBody(stats)
        } else {
            inspectorStatsBody(stats)
        }
    }

    func inspectorStatsBody(_ stats: FfiSystemStats) -> some View {
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0

        return GeometryReader { proxy in
            ScrollView {
                let contentHeight = max(0, proxy.size.height - 32)

                VStack(alignment: .leading, spacing: 16) {
                    metricBlock(
                        title: "CPU",
                        icon: "cpu",
                        progress: stats.cpuPercent / 100,
                        rightLabel: String(format: "%.1f%%", stats.cpuPercent),
                        series: \.cpuPercent,
                        showsActionIndicator: true
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { drillDown = .cpu }
                    .help("Analyze CPU-intensive processes")

                    metricBlock(
                        title: "Memory",
                        icon: "memorychip",
                        progress: memoryPercent / 100,
                        rightLabel: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                        series: \.memoryPercent,
                        showsActionIndicator: true
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { drillDown = .memory }
                    .help("Analyze memory-intensive processes")

                    if stats.swapTotal > 0 {
                        metricRow(
                            title: "Swap",
                            icon: "arrow.up.arrow.down.square",
                            progress: Double(stats.swapUsed) / Double(stats.swapTotal),
                            rightLabel: "\(formatBytes(stats.swapUsed)) / \(formatBytes(stats.swapTotal))"
                        )
                    }

                    disksSection(stats.disks)

                    Divider()

                    summaryRow(
                        icon: "clock",
                        label: "Uptime",
                        value: formatUptime(stats.uptimeSeconds)
                    )

                    summaryRow(
                        icon: "speedometer",
                        label: "Load (1 min)",
                        value: String(format: "%.2f", stats.loadAverage1m)
                    )

                    MonitoredSystemdServicesPane(
                        connectionId: connectionId,
                        profileId: profileId,
                        isActive: isActive,
                        onSelectService: { unit in
                            drillDown = .systemdService(unit)
                        },
                        onOpenSystemd: { serviceModal = .systemd },
                        onOpenDocker: { serviceModal = .docker },
                        onOpenPostgres: { serviceModal = .postgres }
                    )

                    ActivityTimelineView(
                        profileId: profileId,
                        connectionId: connectionId,
                        maxEvents: 6
                    )

                    if let profile, let connectionId {
                        PortForwardingPanel(
                            profile: profile,
                            connectionId: connectionId,
                            isActive: isActive
                        )
                    }

                    Spacer(minLength: 16)

                    if let connectionId {
                        ConnectionWorldMapView(connectionId: connectionId, isActive: isActive)
                    }
                }
                .frame(minHeight: contentHeight, alignment: .top)
                .padding(16)
            }
        }
    }

    func dashboardStatsBody(_ stats: FfiSystemStats) -> some View {
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0

        return GeometryReader { proxy in
            ScrollView {
                let contentHeight = max(0, proxy.size.height - 28)

                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        drillDown = .cpu
                    } label: {
                        metricBlock(
                            title: "CPU",
                            icon: "cpu",
                            progress: stats.cpuPercent / 100,
                            rightLabel: String(format: "%.1f%%", stats.cpuPercent),
                            series: \.cpuPercent,
                            showsActionIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Analyze CPU-intensive processes")

                    Button {
                        drillDown = .memory
                    } label: {
                        metricBlock(
                            title: "Memory",
                            icon: "memorychip",
                            progress: memoryPercent / 100,
                            rightLabel: "\(Int(memoryPercent.rounded()))% · \(formatBytes(stats.memoryUsed))",
                            series: \.memoryPercent,
                            showsActionIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .help(
                        "\(formatBytes(stats.memoryUsed)) of \(formatBytes(stats.memoryTotal)) used"
                            + " — click to analyze memory-intensive processes"
                    )

                    if stats.swapTotal > 0 {
                        metricRow(
                            title: "Swap",
                            icon: "arrow.up.arrow.down.square",
                            progress: Double(stats.swapUsed) / Double(stats.swapTotal),
                            rightLabel: "\(formatBytes(stats.swapUsed)) / \(formatBytes(stats.swapTotal))"
                        )
                    }

                    disksSection(stats.disks, collapsible: true)

                    Divider()

                    summaryRow(
                        icon: "clock",
                        label: "Uptime",
                        value: formatUptime(stats.uptimeSeconds)
                    )

                    summaryRow(
                        icon: "speedometer",
                        label: "Load (1 min)",
                        value: String(format: "%.2f", stats.loadAverage1m)
                    )

                    dashboardDiagnostics
                }
                .frame(minHeight: contentHeight, alignment: .top)
                .padding(14)
            }
        }
    }

    // MARK: - Detail band (expanded fleet-table row)

    /// Compact expansion under a fleet-table row, ordered by intent:
    /// the user expands a row to get from a problem to its fix. Issues
    /// with remediation buttons lead; trend/disk context follows;
    /// diagnostics panels close the band. Intrinsic height.
    var detailBandBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailBandMetaLine

            let issues = currentDashboardHealthIssues
            if !issues.isEmpty {
                detailBandIssues(issues)
            }

            if connectionId == nil {
                detailBandNote("Open a terminal session to see live host stats.")
            } else if let unsupportedOs {
                detailBandNote("Host OS \"\(unsupportedOs)\" isn't supported yet.")
            } else if let error {
                detailBandNote(error)
            } else if let stats {
                detailBandStats(stats)
            } else {
                ProgressView("Loading host stats…")
                    .controlSize(.small)
            }

            diagnosticsPanels(includeMap: false)
        }
        .padding(12)
    }

    /// One actionable row per issue: what's wrong, and a button that
    /// jumps straight to the matching remediation drill-down.
    func detailBandIssues(_ issues: [DashboardHealthIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { issue in
                detailBandIssueRow(issue)
            }
        }
    }

    func detailBandIssueRow(_ issue: DashboardHealthIssue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: issue.icon)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(issue.severity.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(issue.title.replacingOccurrences(of: "\(connectionLabel): ", with: ""))
                    .font(.caption.weight(.semibold))
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let action = fleetIssueAction(issueId: issue.id, disks: stats?.disks ?? []) {
                Button(action.label) {
                    openIssueDestination(action.destination)
                }
                .controlSize(.small)
                .help(action.help)
            }
        }
        .padding(8)
        .background(
            issue.severity.color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
        )
    }

    /// Routes a remediation destination to the matching presenter.
    func openIssueDestination(_ destination: FleetIssueDestination) {
        switch destination {
        case .drill(let target):
            drillDown = target
        case .service(let kind):
            serviceModal = kind
        case .journal:
            showingJournalSheet = true
        }
    }

    var detailBandMetaLine: some View {
        HStack(spacing: 8) {
            Text(
                [endpointLine, osInfo, resolvedIPLine.map { "IP \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(MidnightMacDesign.FontToken.metadataMono)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(
                [endpointLine, osInfo, resolvedIPAddresses.joined(separator: ", ")]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            )
            Spacer()
            if connectionId != nil {
                ufwStatusBadge
            }
        }
    }

    func detailBandNote(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    func detailBandStats(_ stats: FfiSystemStats) -> some View {
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Button {
                    drillDown = .cpu
                } label: {
                    detailBandTrend(
                        title: "CPU",
                        valueText: String(format: "%.1f%%", stats.cpuPercent),
                        progress: stats.cpuPercent / 100,
                        series: \.cpuPercent
                    )
                }
                .buttonStyle(.plain)
                .help("Analyze CPU-intensive processes")

                Button {
                    drillDown = .memory
                } label: {
                    detailBandTrend(
                        title: "Memory",
                        valueText: "\(Int(memoryPercent.rounded()))% · \(formatBytes(stats.memoryUsed))",
                        progress: memoryPercent / 100,
                        series: \.memoryPercent
                    )
                }
                .buttonStyle(.plain)
                .help(
                    "\(formatBytes(stats.memoryUsed)) of \(formatBytes(stats.memoryTotal)) used"
                        + " — click to analyze memory-intensive processes"
                )
            }

            if stats.swapTotal > 0 {
                metricRow(
                    title: "Swap",
                    icon: "arrow.up.arrow.down.square",
                    progress: Double(stats.swapUsed) / Double(stats.swapTotal),
                    rightLabel: "\(formatBytes(stats.swapUsed)) / \(formatBytes(stats.swapTotal))"
                )
            }

            disksSection(stats.disks, collapsible: true)
        }
    }

    /// One compact trend column: label + current value on a line, the
    /// sparkline below. The percentage bar is omitted — the table row
    /// above already shows it.
    func detailBandTrend(
        title: String,
        valueText: String,
        progress: Double,
        series: KeyPath<StatSample, Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(progress >= 0.6 ? progressTint(progress) : Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            trendChart(title: title, series: series, progress: progress, height: 36)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    var dashboardDiagnostics: some View {
        diagnosticsPanels(includeMap: true)
    }

    /// The drill-down disclosure panels. The connection map is context
    /// rather than remediation, so the fleet-table detail band skips it.
    func diagnosticsPanels(includeMap: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            dashboardDisclosure(
                title: "Services",
                icon: "switch.2",
                isExpanded: $servicesExpanded
            ) {
                MonitoredSystemdServicesPane(
                    connectionId: connectionId,
                    profileId: profileId,
                    isActive: isActive,
                    onSelectService: { unit in
                        drillDown = .systemdService(unit)
                    },
                    onOpenSystemd: { serviceModal = .systemd },
                    onOpenDocker: { serviceModal = .docker },
                    onOpenPostgres: { serviceModal = .postgres }
                )
            }

            dashboardDisclosure(
                title: "Activity",
                icon: "clock.arrow.circlepath",
                isExpanded: $activityExpanded
            ) {
                ActivityTimelineView(
                    profileId: profileId,
                    connectionId: connectionId,
                    maxEvents: 6
                )
            }

            if let profile, let connectionId {
                dashboardDisclosure(
                    title: "Ports",
                    icon: "arrow.left.and.right",
                    isExpanded: $portsExpanded
                ) {
                    PortForwardingPanel(
                        profile: profile,
                        connectionId: connectionId,
                        isActive: isActive
                    )
                }
            }

            if includeMap, let connectionId {
                dashboardDisclosure(
                    title: "Connection Map",
                    icon: "map",
                    isExpanded: $mapExpanded
                ) {
                    ConnectionWorldMapView(connectionId: connectionId, isActive: isActive)
                }
            }
        }
    }

    func dashboardDisclosure<Content: View>(
        title: String,
        icon: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Label(title, systemImage: icon)
                .font(MidnightMacDesign.FontToken.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(
            MidnightMacDesign.ColorToken.controlBackground.opacity(0.65),
            in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
        )
    }

    func metricRow(
        title: String,
        icon: String,
        progress: Double,
        rightLabel: String,
        showsActionIndicator: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(rightLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if showsActionIndicator {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .tint(progressTint(progress))
        }
    }

    /// Same as `metricRow` plus a sparkline of recent samples below.
    /// `series` is a key path on `StatSample` so the same block works
    /// for CPU and memory without duplicating the chart wiring.
    func metricBlock(
        title: String,
        icon: String,
        progress: Double,
        rightLabel: String,
        series: KeyPath<StatSample, Double>,
        showsActionIndicator: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricRow(
                title: title,
                icon: icon,
                progress: progress,
                rightLabel: rightLabel,
                showsActionIndicator: showsActionIndicator
            )

            trendChart(title: title, series: series, progress: progress, height: 40)
        }
    }

    /// Sparkline of recent samples for one metric. Reserves its height
    /// before two points exist so the layout doesn't jump on the first
    /// sample.
    @ViewBuilder
    func trendChart(
        title: String,
        series: KeyPath<StatSample, Double>,
        progress: Double,
        height: CGFloat
    ) -> some View {
        if history.count >= 2 {
            Chart(history) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(title, sample[keyPath: series])
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(progressTint(progress))

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(title, sample[keyPath: series])
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(progressTint(progress).opacity(0.15))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: height)
        } else {
            Color.clear.frame(height: height)
        }
    }

    /// Per-mount disk-usage section. Renders one `metricRow` per
    /// volume; collapses to a single placeholder when nothing came
    /// back (e.g. a host where `df` was filtered out by SELinux or
    /// chroot). The mount path is used as the row's identity since
    /// it's unique per host.
    ///
    /// With `collapsible` (dashboard cards) only the fullest mount and
    /// any near-full mounts show by default — `/boot`, `/boot/efi` and
    /// friends hide behind a "+N more" toggle so they don't drown out
    /// the mount that actually matters.
    @ViewBuilder
    func disksSection(_ disks: [FfiDiskMount], collapsible: Bool = false) -> some View {
        if disks.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("No disk mounts reported")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            let visible = collapsible && !disksExpanded
                ? collapsedDisks(disks)
                : disks
            let hiddenCount = disks.count - visible.count

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Disks")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if collapsible && disks.count > collapsedDisks(disks).count {
                        Button(disksExpanded ? "Show less" : "+\(hiddenCount) more") {
                            disksExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            disksExpanded
                                ? "Hide secondary mounts"
                                : "Show all \(disks.count) mounts"
                        )
                    }
                }
                ForEach(visible, id: \.mount) { disk in
                    diskRow(disk)
                }
            }
        }
    }

    /// The mounts worth showing on a collapsed dashboard card: the
    /// fullest mount, plus any others past the warning threshold.
    func collapsedDisks(_ disks: [FfiDiskMount]) -> [FfiDiskMount] {
        func fillFraction(_ disk: FfiDiskMount) -> Double {
            disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        }
        guard let fullest = disks.max(by: { fillFraction($0) < fillFraction($1) }) else {
            return []
        }
        // Preserve the original ordering so rows don't jump around
        // as usage fluctuates.
        return disks.filter {
            $0.mount == fullest.mount || fillFraction($0) >= 0.85
        }
    }

    func diskRow(_ disk: FfiDiskMount) -> some View {
        let progress = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(disk.mount)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(formatBytes(disk.used)) / \(formatBytes(disk.total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .tint(progressTint(progress))
            HStack(spacing: 4) {
                Text(disk.source)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if disk.fsType != "—" && !disk.fsType.isEmpty {
                    Text("·")
                    Text(disk.fsType)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.leading, 22)
        .contentShape(Rectangle())
        .onTapGesture { drillDown = .disk(disk) }
        .help("Show recently changed large files on \(disk.mount)")
    }

    func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Healthy values render muted so color is reserved for the
    /// exceptional: on a fleet dashboard the one hot bar should be
    /// the only loud one.
    func progressTint(_ value: Double) -> Color {
        switch value {
        case ..<0.6:  return .green.opacity(0.55)
        case ..<0.85: return .orange
        default:      return .red
        }
    }

}
