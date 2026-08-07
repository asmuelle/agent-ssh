import AgentSshMacOS
import SwiftUI

/// Native macOS workspace.
///
///   ┌────────────────┬───────────────────┬────────────┐
///   │ Connections    │ Terminal tabs     │            │
///   │ (manager)      │ (always-visible)  │            │
///   ├────────────────│                   │  System    │
///   │ Connection     ├───────────────────┤  Monitor   │
///   │ Details        │ File browser      │  (always)  │
///   │                │ (always-visible)  │            │
///   └────────────────┴───────────────────┴────────────┘
///
/// Layout is an explicit outer `HSplitView` (sidebar | detail). The
/// detail column is itself an `HSplitView` so the main workspace and
/// the inspector collapse and resize independently. The three-column
/// `NavigationSplitView` form can only express
/// `(all / doubleColumn / detailOnly)`, which doesn't allow
/// "sidebar visible, inspector hidden" — so the inspector lives inside
/// the detail column.
///
/// `LayoutManager` is the source of truth for which panels are visible
/// and at what size. The inspector divider is observed via
/// `GeometryReader` preferences and persisted through a 250 ms debounced
/// write.
struct ContentView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @StateObject private var transfersStore = TransferQueueStore()
    @StateObject private var actuatorMonitor = ActuatorFleetMonitor.shared
    @State private var selectedConnection: ConnectionProfile?
    /// What the detail column's main pane shows. `.server` is the
    /// default: the active workspace tab's terminal + files split.
    @State private var workspaceMode = WorkspaceMode.server
    @State private var showingCommandPalette = false
    @State private var serverDoctorTarget: ServerDoctorTarget?
    @State private var didRunAutoConnect = false
    /// Startup auto-connect targeted several hosts: land on the fleet
    /// dashboard as soon as two of them are actually connected.
    @State private var pendingAutoConnectDashboard = false

    var body: some View {
        HSplitView {
            if layoutManager.layout.sidebarVisible {
                SidebarColumn(
                    layoutManager: layoutManager,
                    storeManager: connectionStore,
                    selectedConnection: $selectedConnection,
                    onConnect: { profile in
                        Task { await tabsStore.openConnection(profile) }
                    },
                    onDiagnose: { profile in
                        if let tab = tabsStore.connectedSSHTabs.first(where: { $0.profile.id == profile.id }) {
                            serverDoctorTarget = ServerDoctorTarget(tab: tab)
                        }
                    }
                )
            }

            DetailColumn(
                layoutManager: layoutManager,
                mode: $workspaceMode,
                onDiagnose: { tab in
                    serverDoctorTarget = ServerDoctorTarget(tab: tab)
                }
            )
        }
        .environmentObject(transfersStore)
        .frame(minWidth: 900, minHeight: 600)
        .task {
            // The unit-test host launches the full app. Auto-connect
            // would then dial real servers and touch the Keychain from
            // an ad-hoc-signed binary — the permission dialog blocks
            // the test runner before it can attach. Keep the test host
            // inert.
            guard !ProcessInfo.isRunningTests else { return }
            actuatorMonitor.start(tabsStore: tabsStore)
            await runAutoConnect()
        }
        .onChange(of: tabsStore.connectedSSHTabs.count) { count in
            if pendingAutoConnectDashboard, count >= 2 {
                pendingAutoConnectDashboard = false
                workspaceMode = .dashboard
            }
        }
        .onDisappear {
            Task { await actuatorMonitor.stop() }
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                connections: connectionStore.connections,
                selectedConnection: selectedConnection,
                activeTab: tabsStore.activeTab,
                connectedHostCount: tabsStore.connectedSSHTabs.count,
                onConnect: { profile in
                    selectedConnection = profile
                    Task { await tabsStore.openConnection(profile) }
                },
                onReconnectActive: {
                    if let activeTab = tabsStore.activeTab {
                        Task { await tabsStore.reconnect(tabId: activeTab.id) }
                    }
                },
                onCloseActive: {
                    tabsStore.closeActiveTab()
                },
                onOpenDashboard: {
                    if tabsStore.connectedSSHTabs.count >= 2 {
                        workspaceMode = .dashboard
                    }
                },
                onToggleSidebar: {
                    layoutManager.toggleSidebar()
                },
                onToggleInspector: {
                    layoutManager.toggleInspector()
                },
                onExportDiagnostics: {
                    DiagnosticsBundleExporter.export(
                        connectionStore: connectionStore,
                        tabsStore: tabsStore,
                        layoutManager: layoutManager
                    )
                },
                onDiagnoseActive: {
                    if let tab = tabsStore.activeOpenSSHTab {
                        serverDoctorTarget = ServerDoctorTarget(tab: tab)
                    }
                }
            )
        }
        .sheet(item: $serverDoctorTarget) { target in
            ServerDoctorView(target: target)
        }
        .onReceive(AgentSshEventBus.shared.events) { event in
            switch event {
            case .showCommandPalette:
                showingCommandPalette = true
            case .showDashboard:
                if tabsStore.connectedSSHTabs.count >= 2 {
                    workspaceMode = .dashboard
                }
            default:
                break
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .onContinueUserActivity("com.agent-ssh.agent-ssh.route") { activity in
            handleRouteActivity(activity)
        }
        .userActivity("com.agent-ssh.agent-ssh.route") { activity in
            if let selectedConnection {
                activity.title = selectedConnection.name
                activity.userInfo = ["url": "agent-ssh://server/\(selectedConnection.id)"]
            } else {
                activity.title = "agent-ssh"
                activity.userInfo = ["url": "agent-ssh://server"]
            }
        }
        .explainableErrorAlert(
            "Connection error",
            context: "an SSH connection error message",
            message: Binding(
                get: { tabsStore.lastError },
                set: { tabsStore.lastError = $0 }
            )
        )
        // SSH→SFTP fallback prompt. Distinct from the error alert
        // because the connect *did* succeed, just in a different
        // shape than asked for. Offers a one-click commit to make
        // the demotion permanent so future connects skip the shell
        // attempt entirely.
        .alert("Server doesn't allow shell access",
               isPresented: Binding(
                   get: { tabsStore.pendingFallback != nil },
                   set: { if !$0 { tabsStore.pendingFallback = nil } }
               ),
               presenting: tabsStore.pendingFallback)
        { fallback in
            Button("Convert profile to SFTP") {
                connectionStore.setKind(profileId: fallback.profileId, kind: .sftp)
                tabsStore.pendingFallback = nil
            }
            Button("Keep as SSH", role: .cancel) {
                tabsStore.pendingFallback = nil
            }
        } message: { fallback in
            Text(fallback.message)
        }
    }

    /// Connect every profile marked "Connect at launch" — once per app
    /// run, and only profiles whose stored credentials allow a silent
    /// connect, so startup never opens a wall of password prompts.
    ///
    /// Connects run in parallel: a serial loop would let one slow or
    /// unreachable host block every server behind it (the "only one
    /// connected on startup" failure). A multi-host startup lands on
    /// the fleet dashboard — switched reactively as soon as two hosts
    /// are up (see the onChange in `body`), so a hanging connect can't
    /// delay the overview either.
    @MainActor
    private func runAutoConnect() async {
        guard !didRunAutoConnect else { return }
        didRunAutoConnect = true

        let profiles = connectionStore.connections.filter {
            $0.autoConnect && canConnectSilently($0)
        }
        guard !profiles.isEmpty else { return }

        if profiles.count >= 2 {
            pendingAutoConnectDashboard = true
        }

        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { @MainActor in
                    await tabsStore.openConnection(profile)
                }
            }
        }

        if pendingAutoConnectDashboard, tabsStore.connectedSSHTabs.count >= 2 {
            workspaceMode = .dashboard
        }
        pendingAutoConnectDashboard = false
    }

    private func canConnectSilently(_ profile: ConnectionProfile) -> Bool {
        switch profile.authMethod {
        case .password:
            return KeychainManager.shared.hasPassword(
                kind: .sshPassword,
                account: profile.keychainAccount
            )
        case .publicKey:
            return profile.sshKeyReference != nil
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let link = AgentSshDeepLink(url) else { return }

        switch link.kind {
        case .monitoring:
            if let profileId = link.profileId,
               let profile = connectionStore.connection(withId: profileId)
            {
                selectedConnection = profile
            }
            if tabsStore.connectedSSHTabs.count >= 2 {
                workspaceMode = .dashboard
            }
        case .server, .terminal, .folder:
            guard let profileId = link.profileId,
                  let profile = connectionStore.connection(withId: profileId)
            else {
                return
            }
            selectedConnection = profile
            if link.kind == .terminal || link.kind == .folder {
                Task { await tabsStore.openConnection(profile) }
            }
        case .automation:
            guard let operationId = link.operationId,
                  let operation = try? BackgroundSSHOperationStore().load().operations.first(where: { $0.id == operationId }),
                  let profile = connectionStore.connection(withId: operation.profileId)
            else {
                return
            }
            selectedConnection = profile
        }
    }

    private func handleRouteActivity(_ activity: NSUserActivity) {
        if let rawURL = activity.userInfo?["url"] as? String,
           let url = URL(string: rawURL)
        {
            handleDeepLink(url)
            return
        }

        if let url = activity.webpageURL {
            handleDeepLink(url)
        }
    }
}

