import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension SystemMonitorView {
    // MARK: - Header

    var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                connectionStatusIcon
                Text(connectionLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if connectionId != nil {
                    ufwStatusBadge
                }
                Spacer()
                if stats != nil {
                    Text("Updated \(Date().formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let osInfo {
                Text(osInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(osInfo)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    var connectionStatusIcon: some View {
        let color = connectionStatusColor
        if profile != nil {
            Button {
                showingConfidence = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .help("Show connection details and credential confidence")
        } else {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(color)
        }
    }

    var connectionStatusColor: Color {
        guard let connectionStatus else { return MidnightMacDesign.StatusTone.unknown.color }
        return MidnightMacDesign.statusColor(connectionStatus)
    }

    var ufwStatusBadge: some View {
        let color = ufwProtectionColor(ufwSummary)
        let label = ufwSummary.badgeText == "on" ? "UFW" : "UFW \(ufwSummary.badgeText)"
        return Button {
            drillDown = .ufw
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(ufwSummary.helpText)
    }

    func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
        switch summary.level {
        case .protected:
            return MidnightMacDesign.StatusTone.ok.color
        case .inactive, .open:
            return MidnightMacDesign.StatusTone.warning.color
        case .unknown, .loading, .unavailable:
            return MidnightMacDesign.StatusTone.unknown.color
        }
    }

}
