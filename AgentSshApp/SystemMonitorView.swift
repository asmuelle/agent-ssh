import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

fileprivate enum ServiceModalKind: String, Identifiable {
    case systemd
    case docker
    case postgres

    var id: String { rawValue }
}

fileprivate enum MonitorDrillDown: Identifiable {
    case cpu
    case memory
    case disk(FfiDiskMount)
    case systemdService(String)
    case ufw

    var id: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memory"
        case .disk(let disk):
            return "disk:\(disk.mount):\(disk.source)"
        case .systemdService(let unit):
            return "systemd:\(unit)"
        case .ufw:
            return "ufw"
        }
    }

    var title: String {
        switch self {
        case .cpu:
            return "CPU Analysis"
        case .memory:
            return "Memory Analysis"
        case .disk(let disk):
            return "Recent Large Files: \(disk.mount)"
        case .systemdService(let unit):
            return unit
        case .ufw:
            return "UFW Details"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu:
            return "CPU-heavy processes, thread hot spots, and current load."
        case .memory:
            return "Memory-heavy processes, pressure signals, and allocation summary."
        case .disk(let disk):
            return "\(disk.source) - files changed in the last 14 days, sorted by size."
        case .systemdService:
            return "Unit identity, environment, service files, recent logs, and actions."
        case .ufw:
            return "Firewall posture, public exposure, recent blocks, and raw command output."
        }
    }

    var icon: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .systemdService:
            return "switch.2"
        case .ufw:
            return "shield"
        }
    }
}

struct DashboardHealthIssue: Identifiable, Equatable {
    enum Severity: Int, Equatable {
        case warning
        case critical

        var color: Color {
            switch self {
            case .warning: return .orange
            case .critical: return .red
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let severity: Severity
}

struct DashboardHealthSnapshot: Identifiable, Equatable {
    let id: String
    let hostName: String
    let issues: [DashboardHealthIssue]
}

/// Polls host stats through `BridgeManager` every few seconds for the active
/// connection and renders CPU / memory / per-mount disk / uptime / load.
///
/// **Multi-OS**: the Rust side runs `uname -s` once per connection
/// (cached) and routes to the matching parser. Linux (`/proc`) and
/// macOS (`top`/`vm_stat`/`sysctl`/`df -k -P`) are supported; BSD /
/// Solaris hosts surface as `MonitorError.Unsupported` and we render
/// a friendly placeholder instead of error spam.
///
/// The polling Task is bound to the view's lifetime via `.task` —
/// switching tabs or disconnecting tears it down automatically.
struct SystemMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    var profileId: String? = nil
    var sshPort: UInt16? = nil
    var profile: ConnectionProfile? = nil
    var connectionStatus: TerminalConnectionStatus? = nil
    var isActive: Bool = true
    var dashboardMode = false
    var dashboardIdentity: String? = nil
    var resolvedIPAddresses: [String] = []
    var onDashboardHealthChange: ((DashboardHealthSnapshot) -> Void)? = nil

    @State private var stats: FfiSystemStats?
    @State private var error: String?
    @State private var ufwSummary = UFWProtectionSummary.loading
    /// Set when the host's OS isn't supported. Renders a stable
    /// placeholder so we don't spam the user with parse errors on
    /// every poll. Reset on connection change.
    @State private var unsupportedOs: String?
    /// Sliding window of recent samples for the CPU / memory trend
    /// charts. Capped at `maxHistory` — older samples are dropped at
    /// each append. Reset on `connectionId` change so a switch between
    /// hosts doesn't render misleading lines that span both.
    @State private var history: [StatSample] = []
    @State private var lastConnectionId: String?
    @State private var drillDown: MonitorDrillDown?
    @State private var serviceModal: ServiceModalKind?
    @State private var showingConfidence = false
    @State private var servicesExpanded = false
    @State private var activityExpanded = false
    @State private var portsExpanded = false
    @State private var mapExpanded = false
    /// Distro / kernel / arch summary shown under the connection label.
    /// `nil` until the probe finishes; reset on `connectionId` change.
    @State private var osInfo: String?

    private let logger = Logger(subsystem: "com.mc-ssh", category: "monitor")
    private static let pollInterval: UInt64 = 3_000_000_000  // 3 s
    private static let ufwPollInterval: UInt64 = 30_000_000_000  // 30 s
    /// 60 × 3s = 3 minutes of trailing history per chart.
    private static let maxHistory = 60

    /// One CPU/memory snapshot for the trend charts.
    fileprivate struct StatSample: Identifiable {
        let id = UUID()
        let timestamp: Date
        let cpuPercent: Double
        /// Memory utilisation 0..100 — derived from used / total at
        /// sample time so the chart's Y axis aligns with the linear
        /// progress bar above it.
        let memoryPercent: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if dashboardMode {
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                    .fill(MidnightMacDesign.ColorToken.windowBackground)
            }
        }
        .overlay {
            if dashboardMode {
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                    .stroke(MidnightMacDesign.ColorToken.separator.opacity(0.45), lineWidth: 1)
            }
        }
        .task(id: pollTaskKey) {
            guard isActive else { return }
            await pollLoop()
        }
        .task(id: ufwPollTaskKey) {
            guard isActive, let connectionId else {
                ufwSummary = connectionId == nil
                    ? UFWProtectionSummary(
                        level: .unavailable,
                        statusText: "No connection",
                        extraOpenRules: [],
                        error: nil
                    )
                    : .loading
                return
            }
            await ufwPollLoop(connectionId: connectionId)
        }
        .task(id: connectionId ?? "none") {
            osInfo = nil
            guard isActive, connectionId != nil else { return }
            await loadOsInfo()
        }
        .sheet(item: $drillDown) { item in
            MonitorDrillDownSheet(
                connectionId: connectionId,
                drillDown: item,
                sshPort: sshPort
            )
        }
        .sheet(item: $serviceModal) { kind in
            ServiceModalSheet(
                kind: kind,
                connectionId: connectionId,
                profileId: profileId,
                connectionLabel: connectionLabel
            )
        }
        .sheet(isPresented: $showingConfidence) {
            if let profile {
                ConnectionConfidenceSheet(profile: profile, status: connectionStatus)
            }
        }
        .onAppear {
            publishDashboardHealthSnapshot()
        }
        .onChange(of: connectionStatus) { _ in
            publishDashboardHealthSnapshot()
        }
    }