extension ProcessInfo {
    /// True when the process is a unit-test host rather than a real
    /// app launch.
    static var isRunningTests: Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

// MARK: - Sidebar column

private struct SidebarColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    let onConnect: (ConnectionProfile) -> Void
    let onDiagnose: (ConnectionProfile) -> Void
    @State private var sidebarWidthDebounce: Task<Void, Never>?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            selectedConnection: $selectedConnection,
            onConnect: onConnect,
            onDiagnose: onDiagnose
        )
        .finderSidebarBackground()
        .frame(
            minWidth: LayoutConstants.minSidebarWidth,
            idealWidth: layoutManager.layout.sidebarWidth,
            maxWidth: LayoutConstants.maxSidebarWidth
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SidebarWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SidebarWidthKey.self, perform: persistSidebarWidth)
    }

    private func persistSidebarWidth(_ measured: CGFloat) {
        sidebarWidthDebounce?.cancel()
        sidebarWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clamped = min(
                max(measured, LayoutConstants.minSidebarWidth),
                LayoutConstants.maxSidebarWidth
            )
            if abs(clamped - layoutManager.layout.sidebarWidth) > 1 {
                layoutManager.layout.sidebarWidth = clamped
            }
        }
    }
}

// MARK: - Detail column (main + bottom + inspector)

