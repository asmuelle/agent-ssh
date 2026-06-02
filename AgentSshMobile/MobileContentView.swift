import SwiftUI
import UniformTypeIdentifiers

struct MobileContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var bridgeManager: MobileBridgeManager
    @EnvironmentObject private var keychainManager: MobileKeychainManager
    @EnvironmentObject private var connectionStore: MobileConnectionStore
    @EnvironmentObject private var sessionStore: MobileSessionStore
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore

    @State private var selectedConnectionId: String?
    @State private var compactPath = NavigationPath()
    @State private var connectionSearch = ""
    @State private var editorTarget: MobileConnectionProfile?
    @State private var creatingConnection = false
    @State private var showingProUpgrade = false
    @State private var showingFleetDashboard = false
    @State private var showingSecurityVault = false
    @State private var showingCommandPalette = false
    @State private var exportingDiagnostics = false
    @State private var diagnosticsDocument = MobileDiagnosticsDocument()
    @State private var diagnosticsFilename = MobileDiagnosticsBundleFactory.defaultFilename()
    @State private var diagnosticsError: String?
    @State private var exportingConnectionsCSV = false
    @State private var importingConnectionsCSV = false
    @State private var connectionCSVDocument = MobileTextDocument()
    @State private var connectionCSVImportPlan: ConnectionCSVImportPlan?
    @State private var connectionImportExportError: String?
    @State private var syncStatusMessage: String?
    @State private var showingKeyboardHUD = false
    @State private var pendingDetailRoute: MobileServerDetailRoute?

    private var selectedConnection: MobileConnectionProfile? {
        guard let selectedConnectionId else { return connectionStore.connections.first }
        return connectionStore.connections.first { $0.id == selectedConnectionId }
    }

    private var filteredConnections: [MobileConnectionProfile] {
        let sorted = connectionStore.connections.sorted(by: connectionSort)
        let needle = connectionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { profile in
            connectionSearchFields(for: profile).contains { field in
                field.lowercased().contains(needle)
            }
        }
    }

    private var connectionGroups: [MobileConnectionFolderGroup] {
        let profiles = filteredConnections
        let hasFolders = profiles.contains { profile in
            profile.folder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let grouped = Dictionary(grouping: profiles) { profile in
            guard hasFolders else { return "Connections" }
            return connectionFolderTitle(for: profile)
        }

        return grouped.keys
            .sorted(by: connectionFolderSort)
            .compactMap { title in
                guard let profiles = grouped[title] else { return nil }
                return MobileConnectionFolderGroup(title: title, profiles: profiles)
            }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $creatingConnection) {
            MobileConnectionEditorView(profile: nil) { profile in
                connectionStore.upsert(profile)
                selectedConnectionId = profile.id
                if horizontalSizeClass == .compact {
                    compactPath = NavigationPath()
                    compactPath.append(profile.id)
                }
                creatingConnection = false
            } onCancel: {
                creatingConnection = false
            }
        }
        .sheet(isPresented: $showingProUpgrade) {
            MobileProUpgradeView(currentSavedHosts: connectionStore.connections.count)
        }
        .sheet(isPresented: $showingFleetDashboard) {
            MobileFleetDashboardView(profiles: connectionStore.connections)
        }
        .sheet(isPresented: $showingSecurityVault) {
            MobileSecurityVaultView(profiles: connectionStore.connections)
        }
        .sheet(isPresented: $showingCommandPalette) {
            MobileGlobalCommandPaletteView(
                profiles: connectionStore.connections,
                selectedProfileId: selectedConnectionId,
                onSelectProfile: { profile in
                    selectedConnectionId = profile.id
                    if horizontalSizeClass == .compact {
                        compactPath = NavigationPath()
                        compactPath.append(profile.id)
                    }
                },
                onAddConnection: {
                    beginCreateConnection()
                },
                onOpenFleet: {
                    showingFleetDashboard = true
                },
                onOpenSecurityVault: {
                    showingSecurityVault = true
                },
                onExportDiagnostics: {
                    exportDiagnostics()
                }
            )
        }
        .sheet(item: $editorTarget) { profile in
            MobileConnectionEditorView(profile: profile) { updated in
                connectionStore.upsert(updated)
                selectedConnectionId = updated.id
                editorTarget = nil
            } onCancel: {
                editorTarget = nil
            }
        }
        .alert(
            "Storage Error",
            isPresented: Binding(
                get: { connectionStore.lastError != nil },
                set: { if !$0 { connectionStore.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionStore.lastError ?? "")
        }
        .alert(
            "Credential Error",
            isPresented: Binding(
                get: { keychainManager.lastError != nil },
                set: { if !$0 { keychainManager.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keychainManager.lastError ?? "")
        }
        .alert(
            "Diagnostics Export Failed",
            isPresented: Binding(
                get: { diagnosticsError != nil },
                set: { if !$0 { diagnosticsError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsError ?? "")
        }
        .alert(
            "Import or Sync Failed",
            isPresented: Binding(
                get: { connectionImportExportError != nil },
                set: { if !$0 { connectionImportExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionImportExportError ?? "")
        }
        .confirmationDialog(
            "Import Connections CSV",
            isPresented: Binding(
                get: { connectionCSVImportPlan != nil },
                set: { if !$0 { connectionCSVImportPlan = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let connectionCSVImportPlan {
                Button("Apply \(connectionCSVImportPlan.addCount + connectionCSVImportPlan.updateCount) Change\(connectionCSVImportPlan.addCount + connectionCSVImportPlan.updateCount == 1 ? "" : "s")") {
                    connectionStore.applyCSVImport(connectionCSVImportPlan)
                    syncStatusMessage = "CSV import applied: \(connectionCSVImportPlan.summary)."
                    self.connectionCSVImportPlan = nil
                }
                .disabled(!connectionCSVImportPlan.isApplicable)
            }
            Button("Cancel", role: .cancel) {
                connectionCSVImportPlan = nil
            }
        } message: {
            Text(connectionCSVImportPlan?.summary ?? "")
        }
        .fileExporter(
            isPresented: $exportingDiagnostics,
            document: diagnosticsDocument,
            contentType: .json,
            defaultFilename: diagnosticsFilename
        ) { result in
            if case .failure(let error) = result {
                diagnosticsError = MobileDiagnosticsRedactor.redactSecrets(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $exportingConnectionsCSV,
            document: connectionCSVDocument,
            contentType: .plainText,
            defaultFilename: "agent-ssh-connections.csv"
        ) { result in
            if case .failure(let error) = result {
                connectionImportExportError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $importingConnectionsCSV,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    connectionCSVImportPlan = try connectionStore.previewCSVImport(url: url)
                } catch {
                    connectionImportExportError = error.localizedDescription
                }
            case .failure(let error):
                connectionImportExportError = error.localizedDescription
            }
        }
        .onAppear {
            bridgeManager.initialize()
        }
        .onOpenURL(perform: handleDeepLink)
        .onContinueUserActivity("com.mc-ssh.agent-ssh.route") { activity in
            if let raw = activity.userInfo?["url"] as? String,
               let url = URL(string: raw) {
                handleDeepLink(url)
            } else if let url = activity.webpageURL {
                handleDeepLink(url)
            }
        }
        .overlay {
            if showingKeyboardHUD {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showingKeyboardHUD = false }
                KeyboardShortcutHUDView {
                    showingKeyboardHUD = false
                }
                .transition(.opacity)
                .animation(.easeOut(duration: 0.15), value: showingKeyboardHUD)
            }
        }
        .background {
            Button("Keyboard Shortcuts") {
                showingKeyboardHUD.toggle()
            }
            .keyboardShortcut("/", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .background {
            Button("Command Palette") {
                showingCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List(selection: $selectedConnectionId) {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "server.rack",
                        description: Text("Add an SSH or SFTP profile to start testing the mobile bridge.")
                    )
                    .listRowSeparator(.hidden)
                } else if filteredConnections.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No saved connection matches this search.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(connectionGroups) { group in
                        Section(group.title) {
                            ForEach(group.profiles) { profile in
                                MobileConnectionRow(profile: profile)
                                    .tag(profile.id)
                                    .contextMenu {
                                        connectionContextMenu(for: profile)
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("agent-ssh")
            .searchable(
                text: $connectionSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Connections"
            )
            .toolbar {
                connectionToolbar
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            if let selectedConnection {
                MobileServerDetailView(
                    profile: selectedConnection,
                    route: route(for: selectedConnection.id)
                )
                    .id(selectedConnection.id)
            } else {
                ContentUnavailableView(
                    "Select a Connection",
                    systemImage: "terminal",
                    description: Text("The iPadOS workspace will show terminal, files, and server health here.")
                )
            }
        }
    }

    private var compactLayout: some View {
        NavigationStack(path: $compactPath) {
            List {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "server.rack",
                        description: Text("Add an SSH or SFTP profile to start testing the mobile bridge.")
                    )
                    .listRowSeparator(.hidden)
                } else if filteredConnections.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No saved connection matches this search.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(connectionGroups) { group in
                        Section(group.title) {
                            ForEach(group.profiles) { profile in
                                NavigationLink(value: profile.id) {
                                    MobileConnectionRow(profile: profile)
                                }
                                .contextMenu {
                                    connectionContextMenu(for: profile)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("agent-ssh")
            .searchable(
                text: $connectionSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Connections"
            )
            .toolbar {
                connectionToolbar
            }
            .navigationDestination(for: String.self) { profileId in
                if let profile = connectionStore.connections.first(where: { $0.id == profileId }) {
                    MobileServerDetailView(
                        profile: profile,
                        route: route(for: profile.id)
                    )
                        .id(profile.id)
                } else {
                    ContentUnavailableView(
                        "Connection Removed",
                        systemImage: "trash",
                        description: Text("This saved connection is no longer available.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 6) {
            if let syncStatusMessage {
                Text(syncStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            MobileConnectionLimitStatusView {
                showingProUpgrade = true
            }
            MobileBridgeStatusView()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    showingProUpgrade = true
                } label: {
                    Label(
                        entitlementsStore.isPro ? "Pro Active" : "Upgrade to Pro",
                        systemImage: entitlementsStore.isPro ? "checkmark.seal.fill" : "sparkles"
                    )
                }

                Button {
                    showingCommandPalette = true
                } label: {
                    Label("Command Palette", systemImage: "command")
                }

                Button {
                    showingFleetDashboard = true
                } label: {
                    Label("Fleet Dashboard", systemImage: "rectangle.grid.2x2")
                }

                Button {
                    showingSecurityVault = true
                } label: {
                    Label("Security Vault", systemImage: "lock.shield")
                }

                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button {
                    publishSyncSnapshot()
                } label: {
                    Label("Publish Sync Snapshot", systemImage: "icloud.and.arrow.up")
                }

                Button {
                    applySyncSnapshot()
                } label: {
                    Label("Apply Latest Sync", systemImage: "icloud.and.arrow.down")
                }

                Button {
                    importingConnectionsCSV = true
                } label: {
                    Label("Import Connections CSV", systemImage: "tray.and.arrow.down")
                }

                Button {
                    exportConnectionsCSV()
                } label: {
                    Label("Export Connections CSV", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                beginCreateConnection()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add connection")
        }
    }

    @ViewBuilder
    private func connectionContextMenu(for profile: MobileConnectionProfile) -> some View {
        if case .connected = sessionStore.status(for: profile) {
            Button("Disconnect", role: .destructive) {
                sessionStore.disconnect(profile: profile)
            }
        }
        Button("Edit") { editorTarget = profile }
        Button("Delete", role: .destructive) {
            connectionStore.delete(profile)
        }
    }

    @MainActor
    private func exportDiagnostics() {
        do {
            let bundle = MobileDiagnosticsBundleFactory.make(
                bridgeManager: bridgeManager,
                keychainManager: keychainManager,
                connectionStore: connectionStore,
                sessionStore: sessionStore,
                terminalPreferences: terminalPreferences,
                entitlementsStore: entitlementsStore
            )
            diagnosticsDocument = MobileDiagnosticsDocument(
                data: try MobileDiagnosticsBundleFactory.encode(bundle)
            )
            diagnosticsFilename = MobileDiagnosticsBundleFactory.defaultFilename(
                generatedAt: bundle.generatedAt
            )
            exportingDiagnostics = true
        } catch {
            diagnosticsError = MobileDiagnosticsRedactor.redactSecrets(error.localizedDescription)
        }
    }

    @MainActor
    private func exportConnectionsCSV() {
        connectionCSVDocument = MobileTextDocument(text: connectionStore.exportConnectionsCSV())
        exportingConnectionsCSV = true
        syncStatusMessage = "Prepared \(connectionStore.connections.count) connection\(connectionStore.connections.count == 1 ? "" : "s") for export."
    }

    @MainActor
    private func publishSyncSnapshot() {
        do {
            let report = try connectionStore.publishCloudSync(terminalSettings: currentTerminalSettingsRecord())
            syncStatusMessage = "Published sync snapshot. \(report.summary)."
        } catch {
            connectionImportExportError = error.localizedDescription
        }
    }

    @MainActor
    private func applySyncSnapshot() {
        do {
            let result = try connectionStore.applyLatestCloudSync()
            if let settings = result.terminalSettings {
                applyTerminalSettings(settings)
            }
            syncStatusMessage = "Applied sync snapshot. \(result.report.summary)."
        } catch {
            connectionImportExportError = error.localizedDescription
        }
    }

    private func currentTerminalSettingsRecord() -> SyncedTerminalSettingsRecord {
        SyncedTerminalSettingsRecord(
            defaultColumns: 100,
            defaultRows: 30,
            fontSize: terminalPreferences.fontSize,
            themeId: terminalPreferences.themeId,
            scrollbackLines: terminalPreferences.scrollbackLines,
            cursorStyleId: terminalPreferences.cursorStyleId,
            mouseReporting: terminalPreferences.mouseReporting,
            optionAsMeta: terminalPreferences.optionAsMeta,
            copyOnSelect: terminalPreferences.copyOnSelect,
            accessoryKeyIds: terminalPreferences.accessoryKeyIds,
            updatedAt: Date()
        )
    }

    @MainActor
    private func applyTerminalSettings(_ settings: SyncedTerminalSettingsRecord) {
        terminalPreferences.fontSize = settings.fontSize
        terminalPreferences.themeId = settings.themeId
        terminalPreferences.scrollbackLines = settings.scrollbackLines
        terminalPreferences.cursorStyleId = settings.cursorStyleId
        terminalPreferences.mouseReporting = settings.mouseReporting
        terminalPreferences.optionAsMeta = settings.optionAsMeta
        terminalPreferences.copyOnSelect = settings.copyOnSelect
        terminalPreferences.accessoryKeyIds = settings.accessoryKeyIds
    }

    private func beginCreateConnection() {
        if entitlementsStore.canCreateConnection(currentCount: connectionStore.connections.count) {
            creatingConnection = true
        } else {
            showingProUpgrade = true
        }
    }

    private func connectionSort(_ lhs: MobileConnectionProfile, _ rhs: MobileConnectionProfile) -> Bool {
        if lhs.favorite != rhs.favorite {
            return lhs.favorite && !rhs.favorite
        }

        let lhsFolder = connectionFolderTitle(for: lhs)
        let rhsFolder = connectionFolderTitle(for: rhs)
        if lhsFolder != rhsFolder {
            return connectionFolderSort(lhsFolder, rhsFolder)
        }

        let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
        if nameCompare != .orderedSame {
            return nameCompare == .orderedAscending
        }

        return lhs.host.localizedStandardCompare(rhs.host) == .orderedAscending
    }

    private func connectionFolderTitle(for profile: MobileConnectionProfile) -> String {
        let folder = profile.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return folder.isEmpty ? "Unfiled" : folder
    }

    private func connectionFolderSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Unfiled" { return false }
        if rhs == "Unfiled" { return true }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func connectionSearchFields(for profile: MobileConnectionProfile) -> [String] {
        [
            profile.name,
            profile.host,
            profile.username,
            "\(profile.port)",
            profile.kind.rawValue,
            profile.kind.displayName,
            profile.authMethod.rawValue,
            profile.authMethod.displayName,
            profile.folder ?? "",
            profile.tags.joined(separator: " "),
            profile.notes ?? ""
        ]
    }

    private func route(for profileId: String) -> MobileServerDetailRoute? {
        guard pendingDetailRoute?.profileId == profileId else { return nil }
        return pendingDetailRoute
    }

    private func handleDeepLink(_ url: URL) {
        guard let link = AgentSshDeepLink(url) else { return }

        switch link.kind {
        case .monitoring, .server, .terminal, .folder:
            guard let profileId = link.profileId,
                  connectionStore.connections.contains(where: { $0.id == profileId }) else {
                return
            }
            selectedConnectionId = profileId
            if horizontalSizeClass == .compact {
                compactPath = NavigationPath()
                compactPath.append(profileId)
            }
            pendingDetailRoute = MobileServerDetailRoute(
                profileId: profileId,
                kind: detailRouteKind(for: link)
            )
        case .automation:
            guard let operationId = link.operationId,
                  let operation = try? BackgroundSSHOperationStore().load().operations.first(where: { $0.id == operationId }) else {
                return
            }
            selectedConnectionId = operation.profileId
            if horizontalSizeClass == .compact {
                compactPath = NavigationPath()
                compactPath.append(operation.profileId)
            }
            pendingDetailRoute = MobileServerDetailRoute(
                profileId: operation.profileId,
                kind: .automation(operationId)
            )
        }
    }

    private func detailRouteKind(for link: AgentSshDeepLink) -> MobileServerDetailRoute.Kind {
        switch link.kind {
        case .terminal:
            return .terminal
        case .folder:
            return .folder(link.remotePath)
        case .monitoring, .server:
            return .server
        case .automation:
            return .server
        }
    }
}

private struct MobileConnectionFolderGroup: Identifiable {
    let title: String
    let profiles: [MobileConnectionProfile]

    var id: String { title }
}

private struct MobileConnectionRow: View {
    @EnvironmentObject private var sessionStore: MobileSessionStore

    let profile: MobileConnectionProfile

    private var status: MobileSessionStatus {
        sessionStore.status(for: profile)
    }

    var body: some View {
        HStack(spacing: MidnightMobileDesign.Spacing.large) {
            Image(systemName: profile.kind.supportsTerminal ? "terminal" : "folder")
                .foregroundStyle(profile.kind.supportsTerminal ? .green : .blue)
                .font(MidnightMobileDesign.FontToken.headline)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(MidnightMobileDesign.FontToken.headline)
                    .lineLimit(1)
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if profile.favorite {
                Image(systemName: "star.fill")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.yellow)
            }

            if case .connected = status {
                Button {
                    sessionStore.disconnect(profile: profile)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(MidnightMobileDesign.FontToken.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Disconnect \(profile.name)")
            }

            MobileSessionStatusIndicator(status: status)
        }
        .padding(.vertical, MidnightMobileDesign.Spacing.medium)
        .midnightMobileMinimumTapTarget()
    }
}

private struct MobileSessionStatusIndicator: View {
    let status: MobileSessionStatus

    var body: some View {
        Image(systemName: symbol)
            .font(MidnightMobileDesign.FontToken.captionStrong)
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
            .frame(width: 18, height: 18)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        MidnightMobileDesign.statusColor(status)
    }

    private var symbol: String {
        MidnightMobileDesign.statusSymbol(status)
    }
}

private struct MobileConnectionLimitStatusView: View {
    @EnvironmentObject private var connectionStore: MobileConnectionStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore

    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entitlementsStore.isPro ? "checkmark.seal.fill" : "server.rack")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(entitlementsStore.isPro ? .green : .secondary)

            Text(statusText)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !entitlementsStore.isPro {
                Button("Pro") {
                    onUpgrade()
                }
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .buttonStyle(.borderless)
                .disabled(entitlementsStore.status.isBusy)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var statusText: String {
        if entitlementsStore.isPro {
            return "Pro active"
        }

        return "Saved hosts \(connectionStore.connections.count)/\(MobileEntitlementsStore.freeSavedHostLimit)"
    }
}

private struct MobileBridgeStatusView: View {
    @EnvironmentObject private var bridgeManager: MobileBridgeManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bridgeManager.initialized ? "checkmark.circle.fill" : "clock.fill")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(bridgeManager.initialized ? Color.green : Color.orange)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18, height: 18)

            Text(bridgeManager.initialized ? "Rust bridge ready" : "Initializing bridge")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let initializationError = bridgeManager.initializationError {
                Text(initializationError)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

private struct KeyboardShortcutHUDView: View {
    let onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(MidnightMobileDesign.FontToken.headline)
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                ShortcutSection("Navigation") {
                    ShortcutRow(key: ["⌘", "1"], action: "Inspect Mode")
                    ShortcutRow(key: ["⌘", "2"], action: "Work Mode")
                    ShortcutRow(key: ["⌘", "K"], action: "Command Palette")
                    ShortcutRow(key: ["⌘", "/"], action: "This Shortcut HUD")
                }

                ShortcutSection("Connection") {
                    ShortcutRow(key: ["⌘", "R"], action: "Reconnect")
                    ShortcutRow(key: ["⌘", "L"], action: "Tail Logs")
                }

                ShortcutSection("Terminal") {
                    ShortcutRow(key: ["⌘", "`"], action: "Focus Terminal")
                    ShortcutRow(key: ["⌘", "⇧", "P"], action: "Terminal Commands")
                    ShortcutRow(key: ["⌘", "V"], action: "Paste")
                    ShortcutRow(key: ["⌘", "C"], action: "Copy Selection")
                    ShortcutRow(key: ["⌘", "A"], action: "Select All")
                    ShortcutRow(key: ["⌘", "K"], action: "Clear Screen")
                    ShortcutRow(key: ["⌘", "."], action: "Interrupt (Ctrl+C)")
                    ShortcutRow(key: ["⌘", "R"], action: "Restart Terminal")
                    ShortcutRow(key: ["⌘", ","], action: "Terminal Settings")
                }
            }
            .padding(24)
        }
        .frame(maxWidth: horizontalSizeClass == .compact ? 340 : 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.overlay))
        .padding(20)
    }
}

private struct ShortcutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                content()
            }
        }
    }
}

private struct ShortcutRow: View {
    let key: [String]
    let action: String

    var body: some View {
        HStack {
            Text(action)
                .font(MidnightMobileDesign.FontToken.subheadline)
            Spacer()
            HStack(spacing: 3) {
                ForEach(key, id: \.self) { k in
                    Text(k)
                        .font(MidnightMobileDesign.FontToken.metadataMono.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            MidnightMobileDesign.ColorToken.tertiaryGroupedBackground,
                            in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.small)
                        )
                }
            }
        }
    }
}
