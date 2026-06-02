import AppKit
import SwiftUI
import AgentSshMacOS
import UniformTypeIdentifiers

/// Settings panel with Terminal, Appearance, Credentials, License, and Privacy tabs.
struct SettingsView: View {
    @AppStorage("defaultColumns") private var defaultColumns = 80
    @AppStorage("defaultRows") private var defaultRows = 24
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("terminalTheme") private var terminalTheme = "system"
    @AppStorage("scrollbackLines") private var scrollbackLines = 10_000
    @AppStorage("terminalCursorStyle") private var terminalCursorStyle = "blinkBlock"
    @AppStorage("terminalMouseReporting") private var terminalMouseReporting = true
    @AppStorage("terminalOptionAsMeta") private var terminalOptionAsMeta = true
    @AppStorage("terminalCopyOnSelect") private var terminalCopyOnSelect = false
    @AppStorage("SUEnableAutomaticChecks") private var automaticUpdateChecks = true
    @AppStorage("SUAllowsAutomaticUpdates") private var automaticUpdateInstall = true
    @AppStorage("privacy.shareUsageDiagnostics") private var shareUsageDiagnostics = false
    @AppStorage("privacy.includeUnifiedLogsInDiagnostics") private var includeUnifiedLogsInDiagnostics = true

    @EnvironmentObject private var updateManager: UpdateManager
    @EnvironmentObject private var entitlementsStore: EntitlementsStore
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @State private var selectedConnections = Set<String>()
    @State private var licenseKeyInput = ""
    @State private var licenseError: String?
    @State private var csvImportPlan: ConnectionCSVImportPlan?
    @State private var importExportError: String?
    @State private var syncStatus: String?
    @State private var syncError: String?

    @State private var selectedSection: SettingsSection? = .terminal

    /// Settings panes. A sidebar list is used instead of a horizontal tab
    /// toolbar because the app has more panes than fit in a tab strip — the
    /// overflow `»` menu previously hid (and grayed out) Server Doctor,
    /// License, and Privacy. A sidebar keeps every pane reachable.
    enum SettingsSection: String, CaseIterable, Identifiable {
        case terminal, appearance, sync, cloud, network
        case credentials, advancedAuth, aiCommandCenter, serverDoctor
        case license, privacy

