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
                            rightLabel: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                            series: \.memoryPercent,
                            showsActionIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
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

                    dashboardDiagnostics
                }
                .frame(minHeight: contentHeight, alignment: .top)
                .padding(14)
            }
        }
    }

    var dashboardDiagnostics: some View {
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

            if let connectionId {
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

            // Need at least two points to draw a line; until then, leave
            // a small gap so the layout doesn't jump on the first sample.
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
                .frame(height: 40)
            } else {
                Color.clear.frame(height: 40)
            }
        }
    }

    /// Per-mount disk-usage section. Renders one `metricRow` per
    /// volume; collapses to a single placeholder when nothing came
    /// back (e.g. a host where `df` was filtered out by SELinux or
    /// chroot). The mount path is used as the row's identity since
    /// it's unique per host.
    @ViewBuilder
    func disksSection(_ disks: [FfiDiskMount]) -> some View {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Disks")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                ForEach(disks, id: \.mount) { disk in
                    diskRow(disk)
                }
            }
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

    func progressTint(_ value: Double) -> Color {
        switch value {
        case ..<0.6:  return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

}
