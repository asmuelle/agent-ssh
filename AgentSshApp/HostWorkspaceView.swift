import AgentSshMacOS
import SwiftUI

/// What the host screen shows. Diagnosis comes first: after a connect
/// the user lands on what is wrong with the host, with the terminal and
/// files one click (or ⌘2 / ⌘3) away.
enum HostSection: String, CaseIterable, Identifiable, Equatable {
    case diagnosis, terminal, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagnosis: return "Diagnosis"
        case .terminal: return "Terminal"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .diagnosis: return "stethoscope"
        case .terminal: return "terminal"
        case .files: return "folder"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .diagnosis: return "1"
        case .terminal: return "2"
        case .files: return "3"
        }
    }

    /// SFTP-only hosts have no shell, so nothing to diagnose and no
    /// terminal: they get Files alone.
    static func available(for kind: ConnectionKind) -> [HostSection] {
        kind.supportsTerminal ? allCases : [.files]
    }

    static func initial(for kind: ConnectionKind) -> HostSection {
        available(for: kind)[0]
    }
}

/// The detail column: one host at a time, chosen in the sidebar.
///
/// Every open connection stays mounted (stacked, only the selected one
/// visible) so terminal scrollback, file-browser paths and a finished
/// diagnosis survive switching hosts and sections.
struct HostWorkspaceView: View {
    let profile: ConnectionProfile?
    /// Section per profile id; a host not in the map shows its initial
    /// section.
    @Binding var sections: [String: HostSection]
    let onConnect: (ConnectionProfile) -> Void
    @EnvironmentObject private var tabsStore: TerminalTabsStore
    @ObservedObject private var connectionStore = ConnectionStoreManager.shared

