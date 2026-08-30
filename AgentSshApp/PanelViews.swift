import AgentSshMacOS
import SwiftUI

// MARK: - Sidebar

struct SidebarPanel: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    var onConnect: ((ConnectionProfile) -> Void)?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            selectedConnection: $selectedConnection,
            onConnect: onConnect
        )
    }
}

// MARK: - Main workspace (terminals + files)

/// Connection-level workspace tab strip. Each tab represents a connected workspace,
/// not just a terminal surface: terminal, files, and monitor all follow
/// the selected tab together.
struct ConnectionWorkspaceStrip: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @Binding var mode: WorkspaceMode
    @ObservedObject private var triage = AgentTriageStore.shared

    private var connectedSSHTabs: [TerminalTab] {
        tabsStore.connectedSSHTabs
    }

    /// Files view covers any connected tab (SFTP-only tabs browse
    /// files too, unlike the dashboard's terminal-backed monitors).
    private var connectedFileTabCount: Int {
        tabsStore.tabs.filter { $0.status == .connected }.count
    }

    var body: some View {
        WorkspaceTabStripView(
            tabs: tabsStore.tabs.map {
                WorkspaceTab(
                    id: $0.id,
                    title: $0.title,
                    connectionId: $0.connectionId,
                    order: $0.order
                )
            },
            activeTabId: Binding(
                get: { tabsStore.activeTabId },
                set: { id in if let id { tabsStore.setActive(id) } }
            ),
            onClose: { tab in tabsStore.closeTab(tab.id) },
            onNewTab: {},
            onSetTheme: { tab, themeId in
                tabsStore.setTheme(themeId, forTabId: tab.id)
            },
            themeOverrides: Dictionary(
                uniqueKeysWithValues: tabsStore.tabs.compactMap { tab in
                    tab.themeOverride.map { (tab.id, $0) }
                }
            ),
            statuses: Dictionary(
                uniqueKeysWithValues: tabsStore.tabs.map { ($0.id, $0.status) }
            ),
            tooltips: Dictionary(
                uniqueKeysWithValues: tabsStore.tabs.compactMap { tab in
                    tab.remoteTitle.map { (tab.id, $0) }
                }
            ),
            mode: $mode,
            // In server mode the segment is a status ("you are on
            // ud-orbit"); in every other mode it's a destination, and
            // a host name would misread as a link to that one server.
            serverSegmentTitle: mode == .server
                ? (tabsStore.activeTab?.profile.name ?? "Details")
                : "Details",
            dashboardAvailable: connectedSSHTabs.count >= 2,
            agentAvailable: !tabsStore.tabs.isEmpty,
            filesAvailable: connectedFileTabCount >= 1,
            agentIssueCount: triage.confirmedCount
        )
    }
}

