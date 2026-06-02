import SwiftUI
import AgentSshMacOS

/// Browser-style workspace session switcher. This is intentionally not a
/// platform tab bar: it switches connected workspaces, not app sections.
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
    var showsDashboardButton = false
    var dashboardVisible = false
    var onToggleDashboard: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        WorkspaceTabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabId,
                            currentThemeOverride: themeOverrides[tab.id],
                            status: statuses[tab.id] ?? .connected,
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

            Spacer(minLength: 0)

            if showsDashboardButton, let onToggleDashboard {
                Button(action: onToggleDashboard) {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .font(MidnightMacDesign.FontToken.label)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                                .fill(
                                    dashboardVisible
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(dashboardVisible ? Color.accentColor : Color.primary)
                .help(dashboardVisible ? "Close dashboard" : "Open multi-host dashboard")
                .padding(.trailing, 8)
            }
        }
        .frame(height: LayoutConstants.workspaceTabStripHeight)
        .background(MidnightMacDesign.ColorToken.controlBackground)
    }
}

// MARK: - Single workspace tab

struct WorkspaceTabItemView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    var currentThemeOverride: String? = nil
    var status: TerminalConnectionStatus = .connected
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
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Disconnected"
        case .error:        return "Connection error"
        }
    }
}