    var body: some View {
        if let profile {
            VStack(spacing: 0) {
                HostHeader(
                    profile: profile,
                    tab: tab(for: profile),
                    isConnecting: tabsStore.connectingProfileIds.contains(profile.id),
                    section: sectionBinding(for: profile),
                    onConnect: { onConnect(profile) }
                )
                Divider()
                content(for: profile)
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func content(for profile: ConnectionProfile) -> some View {
        ZStack {
            ForEach(tabsStore.tabs) { tab in
                let isSelected = tab.profile.id == profile.id
                HostTabContent(
                    tab: tab,
                    section: section(for: tab.profile, kind: tab.effectiveKind),
                    isActive: isSelected
                )
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .id(tab.id)
            }

            if tab(for: profile) == nil {
                HostOverview(
                    profile: profile,
                    isConnecting: tabsStore.connectingProfileIds.contains(profile.id),
                    onConnect: { onConnect(profile) }
                )
            }
        }
        .frame(minWidth: 320, minHeight: 320)
    }

    private func tab(for profile: ConnectionProfile) -> TerminalTab? {
        tabsStore.tabs.first { $0.profile.id == profile.id }
    }

    private func section(for profile: ConnectionProfile, kind: ConnectionKind) -> HostSection {
        let available = HostSection.available(for: kind)
        if let chosen = sections[profile.id], available.contains(chosen) {
            return chosen
        }
        return HostSection.initial(for: kind)
    }

    private func sectionBinding(for profile: ConnectionProfile) -> Binding<HostSection> {
        let kind = tab(for: profile)?.effectiveKind ?? profile.kind
        return Binding(
            get: { section(for: profile, kind: kind) },
            set: { sections[profile.id] = $0 }
        )
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            // One instruction: what to do next, which depends on whether
            // anything is saved yet.
            Text(connectionStore.connections.isEmpty
                ? "Add a host with + at the top of the sidebar."
                : "Select a host in the sidebar.")
                .font(MidnightMacDesign.FontToken.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

/// Host name and address, the section switcher, and the one connection
/// action that applies right now (Connect, Reconnect or Disconnect).
private struct HostHeader: View {
    let profile: ConnectionProfile
    let tab: TerminalTab?
    let isConnecting: Bool
    @Binding var section: HostSection
    let onConnect: () -> Void
    @EnvironmentObject private var tabsStore: TerminalTabsStore

    private var status: TerminalConnectionStatus? {
        isConnecting ? .connecting : tab?.status
    }

    private var sections: [HostSection] {
        HostSection.available(for: tab?.effectiveKind ?? profile.kind)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(MidnightMacDesign.FontToken.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let status {
                        Image(systemName: status.sidebarSymbol)
                            .foregroundStyle(status.sidebarColor)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        Text(status.sidebarLabel)
                    } else {
                        Text("Not connected")
                    }
                    Text("·")
                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                        .font(MidnightMacDesign.FontToken.metadataMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if sections.count > 1 {
                Picker("Section", selection: $section) {
                    ForEach(sections) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            connectionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var connectionButton: some View {
        if isConnecting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 90)
        } else if let tab, tab.status == .disconnected || tab.status == .error {
            Button("Reconnect") {
                Task { await tabsStore.reconnect(tabId: tab.id) }
            }
            .buttonStyle(.borderedProminent)
        } else if let tab {
            Button("Disconnect") {
                tabsStore.closeTab(tab.id)
            }
        } else {
            Button("Connect", action: onConnect)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Connected host

/// One open connection's sections, all mounted so each keeps its state.
private struct HostTabContent: View {
    let tab: TerminalTab
    let section: HostSection
    let isActive: Bool

    var body: some View {
        ZStack {
            if tab.effectiveKind.supportsTerminal {
                layer(.diagnosis) { DiagnosisPane(tab: tab) }
                layer(.terminal) {
                    TerminalPane(tab: tab, isActive: isActive && section == .terminal)
                }
            }
            layer(.files) {
                DualPaneFileBrowserView(
                    connectionId: tab.connectionId,
                    connectionLabel: tab.profile.name,
                    canEditPermissions: tab.effectiveKind.supportsTerminal,
                    canRunRemoteCommands: tab.effectiveKind.supportsTerminal
                )
            }
        }
    }

    private func layer<Content: View>(
        _ layerSection: HostSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(section == layerSection ? 1 : 0)
            .allowsHitTesting(section == layerSection)
            .accessibilityHidden(section != layerSection)
    }
}

/// Server Doctor's health check and the security-update scan: the two
/// checks behind the sidebar's health dot, side by side under one tab.
private struct DiagnosisPane: View {
    let tab: TerminalTab
    @State private var check = Check.health

    private enum Check: String, CaseIterable, Identifiable {
        case health, security
        var id: String { rawValue }
        var title: String {
            switch self {
            case .health: return "Health Check"
            case .security: return "Security Updates"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Check", selection: $check) {
                ForEach(Check.allCases) { check in
                    Text(check.title).tag(check)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)

            Divider()

            ZStack {
                ServerDoctorView(target: ServerDoctorTarget(tab: tab))
                    .opacity(check == .health ? 1 : 0)
                    .allowsHitTesting(check == .health)
                SecurityPatchMonitorView(
                    connectionId: tab.connectionId,
                    profileId: tab.profile.id,
                    connectionLabel: tab.profile.name
                )
                .opacity(check == .security ? 1 : 0)
                .allowsHitTesting(check == .security)
            }
        }
    }
}

// MARK: - Not connected

/// A saved host that isn't open: what we last knew about it and the way
/// to connect.
private struct HostOverview: View {
    let profile: ConnectionProfile
    let isConnecting: Bool
    let onConnect: () -> Void
    @ObservedObject private var securitySummaries = SecurityPatchMonitorSummaryStore.shared

    private var health: HostHealth? {
        HostHealth(
            security: securitySummaries.summary(profileId: profile.id, connectionId: nil),
            doctor: ServerDoctorSummaryStore().summary(profileId: profile.id)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let health {
                    Label {
                        Text(health.help)
                    } icon: {
                        Image(systemName: health.symbol)
                            .foregroundStyle(health.color)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(MidnightMacDesign.FontToken.callout)
                }

                Text(profile.kind.supportsTerminal
                    ? "Connect to diagnose this host and open its terminal and files."
                    : "Connect to browse this host's files.")
                    .font(MidnightMacDesign.FontToken.callout)
                    .foregroundStyle(.secondary)

                Button(action: onConnect) {
                    Label("Connect", systemImage: "bolt.horizontal.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isConnecting)

                Divider()

                HostDetailsView(profile: profile, status: nil)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
    }
}