/// Layout switches based on each tab's `ConnectionKind`:
///
/// - `.ssh`: vertical split mirroring the Tauri layout — terminal
///   on top, file browser on the bottom. Both panes target the tab's
///   connection and stay mounted while inactive.
/// - `.sftp`: Midnight-Commander dual-pane file browser (remote left,
///   local right). The terminal section goes away.
///
/// When there's no tab, shows the "Connect to a host" placeholder.
struct MainPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        if tabsStore.tabs.isEmpty {
            placeholder
        } else {
            // Render every open connection workspace once, stacked. Switching
            // tabs toggles visibility and hit testing; inactive workspaces
            // stay mounted so terminal scrollback, file-browser paths, and
            // dual-pane local/remote state survive tab switches.
            ZStack {
                ForEach(tabsStore.tabs) { tab in
                    let isActive = tab.id == tabsStore.activeTabId
                    connectionWorkspace(for: tab, isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .id(tab.id)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionWorkspace(for tab: TerminalTab, isActive: Bool) -> some View {
        if tab.effectiveKind == .sftp {
            DualPaneFileBrowserView(
                connectionId: tab.connectionId,
                connectionLabel: tab.profile.name
            )
        } else {
            VSplitView {
                TerminalPane(tab: tab, isActive: isActive)

                if FeatureFlags.securityPatchMonitor.isEnabled {
                    TabView {
                        DualPaneFileBrowserView(
                            connectionId: tab.connectionId,
                            connectionLabel: tab.profile.name,
                            canEditPermissions: true,
                            canRunRemoteCommands: true
                        )
                        .tabItem {
                            Label("Files", systemImage: "folder")
                        }

                        SecurityPatchMonitorView(
                            connectionId: tab.connectionId,
                            profileId: tab.profile.id,
                            connectionLabel: tab.profile.name
                        )
                        .tabItem {
                            Label("Security", systemImage: "shield.lefthalf.filled")
                        }
                    }
                    .frame(minHeight: 220, idealHeight: 300)
                } else {
                    DualPaneFileBrowserView(
                        connectionId: tab.connectionId,
                        connectionLabel: tab.profile.name,
                        canEditPermissions: true,
                        canRunRemoteCommands: true
                    )
                    .frame(minHeight: 180, idealHeight: 260)
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select a connection from the sidebar to open a workspace")
                .font(MidnightMacDesign.FontToken.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var tabsStore: TerminalTabsStore
    @AppStorage("terminalTheme") private var globalTerminalTheme = "system"

    let tab: TerminalTab
    let isActive: Bool

    private var activeTheme: TerminalTheme {
        TerminalTheme.resolve(tab.themeOverride ?? globalTerminalTheme)
    }

    private var globalTheme: TerminalTheme {
        TerminalTheme.resolve(globalTerminalTheme)
    }

    var body: some View {
        TerminalView(
            connectionId: tab.connectionId,
            ptyGeneration: tab.ptyGeneration,
            themeOverride: tab.themeOverride,
            isActive: isActive,
            terminalTitle: .constant(tab.title),
            searchVisible: .constant(false),
            onSearchQueryChanged: nil,
            onSearchNext: nil,
            onSearchPrevious: nil
        )
        .padding(5)
        .frame(minHeight: 200, idealHeight: 380)
        .background(Color(activeTheme.background))
        .overlay(alignment: .topTrailing) {
            TerminalThemeSelector(
                currentThemeOverride: tab.themeOverride,
                globalTheme: globalTheme,
                activeTheme: activeTheme
            ) { themeId in
                tabsStore.setTheme(themeId, forTabId: tab.id)
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }
}

private struct TerminalThemeSelector: View {
    let currentThemeOverride: String?
    let globalTheme: TerminalTheme
    let activeTheme: TerminalTheme
    let onSetTheme: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                onSetTheme(nil)
            } label: {
                Label(
                    "Use global (\(globalTheme.label))",
                    systemImage: currentThemeOverride == nil ? "checkmark" : ""
                )
            }
            Divider()
            ForEach(TerminalTheme.all) { theme in
                Button {
                    onSetTheme(theme.id)
                } label: {
                    Label(
                        theme.label,
                        systemImage: currentThemeOverride == theme.id ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(MidnightMacDesign.FontToken.body)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Color(activeTheme.foreground).opacity(0.85))
        .background(
            Color(activeTheme.background).opacity(0.9),
            in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
        )
        .help("Terminal theme")
    }
}

/// A terminal tab opened from the sidebar.
struct TerminalTab: Identifiable {
    let id: UUID
    /// Carried so a Reconnect action after a network drop can re-run
    /// the connect flow with the same credentials.
    let profile: ConnectionProfile
    /// UUID-derived suffix so multiple tabs to the same host have
    /// distinct connection_ids in ssh-commander-core. Stable across
    /// reconnects so the rebuilt PTY routes to the same Swift session.
    let sessionId: String
    /// `user@host:port#sessionId` — looked up via this in the rest of
    /// the bridge. Stays the same across reconnects.
    let connectionId: String
    /// Generation counter from the most recent `rshellPtyStart` for
    /// this tab. `var` so reconnect can update it without rebuilding
    /// the SwiftTerm view.
    var ptyGeneration: UInt64
    /// Tab label. The connection name from the saved profile (plus a
    /// kind suffix when the session fell back to SFTP) — deliberately
    /// not the shell's own title, see `remoteTitle`.
    var title: String
    /// Last title the remote shell announced via OSC (`root@host: ~`).
    /// Tooltip only.
    var remoteTitle: String?
    var order: Int
    /// When non-nil, overrides the global `@AppStorage("terminalTheme")`.
    var themeOverride: String?
    /// Live connection state from the `connection_status` event bus.
    /// Defaults to `.connected` since we only build a tab after a
    /// successful `rshellConnect`.
    var status: TerminalConnectionStatus = .connected
    /// Per-tab kind override. Set when `openConnection` falls back
    /// from SSH to SFTP because the server denied the shell channel
    /// (scponly, ForceCommand internal-sftp). The user's saved
    /// `profile.kind` is left untouched — flipping it would silently
    /// rewrite their settings — but the tab renders as SFTP for the
    /// rest of its lifetime. `effectiveKind` is the value the rest
    /// of the UI should consult; nothing should read `profile.kind`
    /// directly to decide layout.
    var kindOverride: ConnectionKind?

    /// Effective connection kind for this tab. Prefers an explicit
    /// override (set on shell-denied fallback) over the saved
    /// profile setting.
    var effectiveKind: ConnectionKind {
        kindOverride ?? profile.kind
    }
}

// MARK: - Inspector

/// Right-hand panel — System Monitor for the active tab. Mirrors the
/// Tauri layout's right column. Updates automatically when the user
/// switches tabs because `SystemMonitorView`'s `.task(id:)` is keyed on
/// `connectionId`.
struct InspectorPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        if tabsStore.tabs.isEmpty {
            SystemMonitorView(connectionId: nil, connectionLabel: "No connection")
                .frame(minWidth: LayoutConstants.minInspectorWidth)
        } else {
            ZStack {
                ForEach(tabsStore.tabs) { tab in
                    let isActive = tab.id == tabsStore.activeTabId
                    SystemMonitorView(
                        connectionId: tab.connectionId,
                        connectionLabel: tab.profile.name,
                        profileId: tab.profile.id,
                        sshPort: tab.profile.port,
                        profile: tab.profile,
                        connectionStatus: tab.status,
                        isActive: isActive
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .id(tab.id)
                }
            }
            .frame(minWidth: LayoutConstants.minInspectorWidth)
        }
    }
}

// MARK: - Multi-host dashboard

/// Full-width monitor desktop. Each connected SSH workspace renders the
/// same view used by the right inspector panel, with polling enabled for
/// every visible host.
struct DashboardPanel: View {
    /// Invoked when the user picks a host from the dashboard (row
    /// double-click, context menu, "Open" on a saved card). The parent
    /// switches the workspace to server mode with that tab active —
    /// without this the activation would happen invisibly behind the
    /// dashboard.
    var onActivateHost: ((UUID) -> Void)? = nil

    @EnvironmentObject var tabsStore: TerminalTabsStore
    @ObservedObject private var connectionStore = ConnectionStoreManager.shared
    @State private var sort = DashboardSort.attention
    @State private var lastStatsUpdate: Date?
    /// The row whose detail band (full monitor card) is open.
    @State private var expandedTabId: UUID?
    /// Remediation sheet opened from a row's chip or gauge.
    @State private var rowSheet: FleetRowSheet?
    @State private var resolvedIPAddresses: [String: [String]] = [:]
    @State private var healthSnapshots: [String: DashboardHealthSnapshot] = [:]
    @State private var fleetHealthRecords: [String: FleetHostHealthRecord] = [:]
    @State private var showingFleetRunbook = false
    @State private var showingStackAudit = false
    @State private var showingActuatorFleet = false
    private let fleetHealthStore = FleetHostHealthStore()
    /// Hotness quantization step: peak-metric ties are bucketed to 5%
    /// so rows don't reshuffle on every 3-second poll tick.
    private static let hotnessStep = 0.05

    private var tabs: [TerminalTab] {
        let tabs = tabsStore.connectedSSHTabs
        switch sort {
        case .attention:
            return tabs.sorted {
                let lhsSeverity = fleetSeverity(for: $0)
                let rhsSeverity = fleetSeverity(for: $1)
                if lhsSeverity != rhsSeverity {
                    return lhsSeverity.rawValue < rhsSeverity.rawValue
                }
                let lhsHotness = fleetHotness(for: $0)
                let rhsHotness = fleetHotness(for: $1)
                if lhsHotness != rhsHotness {
                    return lhsHotness > rhsHotness
                }
                return $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
            }
        case .order:
            return tabs
        case .name:
            return tabs.sorted {
                $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
            }
        case .host:
            return tabs.sorted {
                let lhs = "\($0.profile.host):\($0.profile.port)"
                let rhs = "\($1.profile.host):\($1.profile.port)"
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    private var unconnectedProfiles: [ConnectionProfile] {
        savedProfiles.filter { profile in
            !tabs.contains { $0.profile.id == profile.id }
        }
    }

    private var savedProfiles: [ConnectionProfile] {
        let profiles = connectionStore.connections
        switch sort {
        case .order, .attention:
            return profiles
        case .name:
            return profiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .host:
            return profiles.sorted {
                let lhs = "\($0.host):\($0.port)"
                let rhs = "\($1.host):\($1.port)"
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    var body: some View {
        if savedProfiles.isEmpty && tabs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Save an SSH host to build the fleet inventory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                dashboardToolbar
                Divider()
                // Connected hosts already have a live row below — the
                // inventory strip only lists what still needs a
                // connection.
                if !unconnectedProfiles.isEmpty {
                    savedHostInventory
                    Divider()
                }

                connectedMonitorArea
            }
            .materialBackground(.contentBackground, blendingMode: .withinWindow)
            .task(id: dashboardIPResolutionKey) {
                await refreshDashboardIPAddresses()
            }
            .task(id: savedProfiles.map(\.id).joined(separator: "|")) {
                fleetHealthRecords = fleetHealthStore.load()
                try? fleetHealthStore.prune(keepingProfileIds: savedProfiles.map(\.id))
                fleetHealthRecords = fleetHealthStore.load()
            }
            .onChange(of: tabs.map(\.id)) { _ in
                pruneDashboardHealthSnapshots()
                if let expandedTabId, !tabs.contains(where: { $0.id == expandedTabId }) {
                    self.expandedTabId = nil
                }
            }
            .sheet(isPresented: $showingFleetRunbook) {
                FleetRunbookSheet(tabs: tabs)
            }
            .sheet(isPresented: $showingStackAudit) {
                FleetStackAuditSheet(tabs: tabs)
            }
            .sheet(isPresented: $showingActuatorFleet) {
                ActuatorFleetSheet(tabs: tabs)
            }
            .sheet(item: $rowSheet) { sheet in
                switch sheet {
                case .drill(let connectionId, let sshPort, let target):
                    MonitorDrillDownSheet(
                        connectionId: connectionId,
                        drillDown: target,
                        sshPort: sshPort
                    )
                case .service(let kind, let connectionId, let profileId, let label):
                    ServiceModalSheet(
                        kind: kind,
                        connectionId: connectionId,
                        profileId: profileId,
                        connectionLabel: label
                    )
                case .journal(let connectionId, let label):
                    FleetJournalSheet(
                        connectionId: connectionId,
                        connectionLabel: label
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var connectedMonitorArea: some View {
        if tabs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Connect a saved host to start live monitoring.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fleetTable
        }
    }

    private func dashboardMonitorView(
        for tab: TerminalTab,
        headless: Bool = false,
        detailBand: Bool = false
    ) -> some View {
        SystemMonitorView(
            connectionId: tab.connectionId,
            connectionLabel: tab.profile.name,
            profileId: tab.profile.id,
            sshPort: tab.profile.port,
            profile: tab.profile,
            connectionStatus: tab.status,
            isActive: true,
            dashboardMode: true,
            detailBandMode: detailBand,
            dashboardIdentity: dashboardSnapshotKey(for: tab),
            resolvedIPAddresses: dashboardIPAddresses(for: tab.profile) ?? [],
            onDashboardHealthChange: { snapshot in
                recordDashboardHealthSnapshot(snapshot, profile: tab.profile)
                // The Agent view's hidden pollers are
                // suspended while the dashboard is open;
                // keep its triage store fed from here.
                AgentTriageStore.shared.ingest(snapshot: snapshot, tabId: tab.id)
            },
            headless: headless
        )
    }

    // MARK: Fleet table

    /// The fleet as an attention-sorted table: one row per host with
    /// aligned metric columns, warnings inline on their row, and a
    /// click-to-expand detail band hosting the full monitor view.
    private var fleetTable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                fleetTableHeader
                Divider()
                ForEach(tabs, id: \.id) { tab in
                    fleetTableRow(tab)
                    if expandedTabId == tab.id {
                        fleetDetailBand(tab)
                    }
                    Divider()
                }
            }
            .padding(12)
        }
        .background(MidnightMacDesign.ColorToken.controlBackground.opacity(0.35))
        .background(fleetTablePollers)
    }

    /// Invisible headless monitors keep each host's polling and
    /// health-snapshot pipeline alive — the table renders from those
    /// snapshots. The expanded host is excluded: its visible detail
    /// band already runs the same pipeline.
    private var fleetTablePollers: some View {
        HStack(spacing: 0) {
            ForEach(tabs.filter { $0.id != expandedTabId }, id: \.id) { tab in
                dashboardMonitorView(for: tab, headless: true)
            }
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Compact monitor band for the expanded row: only what the row
    /// doesn't already show (trends, all disks, drill-down panels), at
    /// intrinsic height.
    private func fleetDetailBand(_ tab: TerminalTab) -> some View {
        dashboardMonitorView(for: tab, detailBand: true)
            .padding(.vertical, 8)
            .padding(.leading, 24)
            .contextMenu {
                dashboardHostContextMenu(tab)
            }
    }

    private enum FleetColumn {
        static let severity: CGFloat = 18
        static let host: CGFloat = 150
        static let metric: CGFloat = 110
        static let load: CGFloat = 56
        static let uptime: CGFloat = 44
        static let chevron: CGFloat = 16
    }

    private var fleetTableHeader: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: FleetColumn.severity)
            Text("Host").frame(width: FleetColumn.host, alignment: .leading)
            Text("Issues").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: FleetColumn.metric, alignment: .leading)
            Text("Memory").frame(width: FleetColumn.metric, alignment: .leading)
            Text("Disk").frame(width: FleetColumn.metric, alignment: .leading)
            Text("Load").frame(width: FleetColumn.load, alignment: .trailing)
            Text("Up").frame(width: FleetColumn.uptime, alignment: .trailing)
            Spacer().frame(width: FleetColumn.chevron)
        }
        .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func fleetTableRow(_ tab: TerminalTab) -> some View {
        let snapshot = healthSnapshots[dashboardSnapshotKey(for: tab)]
        let metrics = snapshot?.metrics
        let severity = fleetSeverity(for: tab)
        let isExpanded = expandedTabId == tab.id
        let worstDisk = metrics.flatMap { m in
            m.disks.first { $0.mount == m.worstDiskMount }
        }

        return HStack(spacing: 12) {
            fleetSeverityIcon(severity, status: tab.status)
                .frame(width: FleetColumn.severity)

            Text(tab.profile.name)
                .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: FleetColumn.host, alignment: .leading)
                .help("\(tab.profile.username)@\(tab.profile.host):\(tab.profile.port)")

            fleetIssueChips(snapshot, tab: tab)
                .frame(maxWidth: .infinity, alignment: .leading)

            fleetMetricCell(
                fraction: metrics.map { $0.cpuPercent / 100 },
                detail: "Analyze CPU-intensive processes",
                action: { presentRowSheet(.drill(.cpu), tab: tab) }
            )
            fleetMetricCell(
                fraction: metrics.map { $0.memoryPercent / 100 },
                detail: metrics.map {
                    "\(fleetFormatBytes($0.memoryUsed)) / \(fleetFormatBytes($0.memoryTotal))"
                        + " — click to analyze memory-intensive processes"
                },
                action: { presentRowSheet(.drill(.memory), tab: tab) }
            )
            fleetMetricCell(
                fraction: metrics?.worstDiskFraction,
                detail: metrics?.worstDiskMount.map {
                    "\($0) — click to find large files"
                },
                action: worstDisk.map { disk in
                    { presentRowSheet(.drill(.disk(disk)), tab: tab) }
                }
            )

            Text(metrics.map { String(format: "%.2f", $0.loadAverage1m) } ?? "—")
                .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: FleetColumn.load, alignment: .trailing)

            Text(metrics.map { fleetFormatUptime($0.uptimeSeconds) } ?? "—")
                .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: FleetColumn.uptime, alignment: .trailing)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: FleetColumn.chevron)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(fleetRowTint(severity), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            activateHost(tab.id)
        }
        .onTapGesture {
            expandedTabId = isExpanded ? nil : tab.id
        }
        .help("Click for details, double-click to activate \(tab.profile.name)")
        .contextMenu {
            dashboardHostContextMenu(tab)
        }
    }

    private func fleetIssueChips(_ snapshot: DashboardHealthSnapshot?, tab: TerminalTab) -> some View {
        Group {
            if let snapshot {
                if snapshot.issues.isEmpty {
                    Text("—")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(snapshot.issues.prefix(2)), id: \.id) { issue in
                            fleetIssueChip(issue, tab: tab)
                        }
                        if snapshot.issues.count > 2 {
                            // Overflow expands the row, where every
                            // issue is listed with its action button.
                            Button {
                                expandedTabId = tab.id
                            } label: {
                                Text("+\(snapshot.issues.count - 2)")
                                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help(
                                snapshot.issues.dropFirst(2)
                                    .map { "\($0.title): \($0.detail)" }
                                    .joined(separator: "\n")
                            )
                        }
                    }
                }
            } else {
                Text("Collecting…")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fleetIssueChip(_ issue: DashboardHealthIssue, tab: TerminalTab) -> some View {
        let label = issue.title.replacingOccurrences(of: "\(tab.profile.name): ", with: "")
        return Button {
            openIssue(issue, tab: tab)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: issue.icon)
                    .font(MidnightMacDesign.FontToken.caption)
                Text(label)
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(issue.severity.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(issue.severity.color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("\(issue.title): \(issue.detail) — click to open")
    }

    /// Chip click: open the issue's remediation surface, or expand the
    /// row when the issue has no direct drill-down.
    private func openIssue(_ issue: DashboardHealthIssue, tab: TerminalTab) {
        let disks = healthSnapshots[dashboardSnapshotKey(for: tab)]?.metrics?.disks ?? []
        guard let action = fleetIssueAction(issueId: issue.id, disks: disks) else {
            expandedTabId = tab.id
            return
        }
        presentRowSheet(action.destination, tab: tab)
    }

    private func presentRowSheet(_ destination: FleetIssueDestination, tab: TerminalTab) {
        switch destination {
        case .drill(let target):
            rowSheet = .drill(
                connectionId: tab.connectionId,
                sshPort: tab.profile.port,
                target: target
            )
        case .service(let kind):
            rowSheet = .service(
                kind: kind,
                connectionId: tab.connectionId,
                profileId: tab.profile.id,
                label: tab.profile.name
            )
        case .journal:
            rowSheet = .journal(
                connectionId: tab.connectionId,
                label: tab.profile.name
            )
        }
    }

    private func fleetMetricCell(
        fraction: Double?,
        detail: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(spacing: 6) {
            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear)
                    .tint(fleetTint(fraction))
                    .frame(width: 52)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(MidnightMacDesign.FontToken.caption.monospacedDigit())
                    .foregroundStyle(fraction >= 0.6 ? fleetTint(fraction) : Color.secondary)
            } else {
                Text("—")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: FleetColumn.metric, alignment: .leading)

        return Group {
            if let action, fraction != nil {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else {
                content
            }
        }
        .help(detail ?? "")
    }

    // MARK: Fleet severity

    /// Attention buckets, worst first — the primary sort key of the
    /// default "Attention" ordering.
    private enum FleetSeverity: Int {
        case critical = 0
        case warning = 1
        case collecting = 2
        case healthy = 3
    }

    private func fleetSeverity(for tab: TerminalTab) -> FleetSeverity {
        if tab.status == .error {
            return .critical
        }
        guard let snapshot = healthSnapshots[dashboardSnapshotKey(for: tab)] else {
            return tab.status == .connected ? .collecting : .warning
        }
        if snapshot.issues.contains(where: { $0.severity == .critical }) {
            return .critical
        }
        if !snapshot.issues.isEmpty {
            return .warning
        }
        return snapshot.metrics == nil ? .collecting : .healthy
    }

    /// Tiebreaker within a severity bucket: the host's peak metric
    /// fraction, quantized so ordering stays stable across poll ticks.
    private func fleetHotness(for tab: TerminalTab) -> Double {
        guard let metrics = healthSnapshots[dashboardSnapshotKey(for: tab)]?.metrics else {
            return 0
        }
        let peak = max(
            metrics.cpuPercent / 100,
            metrics.memoryPercent / 100,
            metrics.worstDiskFraction ?? 0
        )
        return (peak / Self.hotnessStep).rounded() * Self.hotnessStep
    }

    @ViewBuilder
    private func fleetSeverityIcon(_ severity: FleetSeverity, status: TerminalConnectionStatus) -> some View {
        switch severity {
        case .critical:
            Image(systemName: "exclamationmark.circle.fill")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.orange)
        case .collecting, .healthy:
            Circle()
                .fill(fleetStatusColor(status))
                .frame(width: 7, height: 7)
        }
    }

    /// Subtle warm wash on rows that need attention so the healthy
    /// majority reads as one quiet block.
    private func fleetRowTint(_ severity: FleetSeverity) -> Color {
        switch severity {
        case .critical: return .red.opacity(0.08)
        case .warning: return .orange.opacity(0.07)
        case .collecting, .healthy: return .clear
        }
    }

    /// Same thresholds as the monitor bars: muted when healthy so
    /// color stays reserved for problems.
    private func fleetTint(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6:  return .green.opacity(0.55)
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    private func fleetStatusColor(_ status: TerminalConnectionStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        case .error:        return .red
        }
    }

    private func fleetFormatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func fleetFormatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        if days > 0 { return "\(days)d" }
        let hours = seconds / 3_600
        if hours > 0 { return "\(hours)h" }
        return "\(seconds / 60)m"
    }

    private var dashboardIPResolutionKey: String {
        tabs.map { dashboardIPCacheKey(for: $0.profile) }.joined(separator: "\n")
    }

    private func dashboardSnapshotKey(for tab: TerminalTab) -> String {
        tab.id.uuidString
    }

    private var activeDashboardSnapshotKeys: Set<String> {
        Set(tabs.map { dashboardSnapshotKey(for: $0) })
    }

    private func recordDashboardHealthSnapshot(
        _ snapshot: DashboardHealthSnapshot,
        profile: ConnectionProfile
    ) {
        healthSnapshots[snapshot.id] = snapshot
        lastStatsUpdate = Date()
        pruneDashboardHealthSnapshots()

        let state: FleetHostHealthState
        if snapshot.issues.contains(where: { $0.severity == .critical }) {
            state = .critical
        } else if !snapshot.issues.isEmpty {
            state = .warning
        } else {
            state = .healthy
        }
        let summary = snapshot.issues.first.map { "\($0.title): \($0.detail)" } ?? "Healthy"
        let record = FleetHostHealthRecord(
            profileId: profile.id,
            hostName: profile.name,
            state: state,
            summary: summary
        )
        fleetHealthRecords[profile.id] = record
        try? fleetHealthStore.record(record)
    }

    private func pruneDashboardHealthSnapshots() {
        let activeKeys = activeDashboardSnapshotKeys
        healthSnapshots = healthSnapshots.filter { activeKeys.contains($0.key) }
    }

    /// Route host activation through the parent when it wants to
    /// switch the workspace mode along with the active tab.
    private func activateHost(_ tabId: UUID) {
        if let onActivateHost {
            onActivateHost(tabId)
        } else {
            tabsStore.setActive(tabId)
        }
    }

    private var nonHealthyTabs: [TerminalTab] {
        tabs.filter { $0.status != .connected }
    }

    /// Total warnings across the fleet: reported health issues plus
    /// unhealthy connections that haven't produced a snapshot yet.
    private var dashboardIssueCount: Int {
        let healthIssues = healthSnapshots.values.reduce(0) { $0 + $1.issues.count }
        let fallback = nonHealthyTabs
            .filter { healthSnapshots[dashboardSnapshotKey(for: $0)] == nil }
            .count
        return healthIssues + fallback
    }

    private func dashboardIPAddresses(for profile: ConnectionProfile) -> [String]? {
        resolvedIPAddresses[dashboardIPCacheKey(for: profile)]
    }

    @ViewBuilder
    private func dashboardHostContextMenu(_ tab: TerminalTab) -> some View {
        Button("Activate Host") { activateHost(tab.id) }
        Button("Reconnect") { Task { await tabsStore.reconnect(tabId: tab.id) } }
        Button("Copy SSH Command") {
            RemoteCommandRunner.copy("ssh -p \(tab.profile.port) \(tab.profile.username)@\(tab.profile.host)")
        }
        if let addresses = dashboardIPAddresses(for: tab.profile), !addresses.isEmpty {
            Button("Copy IP Address\(addresses.count == 1 ? "" : "es")") {
                RemoteCommandRunner.copy(addresses.joined(separator: ", "))
            }
        }
    }

    private func dashboardIPCacheKey(for profile: ConnectionProfile) -> String {
        [
            profile.id,
            profile.host,
            String(profile.port),
            profile.networkOptions.tailscaleResolutionMode.rawValue,
            profile.networkOptions.tailscaleHostOverride ?? "",
        ].joined(separator: "|")
    }

    @MainActor
    private func refreshDashboardIPAddresses() async {
        let profiles = tabs.map(\.profile)
        guard !profiles.isEmpty else {
            resolvedIPAddresses = [:]
            return
        }

        var entries: [(String, [String])] = []
        await withTaskGroup(of: (String, [String]).self) { group in
            for profile in profiles {
                let key = dashboardIPCacheKey(for: profile)
                group.addTask {
                    let addresses = await Self.resolveDashboardIPAddresses(for: profile)
                    return (key, addresses)
                }
            }

            for await entry in group {
                entries.append(entry)
            }
        }

        resolvedIPAddresses = Dictionary(uniqueKeysWithValues: entries)
    }

    private nonisolated static func resolveDashboardIPAddresses(for profile: ConnectionProfile) async -> [String] {
        await Task.detached(priority: .utility) {
            let host = Self.dashboardConnectHost(for: profile)
            if TailscaleAddressClassifier.isTailscaleAddress(host) {
                return [host]
            }
            return NetworkPolishHostLookup.systemAddresses(for: host, port: profile.port)
        }.value
    }

    private nonisolated static func dashboardConnectHost(for profile: ConnectionProfile) -> String {
        guard profile.networkOptions.tailscaleResolutionMode != .system else {
            return profile.host
        }
        return profile.networkOptions.tailscaleHostOverride ?? profile.host
    }

    private var savedHostInventory: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(unconnectedProfiles) { profile in
                    savedHostCard(profile)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(MidnightMacDesign.ColorToken.controlBackground.opacity(0.22))
    }

    private func savedHostCard(_ profile: ConnectionProfile) -> some View {
        let tab = tabs.first { $0.profile.id == profile.id }
        let record = fleetHealthRecords[profile.id]
        let freshness = record?.freshness()
        let color = fleetHealthColor(record: record, freshness: freshness, isConnected: tab != nil)
        let status = fleetHealthStatus(record: record, freshness: freshness, isConnected: tab != nil)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(profile.name)
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if tab == nil {
                    Button("Connect") {
                        Task { await tabsStore.openConnection(profile) }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                } else {
                    Button("Open") { activateHost(tab!.id) }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                }
            }
            Text("\(profile.username)@\(profile.host):\(profile.port)")
                .font(MidnightMacDesign.FontToken.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(status)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(color)
                .lineLimit(1)
            if !profile.tags.isEmpty {
                Text(profile.tags.prefix(3).joined(separator: " · "))
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 238, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }

    private func fleetHealthColor(
        record: FleetHostHealthRecord?,
        freshness: FleetObservationFreshness?,
        isConnected: Bool
    ) -> Color {
        if freshness == .stale || record == nil { return .secondary }
        switch record?.state {
        case .healthy: return isConnected ? .green : .secondary
        case .warning: return .orange
        case .critical: return .red
        case .unknown, .none: return .secondary
        }
    }

    private func fleetHealthStatus(
        record: FleetHostHealthRecord?,
        freshness: FleetObservationFreshness?,
        isConnected: Bool
    ) -> String {
        guard let record else { return isConnected ? "Collecting first observation" : "Never observed" }
        if freshness == .stale {
            return "Stale · last observed \(record.observedAt.formatted(date: .omitted, time: .shortened))"
        }
        return isConnected ? record.summary : "Offline · \(record.summary)"
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Workspace Dashboard")
                    .font(MidnightMacDesign.FontToken.title)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label("\(tabs.count)/\(savedProfiles.count) connected", systemImage: "server.rack")
                        .foregroundStyle(.secondary)
                    // Single refresh timestamp for the whole fleet —
                    // every host polls on the same cadence.
                    if let lastStatsUpdate {
                        Text("· Updated \(lastStatsUpdate.formatted(.dateTime.hour().minute().second()))")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .font(MidnightMacDesign.FontToken.caption)
            }

            Spacer(minLength: 0)

            // The former problem strip, reduced to its useful part:
            // the count. The individual warnings live inline on the
            // table rows they belong to.
            if dashboardIssueCount > 0 {
                Label(
                    "\(dashboardIssueCount) warning\(dashboardIssueCount == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(MidnightMacDesign.FontToken.caption.weight(.medium))
            }

            Button {
                showingFleetRunbook = true
            } label: {
                Label("Fleet Runbook", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(tabs.isEmpty)
            .controlSize(.small)

            Button {
                showingStackAudit = true
            } label: {
                Label("Stack Audit", systemImage: "square.stack.3d.up")
            }
            .disabled(tabs.isEmpty)
            .controlSize(.small)

            Button {
                showingActuatorFleet = true
            } label: {
                Label("App Health", systemImage: "heart.text.square")
            }
            .disabled(tabs.isEmpty)
            .controlSize(.small)

            Picker("Sort", selection: $sort) {
                ForEach(DashboardSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Remediation sheet opened from a fleet-table row's chip or gauge.
/// Carries the connection context so the panel can present the sheet
/// without going through a monitor view.
private enum FleetRowSheet: Identifiable {
    case drill(connectionId: String?, sshPort: UInt16?, target: MonitorDrillDown)
    case service(kind: ServiceModalKind, connectionId: String?, profileId: String?, label: String)
    case journal(connectionId: String?, label: String)

    var id: String {
        switch self {
        case .drill(let connectionId, _, let target):
            return "drill:\(connectionId ?? ""):\(target.id)"
        case .service(let kind, let connectionId, _, _):
            return "service:\(connectionId ?? ""):\(kind.rawValue)"
        case .journal(let connectionId, _):
            return "journal:\(connectionId ?? "")"
        }
    }
}

private extension View {
    /// Pointing-hand cursor on hover so chips and gauges read as
    /// clickable inside an otherwise tap-to-expand row.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private enum DashboardSort: String, CaseIterable, Identifiable {
    case attention
    case order
    case name
    case host

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .attention: return "Attention"
        case .order: return "Opened"
        case .name: return "Name"
        case .host: return "Host"
        }
    }
}