    private var pollTaskKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    private var ufwPollTaskKey: String {
        "\(connectionId ?? "none"):\(sshPort.map { String($0) } ?? "default"):\(isActive)"
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: dashboardMode ? 5 : 2) {
            HStack(spacing: 6) {
                connectionStatusIcon
                Text(connectionLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if connectionId != nil {
                    ufwStatusBadge
                }
                if dashboardMode {
                    dashboardIssueBadges
                }
                Spacer()
                if stats != nil {
                    Text("Updated \(Date().formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if dashboardMode, let endpointLine {
                Text(endpointLine)
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(endpointLine)
            }
            if let osInfo {
                Text(osInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(osInfo)
            }
            if dashboardMode, let resolvedIPLine {
                Text("IP \(resolvedIPLine)")
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(resolvedIPAddresses.joined(separator: ", "))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var endpointLine: String? {
        guard let profile else { return nil }
        return "\(profile.username)@\(profile.host):\(profile.port)"
    }

    private var resolvedIPLine: String? {
        guard !resolvedIPAddresses.isEmpty else { return nil }
        let visible = resolvedIPAddresses.prefix(2).joined(separator: ", ")
        let hiddenCount = resolvedIPAddresses.count - 2
        return hiddenCount > 0 ? "\(visible) +\(hiddenCount)" : visible
    }

    @ViewBuilder
    private var dashboardIssueBadges: some View {
        let issues = currentDashboardHealthIssues
        if !issues.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(issues.prefix(2))) { issue in
                    dashboardIssueBadge(issue)
                }
                if issues.count > 2 {
                    Text("+\(issues.count - 2)")
                        .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
        }
    }

    private func dashboardIssueBadge(_ issue: DashboardHealthIssue) -> some View {
        HStack(spacing: 3) {
            Image(systemName: issue.icon)
                .font(MidnightMacDesign.FontToken.caption)
            Text(issue.title.replacingOccurrences(of: "\(connectionLabel): ", with: ""))
                .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(issue.severity.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(issue.severity.color.opacity(0.12), in: Capsule())
        .help("\(issue.title): \(issue.detail)")
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        let color = connectionStatusColor
        if profile != nil {
            Button {
                showingConfidence = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .help("Show connection details and credential confidence")
        } else {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(color)
        }
    }

    private var connectionStatusColor: Color {
        switch connectionStatus {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        case .error:        return .red
        case nil:           return .secondary
        }
    }

    private var ufwStatusBadge: some View {
        let color = ufwProtectionColor(ufwSummary)
        let label = ufwSummary.badgeText == "on" ? "UFW" : "UFW \(ufwSummary.badgeText)"
        return Button {
            drillDown = .ufw
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(ufwSummary.helpText)
    }

    private func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
        switch summary.level {
        case .protected:
            return .green
        case .inactive, .open:
            return .orange
        case .unknown:
            return .yellow
        case .loading, .unavailable:
            return .secondary
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
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

    private func placeholder(icon: String, message: String) -> some View {
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
    private func statsBody(_ stats: FfiSystemStats) -> some View {
        if dashboardMode {
            dashboardStatsBody(stats)
        } else {
            inspectorStatsBody(stats)
        }
    }

    private func inspectorStatsBody(_ stats: FfiSystemStats) -> some View {
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
                        ConnectionWorldMapView(connectionId: connectionId)
                    }
                }
                .frame(minHeight: contentHeight, alignment: .top)
                .padding(16)
            }
        }
    }

    private func dashboardStatsBody(_ stats: FfiSystemStats) -> some View {
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

    private var dashboardDiagnostics: some View {
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
                    ConnectionWorldMapView(connectionId: connectionId)
                }
            }
        }
    }

    private func dashboardDisclosure<Content: View>(
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

    private func metricRow(
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
    private func metricBlock(
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
    private func disksSection(_ disks: [FfiDiskMount]) -> some View {
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

    private func diskRow(_ disk: FfiDiskMount) -> some View {
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

    private func summaryRow(icon: String, label: String, value: String) -> some View {
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

    private func progressTint(_ value: Double) -> Color {
        switch value {
        case ..<0.6:  return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    private var currentDashboardHealthIssues: [DashboardHealthIssue] {
        dashboardHealthIssues(
            stats: stats,
            error: error,
            unsupportedOs: unsupportedOs,
            ufwSummary: ufwSummary,
            connectionStatus: connectionStatus
        )
    }

    private func dashboardHealthIssues(
        stats: FfiSystemStats?,
        error: String?,
        unsupportedOs: String?,
        ufwSummary: UFWProtectionSummary,
        connectionStatus: TerminalConnectionStatus?
    ) -> [DashboardHealthIssue] {
        var issues: [DashboardHealthIssue] = []

        if let connectionStatus, connectionStatus != .connected {
            issues.append(DashboardHealthIssue(
                id: "status:\(connectionStatus.rawValue)",
                title: "\(connectionLabel): Connection",
                detail: connectionStatus.rawValue.capitalized,
                icon: connectionStatus == .error ? "exclamationmark.circle.fill" : "wifi.slash",
                severity: connectionStatus == .error ? .critical : .warning
            ))
        }

        if let unsupportedOs {
            issues.append(DashboardHealthIssue(
                id: "unsupported-os",
                title: "\(connectionLabel): Monitor",
                detail: "Unsupported OS \(unsupportedOs)",
                icon: "questionmark.circle",
                severity: .warning
            ))
        } else if let error, !error.isEmpty {
            issues.append(DashboardHealthIssue(
                id: "monitor-error",
                title: "\(connectionLabel): Monitor",
                detail: error,
                icon: "exclamationmark.triangle.fill",
                severity: .warning
            ))
        }

        switch ufwSummary.level {
        case .inactive:
            issues.append(DashboardHealthIssue(
                id: "ufw-inactive",
                title: "\(connectionLabel): UFW",
                detail: "Firewall inactive",
                icon: "shield.slash",
                severity: .warning
            ))
        case .open:
            let detail = ufwSummary.extraOpenRules.isEmpty
                ? "Public exposure detected"
                : "Open: \(ufwSummary.extraOpenRules.prefix(3).joined(separator: ", "))"
            issues.append(DashboardHealthIssue(
                id: "ufw-open",
                title: "\(connectionLabel): UFW",
                detail: detail,
                icon: "shield.lefthalf.filled",
                severity: .warning
            ))
        case .unknown:
            issues.append(DashboardHealthIssue(
                id: "ufw-unknown",
                title: "\(connectionLabel): UFW",
                detail: ufwSummary.error ?? ufwSummary.statusText,
                icon: "shield",
                severity: .warning
            ))
        case .loading, .unavailable, .protected:
            break
        }

        if let stats {
            let cpuFraction = stats.cpuPercent / 100
            if cpuFraction >= 0.85 {
                issues.append(DashboardHealthIssue(
                    id: "cpu",
                    title: "\(connectionLabel): CPU",
                    detail: String(format: "%.1f%%", stats.cpuPercent),
                    icon: "cpu",
                    severity: cpuFraction >= 0.95 ? .critical : .warning
                ))
            }

            let memoryFraction = stats.memoryTotal > 0
                ? Double(stats.memoryUsed) / Double(stats.memoryTotal)
                : 0
            if memoryFraction >= 0.85 {
                issues.append(DashboardHealthIssue(
                    id: "memory",
                    title: "\(connectionLabel): Memory",
                    detail: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                    icon: "memorychip",
                    severity: memoryFraction >= 0.95 ? .critical : .warning
                ))
            }

            let diskIssues = stats.disks
                .compactMap { disk -> (FfiDiskMount, Double)? in
                    guard disk.total > 0 else { return nil }
                    let fraction = Double(disk.used) / Double(disk.total)
                    return fraction >= 0.85 ? (disk, fraction) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(2)

            for (disk, fraction) in diskIssues {
                issues.append(DashboardHealthIssue(
                    id: "disk:\(disk.mount)",
                    title: "\(connectionLabel): Disk",
                    detail: "\(disk.mount) \(Int(fraction * 100))%",
                    icon: "internaldrive",
                    severity: fraction >= 0.95 ? .critical : .warning
                ))
            }
        }

        return issues.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func publishDashboardHealthSnapshot() {
        guard dashboardMode, let onDashboardHealthChange else { return }
        onDashboardHealthChange(DashboardHealthSnapshot(
            id: dashboardIdentity ?? connectionId ?? connectionLabel,
            hostName: connectionLabel,
            issues: currentDashboardHealthIssues
        ))
    }

    // MARK: - Polling

    private func pollLoop() async {
        // Drop the previous connection's history and any sticky error /
        // unsupported flag only when this view is retargeted to a different
        // connection. When it merely becomes inactive and active again, keep
        // its chart history as part of the tab's preserved workspace state.
        if lastConnectionId != connectionId {
            history.removeAll()
            unsupportedOs = nil
            error = nil
            lastConnectionId = connectionId
        }

        guard let connectionId else { return }
        while !Task.isCancelled {
            await fetchOnce(connectionId: connectionId)
            // If we know the host is unsupported, stop polling — the
            // result won't change without a reconnect, and the timer
            // would just churn on the same uname/parser.
            if unsupportedOs != nil { return }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func ufwPollLoop(connectionId: String) async {
        await fetchUFWStatus(connectionId: connectionId)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.ufwPollInterval)
            await fetchUFWStatus(connectionId: connectionId)
        }
    }

    /// One-shot probe for distro / kernel / arch. We only re-run on
    /// connection change — host identity doesn't shift between polls,
    /// and kernel upgrades require a reconnect to take effect anyway.
    private func loadOsInfo() async {
        guard let connectionId else { return }
        let script = """
        pretty=""
        if [ -r /etc/os-release ]; then
          pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:+$NAME ${VERSION:-}}}")
        fi
        if [ -z "$pretty" ] && command -v sw_vers >/dev/null 2>&1; then
          pretty="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
        fi
        if [ -z "$pretty" ] && command -v lsb_release >/dev/null 2>&1; then
          pretty=$(lsb_release -ds 2>/dev/null)
        fi
        if [ -z "$pretty" ]; then
          pretty=$(uname -s 2>/dev/null)
        fi
        kernel=$(uname -sr 2>/dev/null)
        arch=$(uname -m 2>/dev/null)
        printf '%s\\n%s\\n%s\\n' "${pretty:-Unknown}" "${kernel:-}" "${arch:-}"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: script
            )
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let parts = [
                lines.indices.contains(0) ? lines[0] : "",
                lines.indices.contains(1) ? lines[1] : "",
                lines.indices.contains(2) ? lines[2] : "",
            ].filter { !$0.isEmpty }
            osInfo = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } catch {
            osInfo = nil
        }
    }

    private func fetchUFWStatus(connectionId: String) async {
        defer { publishDashboardHealthSnapshot() }

        let script = """
        if command -v ufw >/dev/null 2>&1; then
          sudo -n ufw status numbered 2>&1
        else
          echo \(ufwUnavailableMarker)
        fi
        """

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: script
            )
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !result.succeeded {
                ufwSummary = UFWProtectionSummary(
                    level: .unknown,
                    statusText: "Unable to read UFW status",
                    extraOpenRules: [],
                    error: "Remote command failed with exit code \(result.exitCode)."
                )
            } else {
                ufwSummary = summarizeUFWStatusOutput(result.output, sshPort: sshPort)
            }
        } catch {
            ufwSummary = UFWProtectionSummary(
                level: .unknown,
                statusText: "Unable to read UFW status",
                extraOpenRules: [],
                error: friendlyUFWError(error.localizedDescription)
            )
        }
    }

    private func friendlyUFWError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required")
            || (lower.contains("sudo") && lower.contains("password")) {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw status, or run the command manually in the terminal."
        }
        return message
    }

    /// Append a sample, capping the buffer to `maxHistory`. Memory %
    /// is derived once here so the chart's series lookup stays cheap.
    private func recordSample(_ s: FfiSystemStats) {
        let memoryPct = s.memoryTotal > 0
            ? Double(s.memoryUsed) / Double(s.memoryTotal) * 100
            : 0
        history.append(StatSample(
            timestamp: Date(),
            cpuPercent: s.cpuPercent,
            memoryPercent: memoryPct
        ))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    private func fetchOnce(connectionId: String) async {
        defer { publishDashboardHealthSnapshot() }

        do {
            let s = try await BridgeManager.shared.getSystemStats(connectionId: connectionId)
            stats = s
            error = nil
            unsupportedOs = nil
            recordSample(s)
        } catch let err as MonitorError {
            switch err {
            case .Unsupported(let os):
                // The Rust side detected the OS via `uname -s` and
                // doesn't have parsers for it. Surface the kernel
                // name so the user knows whether to file a request.
                unsupportedOs = os
                error = nil
            case .ParseError(let detail):
                // Output didn't match the expected shape — usually
                // a transient command timeout or a sysctl that's
                // missing on a stripped-down host. Show the detail
                // and let the next poll retry.
                error = "Couldn't parse host stats: \(detail)"
            case .NotConnected:
                error = "Not connected to this host."
            case .Other(let detail):
                error = detail
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Monitor drill-down sheet

private struct MonitorDrillDownSheet: View {
    let connectionId: String?
    let drillDown: MonitorDrillDown
    let sshPort: UInt16?

    @Environment(\.dismiss) private var dismiss
    @State private var rawOutput = ""
    @State private var snapshot: MonitorDiagnosticSnapshot?
    @State private var error: String?
    @State private var notice: String?
    @State private var isLoading = false
    @State private var lastRefreshedAt: Date?
    @State private var mode = DrillDownMode.overview
    @State private var selectedProcessId: Int?
    @State private var selectedThreadId: String?
    @State private var selectedFilePath: String?
    @State private var selectedSystemdFileId: String?
    @State private var selectedUFWRuleId: Int?
    @State private var selectedUFWSource: String?
    @State private var processSortOrder: [KeyPathComparator<ProcessDiagnosticRow>]
    @State private var threadSortOrder: [KeyPathComparator<ThreadDiagnosticRow>] = [
        KeyPathComparator(\.cpuPercent, order: .reverse)
    ]
    @State private var focusedTitle: String?
    @State private var focusedOutput = ""
    @State private var focusedLoading = false

    init(connectionId: String?, drillDown: MonitorDrillDown, sshPort: UInt16?) {
        self.connectionId = connectionId
        self.drillDown = drillDown
        self.sshPort = sshPort
        _processSortOrder = State(initialValue: Self.defaultProcessSortOrder(for: drillDown))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, notice == nil ? 10 : 4)
            }
            Picker("", selection: $mode) {
                ForEach(DrillDownMode.allCases, id: \.self) { mode in
                    Text(mode.title(for: drillDown)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            Divider()
            diagnosticContent
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: drillDown.id) {
            await refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: drillDown.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(drillDown.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(drillDown.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            systemdActions
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let lastRefreshedAt {
                Text("Updated \(lastRefreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(isLoading)
            .help("Refresh")

            Button {
                RemoteCommandRunner.copy(copyOutput)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled(copyOutput.isEmpty)
            .help("Copy output")

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var copyOutput: String {
        if mode == .raw || focusedOutput.isEmpty {
            return rawOutput
        }
        return focusedOutput
    }

    @ViewBuilder
    private var diagnosticContent: some View {
        if mode == .raw {
            rawPane(rawOutput)
        } else if let snapshot {
            switch snapshot {
            case .cpu(let diagnostic):
                cpuContent(diagnostic)
            case .memory(let diagnostic):
                memoryContent(diagnostic)
            case .disk(let diagnostic):
                diskContent(diagnostic)
            case .systemd(let diagnostic):
                systemdContent(diagnostic)
            case .ufw(let diagnostic):
                ufwContent(diagnostic)
            }
        } else if isLoading {
            ProgressView("Loading diagnostics...")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholderPane("No diagnostic data.")
        }
    }

    @ViewBuilder
    private var systemdActions: some View {
        if case .systemdService(let unit) = drillDown {
            HStack(spacing: 6) {
                Button {
                    Task { await runSystemdAction("start", unit: unit) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        Text("Start")
                    }
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .help("Start service")

                Button {
                    Task { await runSystemdAction("stop", unit: unit) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                }
                .tint(.red)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Stop service")

                Button {
                    Task { await runSystemdAction("restart", unit: unit) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .tint(.blue)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Restart service")

                Button {
                    Task { await runSystemdAction("reload", unit: unit) }
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .tint(.secondary)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Reload service")
            }
            .controlSize(.small)
        }
    }

    @MainActor
    private func refresh() async {
        guard let connectionId else {
            rawOutput = ""
            snapshot = nil
            error = "No SSH connection selected."
            return
        }

        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: diagnosticScript()
            )
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot = MonitorDiagnosticParser.parse(rawOutput, kind: drillDown)
            lastRefreshedAt = Date()
            applyDefaultSelections()
            ActivityLogStore.shared.record(
                title: "Deep dive opened",
                detail: drillDown.title,
                connectionId: connectionId,
                icon: drillDown.icon,
                severity: result.succeeded ? .info : .warning
            )
            if result.succeeded {
                error = nil
            } else {
                error = "Diagnostics exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
            rawOutput = ""
            snapshot = nil
        }
    }

    @MainActor
    private func runSystemdAction(_ verb: String, unit: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }

        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        let quotedUnit = RemoteCommandRunner.shellQuote(unit)
        let script = """
        command -v systemctl >/dev/null 2>&1 || { echo "systemctl is not available on this host."; exit 127; }
        systemctl \(verb) \(quotedUnit) 2>&1
        status=$?
        if [ "$status" -ne 0 ]; then
          sudo -n systemctl \(verb) \(quotedUnit) 2>&1
          status=$?
        fi
        exit "$status"
        """

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded {
                let message = "\(verb.capitalized) completed for \(unit)."
                ActivityLogStore.shared.record(
                    title: "Service \(verb)",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "switch.2",
                    severity: .success
                )
                await refresh()
                notice = message
            } else {
                ActivityLogStore.shared.record(
                    title: "Service \(verb) failed",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "exclamationmark.triangle.fill",
                    severity: .critical
                )
                error = "\(verb.capitalized) exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func runFocusedInspection(title: String, script: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }

        focusedTitle = title
        focusedLoading = true
        focusedOutput = ""
        defer { focusedLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            focusedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.succeeded {
                error = "Inspection exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyDefaultSelections() {
        guard let snapshot else { return }
        switch snapshot {
        case .cpu(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
            selectedThreadId = diagnostic.threads.first?.id
        case .memory(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
        case .disk(let diagnostic):
            selectedFilePath = diagnostic.files.first?.path
        case .systemd(let diagnostic):
            selectedSystemdFileId = diagnostic.files.first?.id
        case .ufw(let diagnostic):
            selectedUFWRuleId = diagnostic.rules.first?.id
            selectedUFWSource = ufwBlockedSourceRows(diagnostic).first?.source
        }
        focusedTitle = nil
        focusedOutput = ""
    }

    // MARK: - Typed panes

    @ViewBuilder
    private func cpuContent(_ diagnostic: CPUDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Load", diagnostic.load.isEmpty ? "Unavailable" : diagnostic.load),
                ("CPU Cores", diagnostic.cores.isEmpty ? "Unknown" : diagnostic.cores),
                ("Processes", "\(diagnostic.processes.count)"),
                ("Threads", "\(diagnostic.threads.count)"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: diagnostic.threads
            )
        case .details:
            selectedProcessDetail(diagnostic.processes)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func memoryContent(_ diagnostic: MemoryDiagnostic) -> some View {
        switch mode {
        case .overview:
            memoryOverviewPane(diagnostic)
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: []
            )
        case .details:
            VStack(alignment: .leading, spacing: 12) {
                selectedProcessDetail(diagnostic.processes)
                if !diagnostic.events.isEmpty {
                    sectionBox("Memory Pressure Events") {
                        rawText(diagnostic.events.joined(separator: "\n"))
                    }
                    .frame(height: 180)
                }
            }
        case .raw:
            rawPane(rawOutput)
        }
    }

    private func memoryOverviewPane(_ diagnostic: MemoryDiagnostic) -> some View {
        let topProcess = diagnostic.processes.first

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCards([
                    ("Largest RSS", topProcess.map { formatKilobytes($0.rssKB) } ?? "Unknown"),
                    ("Top Process", topProcess?.command ?? "Unknown"),
                    ("Processes", "\(diagnostic.processes.count)"),
                    ("Pressure Events", "\(diagnostic.events.count)"),
                ])
                sectionBox("Memory Summary") {
                    rawText(diagnostic.summary.joined(separator: "\n"))
                        .frame(minHeight: 110, maxHeight: 220)
                }
                if !diagnostic.events.isEmpty {
                    sectionBox("Pressure Events") {
                        rawText(diagnostic.events.joined(separator: "\n"))
                            .frame(minHeight: 90, maxHeight: 180)
                    }
                }
                if !diagnostic.warnings.isEmpty {
                    warningList(diagnostic.warnings)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func diskContent(_ diagnostic: DiskDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Mount", diagnostic.mount.isEmpty ? "Unknown" : diagnostic.mount),
                ("Usage", diagnostic.usage.isEmpty ? "Unavailable" : diagnostic.usage),
                ("Recent Large Files", "\(diagnostic.files.count)"),
                ("Largest File", diagnostic.files.first.map { formatBytes($0.size) } ?? "None"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            diskFilePane(diagnostic)
        case .details:
            selectedDiskFileDetail(diagnostic.files)
                .padding(16)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func systemdContent(_ diagnostic: SystemdDiagnostic) -> some View {
        switch mode {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(diagnostic.value(for: "Id") ?? "Service Unit")
                                .font(.headline)
                            Text(diagnostic.value(for: "Description") ?? "No description available.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            state: diagnostic.value(for: "ActiveState") ?? "Unknown",
                            substate: diagnostic.value(for: "SubState") ?? "Unknown"
                        )
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    overviewCards([
                        ("User", diagnostic.value(for: "User") ?? "Default"),
                        ("Main PID", diagnostic.value(for: "MainPID") ?? "Unknown"),
                        ("Tasks", diagnostic.value(for: "TasksCurrent") ?? "-"),
                        ("Memory", formatMemoryProperty(diagnostic.value(for: "MemoryCurrent"))),
                    ])
                    if diagnostic.journalIssueCounts.hasIssues {
                        journalIssueSummary(diagnostic.journalIssueCounts)
                    }
                    serviceSpecificPane(diagnostic)
                    keyValuePane(diagnostic.properties)
                }
                .padding(16)
            }
        case .hotspots:
            systemdFilesPane(diagnostic)
        case .details:
            systemdJournalPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func ufwContent(_ diagnostic: UFWDiagnostic) -> some View {
        switch mode {
        case .overview:
            ufwOverviewPane(diagnostic)
        case .hotspots:
            ufwBlockedSourcesPane(diagnostic)
        case .details:
            ufwRulesPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    private func ufwOverviewPane(_ diagnostic: UFWDiagnostic) -> some View {
        let publicRules = ufwPublicOpenRules(diagnostic)
        let findings = ufwFindings(diagnostic)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ufwSummaryCards([
                    ("Firewall", ufwFirewallStatus(diagnostic), ufwFirewallColor(diagnostic)),
                    ("Incoming", ufwDefaultPolicy(diagnostic, direction: "incoming"), ufwPolicyColor(ufwDefaultPolicy(diagnostic, direction: "incoming"))),
                    ("Outgoing", ufwDefaultPolicy(diagnostic, direction: "outgoing"), ufwPolicyColor(ufwDefaultPolicy(diagnostic, direction: "outgoing"))),
                    ("SSH", ufwSSHSummary(diagnostic), ufwSSHSummaryColor(diagnostic)),
                    ("Logging", ufwStatusValue(diagnostic, key: "Logging") ?? "-", .secondary),
                    ("IPv6", ufwConfigValue(diagnostic, key: "IPV6") ?? ufwIPv6Summary(diagnostic), ufwIPv6Color(diagnostic)),
                    ("Rules", "\(diagnostic.rules.count)", .secondary),
                    ("Public Rules", "\(publicRules.count)", publicRules.isEmpty ? .green : .orange),
                ])

                ufwFindingsSection(findings)
                ufwPublicRulesSection(publicRules)
            }
            .padding(16)
        }
    }

    private func ufwSummaryCards(_ items: [(String, String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.1.isEmpty ? "-" : item.1)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(item.2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func ufwFindingsSection(_ findings: [String]) -> some View {
        sectionBox("Findings") {
            if findings.isEmpty {
                Label("No high-risk public UFW exposure found in the numbered rules.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings, id: \.self) { finding in
                        Label(finding, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func ufwPublicRulesSection(_ rules: [UFWDiagnosticRule]) -> some View {
        let shownRules = Array(rules.prefix(10))

        return sectionBox("Public Rules") {
            if rules.isEmpty {
                Text("No public ALLOW or LIMIT rules were detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ufwPublicRuleHeader
                    Divider()
                    ForEach(shownRules) { rule in
                        ufwPublicRuleRow(rule)
                        if rule.id != (shownRules.last?.id ?? rule.id) {
                            Divider()
                        }
                    }
                    if rules.count > shownRules.count {
                        Text("\(rules.count - shownRules.count) more public rules are listed in Rules.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private var ufwPublicRuleHeader: some View {
        HStack(spacing: 8) {
            Text("Port")
                .frame(width: 110, alignment: .leading)
            Text("Service")
                .frame(width: 90, alignment: .leading)
            Text("Source")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Version")
                .frame(width: 58, alignment: .leading)
            Text("Risk")
                .frame(width: 112, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func ufwPublicRuleRow(_ rule: UFWDiagnosticRule) -> some View {
        HStack(spacing: 8) {
            ufwMonoCell(rule.target, width: 110)
            Text(ufwServiceName(for: rule))
                .font(.caption)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            ufwMonoCell(rule.source)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ufwRuleVersion(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            ufwRiskBadge(ufwRisk(for: rule))
                .frame(width: 112, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func ufwFindings(_ diagnostic: UFWDiagnostic) -> [String] {
        var findings = diagnostic.warnings
        let publicRules = ufwPublicOpenRules(diagnostic)

        if ufwIsInactive(diagnostic) {
            findings.append("UFW is inactive; firewall rules are not being enforced.")
        }
        if ufwDefaultPolicy(diagnostic, direction: "incoming").lowercased().contains("allow") {
            findings.append("The default incoming policy allows traffic.")
        }
        if publicRules.contains(where: ufwIsSSHRule) {
            findings.append("SSH is open to anywhere on port \(effectiveSSHPort).")
        }
        if publicRules.contains(where: ufwIsDatabaseRule) {
            findings.append("Postgres is open to anywhere on port 5432.")
        }
        if publicRules.contains(where: { ufwRuleVersion($0) == "IPv6" }) {
            findings.append("IPv6 public allow rules are enabled.")
        }

        var unique: [String] = []
        for finding in findings where !unique.contains(finding) {
            unique.append(finding)
        }
        return unique
    }

    private func ufwPublicOpenRules(_ diagnostic: UFWDiagnostic) -> [UFWDiagnosticRule] {
        diagnostic.rules
            .filter { rule in
                let action = rule.action.lowercased()
                return (action.contains("allow") || action.contains("limit"))
                    && ufwIsPublicSource(rule.source)
            }
            .sorted {
                let lhsRisk = ufwRisk(for: $0)
                let rhsRisk = ufwRisk(for: $1)
                if lhsRisk.rank != rhsRisk.rank {
                    return lhsRisk.rank < rhsRisk.rank
                }
                return $0.number < $1.number
            }
    }

    private var effectiveSSHPort: Int {
        Int(sshPort ?? 22)
    }

    private func ufwStatusValue(_ diagnostic: UFWDiagnostic, key: String) -> String? {
        let prefix = "\(key):".lowercased()
        for line in diagnostic.statusLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func ufwConfigValue(_ diagnostic: UFWDiagnostic, key: String) -> String? {
        let prefix = "\(key)=".lowercased()
        for line in diagnostic.configLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func ufwIsActive(_ diagnostic: UFWDiagnostic) -> Bool {
        let value = ufwStatusValue(diagnostic, key: "Status")?.lowercased() ?? ""
        return value.contains("active") && !value.contains("inactive")
    }

    private func ufwIsInactive(_ diagnostic: UFWDiagnostic) -> Bool {
        ufwStatusValue(diagnostic, key: "Status")?.lowercased().contains("inactive") == true
    }

    private func ufwFirewallStatus(_ diagnostic: UFWDiagnostic) -> String {
        guard let value = ufwStatusValue(diagnostic, key: "Status"), !value.isEmpty else {
            return "Unknown"
        }
        return value.capitalized
    }

    private func ufwFirewallColor(_ diagnostic: UFWDiagnostic) -> Color {
        if ufwIsActive(diagnostic) { return .green }
        if ufwIsInactive(diagnostic) { return .orange }
        return .secondary
    }

    private func ufwDefaultPolicy(_ diagnostic: UFWDiagnostic, direction: String) -> String {
        guard let value = ufwStatusValue(diagnostic, key: "Default") else { return "-" }
        let directionNeedle = "(\(direction.lowercased()))"
        for component in value.split(separator: ",") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains(directionNeedle) {
                return trimmed.replacingOccurrences(of: directionNeedle, with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .capitalized
            }
        }
        return value
    }

    private func ufwPolicyColor(_ policy: String) -> Color {
        let lower = policy.lowercased()
        if lower.contains("deny") || lower.contains("reject") { return .green }
        if lower.contains("allow") { return .orange }
        return .secondary
    }

    private func ufwSSHSummary(_ diagnostic: UFWDiagnostic) -> String {
        if ufwPublicOpenRules(diagnostic).contains(where: ufwIsSSHRule) {
            return "Public on \(effectiveSSHPort)"
        }
        let restrictedSSH = diagnostic.rules.contains { rule in
            let action = rule.action.lowercased()
            return (action.contains("allow") || action.contains("limit"))
                && ufwIsSSHRule(rule)
        }
        return restrictedSSH ? "Restricted" : "No allow rule"
    }

    private func ufwSSHSummaryColor(_ diagnostic: UFWDiagnostic) -> Color {
        let summary = ufwSSHSummary(diagnostic).lowercased()
        if summary.contains("public") { return .orange }
        if summary.contains("restricted") { return .green }
        return .secondary
    }

    private func ufwIPv6Summary(_ diagnostic: UFWDiagnostic) -> String {
        diagnostic.rules.contains { ufwRuleVersion($0) == "IPv6" } ? "yes" : "no"
    }

    private func ufwIPv6Color(_ diagnostic: UFWDiagnostic) -> Color {
        ufwPublicOpenRules(diagnostic).contains { ufwRuleVersion($0) == "IPv6" } ? .orange : .secondary
    }

    private func ufwRisk(for rule: UFWDiagnosticRule) -> UFWRuleRisk {
        let action = rule.action.lowercased()
        guard action.contains("allow") || action.contains("limit") else {
            return action.contains("deny") || action.contains("reject") ? .blocked : .neutral
        }
        guard ufwIsPublicSource(rule.source) else { return .restricted }
        if ufwIsSSHRule(rule) { return .sshExposed }
        if ufwIsDatabaseRule(rule) { return .databaseExposed }
        if ufwIsMailRule(rule) { return .publicMail }
        if ufwIsWebRule(rule) { return .publicWeb }
        return .publicRule
    }

    private func ufwIsSSHRule(_ rule: UFWDiagnosticRule) -> Bool {
        let target = rule.target.lowercased()
        return target.contains("openssh")
            || target.contains("ssh")
            || ufwPorts(in: rule.target).contains(effectiveSSHPort)
    }

    private func ufwIsDatabaseRule(_ rule: UFWDiagnosticRule) -> Bool {
        let target = rule.target.lowercased()
        return target.contains("postgres")
            || target.contains("pgsql")
            || ufwPorts(in: rule.target).contains(5432)
    }

    private func ufwIsWebRule(_ rule: UFWDiagnosticRule) -> Bool {
        let ports = ufwPorts(in: rule.target)
        let target = rule.target.lowercased()
        return ports.contains(80)
            || ports.contains(443)
            || target.contains("http")
            || target.contains("nginx")
            || target.contains("apache")
    }

    private func ufwIsMailRule(_ rule: UFWDiagnosticRule) -> Bool {
        let ports = ufwPorts(in: rule.target)
        return ports.contains(25)
            || ports.contains(143)
            || ports.contains(465)
            || ports.contains(587)
            || ports.contains(993)
            || ports.contains(995)
    }

    private func ufwServiceName(for rule: UFWDiagnosticRule) -> String {
        let target = rule.target.lowercased()
        let ports = ufwPorts(in: rule.target)
        if ufwIsSSHRule(rule) { return "SSH" }
        if ports.contains(80) { return "HTTP" }
        if ports.contains(443) { return "HTTPS" }
        if ufwIsDatabaseRule(rule) { return "Postgres" }
        if ports.contains(25) { return "SMTP" }
        if ports.contains(143) { return "IMAP" }
        if ports.contains(993) { return "IMAPS" }
        if ports.contains(5672) { return "AMQP" }
        if target.contains("dns") || ports.contains(53) { return "DNS" }
        return "-"
    }

    private func ufwPorts(in target: String) -> [Int] {
        target
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }

    private func ufwRuleVersion(_ rule: UFWDiagnosticRule) -> String {
        let value = "\(rule.target) \(rule.source)"
        return value.localizedCaseInsensitiveContains("(v6)") || value.contains(":") ? "IPv6" : "IPv4"
    }

    private func ufwIsPublicSource(_ source: String) -> Bool {
        let sourceOnly = source.components(separatedBy: " # ").first ?? source
        let normalized = sourceOnly
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return [
            "any",
            "anyone",
            "anywhere",
            "anywhere (v6)",
            "0.0.0.0/0",
            "::/0",
            "::/0 (v6)",
        ].contains(normalized)
    }

    private func ufwRiskBadge(_ risk: UFWRuleRisk) -> some View {
        Text(risk.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(risk.color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(risk.color.opacity(0.12), in: Capsule())
    }

    private func ufwMonoCell(_ text: String, width: CGFloat? = nil, color: Color = .primary) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
    }

    private func processHotspotPane(
        processes: [ProcessDiagnosticRow],
        threads: [ThreadDiagnosticRow]
    ) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                hotspotHeader(processes: processes, threads: threads)
                Divider()
                if processes.isEmpty {
                    placeholderPane("No processes reported.")
                        .frame(minHeight: 320, maxHeight: .infinity)
                } else {
                    processTable(processes)
                        .frame(minHeight: 320, maxHeight: .infinity)
                }
                if !threads.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .foregroundStyle(.secondary)
                            Text("Thread Hotspots")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(threads.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        threadTable(threads)
                            .frame(height: 150)
                    }
                    .padding(10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )
            .padding(12)
            .frame(minWidth: 560)

            selectedProcessDetail(processes)
                .padding(16)
                .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func hotspotHeader(
        processes: [ProcessDiagnosticRow],
        threads: [ThreadDiagnosticRow]
    ) -> some View {
        let top = processes.sorted(using: processSortOrder).first
        let header = hotspotHeaderDescriptor

        return HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: header.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.title)
                        .font(.subheadline.weight(.semibold))
                    Text(header.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 180, alignment: .leading)
            Spacer()
            if let top {
                topHotspotBadge(top)
                compactHotspotMetric(
                    "Top RSS",
                    formatKilobytes(top.rssKB),
                    color: processRSSColor(top.rssKB)
                )
                compactHotspotMetric(
                    "Top CPU",
                    String(format: "%.1f%%", top.cpuPercent),
                    color: processCPUColor(top.cpuPercent)
                )
            }
            compactHotspotMetric("Rows", "\(processes.count)", color: .secondary)
            if !threads.isEmpty {
                compactHotspotMetric("Threads", "\(threads.count)", color: .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var hotspotHeaderDescriptor: (title: String, subtitle: String, icon: String) {
        switch drillDown {
        case .memory:
            return ("Memory Hotspots", "Sorted by resident memory", "memorychip")
        case .cpu:
            return ("CPU Hotspots", "Sorted by processor load", "cpu")
        case .disk, .systemdService, .ufw:
            return ("Process Hotspots", "Highest-impact processes first", "flame")
        }
    }

    private func topHotspotBadge(_ process: ProcessDiagnosticRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: processIcon(for: process.command))
                .font(.system(size: 10, weight: .semibold))
            Text(process.command.isEmpty ? "Process \(process.pid)" : process.command)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(processAccentColor(for: process))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 120)
        .background(processAccentColor(for: process).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func compactHotspotMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(minWidth: 52, alignment: .trailing)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }

    private func processTable(_ processes: [ProcessDiagnosticRow]) -> some View {
        let rows = processes.sorted(using: processSortOrder)

        return Table(rows, selection: Binding(
            get: { selectedProcessId },
            set: {
                selectedProcessId = $0
                focusedTitle = nil
                focusedOutput = ""
            }
        ), sortOrder: $processSortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)

            TableColumn("Process", value: \.command) { row in
                processSummaryCell(row)
            }
            .width(min: 180, ideal: 230)

            TableColumn("%CPU", value: \.cpuPercent) { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processCPUColor(row.cpuPercent))
            }
            .width(min: 55, ideal: 65)

            TableColumn("%MEM", value: \.memoryPercent) { row in
                Text(String(format: "%.1f", row.memoryPercent))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processMemoryColor(row.memoryPercent))
            }
            .width(min: 55, ideal: 65)

            TableColumn("RSS", value: \.rssKB) { row in
                Text(row.rssKB == 0 ? "-" : formatKilobytes(row.rssKB))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processRSSColor(row.rssKB))
            }
            .width(min: 70, ideal: 90)
        }
    }

    private func processSummaryCell(_ row: ProcessDiagnosticRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: processIcon(for: row.command))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(processAccentColor(for: row))
                .frame(width: 22, height: 22)
                .background(processAccentColor(for: row).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.command.isEmpty ? "-" : row.command)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(row.user) - \(row.state)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func threadTable(_ threads: [ThreadDiagnosticRow]) -> some View {
        let rows = threads.sorted(using: threadSortOrder)

        return Table(rows, selection: Binding(
            get: { selectedThreadId },
            set: { selectedThreadId = $0 }
        ), sortOrder: $threadSortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)
            TableColumn("TID", value: \.threadSortKey) { row in
                Text(row.threadId)
                    .font(.caption.monospacedDigit())
            }
            .width(min: 70, ideal: 90)
            TableColumn("%CPU", value: \.cpuPercent) { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 60, ideal: 70)
            TableColumn("Command", value: \.command) { row in
                Text(row.command)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private static func defaultProcessSortOrder(
        for drillDown: MonitorDrillDown
    ) -> [KeyPathComparator<ProcessDiagnosticRow>] {
        switch drillDown {
        case .memory:
            return [KeyPathComparator(\.rssKB, order: .reverse)]
        case .cpu:
            return [KeyPathComparator(\.cpuPercent, order: .reverse)]
        case .disk, .systemdService, .ufw:
            return [KeyPathComparator(\.pid)]
        }
    }

    private func selectedProcessDetail(_ processes: [ProcessDiagnosticRow]) -> some View {
        let process = selectedProcessId.flatMap { id in processes.first { $0.pid == id } }
        return VStack(alignment: .leading, spacing: 12) {
            if let process {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: processIcon(for: process.command))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(processAccentColor(for: process))
                        .frame(width: 42, height: 42)
                        .background(processAccentColor(for: process).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.command.isEmpty ? "Process \(process.pid)" : process.command)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(process.user) - PID \(process.pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Process \(process.pid)",
                                script: Self.processInspectionScript(pid: process.pid)
                            )
                        }
                    } label: {
                        Label("Inspect", systemImage: "magnifyingglass")
                    }
                    .disabled(focusedLoading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                    processMetricChip("CPU", String(format: "%.1f%%", process.cpuPercent), color: processCPUColor(process.cpuPercent))
                    processMetricChip("Memory", String(format: "%.1f%%", process.memoryPercent), color: processMemoryColor(process.memoryPercent))
                    processMetricChip("RSS", formatKilobytes(process.rssKB), color: processRSSColor(process.rssKB))
                    processMetricChip("VSZ", formatKilobytes(process.vszKB), color: .secondary)
                }
                processIdentityCard(process)
                sectionBox("Command Line") {
                    rawText(process.arguments.isEmpty ? process.command : process.arguments)
                        .frame(minHeight: 88, maxHeight: 160)
                }
                focusedInspectionPane
            } else {
                placeholderPane("Select a process.")
            }
        }
    }

    private func processIdentityCard(_ process: ProcessDiagnosticRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                processIdentityRow("PID", "\(process.pid)")
                processIdentityDivider
                processIdentityRow("Parent", "\(process.ppid)")
                processIdentityDivider
                processIdentityRow("State", process.state)
                processIdentityDivider
                processIdentityRow("Elapsed", process.elapsed)
                processIdentityDivider
                processIdentityRow("User", process.user)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        )
    }

    private func processIdentityRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var processIdentityDivider: some View {
        Divider()
            .padding(.leading, 90)
    }

    private func processMetricChip(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func processIcon(for command: String) -> String {
        let normalized = command.lowercased()
        if normalized.contains("postgres") || normalized.contains("mysql") {
            return "cylinder.split.1x2"
        }
        if normalized.contains("docker") || normalized.contains("containerd") {
            return "cube.box"
        }
        if normalized.contains("nginx") || normalized.contains("apache") || normalized.contains("http") {
            return "network"
        }
        if normalized.contains("ssh") || normalized.contains("shell") || normalized.contains("bash") {
            return "terminal"
        }
        if normalized.contains("clam") {
            return "cross.case"
        }
        if normalized.contains("java") || normalized.contains("keycloak") {
            return "server.rack"
        }
        return "gearshape.2"
    }

    private func processAccentColor(for process: ProcessDiagnosticRow) -> Color {
        if process.cpuPercent >= 40 {
            return processCPUColor(process.cpuPercent)
        }
        if process.memoryPercent >= 5 {
            return processMemoryColor(process.memoryPercent)
        }
        if process.rssKB >= 524_288 {
            return processRSSColor(process.rssKB)
        }
        return Color.accentColor
    }

    private func processCPUColor(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 40 { return .orange }
        if value >= 10 { return .blue }
        return .secondary
    }

    private func processMemoryColor(_ value: Double) -> Color {
        if value >= 20 { return .red }
        if value >= 5 { return .orange }
        if value >= 1 { return .blue }
        return .secondary
    }

    private func processRSSColor(_ kilobytes: UInt64) -> Color {
        if kilobytes >= 1_048_576 { return .orange }
        if kilobytes >= 524_288 { return .blue }
        return .secondary
    }

    private func diskFilePane(_ diagnostic: DiskDiagnostic) -> some View {
        HSplitView {
            Table(diagnostic.files, selection: Binding(
                get: { selectedFilePath },
                set: {
                    selectedFilePath = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) {
                TableColumn("Size") { file in
                    Text(formatBytes(file.size))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 90, ideal: 110)
                TableColumn("Modified") { file in
                    Text(file.modified)
                        .font(.caption.monospacedDigit())
                }
                .width(min: 130, ideal: 150)
                TableColumn("Owner") { file in
                    Text(file.owner)
                        .font(.caption)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Path") { file in
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(minWidth: 560)

            selectedDiskFileDetail(diagnostic.files)
                .padding(12)
                .frame(minWidth: 340)
        }
    }

    private func selectedDiskFileDetail(_ files: [DiskFileDiagnosticRow]) -> some View {
        let file = selectedFilePath.flatMap { path in files.first { $0.path == path } }
        return VStack(alignment: .leading, spacing: 10) {
            if let file {
                HStack {
                    Text(file.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Directory \(file.directory)",
                                script: Self.directoryInspectionScript(path: file.directory)
                            )
                        }
                    } label: {
                        Label("Inspect Directory", systemImage: "folder.badge.gearshape")
                    }
                    .disabled(focusedLoading)
                }
                keyValuePane([
                    ("Size", formatBytes(file.size)),
                    ("Modified", file.modified),
                    ("Owner", file.owner),
                    ("Directory", file.directory),
                    ("Path", file.path),
                ])
                focusedInspectionPane
            } else {
                placeholderPane("Select a file.")
            }
        }
    }

    private func systemdFilesPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            List(diagnostic.files, selection: Binding(
                get: { selectedSystemdFileId },
                set: { selectedSystemdFileId = $0 }
            )) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.kind)
                        .font(.caption.weight(.semibold))
                    Text(file.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let file = selectedSystemdFileId.flatMap({ id in diagnostic.files.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.path)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    rawPane(file.content)
                }
                .padding(12)
                .frame(minWidth: 420)
            } else {
                placeholderPane("Select a unit, drop-in, or environment file.")
            }
        }
    }

    private func systemdJournalPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            keyValuePane(diagnostic.properties)
                .padding(12)
                .frame(minWidth: 340)
            JournalLogView(
                rawLines: diagnostic.journalLines,
                fallbackHints: diagnostic.warnings
            )
            .padding(12)
            .frame(minWidth: 460)
        }
    }

    @ViewBuilder
    private func serviceSpecificPane(_ diagnostic: SystemdDiagnostic) -> some View {
        if diagnostic.serviceFamily != .generic || !diagnostic.serviceGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: diagnostic.serviceFamily.icon)
                        .foregroundStyle(.secondary)
                    Text(diagnostic.serviceFamily.title)
                        .font(.headline)
                    Spacer()
                    if !diagnostic.serviceFamily.description.isEmpty {
                        Text(diagnostic.serviceFamily.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !diagnostic.serviceGroups.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(diagnostic.serviceGroups) { group in
                            serviceGroupBox(group)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func serviceGroupBox(_ group: ServiceDiagnosticGroup) -> some View {
        let joinedLines = group.lines.joined(separator: "\n")
        let isShellError = joinedLines.contains("unexpected operator") || joinedLines.contains("sh: ") || joinedLines.contains("permission denied") || joinedLines.contains("not found")

        return VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !group.rows.isEmpty {
                inlineKeyValueRows(group.rows)
            }

            if !group.lines.isEmpty {
                if isShellError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Data retrieval issue")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(joinedLines)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                    )
                } else {
                    rawText(joinedLines)
                        .frame(minHeight: 80, maxHeight: 180)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ufwBlockedSourceRows(_ diagnostic: UFWDiagnostic) -> [UFWBlockedSourceRow] {
        var counts: [String: Int] = [:]
        for line in diagnostic.logs {
            guard let range = line.range(of: "SRC=") else { continue }
            let suffix = line[range.upperBound...]
            guard let source = suffix.split(whereSeparator: \.isWhitespace).first else { continue }
            counts[String(source), default: 0] += 1
        }
        return counts
            .map { UFWBlockedSourceRow(source: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.source < $1.source
                }
                return $0.count > $1.count
            }
    }

    private func ufwRulesPane(_ diagnostic: UFWDiagnostic) -> some View {
        let sortedRules = diagnostic.rules.sorted {
            let lhsRisk = ufwRisk(for: $0)
            let rhsRisk = ufwRisk(for: $1)
            if lhsRisk.rank != rhsRisk.rank {
                return lhsRisk.rank < rhsRisk.rank
            }
            return $0.number < $1.number
        }

        return HSplitView {
            Table(sortedRules, selection: Binding(
                get: { selectedUFWRuleId },
                set: {
                    selectedUFWRuleId = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) {
                TableColumn("#") { rule in
                    Text("\(rule.number)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55)

                TableColumn("Action") { rule in
                    Text(rule.action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ufwRisk(for: rule).color)
                }
                .width(min: 80, ideal: 110)

                TableColumn("Port / Service") { rule in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.target)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Text(ufwServiceName(for: rule))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 210)

                TableColumn("Source") { rule in
                    Text(rule.source)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 170, ideal: 240)

                TableColumn("IP") { rule in
                    Text(ufwRuleVersion(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 54)

                TableColumn("Risk") { rule in
                    ufwRiskBadge(ufwRisk(for: rule))
                }
                .width(min: 104, ideal: 122)
            }
            .contextMenu(forSelectionType: Int.self) { selected in
                if let id = selected.first,
                   let rule = diagnostic.rules.first(where: { $0.id == id }) {
                    Button("Copy Rule") { RemoteCommandRunner.copy(rule.raw) }
                    Button("Copy Source") { RemoteCommandRunner.copy(rule.source) }
                    Button("Copy Delete Command") { RemoteCommandRunner.copy("sudo ufw delete \(rule.number)") }
                }
            }
            .padding(12)
            .frame(minWidth: 650)

            if let rule = selectedUFWRuleId.flatMap({ id in diagnostic.rules.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Rule \(rule.number)")
                            .font(.headline)
                        ufwRiskBadge(ufwRisk(for: rule))
                        Spacer()
                        Button {
                            RemoteCommandRunner.copy(rule.raw)
                        } label: {
                            Label("Copy Rule", systemImage: "doc.on.doc")
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy rule")
                    }
                    keyValuePane([
                        ("Action", rule.action),
                        ("Target", rule.target),
                        ("Service", ufwServiceName(for: rule)),
                        ("Source", rule.source),
                        ("IP Version", ufwRuleVersion(rule)),
                        ("Risk", ufwRisk(for: rule).title),
                        ("Raw", rule.raw),
                    ])
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "UFW Source \(rule.source)",
                                script: Self.ufwSourceInspectionScript(source: rule.source)
                            )
                        }
                    } label: {
                        Label("Inspect Source", systemImage: "network")
                    }
                    .disabled(focusedLoading)
                    focusedInspectionPane
                }
                .padding(12)
                .frame(minWidth: 340)
            } else {
                placeholderPane("Select a UFW rule.")
            }
        }
    }

    private func ufwBlockedSourcesPane(_ diagnostic: UFWDiagnostic) -> some View {
        let rows = ufwBlockedSourceRows(diagnostic)

        return HSplitView {
            List(rows, selection: Binding(
                get: { selectedUFWSource },
                set: {
                    selectedUFWSource = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) { row in
                HStack {
                    Text(row.source)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(row.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 260, idealWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                if let source = selectedUFWSource {
                    HStack {
                        Text(source)
                            .font(.headline)
                        Spacer()
                        Button {
                            Task {
                                await runFocusedInspection(
                                    title: "Blocked Source \(source)",
                                    script: Self.ufwSourceInspectionScript(source: source)
                                )
                            }
                        } label: {
                            Label("Inspect Source", systemImage: "network")
                        }
                        .disabled(focusedLoading)
                    }
                    keyValuePane([
                        ("Blocked Lines", "\(rows.first { $0.source == source }?.count ?? 0)"),
                        ("Source", source),
                    ])
                    sectionBox("Related Logs") {
                        rawText(diagnostic.logs.filter { $0.contains(source) }.joined(separator: "\n"))
                    }
                    focusedInspectionPane
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty {
                            placeholderPane("No blocked source IPs were found in the sampled UFW logs.")
                        } else {
                            Text("Select a source to inspect related UFW log lines.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        sectionBox("Recent Blocks") {
                            rawText(diagnostic.logs.joined(separator: "\n"))
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 520)
        }
    }

    // MARK: - Shared UI

    private func overviewPane(_ items: [(String, String)], warnings: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCards(items)
                if !warnings.isEmpty {
                    warningList(warnings)
                }
            }
            .padding(16)
        }
    }

    private func overviewCards(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func warningList(_ warnings: [String]) -> some View {
        sectionBox("Warnings") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func journalIssueSummary(_ counts: JournalIssueCounts) -> some View {
        HStack(spacing: 8) {
            Text("Recent journal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            JournalIssueBadges(counts: counts)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func keyValuePane(_ rows: [(String, String)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let standardRows = rows.filter { !$0.0.contains("ExecStart") }
                let execRows = rows.filter { $0.0.contains("ExecStart") }

                if !standardRows.isEmpty {
                    inlineKeyValueRows(standardRows)
                }

                if !execRows.isEmpty {
                    Divider()
                    ForEach(execRows, id: \.0) { row in
                        CodeBlockView(label: row.0, code: row.1)
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inlineKeyValueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(row.1.isEmpty ? "-" : row.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rawText(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "No data." : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rawPane(_ text: String) -> some View {
        rawText(text.isEmpty && !isLoading ? "No output." : text)
            .padding(16)
    }

    private func placeholderPane(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var focusedInspectionPane: some View {
        if focusedLoading {
            ProgressView("Inspecting...")
                .controlSize(.small)
        } else if !focusedOutput.isEmpty || focusedTitle != nil {
            sectionBox(focusedTitle ?? "Inspection") {
                rawText(focusedOutput)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatMemoryProperty(_ value: String?) -> String {
        guard let value, let bytes = UInt64(value), bytes > 0 else { return "-" }
        return formatBytes(bytes)
    }

    private func formatKilobytes(_ kilobytes: UInt64) -> String {
        formatBytes(kilobytes.multipliedWithoutOverflow(by: 1024))
    }

    private func diagnosticScript() -> String {
        switch drillDown {
        case .cpu:
            return Self.cpuScript
        case .memory:
            return Self.memoryScript
        case .disk(let disk):
            return Self.diskScript(mount: disk.mount)
        case .systemdService(let unit):
            return Self.systemdScript(unit: unit)
        case .ufw:
            return Self.ufwScript(sshPort: sshPort)
        }
    }

    private static let cpuScript = """
    set +e
    export LC_ALL=C

    printf 'INFO\tLoad\t%s\n' "$(uptime 2>/dev/null || true)"
    if command -v nproc >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(nproc 2>/dev/null || true)"
    elif command -v sysctl >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    if command -v mpstat >/dev/null 2>&1; then
      mpstat 1 1 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    fi

    emit_cpu_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 8 && count < 35 {
          args=$9
          for (i=10; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,0,0,$8,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,etime=,args= --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,etime=,command= -r 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    else
      printf 'WARN\tCould not collect process CPU data.\n'
    fi

    if out=$(ps -eLo pid,tid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | awk '
        BEGIN { OFS="\t"; count=0 }
        NR > 1 && NF >= 5 && count < 35 {
          print "THREAD",$1,$2,$3,$4,$5
          count++
        }
      '
    else
      printf 'WARN\tThread-level CPU data is unavailable on this host.\n'
    fi
    """

    private static let memoryScript = """
    set +e
    export LC_ALL=C

    if command -v free >/dev/null 2>&1; then
      free -h 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    elif command -v vm_stat >/dev/null 2>&1; then
      vm_stat 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
      sysctl hw.memsize 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    else
      printf 'WARN\tNo memory summary command found.\n'
    fi

    emit_memory_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 10 && count < 35 {
          args=$11
          for (i=12; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,rss=,vsz=,etime=,args= --sort=-rss 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,rss=,vsz=,etime=,command= -m 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    else
      printf 'WARN\tCould not collect process memory data.\n'
    fi

    if command -v journalctl >/dev/null 2>&1; then
      sudo -n journalctl -k -n 300 --no-pager 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    elif command -v dmesg >/dev/null 2>&1; then
      sudo -n dmesg 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    else
      printf 'WARN\tKernel memory-pressure logs are unavailable.\n'
    fi
    """

    private static func diskScript(mount: String) -> String {
        let quotedMount = RemoteCommandRunner.shellQuote(mount)
        return """
        set +e
        export LC_ALL=C
        mount_path=\(quotedMount)

        usage=$(df -hP "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        [ -n "$usage" ] || usage=$(df -h "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        printf 'MOUNT\t%s\t%s\n' "$mount_path" "$usage"

        if ! command -v find >/dev/null 2>&1; then
          printf 'WARN\tfind is not available on this host.\n'
          exit 0
        fi

        out="${TMPDIR:-/tmp}/agent-ssh-files-$$.tsv"
        err="${TMPDIR:-/tmp}/agent-ssh-files-$$.err"
        trap 'rm -f "$out" "$err"' EXIT
        : > "$out"
        : > "$err"

        find_flags=""
        if find "$mount_path" -xdev -type f -mtime -14 -print -quit >/dev/null 2>&1; then
          find_flags="-xdev"
        fi

        if find "$mount_path" $find_flags -maxdepth 0 -printf '' >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -printf 'FILE\t%s\t%T@\t%TY-%Tm-%Td %TH:%TM\t%u\t%h\t%p\n' > "$out" 2>"$err"
        elif stat -f '%z' "$mount_path" >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -exec stat -f 'FILE\t%z\t%m\t%Sm\t%Su\t%N' -t '%Y-%m-%d %H:%M' {} + > "$out" 2>"$err"
        else
          find "$mount_path" $find_flags -type f -mtime -14 -exec ls -ln {} + 2>"$err" \
            | awk 'BEGIN { OFS="\t" } NF >= 9 { path=$9; for (i=10; i<=NF; i++) path=path " " $i; print "FILE",$5,0,$6 " " $7 " " $8,$3,"",path }' > "$out"
        fi

        if [ -s "$out" ]; then
          sort -nr -k2,2 "$out" | head -n 120
        else
          printf 'WARN\tNo files changed in the last 14 days were found on this mount, or the current user cannot read them.\n'
        fi
        if [ -s "$err" ]; then
          printf 'WARN\tSome paths could not be read while scanning this mount.\n'
        fi
        """
    }

    private static func systemdScript(unit: String) -> String {
        let quotedUnit = RemoteCommandRunner.shellQuote(unit)
        return """
        set +e
        export LC_ALL=C
        unit=\(quotedUnit)

        command -v systemctl >/dev/null 2>&1 || { printf 'WARN\tsystemctl is not available on this host.\n'; exit 127; }

        show_unit() {
          systemctl show "$unit" --no-pager "$@" 2>&1 || sudo -n systemctl show "$unit" --no-pager "$@" 2>&1 || true
        }

        emit_show() {
          show_unit "$@" | awk -F= 'BEGIN { OFS="\t" } NF { key=$1; sub(/^[^=]*=/, ""); print "KV",key,$0 }'
        }

        emit_family() {
          printf 'SVCFAMILY\t%s\n' "$1"
        }

        emit_svc() {
          printf 'SVC\t%s\t%s\t%s\n' "$1" "$2" "$3"
        }

        emit_lines() {
          section="$1"
          shift
          "$@" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_shell_lines() {
          section="$1"
          script="$2"
          sh -lc "$script" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_file() {
          kind="$1"
          file="$2"
          [ -n "$file" ] || return 0
          printf 'FILE\t%s\t%s\n' "$kind" "$file"
          (sudo -n sed -n '1,240p' "$file" 2>&1 || sed -n '1,240p' "$file" 2>&1 || true) \
            | awk -v kind="$kind" -v file="$file" 'BEGIN { OFS="\t" } { print "FILELINE",kind,file,NR,$0 }'
        }

        emit_show \
          -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
          -p User -p Group -p DynamicUser -p SupplementaryGroups \
          -p MainPID -p ExecMainPID -p ExecMainStatus -p Restart -p RestartUSec \
          -p WorkingDirectory -p FragmentPath -p DropInPaths \
          -p Environment -p EnvironmentFiles \
          -p ExecStart -p ExecReload -p ExecStop -p ExecStartPre -p ExecStartPost

        fragment=$(systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || true)
        emit_file "Unit File" "$fragment"

        dropins=$(systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || true)
        if [ -n "$dropins" ]; then
          for file in $dropins; do
            emit_file "Drop-in" "$file"
          done
        fi

        env_files=$(systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || true)
        if [ -n "$env_files" ]; then
          for file in $env_files; do
            file=${file#-}
            emit_file "Environment File" "$file"
          done
        fi

        if command -v journalctl >/dev/null 2>&1; then
          (journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || sudo -n journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || true) \
            | awk 'BEGIN { OFS="\t" } NF { print "JOURNAL",$0 }'
        else
          printf 'WARN\tjournalctl is not available on this host.\n'
        fi

        service_key=$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')
        case "$service_key" in
          *nginx*|*apache2*|*httpd*)
            emit_family web
            if command -v nginx >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "nginx -t"
              emit_shell_lines "Virtual Hosts" "nginx -T 2>/dev/null | awk '/^[[:space:]]*(server_name|listen)[[:space:]]/ {print}' | head -n 160"
            elif command -v apachectl >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "apachectl configtest"
              emit_shell_lines "Virtual Hosts" "apachectl -S 2>&1 | head -n 180"
            fi
            emit_shell_lines "Listeners" "ss -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || netstat -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || true"
            emit_shell_lines "TLS Certificates" "find /etc/letsencrypt/live /etc/ssl -maxdepth 3 -type f \\( -name fullchain.pem -o -name cert.pem -o -name '*.crt' \\) 2>/dev/null | head -n 60 | while read -r cert; do end=$(openssl x509 -noout -enddate -in \"$cert\" 2>/dev/null | sed 's/^notAfter=//'); [ -n \"$end\" ] && printf '%s -> %s\\n' \"$cert\" \"$end\"; done"
            ;;
          *apparmor*)
            emit_family apparmor
            emit_shell_lines "Profile State" "aa-status 2>/dev/null || apparmor_status 2>/dev/null || true"
            emit_shell_lines "Recent Denials" "(journalctl -k -n 600 --no-pager 2>/dev/null || dmesg 2>/dev/null || true) | grep -Ei 'apparmor=.*DENIED|audit.*DENIED' | tail -n 120"
            ;;
          *fail2ban*)
            emit_family fail2ban
            emit_shell_lines "Jails" "fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true"
            emit_shell_lines "Bans" "status=$(fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true); jails=$(printf '%s\\n' \"$status\" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); for jail in $jails; do jail=$(printf '%s' \"$jail\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -n \"$jail\" ] || continue; echo \"-- $jail --\"; fail2ban-client status \"$jail\" 2>/dev/null || sudo -n fail2ban-client status \"$jail\" 2>/dev/null || true; done"
            emit_shell_lines "Recent Log" "tail -n 160 /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -n 160 --no-pager 2>/dev/null || true"
            ;;
          *apt-daily*|*unattended-upgrades*|*apt*)
            emit_family apt
            emit_shell_lines "Timers" "systemctl list-timers '*apt*' '*unattended*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Recent Package Activity" "tail -n 160 /var/log/apt/history.log /var/log/apt/term.log /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null"
            emit_shell_lines "Locks" "lslocks 2>/dev/null | grep -E 'apt|dpkg|unattended' || true"
            ;;
          *certbot*|*letsencrypt*)
            emit_family certbot
            emit_shell_lines "Certificates" "certbot certificates 2>/dev/null || sudo -n certbot certificates 2>/dev/null || true"
            emit_shell_lines "Renewal Timers" "systemctl list-timers '*certbot*' '*letsencrypt*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Renewal Logs" "tail -n 180 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || journalctl -u certbot -n 180 --no-pager 2>/dev/null || true"
            ;;
          *chrony*|*timesyncd*|*ntp*)
            emit_family chrony
            emit_shell_lines "Tracking" "chronyc tracking 2>/dev/null || timedatectl 2>/dev/null || true"
            emit_shell_lines "Sources" "chronyc sources -v 2>/dev/null || timedatectl timesync-status 2>/dev/null || true"
            emit_shell_lines "Recent Sync Logs" "journalctl -u chrony -u chronyd -u systemd-timesyncd -n 140 --no-pager 2>/dev/null || true"
            ;;
          *clamav*|*clamd*|*freshclam*)
            emit_family clamav
            emit_shell_lines "Version" "clamdscan --version 2>/dev/null || clamscan --version 2>/dev/null || freshclam --version 2>/dev/null || true"
            emit_shell_lines "Definitions" "ls -lh /var/lib/clamav 2>/dev/null || true"
            emit_shell_lines "Recent Logs" "tail -n 180 /var/log/clamav/clamav.log /var/log/clamav/freshclam.log 2>/dev/null || journalctl -u clamav-daemon -u clamav-freshclam -n 180 --no-pager 2>/dev/null || true"
            ;;
          *containerd*|*docker*)
            emit_family container
            emit_shell_lines "Runtime" "ctr version 2>/dev/null || docker version --format '{{.Server.Version}}' 2>/dev/null || true"
            emit_shell_lines "Containers" "ctr namespaces list 2>/dev/null; ctr -n default containers list 2>/dev/null | head -n 120; docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>/dev/null | head -n 120"
            emit_shell_lines "Disk Usage" "docker system df 2>/dev/null || du -sh /var/lib/containerd /var/lib/docker 2>/dev/null || true"
            ;;
          *dovecot*)
            emit_family mail
            emit_shell_lines "Dovecot Config" "doveconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Listeners" "ss -ltnp 2>/dev/null | grep -E ':(143|993|110|995)\\b|dovecot' || true"
            emit_shell_lines "Auth Failures" "(journalctl -u dovecot -n 600 --no-pager 2>/dev/null || tail -n 600 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'auth.*fail|failed password|Disconnected.*auth' | tail -n 120"
            ;;
          *postfix*)
            emit_family mail
            emit_shell_lines "Queue" "postqueue -p 2>/dev/null || mailq 2>/dev/null || true"
            emit_shell_lines "Postfix Config" "postconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Flow" "(journalctl -u postfix -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'status=(sent|deferred|bounced)|reject|warning|fatal|connect from' | tail -n 160"
            ;;
          *rsyslog*|*journald*)
            emit_family syslog
            emit_shell_lines "Config Validation" "rsyslogd -N1 2>&1 || true"
            emit_shell_lines "Rules And Targets" "grep -RhsE '^[^#].*(@@?|/var/log|omfwd|imjournal|imuxsock)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | head -n 160"
            emit_shell_lines "Log Disk Usage" "du -sh /var/log/* 2>/dev/null | sort -hr | head -n 80"
            ;;
          *snapd*|*snap*)
            emit_family snap
            emit_shell_lines "Refreshes" "snap changes 2>/dev/null | head -n 120 || true"
            emit_shell_lines "Installed Snaps" "snap list 2>/dev/null | head -n 160 || true"
            emit_shell_lines "Snap Services" "snap services 2>/dev/null | head -n 160 || true"
            ;;
          *ssh*|*sshd*)
            emit_family ssh
            emit_shell_lines "Listeners And Sessions" "ss -ltnp 2>/dev/null | grep -E ':22\\b|sshd' || true; who 2>/dev/null || true"
            emit_shell_lines "Auth Activity" "(journalctl -u ssh -u sshd -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/auth.log /var/log/secure 2>/dev/null || true) | grep -Ei 'Accepted|Failed|Invalid user|Disconnected|Unable to negotiate' | tail -n 160"
            emit_shell_lines "Effective Config" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|allowusers|denyusers|authenticationmethods|maxauthtries)' || true"
            ;;
          *)
            emit_family generic
            emit_shell_lines "Listeners" "mainpid=$(systemctl show \"$unit\" --value -p MainPID 2>/dev/null || true); case \"$mainpid\" in \"\"|0) ;; *) ss -ltnp 2>/dev/null | grep -F \"pid=$mainpid,\" || true ;; esac"
            emit_shell_lines "Recent Warnings" "journalctl -u \"$unit\" -n 300 --no-pager 2>/dev/null | grep -Ei 'error|warn|fail|fatal|denied|timeout' | tail -n 80 || true"
            ;;
        esac
        """
    }

    private static func ufwScript(sshPort: UInt16?) -> String {
        let sshPortValue = sshPort.map { String($0) } ?? "22"
        return """
        set +e
        export LC_ALL=C

        printf 'INFO\tSSHPort\t\(sshPortValue)\n'
        command -v ufw >/dev/null 2>&1 || { printf 'WARN\tufw is not available on this host.\n'; exit 127; }

        run_ufw() {
          sudo -n ufw "$@" 2>&1 || ufw "$@" 2>&1 || true
        }

        run_ufw status verbose | awk 'NF {print "STATUS\t" $0}'
        run_ufw status numbered | awk 'NF {print "RULE\t" $0}'
        run_ufw app list | awk 'NF {print "APP\t" $0}'

        (sudo -n sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || true) | awk 'NF {print "CONFIG\t" $0}'

        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n tail -n 180 /var/log/ufw.log 2>/dev/null
        elif [ -r /var/log/ufw.log ]; then
          tail -n 180 /var/log/ufw.log 2>/dev/null
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 360 --no-pager 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        elif command -v dmesg >/dev/null 2>&1; then
          sudo -n dmesg 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        else
          printf 'WARN\tNo UFW log source found.\n'
        fi | awk 'NF {print "LOG\t" $0}'

        sudo -n iptables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES\t" $0}' || true
        sudo -n ip6tables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES6\t" $0}' || true
        """
    }

    private static func processInspectionScript(pid: Int) -> String {
        """
        set +e
        export LC_ALL=C
        pid=\(pid)
        echo "== Process =="
        ps -fp "$pid" 2>/dev/null || ps -p "$pid" -o pid,ppid,user,stat,comm,pcpu,pmem,etime,args 2>/dev/null || true
        echo
        echo "== /proc status =="
        [ -r "/proc/$pid/status" ] && sed -n '1,220p' "/proc/$pid/status" || echo "/proc status unavailable."
        echo
        echo "== Open files =="
        if command -v lsof >/dev/null 2>&1; then
          lsof -p "$pid" 2>/dev/null | head -n 80 || true
        elif [ -d "/proc/$pid/fd" ]; then
          ls -la "/proc/$pid/fd" 2>/dev/null | head -n 80 || true
        else
          echo "Open-file inspection unavailable."
        fi
        echo
        echo "== Network sockets =="
        if command -v ss >/dev/null 2>&1; then
          ss -tunap 2>/dev/null | grep -F "pid=$pid," | head -n 80 || true
        elif command -v netstat >/dev/null 2>&1; then
          netstat -tunap 2>/dev/null | grep -F "/$pid" | head -n 80 || true
        else
          echo "Socket inspection unavailable."
        fi
        """
    }

    private static func directoryInspectionScript(path: String) -> String {
        let quotedPath = RemoteCommandRunner.shellQuote(path)
        return """
        set +e
        export LC_ALL=C
        dir=\(quotedPath)
        echo "== Directory Usage =="
        if du -h -d 1 "$dir" >/dev/null 2>&1; then
          du -h -d 1 "$dir" 2>/dev/null | sort -hr | head -n 80
        elif du -h --max-depth=1 "$dir" >/dev/null 2>&1; then
          du -h --max-depth=1 "$dir" 2>/dev/null | sort -hr | head -n 80
        else
          du -h "$dir"/* 2>/dev/null | sort -hr | head -n 80 || true
        fi
        echo
        echo "== Recently Changed In Directory =="
        find "$dir" -maxdepth 1 -type f -mtime -14 -exec ls -lh {} + 2>/dev/null | sort -k6,8 | tail -n 80 || true
        """
    }

    private static func ufwSourceInspectionScript(source: String) -> String {
        let quotedSource = RemoteCommandRunner.shellQuote(source)
        return """
        set +e
        export LC_ALL=C
        source_ip=\(quotedSource)
        echo "== Source =="
        printf '%s\n' "$source_ip"
        echo
        echo "== Reverse DNS =="
        (command -v dig >/dev/null 2>&1 && dig +short -x "$source_ip") || (command -v host >/dev/null 2>&1 && host "$source_ip") || echo "Reverse lookup unavailable."
        echo
        echo "== Recent UFW log lines =="
        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif [ -r /var/log/ufw.log ]; then
          grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 1000 --no-pager 2>/dev/null | grep -F "SRC=$source_ip" | tail -n 120 || true
        else
          echo "No log source found."
        fi
        """
    }
}

// MARK: - Journal log view

private enum JournalSeverity: String, CaseIterable, Hashable, Identifiable {
    case error
    case warn
    case info
    case debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .error: return "Errors"
        case .warn:  return "Warnings"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .info:  return "circle.fill"
        case .debug: return "ladybug.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        case .debug: return .secondary
        }
    }
}

private struct JournalLine: Identifiable {
    let id: Int
    let timestamp: String?
    let prefix: String
    let message: String
    let severity: JournalSeverity
    let raw: String

    static func parseAll(_ rawLines: [String]) -> [JournalLine] {
        rawLines.enumerated().map { idx, raw in parse(raw: raw, id: idx) }
    }

    private static func parse(raw: String, id: Int) -> JournalLine {
        let chars = Array(raw)
        let isShortIso = chars.count >= 19
            && chars[4] == "-" && chars[7] == "-" && chars[10] == "T"
            && chars[13] == ":" && chars[16] == ":"

        var timestamp: String? = nil
        var prefix = ""
        var message = raw

        if isShortIso, let firstSpace = raw.firstIndex(of: " ") {
            let isoPart = raw[..<firstSpace]
            timestamp = formatTimestamp(String(isoPart))
            let rest = String(raw[raw.index(after: firstSpace)...])
            if let colonRange = rest.range(of: ": ") {
                prefix = String(rest[..<colonRange.lowerBound])
                message = String(rest[colonRange.upperBound...])
            } else {
                message = rest
            }
        }

        return JournalLine(
            id: id,
            timestamp: timestamp,
            prefix: prefix,
            message: message,
            severity: severity(for: message),
            raw: raw
        )
    }

    private static func formatTimestamp(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let timePart = iso[iso.index(after: tIndex)...]
        let stopIdx = timePart.firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "." }
        if let stopIdx { return String(timePart[..<stopIdx]) }
        return String(timePart)
    }

    private static let errorRegex = try? NSRegularExpression(
        pattern: #"\b(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)\b"#,
        options: [.caseInsensitive]
    )
    private static let warnRegex = try? NSRegularExpression(
        pattern: #"\b(warn|warning|deprecated|timeout|timed\s*out|retry|retrying|deferred|refused|rejected)\b"#,
        options: [.caseInsensitive]
    )
    private static let debugRegex = try? NSRegularExpression(
        pattern: #"\b(debug|trace)\b"#,
        options: [.caseInsensitive]
    )

    private static func severity(for message: String) -> JournalSeverity {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        if errorRegex?.firstMatch(in: message, range: range) != nil { return .error }
        if warnRegex?.firstMatch(in: message, range: range) != nil { return .warn }
        if debugRegex?.firstMatch(in: message, range: range) != nil { return .debug }
        return .info
    }

    private static let ipv4Regex = try? NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    )

    var extractedIPv4: String? {
        guard let regex = JournalLine.ipv4Regex else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let r = Range(match.range, in: message) else { return nil }
        return String(message[r])
    }
}

private struct JournalLogView: View {
    let rawLines: [String]
    var fallbackHints: [String] = []

    @State private var searchText = ""
    @State private var enabledSeverities: Set<JournalSeverity> = Set(JournalSeverity.allCases)
    @State private var pinnedIDs: Set<Int> = []
    @State private var jumpCursor: Int?

    private var lines: [JournalLine] { JournalLine.parseAll(rawLines) }

    private var counts: [JournalSeverity: Int] {
        var c: [JournalSeverity: Int] = [:]
        for line in lines { c[line.severity, default: 0] += 1 }
        return c
    }

    private var filtered: [JournalLine] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lines.filter { line in
            guard enabledSeverities.contains(line.severity) else { return false }
            if needle.isEmpty { return true }
            return line.raw.lowercased().contains(needle)
        }
    }

    private var pinnedLines: [JournalLine] {
        lines.filter { pinnedIDs.contains($0.id) }
    }

    private var issueIDs: [Int] {
        filtered
            .filter { $0.severity == .error || $0.severity == .warn }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controls
            Group {
                if filtered.isEmpty && pinnedLines.isEmpty {
                    placeholder
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !pinnedLines.isEmpty {
                                    pinnedSection
                                }
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, line in
                                    row(line, isPinned: pinnedIDs.contains(line.id))
                                        .id(line.id)
                                    if index < filtered.count - 1 {
                                        Divider().opacity(0.18)
                                    }
                                }
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: jumpCursor) { newValue in
                            guard let target = newValue else { return }
                            withAnimation(.snappy) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Recent Journal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("(\(filtered.count) of \(lines.count))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            issueNavigator
            exportMenu
        }
    }

    @ViewBuilder
    private var issueNavigator: some View {
        if !issueIDs.isEmpty {
            HStack(spacing: 2) {
                Button {
                    jumpToIssue(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Previous issue (error or warning)")

                Text("\(issueIDs.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .frame(minWidth: 18)

                Button {
                    jumpToIssue(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Next issue (error or warning)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.30), lineWidth: 0.5))
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                copyFiltered()
            } label: {
                Label("Copy filtered (\(filtered.count) lines)", systemImage: "doc.on.doc")
            }
            .disabled(filtered.isEmpty)

            Button {
                copyAll()
            } label: {
                Label("Copy all (\(lines.count) lines)", systemImage: "doc.on.doc.fill")
            }
            .disabled(lines.isEmpty)

            Divider()

            Button {
                saveFiltered()
            } label: {
                Label("Save filtered as .log…", systemImage: "square.and.arrow.down")
            }
            .disabled(filtered.isEmpty)

            if !pinnedIDs.isEmpty {
                Divider()
                Button(role: .destructive) {
                    pinnedIDs.removeAll()
                } label: {
                    Label("Unpin all (\(pinnedIDs.count))", systemImage: "pin.slash")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy or export journal lines")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            severityPills
            Spacer(minLength: 8)
            searchField
        }
    }

    private var severityPills: some View {
        HStack(spacing: 6) {
            ForEach(JournalSeverity.allCases) { severity in
                let count = counts[severity] ?? 0
                let isOn = enabledSeverities.contains(severity)
                Button {
                    toggle(severity)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: severity.symbol)
                            .font(.caption2)
                            .foregroundStyle(isOn ? severity.color : .secondary)
                        Text("\(count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isOn ? severity.color : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (isOn ? severity.color.opacity(0.14) : Color.gray.opacity(0.10)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            isOn ? severity.color.opacity(0.35) : Color.clear,
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("\(severity.label): \(count) — click to toggle")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
    }

    // MARK: Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text("Pinned (\(pinnedLines.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ForEach(Array(pinnedLines.enumerated()), id: \.element.id) { index, line in
                row(line, isPinned: true)
                if index < pinnedLines.count - 1 {
                    Divider().opacity(0.18)
                }
            }
            Divider()
                .overlay(Color.yellow.opacity(0.40))
        }
        .background(Color.yellow.opacity(0.06))
    }

    // MARK: Placeholder

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: lines.isEmpty ? "tray" : "text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(placeholderText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if lines.isEmpty, !fallbackHints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(fallbackHints.enumerated()), id: \.offset) { _, hint in
                        Label(hint, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var placeholderText: String {
        if lines.isEmpty { return "No journal entries." }
        if !searchText.isEmpty { return "No matches for \"\(searchText)\"." }
        return "All severities are filtered out — re-enable one above."
    }

    // MARK: Row

    private func row(_ line: JournalLine, isPinned: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                togglePin(line.id)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.caption2)
                    .foregroundStyle(isPinned ? Color.yellow : Color.gray.opacity(0.35))
            }
            .buttonStyle(.plain)
            .frame(width: 12, alignment: .center)
            .padding(.top, 3)
            .help(isPinned ? "Unpin" : "Pin")

            Image(systemName: line.severity.symbol)
                .font(.caption2)
                .foregroundStyle(line.severity.color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            if let timestamp = line.timestamp {
                Text(timestamp)
                    .font(.system(.caption2, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .leading)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 1) {
                if !line.prefix.isEmpty {
                    Text(line.prefix)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(highlightedMessage(line.message))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(messageColor(for: line.severity))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(jumpCursor == line.id ? Color.accentColor.opacity(0.14) : Color.clear)
        .contextMenu {
            Button(isPinned ? "Unpin line" : "Pin line") {
                togglePin(line.id)
            }
            Button("Copy line") {
                RemoteCommandRunner.copy(line.raw)
            }
            if let ip = line.extractedIPv4 {
                Button("Copy IP \(ip)") {
                    RemoteCommandRunner.copy(ip)
                }
            }
            if let timestamp = line.timestamp {
                Button("Copy timestamp \(timestamp)") {
                    RemoteCommandRunner.copy(timestamp)
                }
            }
        }
    }

    private func messageColor(for severity: JournalSeverity) -> Color {
        switch severity {
        case .error, .warn: return severity.color
        case .info:         return .primary
        case .debug:        return .secondary
        }
    }

    private func highlightedMessage(_ message: String) -> AttributedString {
        var attributed = AttributedString(message)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(of: needle, options: .caseInsensitive) {
            attributed[found].backgroundColor = Color.yellow.opacity(0.45)
            attributed[found].foregroundColor = Color.black
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }

    // MARK: Actions

    private func toggle(_ severity: JournalSeverity) {
        if enabledSeverities.contains(severity) {
            if enabledSeverities.count == 1 {
                enabledSeverities = Set(JournalSeverity.allCases)
            } else {
                enabledSeverities.remove(severity)
            }
        } else {
            enabledSeverities.insert(severity)
        }
    }

    private func togglePin(_ id: Int) {
        if pinnedIDs.contains(id) {
            pinnedIDs.remove(id)
        } else {
            pinnedIDs.insert(id)
        }
    }

    private func jumpToIssue(forward: Bool) {
        guard !issueIDs.isEmpty else { return }
        if let cursor = jumpCursor, let idx = issueIDs.firstIndex(of: cursor) {
            let next = forward
                ? (idx + 1) % issueIDs.count
                : (idx - 1 + issueIDs.count) % issueIDs.count
            jumpCursor = issueIDs[next]
        } else {
            jumpCursor = forward ? issueIDs.first : issueIDs.last
        }
    }

    private func copyFiltered() {
        RemoteCommandRunner.copy(filtered.map(\.raw).joined(separator: "\n"))
    }

    private func copyAll() {
        RemoteCommandRunner.copy(lines.map(\.raw).joined(separator: "\n"))
    }

    private func saveFiltered() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "journal-\(Self.nowSlug()).log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let body = filtered.map(\.raw).joined(separator: "\n")
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func nowSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Monitor diagnostic data

private enum DrillDownMode: String, CaseIterable {
    case overview = "Overview"
    case hotspots = "Hotspots"
    case details = "Details"
    case raw = "Raw"

    func title(for drillDown: MonitorDrillDown) -> String {
        switch (drillDown, self) {
        case (.ufw, .details):
            return "Rules"
        default:
            return rawValue
        }
    }
}

private enum MonitorDiagnosticSnapshot {
    case cpu(CPUDiagnostic)
    case memory(MemoryDiagnostic)
    case disk(DiskDiagnostic)
    case systemd(SystemdDiagnostic)
    case ufw(UFWDiagnostic)
}

private struct ProcessDiagnosticRow: Identifiable {
    let pid: Int
    let ppid: Int
    let user: String
    let state: String
    let command: String
    let cpuPercent: Double
    let memoryPercent: Double
    let rssKB: UInt64
    let vszKB: UInt64
    let elapsed: String
    let arguments: String

    var id: Int { pid }
}

private struct ThreadDiagnosticRow: Identifiable {
    let pid: Int
    let threadId: String
    let cpuPercent: Double
    let memoryPercent: Double
    let command: String

    var id: String { "\(pid):\(threadId)" }
    var threadSortKey: Int { Int(threadId) ?? 0 }
}

private struct CPUDiagnostic {
    var load = ""
    var cores = ""
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var threads: [ThreadDiagnosticRow] = []
    var warnings: [String] = []
}

private struct MemoryDiagnostic {
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var events: [String] = []
    var warnings: [String] = []
}

private struct DiskDiagnostic {
    var mount = ""
    var usage = ""
    var files: [DiskFileDiagnosticRow] = []
    var warnings: [String] = []
}

private struct DiskFileDiagnosticRow: Identifiable {
    let size: UInt64
    let modifiedEpoch: Double
    let modified: String
    let owner: String
    let directory: String
    let path: String

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? path
            : URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct SystemdDiagnostic {
    var properties: [(String, String)] = []
    var files: [SystemdFileDiagnostic] = []
    var journalLines: [String] = []
    var warnings: [String] = []
    var serviceFamily = LinuxServiceFamily.generic
    var serviceGroups: [ServiceDiagnosticGroup] = []

    var journalIssueCounts: JournalIssueCounts {
        JournalIssueClassifier.counts(in: journalLines)
    }

    func value(for key: String) -> String? {
        properties.first { $0.0 == key }?.1
    }

    mutating func appendServiceRow(section: String, label: String, value: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].rows.append((label, value))
    }

    mutating func appendServiceLine(section: String, line: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].lines.append(line)
    }

    private mutating func serviceGroupIndex(for section: String) -> Int {
        let title = section.isEmpty ? "Service" : section
        if let index = serviceGroups.firstIndex(where: { $0.title == title }) {
            return index
        }
        serviceGroups.append(ServiceDiagnosticGroup(title: title))
        return serviceGroups.count - 1
    }
}

private struct SystemdFileDiagnostic: Identifiable {
    let kind: String
    let path: String
    var lines: [String]

    var id: String { "\(kind):\(path)" }
    var content: String { lines.joined(separator: "\n") }
}

private struct ServiceDiagnosticGroup: Identifiable {
    let title: String
    var rows: [(String, String)] = []
    var lines: [String] = []

    var id: String { title }
}

private enum LinuxServiceFamily: String {
    case generic
    case web
    case apparmor
    case fail2ban
    case apt
    case certbot
    case chrony
    case clamav
    case container
    case mail
    case syslog
    case snap
    case ssh

    var title: String {
        switch self {
        case .generic:  return "Generic Service"
        case .web:      return "Web Server"
        case .apparmor: return "AppArmor"
        case .fail2ban: return "Fail2ban"
        case .apt:      return "APT Automation"
        case .certbot:  return "Certificate Renewal"
        case .chrony:   return "Time Sync"
        case .clamav:   return "Malware Scanning"
        case .container:return "Container Runtime"
        case .mail:     return "Mail Service"
        case .syslog:   return "System Logging"
        case .snap:     return "Snap Packages"
        case .ssh:      return "SSH Access"
        }
    }

    var description: String {
        switch self {
        case .generic:  return ""
        case .web:      return "listeners, vhosts, TLS, config test"
        case .apparmor: return "profiles and denials"
        case .fail2ban: return "jails, bans, offenders"
        case .apt:      return "timers and package activity"
        case .certbot:  return "certificates and renewals"
        case .chrony:   return "offset, sources, sync health"
        case .clamav:   return "definitions and scan health"
        case .container:return "namespaces, containers, disk hints"
        case .mail:     return "queues, listeners, auth/mail logs"
        case .syslog:   return "pipeline validation and log targets"
        case .snap:     return "refreshes, snaps, services"
        case .ssh:      return "listeners, sessions, auth signals"
        }
    }

    var icon: String {
        switch self {
        case .generic:  return "switch.2"
        case .web:      return "network"
        case .apparmor: return "shield.lefthalf.filled"
        case .fail2ban: return "hand.raised"
        case .apt:      return "shippingbox"
        case .certbot:  return "lock.doc"
        case .chrony:   return "clock"
        case .clamav:   return "cross.case"
        case .container:return "cube.box"
        case .mail:     return "envelope"
        case .syslog:   return "doc.text.magnifyingglass"
        case .snap:     return "sparkles"
        case .ssh:      return "terminal"
        }
    }
}

private struct UFWDiagnostic {
    var info: [(String, String)] = []
    var statusLines: [String] = []
    var rules: [UFWDiagnosticRule] = []
    var logs: [String] = []
    var configLines: [String] = []
    var rawTables: [String] = []
    var warnings: [String] = []

    var blockedSources: [String] {
        let values = logs.compactMap { line -> String? in
            guard let range = line.range(of: "SRC=") else { return nil }
            let suffix = line[range.upperBound...]
            return suffix.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return Array(Set(values)).sorted()
    }
}

private struct UFWDiagnosticRule: Identifiable {
    let id: Int
    let number: Int
    let target: String
    let action: String
    let source: String
    let raw: String
}

private struct UFWBlockedSourceRow: Identifiable {
    let source: String
    let count: Int

    var id: String { source }
}

private enum UFWRuleRisk {
    case sshExposed
    case databaseExposed
    case publicMail
    case publicWeb
    case publicRule
    case restricted
    case blocked
    case neutral

    var title: String {
        switch self {
        case .sshExposed: return "SSH exposed"
        case .databaseExposed: return "DB exposed"
        case .publicMail: return "Public mail"
        case .publicWeb: return "Public web"
        case .publicRule: return "Public"
        case .restricted: return "Restricted"
        case .blocked: return "Blocked"
        case .neutral: return "Neutral"
        }
    }

    var color: Color {
        switch self {
        case .sshExposed, .databaseExposed:
            return .red
        case .publicMail, .publicRule:
            return .orange
        case .publicWeb:
            return .blue
        case .restricted, .blocked:
            return .green
        case .neutral:
            return .secondary
        }
    }

    var rank: Int {
        switch self {
        case .sshExposed: return 0
        case .databaseExposed: return 1
        case .publicMail: return 2
        case .publicRule: return 3
        case .publicWeb: return 4
        case .restricted: return 5
        case .blocked: return 6
        case .neutral: return 7
        }
    }
}

private enum MonitorDiagnosticParser {
    static func parse(_ output: String, kind: MonitorDrillDown) -> MonitorDiagnosticSnapshot {
        switch kind {
        case .cpu:
            return .cpu(parseCPU(output))
        case .memory:
            return .memory(parseMemory(output))
        case .disk:
            return .disk(parseDisk(output))
        case .systemdService:
            return .systemd(parseSystemd(output))
        case .ufw:
            return .ufw(parseUFW(output))
        }
    }

    private static func parseCPU(_ output: String) -> CPUDiagnostic {
        var diagnostic = CPUDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                if fields[1] == "Load" {
                    diagnostic.load = joined(fields, from: 2)
                } else if fields[1] == "Cores" {
                    diagnostic.cores = joined(fields, from: 2)
                }
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "THREAD":
                if fields.count >= 6 {
                    diagnostic.threads.append(ThreadDiagnosticRow(
                        pid: int(fields[1]),
                        threadId: fields[2],
                        cpuPercent: double(fields[3]),
                        memoryPercent: double(fields[4]),
                        command: joined(fields, from: 5)
                    ))
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.cpuPercent > $1.cpuPercent }
        diagnostic.threads.sort { $0.cpuPercent > $1.cpuPercent }
        return diagnostic
    }

    private static func parseMemory(_ output: String) -> MemoryDiagnostic {
        var diagnostic = MemoryDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "EVENT":
                diagnostic.events.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.rssKB > $1.rssKB }
        return diagnostic
    }

    private static func parseDisk(_ output: String) -> DiskDiagnostic {
        var diagnostic = DiskDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "MOUNT":
                diagnostic.mount = fields.count > 1 ? fields[1] : ""
                diagnostic.usage = fields.count > 2 ? joined(fields, from: 2) : ""
            case "FILE":
                if let row = parseDiskFile(fields) {
                    diagnostic.files.append(row)
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.files.sort {
            if $0.size == $1.size {
                return $0.modifiedEpoch > $1.modifiedEpoch
            }
            return $0.size > $1.size
        }
        return diagnostic
    }

    private static func parseSystemd(_ output: String) -> SystemdDiagnostic {
        var diagnostic = SystemdDiagnostic()
        var fileOrder: [String] = []
        var filesById: [String: SystemdFileDiagnostic] = [:]

        for fields in records(output) {
            switch fields.first {
            case "KV":
                guard fields.count >= 3 else { continue }
                diagnostic.properties.append((fields[1], joined(fields, from: 2)))
            case "FILE":
                guard fields.count >= 3 else { continue }
                let file = SystemdFileDiagnostic(kind: fields[1], path: fields[2], lines: [])
                if filesById[file.id] == nil {
                    fileOrder.append(file.id)
                }
                filesById[file.id] = file
            case "FILELINE":
                guard fields.count >= 5 else { continue }
                let kind = fields[1]
                let path = fields[2]
                let id = "\(kind):\(path)"
                if filesById[id] == nil {
                    fileOrder.append(id)
                    filesById[id] = SystemdFileDiagnostic(kind: kind, path: path, lines: [])
                }
                filesById[id]?.lines.append(joined(fields, from: 4))
            case "JOURNAL":
                diagnostic.journalLines.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            case "SVCFAMILY":
                if fields.count >= 2 {
                    diagnostic.serviceFamily = LinuxServiceFamily(rawValue: fields[1]) ?? .generic
                }
            case "SVC":
                guard fields.count >= 4 else { continue }
                diagnostic.appendServiceRow(
                    section: fields[1],
                    label: fields[2],
                    value: joined(fields, from: 3)
                )
            case "SVCLINE":
                guard fields.count >= 3 else { continue }
                diagnostic.appendServiceLine(
                    section: fields[1],
                    line: joined(fields, from: 2)
                )
            default:
                continue
            }
        }

        diagnostic.files = fileOrder.compactMap { filesById[$0] }
        return diagnostic
    }

    private static func parseUFW(_ output: String) -> UFWDiagnostic {
        var diagnostic = UFWDiagnostic()
        var fallbackRuleId = 10_000

        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                diagnostic.info.append((fields[1], joined(fields, from: 2)))
            case "STATUS":
                diagnostic.statusLines.append(joined(fields, from: 1))
            case "RULE":
                let raw = joined(fields, from: 1)
                if let rule = parseUFWRule(raw, fallbackId: fallbackRuleId) {
                    diagnostic.rules.append(rule)
                    fallbackRuleId += 1
                }
            case "LOG":
                diagnostic.logs.append(joined(fields, from: 1))
            case "CONFIG":
                diagnostic.configLines.append(joined(fields, from: 1))
            case "IPTABLES", "IPTABLES6":
                diagnostic.rawTables.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }

        diagnostic.rules.sort { $0.number < $1.number }
        return diagnostic
    }

    private static func parseProcess(_ fields: [String]) -> ProcessDiagnosticRow? {
        guard fields.count >= 12 else { return nil }
        return ProcessDiagnosticRow(
            pid: int(fields[1]),
            ppid: int(fields[2]),
            user: fields[3],
            state: fields[4],
            command: fields[5],
            cpuPercent: double(fields[6]),
            memoryPercent: double(fields[7]),
            rssKB: uint(fields[8]),
            vszKB: uint(fields[9]),
            elapsed: fields[10],
            arguments: joined(fields, from: 11)
        )
    }

    private static func parseDiskFile(_ fields: [String]) -> DiskFileDiagnosticRow? {
        guard fields.count >= 6 else { return nil }
        let size = uint(fields[1])
        let modifiedEpoch = double(fields[2])
        let modified = fields[3]
        let owner = fields[4]

        let directory: String
        let path: String
        if fields.count >= 7 {
            directory = fields[5]
            path = joined(fields, from: 6)
        } else {
            path = joined(fields, from: 5)
            directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return DiskFileDiagnosticRow(
            size: size,
            modifiedEpoch: modifiedEpoch,
            modified: modified,
            owner: owner.isEmpty ? "-" : owner,
            directory: directory.isEmpty ? "/" : directory,
            path: path
        )
    }

    private static func parseUFWRule(_ raw: String, fallbackId: Int) -> UFWDiagnosticRule? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return nil }

        let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|DENY(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?|REJECT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 5,
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let targetRange = Range(match.range(at: 2), in: trimmed),
              let actionRange = Range(match.range(at: 3), in: trimmed),
              let sourceRange = Range(match.range(at: 4), in: trimmed)
        else {
            return UFWDiagnosticRule(
                id: fallbackId,
                number: fallbackId,
                target: trimmed,
                action: "Unknown",
                source: "",
                raw: raw
            )
        }

        let number = int(String(trimmed[numberRange]))
        return UFWDiagnosticRule(
            id: number,
            number: number,
            target: String(trimmed[targetRange]).trimmingCharacters(in: .whitespaces),
            action: String(trimmed[actionRange]).trimmingCharacters(in: .whitespaces),
            source: String(trimmed[sourceRange]).trimmingCharacters(in: .whitespaces),
            raw: raw
        )
    }

    private static func records(_ output: String) -> [[String]] {
        output
            .split(whereSeparator: \.isNewline)
            .map { line in
                String(line).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
    }

    private static func joined(_ fields: [String], from index: Int) -> String {
        guard fields.count > index else { return "" }
        return fields[index...].joined(separator: "\t")
    }

    private static func int(_ value: String) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func uint(_ value: String) -> UInt64 {
        UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func double(_ value: String) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private extension UInt64 {
    func multipliedWithoutOverflow(by rhs: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : value
    }
}

// MARK: - Connection world map

private struct ConnectionWorldMapView: View {
    let connectionId: String

    @State private var snapshot = RemoteIPMapSnapshot.empty
    @State private var isLoading = false
    @State private var lastError: String?

    private static let pollInterval: UInt64 = 60_000_000_000
    private static let maxGeolocatedIPs = 24
    private static let remoteAddressScript = """
    set +e

    emit_connected() {
      [ -n "$1" ] || return 0
      printf 'CONNECTED\\t%s\\n' "$1"
    }

    if [ -n "${SSH_CONNECTION:-}" ]; then
      set -- $SSH_CONNECTION
      emit_connected "$1"
    fi

    if [ -n "${SSH_CLIENT:-}" ]; then
      set -- $SSH_CLIENT
      emit_connected "$1"
    fi

    if command -v ss >/dev/null 2>&1; then
      ss -Htn state established 2>/dev/null | awk 'NF >= 5 {print "CONNECTED\\t" $NF}'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ant 2>/dev/null | awk 'toupper($0) ~ /ESTABLISHED/ && NF >= 5 {print "CONNECTED\\t" $(NF-1)}'
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
      f2b_status="$(sudo -n fail2ban-client status 2>/dev/null || fail2ban-client status 2>/dev/null || true)"
      jails="$(printf '%s\\n' "$f2b_status" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
      for jail in $jails; do
        jail="$(printf '%s' "$jail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$jail" ] || continue
        (sudo -n fail2ban-client status "$jail" 2>/dev/null || fail2ban-client status "$jail" 2>/dev/null || true) \
          | sed -n 's/.*Banned IP list:[[:space:]]*//p' \
          | tr ' ' '\\n' \
          | awk 'NF {print "BANNED\\t" $1}'
      done
    fi

    if command -v ufw >/dev/null 2>&1; then
      if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
        sudo -n tail -n 500 /var/log/ufw.log 2>/dev/null
      elif command -v journalctl >/dev/null 2>&1; then
        sudo -n journalctl -k -n 500 --no-pager 2>/dev/null
      else
        true
      fi | awk 'index($0, "[UFW BLOCK]") || index($0, "[UFW DENY]") {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^SRC=/) {
            sub(/^SRC=/, "", $i)
            print "BANNED\\t" $i
          }
        }
      }'
    fi
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Connection Map")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else if let updatedAt = snapshot.updatedAt {
                    Text(updatedAt.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            WorldMapCanvas(points: snapshot.points)
                .frame(height: 132)
                .help("Public IP geolocation is approximate.")

            HStack(spacing: 12) {
                mapLegend(color: .green, label: "Connected", count: snapshot.connectedCount)
                mapLegend(color: .red, label: "Blocked", count: snapshot.bannedCount)
                Spacer()
                if snapshot.truncatedCount > 0 {
                    Text("+\(snapshot.truncatedCount) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if snapshot.connectedCount == 0 && snapshot.bannedCount == 0 && !isLoading {
                Text("No public connected or banned IPs found.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .task(id: connectionId) {
            await pollLoop()
        }
    }

    private func mapLegend(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label) \(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func pollLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: Self.remoteAddressScript
            )
            let addresses = RemoteIPParser.parse(result.output)
            let sourceIPs = Self.cappedSourceIPs(
                connected: addresses.connected,
                banned: addresses.banned
            )
            let locations = await IPGeolocationService.shared.lookup(sourceIPs.visible)
            snapshot = RemoteIPMapSnapshot(
                connectedCount: addresses.connected.count,
                bannedCount: addresses.banned.count,
                truncatedCount: sourceIPs.truncated,
                points: makePoints(
                    connected: addresses.connected,
                    banned: addresses.banned,
                    locations: locations
                ),
                updatedAt: Date()
            )
            lastError = result.succeeded ? nil : "Remote IP scan exited with code \(result.exitCode)."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func cappedSourceIPs(
        connected: [String],
        banned: [String]
    ) -> (visible: [String], truncated: Int) {
        let all = RemoteIPParser.unique(connected + banned)
        let visible = Array(all.prefix(maxGeolocatedIPs))
        return (visible, max(0, all.count - visible.count))
    }

    private func makePoints(
        connected: [String],
        banned: [String],
        locations: [String: IPGeolocation]
    ) -> [RemoteIPMapPoint] {
        let connectedOnly = connected.filter { !banned.contains($0) }
        let connectedPoints = connectedOnly.compactMap { ip -> RemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return RemoteIPMapPoint(ip: ip, kind: .connected, location: location)
        }
        let bannedPoints = banned.compactMap { ip -> RemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return RemoteIPMapPoint(ip: ip, kind: .banned, location: location)
        }
        return connectedPoints + bannedPoints
    }
}

private struct RemoteIPMapSnapshot {
    let connectedCount: Int
    let bannedCount: Int
    let truncatedCount: Int
    let points: [RemoteIPMapPoint]
    let updatedAt: Date?

    static let empty = RemoteIPMapSnapshot(
        connectedCount: 0,
        bannedCount: 0,
        truncatedCount: 0,
        points: [],
        updatedAt: nil
    )
}

private enum RemoteIPMapPointKind {
    case connected
    case banned

    var color: Color {
        switch self {
        case .connected: return .green
        case .banned:    return .red
        }
    }

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .banned:    return "Banned"
        }
    }
}

private struct RemoteIPMapPoint: Identifiable {
    let ip: String
    let kind: RemoteIPMapPointKind
    let location: IPGeolocation

    var id: String { "\(kind.title):\(ip)" }

    var helpText: String {
        let place = [location.city, location.country]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        return place.isEmpty ? "\(kind.title): \(ip)" : "\(kind.title): \(ip) - \(place)"
    }
}

private struct WorldMapCanvas: View {
    let points: [RemoteIPMapPoint]

    @State private var region = Self.worldRegion

    private static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 145, longitudeDelta: 360)
    )

    private var regionKey: String {
        points
            .map { point in
                "\(point.id):\(point.location.coordinate.latitude):\(point.location.coordinate.longitude)"
            }
            .joined(separator: "|")
    }

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: points) { point in
            MapAnnotation(coordinate: point.location.coordinate.mapCoordinate) {
                Circle()
                    .fill(point.kind.color)
                    .frame(width: point.kind == .banned ? 10 : 9, height: point.kind == .banned ? 10 : 9)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.25)
                    )
                    .shadow(color: point.kind.color.opacity(0.65), radius: 5)
                    .help(point.helpText)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            fitRegionToPoints()
        }
        .onChange(of: regionKey) { _ in
            fitRegionToPoints()
        }
    }

    private func fitRegionToPoints() {
        guard !points.isEmpty else {
            region = Self.worldRegion
            return
        }

        let latitudes = points.map(\.location.coordinate.latitude)
        let longitudes = points.map(\.location.coordinate.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max()
        else {
            region = Self.worldRegion
            return
        }

        let longitudeFit = Self.fittedLongitudeCenterAndSpan(longitudes)
        let latitudeDelta = Self.paddedDelta(maxLatitude - minLatitude, minimum: 18, maximum: 145)
        let longitudeDelta = Self.paddedDelta(longitudeFit.span, minimum: 28, maximum: 360)
        let latitudeCenter = max(-72, min(72, (minLatitude + maxLatitude) / 2))

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: latitudeCenter,
                longitude: Self.normalizedLongitude(longitudeFit.center)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    private static func paddedDelta(_ delta: Double, minimum: Double, maximum: Double) -> Double {
        let padded = delta <= 0 ? minimum : delta * 1.4 + minimum * 0.35
        return min(maximum, max(minimum, padded))
    }

    private static func fittedLongitudeCenterAndSpan(_ longitudes: [Double]) -> (center: Double, span: Double) {
        guard !longitudes.isEmpty else { return (0, 360) }
        let sorted = longitudes
            .map { normalized360($0) }
            .sorted()
        guard sorted.count > 1 else {
            return (sorted[0], 0)
        }

        var largestGap = -1.0
        var gapAfterIndex = 0
        for index in sorted.indices {
            let current = sorted[index]
            let next = index == sorted.index(before: sorted.endIndex)
                ? sorted[0] + 360
                : sorted[sorted.index(after: index)]
            let gap = next - current
            if gap > largestGap {
                largestGap = gap
                gapAfterIndex = index
            }
        }

        let startIndex = sorted.index(after: gapAfterIndex) == sorted.endIndex
            ? sorted.startIndex
            : sorted.index(after: gapAfterIndex)
        let start = sorted[startIndex]
        let end = sorted[gapAfterIndex] < start
            ? sorted[gapAfterIndex] + 360
            : sorted[gapAfterIndex]
        return (center: start + (end - start) / 2, span: end - start)
    }

    private static func normalized360(_ longitude: Double) -> Double {
        let value = longitude.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        let value = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }
}

private struct GeoCoordinate {
    let longitude: Double
    let latitude: Double

    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct IPGeolocation {
    let coordinate: GeoCoordinate
    let city: String?
    let country: String?
}

private actor IPGeolocationService {
    static let shared = IPGeolocationService()

    private var cache: [String: IPGeolocation] = [:]
    private var failed = Set<String>()

    func lookup(_ ips: [String]) async -> [String: IPGeolocation] {
        let unique = RemoteIPParser.unique(ips)
        var result: [String: IPGeolocation] = [:]

        for ip in unique {
            if let cached = cache[ip] {
                result[ip] = cached
                continue
            }
            if failed.contains(ip) {
                continue
            }
            guard !Task.isCancelled else { break }
            if let location = await fetch(ip) {
                cache[ip] = location
                result[ip] = location
            } else {
                failed.insert(ip)
            }
        }

        return result
    }

    private func fetch(_ ip: String) async -> IPGeolocation? {
        guard let encodedIP = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encodedIP)?fields=success,message,ip,latitude,longitude,city,country,country_code")
        else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            guard decoded.success,
                  let latitude = decoded.latitude,
                  let longitude = decoded.longitude,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude)
            else { return nil }
            return IPGeolocation(
                coordinate: GeoCoordinate(longitude: longitude, latitude: latitude),
                city: decoded.city,
                country: decoded.country
            )
        } catch {
            return nil
        }
    }
}

private struct IPWhoIsResponse: Decodable {
    let success: Bool
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let country: String?
}

private enum RemoteIPParser {
    static func parse(_ output: String) -> (connected: [String], banned: [String]) {
        var connected: [String] = []
        var banned: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let ip = extractIPAddress(from: String(parts[1])),
                  isPublicIPAddress(ip)
            else { continue }

            switch parts[0] {
            case "CONNECTED":
                appendUnique(ip, to: &connected)
            case "BANNED":
                appendUnique(ip, to: &banned)
            default:
                continue
            }
        }

        return (connected, banned)
    }

    static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }

    private static func extractIPAddress(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ipv4 = extractIPv4(from: trimmed) {
            return ipv4
        }

        if let start = trimmed.firstIndex(of: "["),
           let end = trimmed[start...].firstIndex(of: "]") {
            let candidate = String(trimmed[trimmed.index(after: start)..<end])
            return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
        }

        let token = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init) ?? trimmed
        let withoutCIDR = token.split(separator: "/", maxSplits: 1).first.map(String.init) ?? token
        let withoutZone = withoutCIDR.split(separator: "%", maxSplits: 1).first.map(String.init) ?? withoutCIDR
        let candidate = withoutZone.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>;"))
        return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
    }