        var id: String { rawValue }

        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .appearance: return "Appearance"
            case .sync: return "Sync"
            case .cloud: return "Cloud"
            case .network: return "Network"
            case .credentials: return "Credentials"
            case .advancedAuth: return "Advanced Auth"
            case .aiCommandCenter: return "AI Command Center"
            case .serverDoctor: return "Server Doctor"
            case .license: return "License"
            case .privacy: return "Privacy"
            }
        }

        var systemImage: String {
            switch self {
            case .terminal: return "terminal"
            case .appearance: return "paintbrush"
            case .sync: return "icloud"
            case .cloud: return "server.rack"
            case .network: return "network"
            case .credentials: return "key"
            case .advancedAuth: return "lock.shield"
            case .aiCommandCenter: return "cpu"
            case .serverDoctor: return "stethoscope"
            case .license: return "seal"
            case .privacy: return "lock.shield"
            }
        }

        var isAvailable: Bool {
            switch self {
            case .cloud: return FeatureFlags.cloudServerManagement.isEnabled
            case .network: return FeatureFlags.networkPolish.isEnabled
            default: return true
            }
        }

        static var available: [SettingsSection] {
            allCases.filter(\.isAvailable)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.available, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detail(for: selectedSection ?? .terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle((selectedSection ?? .terminal).label)
        }
        .frame(minWidth: 880, idealWidth: 940, minHeight: 660, idealHeight: 720)
        .confirmationDialog(
            "Import CSV",
            isPresented: Binding(
                get: { csvImportPlan != nil },
                set: { if !$0 { csvImportPlan = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let csvImportPlan {
                Button("Apply \(csvImportPlan.addCount + csvImportPlan.updateCount) Change\(csvImportPlan.addCount + csvImportPlan.updateCount == 1 ? "" : "s")") {
                    connectionStore.applyCSVImport(csvImportPlan)
                    syncStatus = "CSV import applied: \(csvImportPlan.summary)."
                    self.csvImportPlan = nil
                }
                .disabled(!csvImportPlan.isApplicable)
            }
            Button("Cancel", role: .cancel) {
                csvImportPlan = nil
            }
        } message: {
            Text(csvImportPlan?.summary ?? "")
        }
        .alert(
            "Import or Export Failed",
            isPresented: Binding(
                get: { importExportError != nil },
                set: { if !$0 { importExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importExportError ?? "")
        }
        .alert(
            "Sync Failed",
            isPresented: Binding(
                get: { syncError != nil },
                set: { if !$0 { syncError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(syncError ?? "")
        }
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .terminal: terminalSettings
        case .appearance: appearanceSettings
        case .sync: syncSettings
        case .cloud: CloudServerManagementView(connectionStore: connectionStore)
        case .network: NetworkPolishSettingsView()
        case .credentials: credentialsSettings
        case .advancedAuth: AdvancedAuthenticationView()
        case .aiCommandCenter: MCPSettingsView()
        case .serverDoctor: ServerDoctorSettingsView()
        case .license: licenseSettings
        case .privacy: privacySettings
        }
    }

    // MARK: - Terminal tab

    private var terminalSettings: some View {
        Form {
            Section("Defaults") {
                Picker("Default columns", selection: $defaultColumns) {
                    ForEach([80, 100, 120, 160], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Picker("Default rows", selection: $defaultRows) {
                    ForEach([24, 40, 48, 60], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Picker("Scrollback", selection: $scrollbackLines) {
                    ForEach([1_000, 5_000, 10_000, 50_000, 100_000], id: \.self) { n in
                        Text(n.formatted()).tag(n)
                    }
                }

                Picker("Cursor", selection: $terminalCursorStyle) {
                    ForEach(cursorStyles, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }

            Section("Input") {
                Toggle("Use Option as Meta", isOn: $terminalOptionAsMeta)
                Toggle("Mouse reporting", isOn: $terminalMouseReporting)
                Toggle("Copy on select", isOn: $terminalCopyOnSelect)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance tab

    private var appearanceSettings: some View {
        Form {
            Section("Typography") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $fontSize, in: 8...24, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Theme", selection: $terminalTheme) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.label).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Terminal colours")
            } footer: {
                Text("Named themes override the 16-colour ANSI palette. \"Follow system\", \"Light\", and \"Dark\" leave the palette at SwiftTerm's defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sync tab

    private var syncSettings: some View {
        Form {
            Section {
                statusRow(
                    icon: "key.fill",
                    title: "Secrets",
                    value: "Local Keychain only",
                    color: .green
                )
                statusRow(
                    icon: "icloud.fill",
                    title: "Profile metadata",
                    value: "iCloud key-value snapshot",
                    color: .blue
                )
            } header: {
                Text("Scope")
            } footer: {
                Text("Sync snapshots contain server names, hosts, usernames, folders, tags, snippets, and terminal preferences. Passwords and passphrases are not exported from Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manual sync") {
                HStack {
                    Button("Publish Snapshot") {
                        publishSyncSnapshot()
                    }
                    Button("Apply Latest Snapshot") {
                        applySyncSnapshot()
                    }
                    Spacer()
                }

                if let syncStatus {
                    Text(syncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Import CSV...") {
                        importConnectionsCSV()
                    }
                    Button("Export CSV...") {
                        exportConnectionsCSV()
                    }
                    Spacer()
                }
            } header: {
                Text("CSV import/export")
            } footer: {
                Text("CSV files use stable profile IDs when present. Matching IDs update existing profiles while preserving local Keychain credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials tab

    private var credentialsSettings: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                    Text("macOS Keychain")
                        .font(.headline)
                    Spacer()
                    Text("Available")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Keychain provides encrypted storage for your credentials separately from the app database. Keychain entries persist even if the app is uninstalled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saved credentials") {
                if connectionStore.connections.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "key.slash")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("No saved credentials")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    List(selection: $selectedConnections) {
                        ForEach(connectionStore.connections) { conn in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conn.name)
                                    Text(conn.keychainAccount)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                            .tag(conn.id)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                connectionStore.delete(connectionStore.connections[idx])
                            }
                        }
                    }
                    .frame(minHeight: 140)
                }
            }

            if !connectionStore.connections.isEmpty {
                Section {
                    HStack {
                        Button("Remove Selected") {
                            for id in selectedConnections {
                                if let conn = connectionStore.connection(withId: id) {
                                    connectionStore.delete(conn)
                                }
                            }
                            selectedConnections.removeAll()
                        }
                        .disabled(selectedConnections.isEmpty)

                        Spacer()

                        Button("Import from Tauri…") {
                            importFromTauri()
                        }

                        Button("Import CSV...") {
                            importConnectionsCSV()
                        }

                        Button("Export CSV...") {
                            exportConnectionsCSV()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importFromTauri() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Select the Tauri export JSON file"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                _ = connectionStore.importFromTauriJSON(url: url)
            }
        }
    }

    private func importConnectionsCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Select a agent-ssh connections CSV file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                csvImportPlan = try connectionStore.previewCSVImport(url: url)
            } catch {
                importExportError = error.localizedDescription
            }
        }
    }

    private func exportConnectionsCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "agent-ssh-connections.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try connectionStore.exportConnectionsCSV().write(to: url, atomically: true, encoding: .utf8)
                syncStatus = "Exported \(connectionStore.connections.count) connection\(connectionStore.connections.count == 1 ? "" : "s")."
            } catch {
                importExportError = error.localizedDescription
            }
        }
    }

    private func publishSyncSnapshot() {
        do {
            let report = try connectionStore.publishCloudSync(terminalSettings: currentTerminalSettingsRecord())
            syncStatus = "Published sync snapshot. \(report.summary)."
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func applySyncSnapshot() {
        do {
            let result = try connectionStore.applyLatestCloudSync()
            if let terminalSettings = result.terminalSettings {
                applyTerminalSettings(terminalSettings)
            }
            syncStatus = "Applied sync snapshot. \(result.report.summary)."
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func currentTerminalSettingsRecord() -> SyncedTerminalSettingsRecord {
        SyncedTerminalSettingsRecord(
            defaultColumns: defaultColumns,
            defaultRows: defaultRows,
            fontSize: fontSize,
            themeId: terminalTheme,
            scrollbackLines: scrollbackLines,
            cursorStyleId: terminalCursorStyle,
            mouseReporting: terminalMouseReporting,
            optionAsMeta: terminalOptionAsMeta,
            copyOnSelect: terminalCopyOnSelect,
            updatedAt: Date()
        )
    }

    private func applyTerminalSettings(_ settings: SyncedTerminalSettingsRecord) {
        defaultColumns = settings.defaultColumns
        defaultRows = settings.defaultRows
        fontSize = settings.fontSize
        terminalTheme = settings.themeId
        scrollbackLines = settings.scrollbackLines
        terminalCursorStyle = settings.cursorStyleId
        terminalMouseReporting = settings.mouseReporting
        terminalOptionAsMeta = settings.optionAsMeta
        terminalCopyOnSelect = settings.copyOnSelect
    }

    // MARK: - License tab

    private var licenseSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: licenseStatusIcon)
                            .foregroundStyle(licenseStatusColor)
                        Text(entitlementsStore.snapshot.status.label)
                            .font(.headline)
                        Spacer()
                        Text(entitlementsStore.snapshot.tier.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entitlementsStore.snapshot.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Commercial state")
            }

            Section {
                HStack {
                    Button("Start 14-day Trial") {
                        entitlementsStore.startTrial()
                    }
                    .disabled(!canStartTrial)

                    Button("Refresh") {
                        entitlementsStore.refresh()
                    }

                    Spacer()

                    if let limit = entitlementsStore.snapshot.savedConnectionLimit {
                        Text("Saved hosts limit: \(limit)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Saved hosts: unlimited")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Pre-release builds keep all Pro features enabled until entitlement enforcement is switched on in Info.plist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("License key") {
                TextField("mssh1.payload.signature", text: $licenseKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Button("Save License Key") {
                        saveLicenseKey()
                    }
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Clear Stored Key") {
                        entitlementsStore.clearLicenseKey()
                        licenseError = nil
                    }
                    .disabled(entitlementsStore.snapshot.licenseKeyHash == nil)

                    Spacer()

                    if let hash = entitlementsStore.snapshot.licenseKeyHash {
                        Text("Stored key: \(hash)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let licenseError {
                    Text(licenseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Feature access") {
                ForEach(AppFeature.allCases) { feature in
                    HStack {
                        Image(systemName: entitlementsStore.isEnabled(feature) ? "checkmark.circle.fill" : "lock.fill")
                            .foregroundStyle(entitlementsStore.isEnabled(feature) ? .green : .secondary)
                        Text(feature.label)
                        Spacer()
                        if feature.isPremium {
                            Text("Pro")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Privacy tab

    private var privacySettings: some View {
        Form {
            Section {
                statusRow(
                    icon: "key.fill",
                    title: "macOS Keychain",
                    value: KeychainManager.shared.isAvailable ? "Available" : "Unavailable",
                    color: KeychainManager.shared.isAvailable ? .green : .red
                )
                statusRow(
                    icon: "checkmark.shield.fill",
                    title: "Trusted host keys",
                    value: knownHostsSummary,
                    color: knownHostsFileExists ? .green : .secondary
                )
                statusRow(
                    icon: "externaldrive.fill",
                    title: "Connection database",
                    value: appSupportURL.path,
                    color: .secondary
                )
            } header: {
                Text("Local storage")
            } footer: {
                Text("Connection profiles stay in Application Support. Passwords and key passphrases stay in macOS Keychain. SSH host keys are stored in the Rust bridge's known_hosts file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include redacted unified logs in diagnostics export", isOn: $includeUnifiedLogsInDiagnostics)
                Toggle("Share anonymous usage diagnostics", isOn: $shareUsageDiagnostics)

                Button("Open Application Support Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appSupportURL])
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Anonymous diagnostics is only a stored preference right now; no analytics endpoint is active in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow(
                    icon: updateManager.status.symbolName,
                    title: "Sparkle",
                    value: updateManager.status.label,
                    color: Color(nsColor: updateManager.status.tint)
                )

                LabeledContent("Feed") {
                    Text(updateManager.feedURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Automatically check for updates", isOn: $automaticUpdateChecks)
                Toggle("Install updates automatically", isOn: $automaticUpdateInstall)

                Button("Check Now") {
                    updateManager.checkForUpdates()
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateManager.status.userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveLicenseKey() {
        do {
            try entitlementsStore.saveLicenseKey(licenseKeyInput)
            licenseKeyInput = ""
            licenseError = nil
        } catch {
            licenseError = error.localizedDescription
        }
    }

    private func statusRow(
        icon: String,
        title: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var canStartTrial: Bool {
        switch entitlementsStore.snapshot.status {
        case .free:
            return true
        default:
            return false
        }
    }

    private var licenseStatusIcon: String {
        switch entitlementsStore.snapshot.status {
        case .preview, .licensed, .trialActive:
            return "checkmark.seal.fill"
        case .free:
            return "seal"
        case .trialExpired, .licenseNeedsPublicKey:
            return "exclamationmark.triangle.fill"
        case .invalidLicense:
            return "xmark.seal.fill"
        }
    }

    private var licenseStatusColor: Color {
        switch entitlementsStore.snapshot.status {
        case .preview, .licensed, .trialActive:
            return .green
        case .free:
            return .secondary
        case .trialExpired, .licenseNeedsPublicKey:
            return .orange
        case .invalidLicense:
            return .red
        }
    }

    private var cursorStyles: [(id: String, label: String)] {
        [
            ("blinkBlock", "Blinking Block"),
            ("steadyBlock", "Steady Block"),
            ("blinkUnderline", "Blinking Underline"),
            ("steadyUnderline", "Steady Underline"),
            ("blinkBar", "Blinking Bar"),
            ("steadyBar", "Steady Bar"),
        ]
    }

    private var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.mc-ssh")
    }

    private var knownHostsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("mc-ssh/known_hosts")
    }

    private var knownHostsFileExists: Bool {
        FileManager.default.fileExists(atPath: knownHostsURL.path)
    }

    private var knownHostsSummary: String {
        guard let raw = try? String(contentsOf: knownHostsURL, encoding: .utf8) else {
            return "No trust store yet"
        }
        let count = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
        return "\(count) trusted host\(count == 1 ? "" : "s")"
    }
}
