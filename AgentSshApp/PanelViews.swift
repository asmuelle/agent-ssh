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
    @Binding var dashboardVisible: Bool
    @Binding var agentVisible: Bool
    @Binding var filesVisible: Bool
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
            showsDashboardButton: connectedSSHTabs.count >= 2,
            dashboardVisible: dashboardVisible,
            onToggleDashboard: {
                dashboardVisible.toggle()
                if dashboardVisible {
                    agentVisible = false
                    filesVisible = false
                }
            },
            showsAgentButton: !tabsStore.tabs.isEmpty,
            agentVisible: agentVisible,
            agentIssueCount: triage.confirmedCount,
            onToggleAgent: {
                agentVisible.toggle()
                if agentVisible {
                    dashboardVisible = false
                    filesVisible = false
                }
            },
            showsFilesButton: connectedFileTabCount >= 1,
            filesVisible: filesVisible,
            onToggleFiles: {
                filesVisible.toggle()
                if filesVisible {
                    dashboardVisible = false
                    agentVisible = false
                }
            }
        )
        .onChange(of: connectedSSHTabs.map(\.id)) { ids in
            if ids.count < 2 {
                dashboardVisible = false
            }
        }
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
    var title: String
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
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @ObservedObject private var activityLog = ActivityLogStore.shared
    @State private var sort = DashboardSort.order
    @State private var resolvedIPAddresses: [String: [String]] = [:]
    @State private var healthSnapshots: [String: DashboardHealthSnapshot] = [:]
    private static let problemVisibilityDuration: TimeInterval = 10

    private var tabs: [TerminalTab] {
        let tabs = tabsStore.connectedSSHTabs
        switch sort {
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

    var body: some View {
        if tabs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Connect to two or more SSH hosts to open the dashboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                dashboardToolbar
                Divider()
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    problemStrip(now: context.date)
                }
                Divider()

                GeometryReader { proxy in
                    let spacing: CGFloat = 12
                    let horizontalPadding: CGFloat = 24
                    let totalSpacing = spacing * CGFloat(max(tabs.count - 1, 0))
                    let columnWidth = max(
                        LayoutConstants.minInspectorWidth,
                        (proxy.size.width - horizontalPadding - totalSpacing) / CGFloat(max(tabs.count, 1))
                    )

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(tabs, id: \.id) { tab in
                                SystemMonitorView(
                                    connectionId: tab.connectionId,
                                    connectionLabel: tab.profile.name,
                                    profileId: tab.profile.id,
                                    sshPort: tab.profile.port,
                                    profile: tab.profile,
                                    connectionStatus: tab.status,
                                    isActive: true,
                                    dashboardMode: true,
                                    dashboardIdentity: dashboardSnapshotKey(for: tab),
                                    resolvedIPAddresses: dashboardIPAddresses(for: tab.profile) ?? [],
                                    onDashboardHealthChange: { snapshot in
                                        recordDashboardHealthSnapshot(snapshot)
                                        // The Agent view's hidden pollers are
                                        // suspended while the dashboard is open;
                                        // keep its triage store fed from here.
                                        AgentTriageStore.shared.ingest(snapshot: snapshot, tabId: tab.id)
                                    }
                                )
                                .frame(width: columnWidth)
                                .onTapGesture(count: 2) {
                                    tabsStore.setActive(tab.id)
                                }
                                .help("Double-click to activate \(tab.profile.name)")
                                .contextMenu {
                                    dashboardHostContextMenu(tab)
                                }
                            }
                        }
                        .padding(12)
                        .frame(
                            minWidth: proxy.size.width,
                            maxHeight: .infinity,
                            alignment: .leading
                        )
                    }
                    .background(MidnightMacDesign.ColorToken.controlBackground.opacity(0.35))
                }
            }
            .materialBackground(.contentBackground, blendingMode: .withinWindow)
            .task(id: dashboardIPResolutionKey) {
                await refreshDashboardIPAddresses()
            }
            .onChange(of: tabs.map(\.id)) { _ in
                pruneDashboardHealthSnapshots()
            }
        }
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

    private func recordDashboardHealthSnapshot(_ snapshot: DashboardHealthSnapshot) {
        healthSnapshots[snapshot.id] = snapshot
        pruneDashboardHealthSnapshots()
    }

    private func pruneDashboardHealthSnapshots() {
        let activeKeys = activeDashboardSnapshotKeys
        healthSnapshots = healthSnapshots.filter { activeKeys.contains($0.key) }
    }

    private func problemEvents(now: Date) -> [ActivityLogEvent] {
        activityLog.recentProblems(
            limit: 5,
            after: now.addingTimeInterval(-Self.problemVisibilityDuration)
        )
    }

    private var nonHealthyTabs: [TerminalTab] {
        tabs.filter { $0.status != .connected }
    }

    private func dashboardHealthIssues() -> [DashboardHealthIssue] {
        healthSnapshots.values
            .flatMap { snapshot in
                snapshot.issues.map { issue in
                    DashboardHealthIssue(
                        id: "\(snapshot.id):\(issue.id)",
                        title: issue.title,
                        detail: issue.detail,
                        icon: issue.icon,
                        severity: issue.severity
                    )
                }
            }
            .sorted {
                if $0.severity.rawValue != $1.severity.rawValue {
                    return $0.severity.rawValue > $1.severity.rawValue
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private func dashboardIPAddresses(for profile: ConnectionProfile) -> [String]? {
        resolvedIPAddresses[dashboardIPCacheKey(for: profile)]
    }

    @ViewBuilder
    private func dashboardHostContextMenu(_ tab: TerminalTab) -> some View {
        Button("Activate Host") { tabsStore.setActive(tab.id) }
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

    private func problemStrip(now: Date) -> some View {
        let problemEvents = problemEvents(now: now)
        let healthIssues = dashboardHealthIssues()
        let fallbackNonHealthyTabs = nonHealthyTabs.filter {
            healthSnapshots[dashboardSnapshotKey(for: $0)] == nil
        }
        let issueCount = problemEvents.count + healthIssues.count + fallbackNonHealthyTabs.count
        let connectedCount = tabs.filter { $0.status == .connected }.count
        let isCollectingHealth = healthSnapshots.count < tabs.count

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                dashboardStatusCard(
                    connectedCount: connectedCount,
                    totalCount: tabs.count,
                    issueCount: issueCount,
                    isCollectingHealth: isCollectingHealth
                )

                if issueCount > 0 {
                    ForEach(fallbackNonHealthyTabs, id: \.id) { tab in
                        dashboardProblemCard(
                            title: tab.profile.name,
                            detail: tab.status.rawValue.capitalized,
                            icon: "wifi.slash",
                            color: .orange,
                            action: isReconnectable(tab.status) ? {
                                Task { await tabsStore.reconnect(tabId: tab.id) }
                            } : nil
                        )
                    }
                    ForEach(Array(healthIssues.prefix(8)), id: \.id) { issue in
                        dashboardProblemCard(
                            title: issue.title,
                            detail: issue.detail,
                            icon: issue.icon,
                            color: issue.severity.color
                        )
                    }
                    ForEach(problemEvents, id: \.id) { event in
                        dashboardProblemCard(
                            title: event.title,
                            detail: event.detail,
                            icon: event.icon,
                            color: event.severity.color
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
    }

    private func dashboardStatusCard(
        connectedCount: Int,
        totalCount: Int,
        issueCount: Int,
        isCollectingHealth: Bool
    ) -> some View {
        let isClean = issueCount == 0
        let color: Color = isClean ? (isCollectingHealth ? .secondary : .green) : .orange
        let title: String
        if isClean && isCollectingHealth {
            title = "\(connectedCount)/\(totalCount) hosts online · collecting status"
        } else if isClean {
            title = "\(connectedCount) hosts online · no recent warnings"
        } else {
            title = "\(connectedCount)/\(totalCount) hosts online · \(issueCount) warning\(issueCount == 1 ? "" : "s")"
        }

        return Label(title, systemImage: isClean ? (isCollectingHealth ? "clock" : "checkmark.circle.fill") : "exclamationmark.triangle.fill")
            .foregroundStyle(color)
            .font(MidnightMacDesign.FontToken.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                color.opacity(0.10),
                in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
            )
    }

    private func dashboardProblemCard(
        title: String,
        detail: String,
        icon: String,
        color: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        Group {
            if let action {
                Button(action: action) {
                    dashboardProblemCardContent(title: title, detail: detail, icon: icon, color: color)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Reconnect \(title)")
            } else {
                dashboardProblemCardContent(title: title, detail: detail, icon: icon, color: color)
            }
        }
    }

    private func dashboardProblemCardContent(
        title: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium))
    }

    private func isReconnectable(_ status: TerminalConnectionStatus) -> Bool {
        status == .disconnected || status == .error
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Workspace Dashboard")
                    .font(MidnightMacDesign.FontToken.title)
                    .lineLimit(1)
                Label("\(tabs.count) SSH host\(tabs.count == 1 ? "" : "s")", systemImage: "server.rack")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Picker("Sort", selection: $sort) {
                ForEach(DashboardSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private enum DashboardSort: String, CaseIterable, Identifiable {
    case order
    case name
    case host

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .order: return "Opened"
        case .name: return "Name"
        case .host: return "Host"
        }
    }
}