    private static func extractIPv4(from value: String) -> String? {
        let pattern = #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value)
        else { return nil }
        let candidate = String(value[swiftRange])
        let octets = candidate.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } ? candidate : nil
    }

    private static func looksLikeIPv6(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
        return value.contains(":")
            && value.rangeOfCharacter(from: allowed.inverted) == nil
            && (value.contains("::") || value.split(separator: ":").count >= 3)
    }

    private static func normalizeIPv6(_ value: String) -> String {
        value.lowercased()
    }

    private static func isPublicIPAddress(_ ip: String) -> Bool {
        if ip.contains(":") {
            return isPublicIPv6(ip)
        }
        return isPublicIPv4(ip)
    }

    private static func isPublicIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]
        let third = octets[2]

        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && third == 2 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        if first >= 224 { return false }
        return true
    }

    private static func isPublicIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::" || lower == "::1" { return false }
        if lower.hasPrefix("fe80:") { return false }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false }
        if lower.hasPrefix("ff") { return false }
        if lower.hasPrefix("2001:db8") { return false }
        return true
    }
}

private struct ConnectionConfidenceSheet: View {
    let profile: ConnectionProfile
    let status: TerminalConnectionStatus?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection Details")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                ConnectionConfidenceView(profile: profile, status: status)
                    .padding(16)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
    }
}

