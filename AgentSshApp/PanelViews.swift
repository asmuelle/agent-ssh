import AgentSshMacOS
import SwiftUI

// MARK: - Terminal

struct TerminalPane: View {
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
