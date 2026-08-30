import AgentSshMacOS
import SwiftUI

/// What the detail column's main pane shows. One value, one source of
/// truth — exactly one of these is active at any moment, so the
/// switcher always has exactly one lit segment.
enum WorkspaceMode: String {
    case server
    case dashboard
    case agent
    case files
}

/// Top bar of the detail column: workspace tabs on the left (only in
/// server mode — in every other mode the tabs don't control the main
/// pane and would just be misleading chrome), and the mode switcher
/// pinned on the right.
struct WorkspaceTabStripView: View {
    let tabs: [WorkspaceTab]
    @Binding var activeTabId: UUID?
    var onClose: (WorkspaceTab) -> Void
    var onNewTab: () -> Void
    /// Workspace tab right-click -> "Theme" submenu. `nil` means "use global".
    var onSetTheme: ((WorkspaceTab, String?) -> Void)? = nil
    /// Currently applied per-workspace override, by tab id. Used to put a check
    /// mark next to the active selection in the context menu.
    var themeOverrides: [UUID: String] = [:]
    /// Live connection state per tab id, for the status symbol prefix.
    var statuses: [UUID: TerminalConnectionStatus] = [:]
    /// Optional hover text per tab id — the shell-reported title, so the
    /// label can stay the connection name without losing `user@host: cwd`.
    var tooltips: [UUID: String] = [:]

    @Binding var mode: WorkspaceMode
    /// Name of the active host, shown on the Server segment so the
    /// user knows where ⌘1 leads even while the tabs are hidden.
    var serverSegmentTitle = "Server"
    var dashboardAvailable = false
    var agentAvailable = false
    var filesAvailable = false
    /// Confirmed triage issues — when > 0 the Agent segment turns loud
    /// (red, with a count) even while the Agent view is closed.
    var agentIssueCount = 0

    var body: some View {
        HStack(spacing: 0) {
            if mode == .server {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            WorkspaceTabItemView(
                                tab: tab,
                                isActive: tab.id == activeTabId,
                                currentThemeOverride: themeOverrides[tab.id],
                                status: statuses[tab.id] ?? .connected,
                                tooltip: tooltips[tab.id],
                                onSelect: { activeTabId = tab.id },
                                onClose: { onClose(tab) },
                                onSetTheme: onSetTheme.map { setter in
                                    { themeId in setter(tab, themeId) }
                                }
                            )
                        }

                        if tabs.isEmpty {
                            Button(action: onNewTab) {
                                Image(systemName: "plus")
                                    .font(MidnightMacDesign.FontToken.subheadline)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .help("New Connection")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            WorkspaceModeSwitcher(
                mode: $mode,
                serverTitle: serverSegmentTitle,
                dashboardAvailable: dashboardAvailable,
                agentAvailable: agentAvailable,
                filesAvailable: filesAvailable,
                agentIssueCount: agentIssueCount
            )
            .padding(.trailing, 8)
        }
        .frame(height: LayoutConstants.workspaceTabStripHeight)
        .background(MidnightMacDesign.ColorToken.controlBackground)
    }
}

/// Segmented switcher for the main pane. Exactly one segment is always
/// selected; unavailable modes hide their segment entirely. ⌘1–⌘4
/// switch modes from the keyboard.
struct WorkspaceModeSwitcher: View {
    @Binding var mode: WorkspaceMode
    var serverTitle = "Server"
    var dashboardAvailable = false
    var agentAvailable = false
    var filesAvailable = false
    var agentIssueCount = 0

    var body: some View {
        HStack(spacing: 2) {
            segment(
                .server,
                title: serverTitle,
                icon: "terminal",
                shortcut: "1",
                help: "Show the active server workspace (⌘1)"
            )
            if dashboardAvailable {
                segment(
                    .dashboard,
                    title: "Dashboard",
                    icon: "square.grid.2x2",
                    shortcut: "2",
                    help: "Multi-host dashboard (⌘2)"
                )
            }
            if agentAvailable {
                segment(
                    .agent,
                    title: "Agent",
                    icon: "waveform.path.ecg",
                    shortcut: "3",
                    help: agentIssueCount > 0
                        ? "\(agentIssueCount) issue\(agentIssueCount == 1 ? "" : "s") need attention (⌘3)"
                        : "Agent view — silent unless something needs fixing (⌘3)",
                    badge: agentIssueCount
                )
            }
            if filesAvailable {
                segment(
                    .files,
                    title: "Files",
                    icon: "folder",
                    shortcut: "4",
                    help: "Browse every connected host's files side by side (⌘4)"
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small + 2)
                .fill(MidnightMacDesign.ColorToken.controlBackground.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small + 2)
                .stroke(MidnightMacDesign.ColorToken.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private func segment(
        _ target: WorkspaceMode,
        title: String,
        icon: String,
        shortcut: Character,
        help: String,
        badge: Int = 0
    ) -> some View {
        let isActive = mode == target
        return Button {
            mode = target
        } label: {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                    .font(MidnightMacDesign.FontToken.label)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isActive
                ? Color.accentColor
                : (badge > 0 ? Color.red : Color.primary)
        )
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .help(help)
    }
}

// MARK: - Single workspace tab

struct WorkspaceTabItemView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    var currentThemeOverride: String? = nil
    var status: TerminalConnectionStatus = .connected
    var tooltip: String? = nil
    let onSelect: () -> Void
    let onClose: () -> Void
    var onSetTheme: ((String?) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 12, height: 12)
                .help(statusTooltip)
                .accessibilityLabel(statusTooltip)

            Text(tab.title)
                .font(MidnightMacDesign.FontToken.subheadline)
                .lineLimit(1)
                .help(tooltip ?? tab.title)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Close (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? MidnightMacDesign.ColorToken.selection.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.xsmall))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if let onSetTheme {
                Menu("Theme") {
                    Button {
                        onSetTheme(nil)
                    } label: {
                        Label(
                            "Use global",
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
                }
            }
            Button("Close Tab", action: onClose)
        }
    }

    private var statusColor: Color {
        MidnightMacDesign.statusColor(status)
    }

    private var statusSymbol: String {
        MidnightMacDesign.statusSymbol(status)
    }

    private var statusTooltip: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .error: return "Connection error"
        }
    }
}
