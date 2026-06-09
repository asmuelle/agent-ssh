import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

enum ServiceModalKind: String, Identifiable {
    case systemd
    case docker
    case postgres

    var id: String { rawValue }
}

enum MonitorDrillDown: Identifiable {
    case cpu
    case memory
    case disk(FfiDiskMount)
    case systemdService(String)
    case ufw

    var id: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memory"
        case .disk(let disk):
            return "disk:\(disk.mount):\(disk.source)"
        case .systemdService(let unit):
            return "systemd:\(unit)"
        case .ufw:
            return "ufw"
        }
    }

    var title: String {
        switch self {
        case .cpu:
            return "CPU Analysis"
        case .memory:
            return "Memory Analysis"
        case .disk(let disk):
            return "Recent Large Files: \(disk.mount)"
        case .systemdService(let unit):
            return unit
        case .ufw:
            return "UFW Details"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu:
            return "CPU-heavy processes, thread hot spots, and current load."
        case .memory:
            return "Memory-heavy processes, pressure signals, and allocation summary."
        case .disk(let disk):
            return "\(disk.source) - files changed in the last 14 days, sorted by size."
        case .systemdService:
            return "Unit identity, environment, service files, recent logs, and actions."
        case .ufw:
            return "Firewall posture, public exposure, recent blocks, and raw command output."
        }
    }

    var icon: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .systemdService:
            return "switch.2"
        case .ufw:
            return "shield"
        }
    }
}


struct ConnectionConfidenceSheet: View {
    let profile: ConnectionProfile
    let status: TerminalConnectionStatus?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection Details")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                ConnectionConfidenceView(profile: profile, status: status)
                    .padding(16)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
    }
}

// MARK: - Service modal sheet

struct ServiceModalSheet: View {
    let kind: ServiceModalKind
    let connectionId: String?
    let profileId: String?
    let connectionLabel: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 660, idealHeight: 760)
    }

    private var title: String {
        switch kind {
        case .systemd: return "systemd"
        case .docker: return "Docker"
        case .postgres: return "PostgreSQL"
        }
    }

    private var icon: String {
        switch kind {
        case .systemd: return "switch.2"
        case .docker: return "shippingbox"
        case .postgres: return "cylinder.split.1x2"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .systemd:
            SystemdMonitorView(
                connectionId: connectionId,
                profileId: profileId,
                connectionLabel: connectionLabel
            )
        case .docker:
            DockerMonitorView(
                connectionId: connectionId,
                connectionLabel: connectionLabel
            )
        case .postgres:
            PostgresMonitorView(
                connectionId: connectionId,
                connectionLabel: connectionLabel
            )
        }
    }
}

// MARK: - Premium Status Badge
struct StatusBadge: View {
    let state: String
    let substate: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text("\(state) (\(substate))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state.lowercased() {
        case "active", "running":
            return .green
        case "failed", "error":
            return .red
        case "activating", "reloading":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Premium Code Block View
struct CodeBlockView: View {
    let label: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            
            Text(code.isEmpty ? "No details." : code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }
}
