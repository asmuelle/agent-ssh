import AgentSshMacOS
import SwiftUI

/// Native macOS workspace: hosts on the left, the selected host on
/// the right.
///
///   ┌────────────────┬───────────────────────────┬────────────┐
///   │ Needs Attention│ host · Diagnosis Terminal │            │
///   │  web-1  ●      │        Files              │  System    │
///   │ All Hosts      ├───────────────────────────┤  Monitor   │
///   │  db-1          │ diagnosis, terminal or    │ (optional) │
///   │  web-1  ●      │ files for that host       │            │
///   └────────────────┴───────────────────────────┴────────────┘
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
    @State private var selectedConnection: ConnectionProfile?
    /// Which section each host shows; hosts not in the map open on
    /// their first section (Diagnosis for SSH hosts).
    @State private var hostSections: [String: HostSection] = [:]
    @State private var showingCommandPalette = false
    @State private var fleetTool: FleetTool?
    @State private var didRunAutoConnect = false

    var body: some View {
        HSplitView {
            if layoutManager.layout.sidebarVisible {
                SidebarColumn(
                    layoutManager: layoutManager,
                    storeManager: connectionStore,
                    selectedConnection: $selectedConnection,
                    onConnect: connect,
                    onDiagnose: diagnose
                )
            }

            DetailColumn(
                layoutManager: layoutManager,
                selectedConnection: selectedConnection,
                hostSections: $hostSections,
                onConnect: connect
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
            await runAutoConnect()
        }
        // The sidebar selection is the one source of truth for "which
        // host": the active connection is always the selected host's,
        // or none when that host isn't connected, so Reconnect,
        // Disconnect and the palette can only ever act on the host on
        // screen. A connect finishing in the background never moves
        // the selection. The one exception is launch, when nothing is
        // selected yet: the first host to connect is selected.
        .onChange(of: selectedConnection?.id) { _, _ in syncActiveTab() }
        .onChange(of: tabsStore.tabs.map(\.id)) { _, _ in syncActiveTab() }
        .onChange(of: tabsStore.activeTabId) { _, _ in
            if selectedConnection == nil, let profile = tabsStore.activeTab?.profile {
                selectedConnection = profile
            } else {
                syncActiveTab()
            }
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                connections: connectionStore.connections,
                selectedConnection: selectedConnection,
                activeTab: tabsStore.activeTab,
                connectedHostCount: tabsStore.connectedSSHTabs.count,
                onConnect: connect,
                onReconnectActive: {
                    if let activeTab = tabsStore.activeTab {
                        Task { await tabsStore.reconnect(tabId: activeTab.id) }
                    }
                },
                onCloseActive: {
                    tabsStore.closeActiveTab()
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
                onOpenFleetTool: { tool in
                    fleetTool = tool
                },
                onDiagnoseActive: {
                    if let profile = tabsStore.activeTab?.profile {
                        diagnose(profile)
                    }
                }
            )
        }
        .onReceive(AgentSshEventBus.shared.events) { event in
            switch event {
            case .showCommandPalette:
                showingCommandPalette = true
            case .selectAdjacentHost(let forward):
                selectAdjacentConnectedHost(forward: forward)
            case .showFleetTool(let tool):
                if !tabsStore.connectedSSHTabs.isEmpty {
                    fleetTool = tool
                }
            case .showHostSection(let section):
                if let profile = selectedConnection {
                    hostSections[profile.id] = section
                }
            default:
                break
            }
        }
        .sheet(item: $fleetTool) { tool in
            switch tool {
            case .runbook: FleetRunbookSheet(tabs: tabsStore.connectedSSHTabs)
            case .stackAudit: FleetStackAuditSheet(tabs: tabsStore.connectedSSHTabs)
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
            Button("Convert host to SFTP") {
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

    /// Open (or refocus) a host's connection and select it. A fresh
    /// connection opens on its first section, so connecting lands on
    /// the diagnosis.
    private func connect(_ profile: ConnectionProfile) {
        selectedConnection = profile
        if !tabsStore.tabs.contains(where: { $0.profile.id == profile.id }) {
            hostSections[profile.id] = nil
        }
        Task { await tabsStore.openConnection(profile) }
    }

    private func syncActiveTab() {
        let selectedTabId = selectedConnection.flatMap { selected in
            tabsStore.tabs.first { $0.profile.id == selected.id }?.id
        }
        if tabsStore.activeTabId != selectedTabId {
            tabsStore.activeTabId = selectedTabId
        }
    }

    /// Move the selection to the next (or previous) connected host,
    /// starting from the selected one.
    private func selectAdjacentConnectedHost(forward: Bool) {
        let connected = tabsStore.tabs.sorted { $0.order < $1.order }
        guard !connected.isEmpty else { return }
        let current = connected.firstIndex { $0.profile.id == selectedConnection?.id }
        let next: Int
        if let current {
            next = (current + (forward ? 1 : -1) + connected.count) % connected.count
        } else {
            next = forward ? 0 : connected.count - 1
        }
        selectedConnection = connected[next].profile
    }

    /// Show a host's diagnosis, connecting first when needed.
    private func diagnose(_ profile: ConnectionProfile) {
        selectedConnection = profile
        hostSections[profile.id] = .diagnosis
        let tab = tabsStore.tabs.first { $0.profile.id == profile.id }
        if tab == nil || tab?.status == .disconnected || tab?.status == .error {
            Task { await tabsStore.openConnection(profile) }
        }
    }

    /// Connect every profile marked "Connect at launch" — once per app
    /// run, and only profiles whose stored credentials allow a silent
    /// connect, so startup never opens a wall of password prompts.
    ///
    /// Connects run in parallel: a serial loop would let one slow or
    /// unreachable host block every server behind it (the "only one
    /// connected on startup" failure). Hosts that come up unhealthy
    /// rise to "Needs Attention" in the sidebar on their own.
    @MainActor
    private func runAutoConnect() async {
        guard !didRunAutoConnect else { return }
        didRunAutoConnect = true

        let profiles = connectionStore.connections.filter {
            $0.autoConnect && canConnectSilently($0)
        }
        guard !profiles.isEmpty else { return }

        let tabsStore = tabsStore
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask {
                    await tabsStore.openConnection(profile)
                }
            }
        }
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
                hostSections[profile.id] = .diagnosis
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

// MARK: - Detail column (host + inspector)

private struct DetailColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    let selectedConnection: ConnectionProfile?
    @Binding var hostSections: [String: HostSection]
    let onConnect: (ConnectionProfile) -> Void
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @State private var inspectorWidthDebounce: Task<Void, Never>?

    /// The System Monitor follows the selected host, and only while it
    /// has an open shell.
    private var inspectorShouldRender: Bool {
        guard layoutManager.layout.inspectorVisible,
              let tab = tabsStore.activeOpenSSHTab
        else { return false }
        return tab.profile.id == selectedConnection?.id
    }

    /// Changes whenever any tab's connection status flips — drives the
    /// triage store's connection-issue sync.
    private var tabStatusKey: String {
        tabsStore.tabs
            .map { "\($0.id.uuidString):\($0.status.rawValue)" }
            .joined(separator: ",")
    }

    var body: some View {
        HSplitView {
            HostWorkspaceView(
                profile: selectedConnection,
                sections: $hostSections,
                onConnect: onConnect
            )
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
        .background {
            // Keeps host health fresh for the sidebar's attention
            // ordering whichever host is on screen.
            AgentTriagePollers()
        }
        .task(id: tabStatusKey) {
            AgentTriageStore.shared.syncTabs(tabsStore.tabs)
        }
        .onPreferenceChange(InspectorWidthKey.self, perform: persistInspectorWidth)
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
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