private struct DetailColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @Binding var mode: WorkspaceMode
    var onDiagnose: ((TerminalTab) -> Void)? = nil
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @State private var inspectorWidthDebounce: Task<Void, Never>?

    private var inspectorShouldRender: Bool {
        layoutManager.layout.inspectorVisible && tabsStore.activeOpenSSHTab != nil
    }

    private var dashboardShouldRender: Bool {
        mode == .dashboard && tabsStore.connectedSSHTabs.count >= 2
    }

    private var agentShouldRender: Bool {
        mode == .agent && !tabsStore.tabs.isEmpty
    }

    /// Files view stays useful down to a single connected host (unlike
    /// the dashboard's 2-host minimum) — one full-width pane is still a
    /// better file workspace than nothing when the user asked for it.
    private var filesShouldRender: Bool {
        mode == .files && connectedFileTabCount >= 1
    }

    private var connectedFileTabCount: Int {
        tabsStore.tabs.filter { $0.status == .connected }.count
    }

    private var connectedSSHTabIds: [UUID] {
        tabsStore.connectedSSHTabs.map(\.id)
    }

    /// Changes whenever any tab's connection status flips — drives the
    /// triage store's connection-issue sync.
    private var tabStatusKey: String {
        tabsStore.tabs
            .map { "\($0.id.uuidString):\($0.status.rawValue)" }
            .joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tabsStore.tabs.isEmpty {
                ConnectionWorkspaceStrip(mode: $mode)
                Divider()
            }

            if agentShouldRender {
                AgentPanel(
                    onDiagnose: onDiagnose,
                    onOpenHost: { tabId in
                        tabsStore.setActive(tabId)
                        mode = .server
                    }
                )
                .frame(minWidth: 320, minHeight: 320)
            } else if filesShouldRender {
                FilesPanel()
                    .frame(minWidth: 320, minHeight: 320)
            } else if dashboardShouldRender {
                DashboardPanel(
                    onActivateHost: { tabId in
                        tabsStore.setActive(tabId)
                        mode = .server
                    }
                )
                .frame(minWidth: 320, minHeight: 320)
            } else {
                HSplitView {
                    MainPanel()
                        .frame(minWidth: 320, minHeight: 320)

                    if inspectorShouldRender {
                        InspectorPanel()
                            .frame(
                                minWidth: LayoutConstants.minInspectorWidth,
                                idealWidth: layoutManager.layout.inspectorWidth,
                                maxWidth: LayoutConstants.maxInspectorWidth
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: InspectorWidthKey.self,
                                                    value: proxy.size.width)
                                }
                            )
                            .materialBackground(.contentBackground,
                                                blendingMode: .withinWindow)
                    }
                }
            }
        }
        .background {
            // Keeps triage data (and the Agent badge) fresh whether or
            // not the Agent view is open. Suspended while the dashboard
            // renders its own monitors, which feed the same store.
            AgentTriagePollers(isSuspended: dashboardShouldRender)
        }
        .task(id: tabStatusKey) {
            AgentTriageStore.shared.syncTabs(tabsStore.tabs)
        }
        .onPreferenceChange(InspectorWidthKey.self, perform: persistInspectorWidth)
        // When a mode's precondition disappears, fall back to the
        // server workspace instead of leaving a lit segment with a
        // dead pane behind it.
        .onChange(of: connectedSSHTabIds) { ids in
            if ids.count < 2, mode == .dashboard {
                mode = .server
            }
        }
        .onChange(of: tabsStore.tabs.isEmpty) { isEmpty in
            if isEmpty, mode == .agent {
                mode = .server
            }
        }
        .onChange(of: connectedFileTabCount) { count in
            if count < 1, mode == .files {
                mode = .server
            }
        }
    }

    /// Debounce drag updates: split views fire preference changes on every
    /// frame while the user drags, *and* every frame during a window
    /// resize. We coalesce to one disk write 250 ms after the last update,
    /// and clamp to the configured min/max so a transient `0` (e.g.,
    /// during reappearance after toggle) cannot corrupt the persisted
    /// dimension.
    ///
    /// Note: this means the persisted dimension drifts with window
    /// resizes, since the split view rebalances proportionally. That's
    /// the trade-off for keeping the persistence path simple — there is
    /// no reliable "drag began / drag ended" callback on `HSplitView` /
    /// `VSplitView` to differentiate user drag from system reflow.
    private func persistInspectorWidth(_ measured: CGFloat) {
        inspectorWidthDebounce?.cancel()
        inspectorWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clamped = min(
                max(measured, LayoutConstants.minInspectorWidth),
                LayoutConstants.maxInspectorWidth
            )
            if abs(clamped - layoutManager.layout.inspectorWidth) > 1 {
                layoutManager.layout.inspectorWidth = clamped
            }
        }
    }
}

// MARK: - Preference keys for split-pane dimensions

private struct InspectorWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
