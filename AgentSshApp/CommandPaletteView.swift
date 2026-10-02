import AppKit
import SwiftUI
import AgentSshMacOS

struct CommandPaletteView: View {
    let connections: [ConnectionProfile]
    let selectedConnection: ConnectionProfile?
    let activeTab: TerminalTab?
    let connectedHostCount: Int
    let onConnect: (ConnectionProfile) -> Void
    let onReconnectActive: () -> Void
    let onCloseActive: () -> Void
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onExportDiagnostics: () -> Void
    let onOpenFleetTool: (FleetTool) -> Void
    let onDiagnoseActive: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var actions: [PaletteAction] {
        var result: [PaletteAction] = []

        if let selectedConnection {
            result.append(PaletteAction(
                title: "Connect to \(selectedConnection.name)",
                subtitle: "\(selectedConnection.username)@\(selectedConnection.host):\(selectedConnection.port)",
                icon: "bolt.horizontal.fill",
                isEnabled: true
            ) {
                onConnect(selectedConnection)
            })
        }

        if let activeTab {
            result.append(PaletteAction(
                title: "Reconnect",
                subtitle: activeTab.profile.name,
                icon: "arrow.clockwise",
                isEnabled: true,
                run: onReconnectActive
            ))
            result.append(PaletteAction(
                title: "Disconnect",
                subtitle: activeTab.profile.name,
                icon: "xmark.circle",
                isEnabled: true,
                run: onCloseActive
            ))
            result.append(PaletteAction(
                title: "Diagnose Host",
                subtitle: activeTab.profile.name,
                icon: "stethoscope",
                isEnabled: activeTab.effectiveKind.supportsTerminal,
                run: onDiagnoseActive
            ))
        }

        let hasConnectedShell = connectedHostCount > 0
        result.append(PaletteAction(
            title: "Run on Several Hosts",
            subtitle: "Roll a command out with canaries and verification",
            icon: "list.bullet.rectangle",
            isEnabled: hasConnectedShell
        ) { onOpenFleetTool(.runbook) })
        result.append(PaletteAction(
            title: "Audit Stacks",
            subtitle: "Read-only check of Docker, web servers, firewalls and databases",
            icon: "square.stack.3d.up",
            isEnabled: hasConnectedShell
        ) { onOpenFleetTool(.stackAudit) })
        result.append(PaletteAction(title: "Toggle Sidebar", subtitle: "Show or hide hosts", icon: "sidebar.left", run: onToggleSidebar))
        result.append(PaletteAction(title: "Toggle Inspector", subtitle: "System monitor and host health", icon: "sidebar.right", run: onToggleInspector))
        result.append(PaletteAction(title: "Export Diagnostics", subtitle: "Create a redacted support bundle", icon: "square.and.arrow.up", run: onExportDiagnostics))

        for profile in connections.sorted(by: profileSort) {
            result.append(PaletteAction(
                title: "Connect: \(profile.name)",
                subtitle: "\(profile.username)@\(profile.host):\(profile.port)",
                icon: profile.kind.supportsTerminal ? "terminal" : "folder",
                isEnabled: true
            ) {
                onConnect(profile)
            })
        }

        return result
    }

    private var filteredActions: [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }
        let needle = trimmed.lowercased()
        return actions.filter {
            $0.title.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Run a command or connect to a host", text: $query)
                    .textFieldStyle(.plain)
                    .font(MidnightMacDesign.FontToken.title)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredActions) { action in
                        Button {
                            guard action.isEnabled else { return }
                            dismiss()
                            action.run()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.icon)
                                    .foregroundStyle(action.isEnabled ? Color.accentColor : Color.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(MidnightMacDesign.FontToken.headline)
                                        .foregroundStyle(action.isEnabled ? .primary : .secondary)
                                    Text(action.subtitle)
                                        .font(MidnightMacDesign.FontToken.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!action.isEnabled)
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .background(MidnightMacDesign.ColorToken.windowBackground)
    }

    private func profileSort(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        if lhs.favorite != rhs.favorite {
            return lhs.favorite && !rhs.favorite
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    var isEnabled = true
    let run: () -> Void
}