// MARK: - Service modal sheet

fileprivate struct ServiceModalSheet: View {
    let kind: ServiceModalKind
    let connectionId: String?
    let profileId: String?
    let connectionLabel: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 660, idealHeight: 760)
    }

    private var title: String {
        switch kind {
        case .systemd: return "systemd"
        case .docker: return "Docker"
        case .postgres: return "PostgreSQL"
        }
    }

    private var icon: String {
        switch kind {
        case .systemd: return "switch.2"
        case .docker: return "shippingbox"
        case .postgres: return "cylinder.split.1x2"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .systemd:
            SystemdMonitorView(
                connectionId: connectionId,
                profileId: profileId,
                connectionLabel: connectionLabel
            )
        case .docker:
            DockerMonitorView(
                connectionId: connectionId,
                connectionLabel: connectionLabel
            )
        case .postgres:
            PostgresMonitorView(
                connectionId: connectionId,
                connectionLabel: connectionLabel
            )
        }
    }
}

// MARK: - Premium Status Badge
fileprivate struct StatusBadge: View {
    let state: String
    let substate: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text("\(state) (\(substate))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state.lowercased() {
        case "active", "running":
            return .green
        case "failed", "error":
            return .red
        case "activating", "reloading":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Premium Code Block View
fileprivate struct CodeBlockView: View {
    let label: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            Text(code.isEmpty ? "No details." : code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }
}
