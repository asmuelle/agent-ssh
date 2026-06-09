import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension SystemMonitorView {
    // MARK: - Header

    var header: some View {
        VStack(alignment: .leading, spacing: dashboardMode ? 5 : 2) {
            HStack(spacing: 6) {
                connectionStatusIcon
                Text(connectionLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if connectionId != nil {
                    ufwStatusBadge
                }
                if dashboardMode {
                    dashboardIssueBadges
                }
                Spacer()
                if stats != nil {
                    Text("Updated \(Date().formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if dashboardMode, let endpointLine {
                Text(endpointLine)
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(endpointLine)
            }
            if let osInfo {
                Text(osInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(osInfo)
            }
            if dashboardMode, let resolvedIPLine {
                Text("IP \(resolvedIPLine)")
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(resolvedIPAddresses.joined(separator: ", "))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var endpointLine: String? {
        guard let profile else { return nil }
        return "\(profile.username)@\(profile.host):\(profile.port)"
    }

    var resolvedIPLine: String? {
        guard !resolvedIPAddresses.isEmpty else { return nil }
        let visible = resolvedIPAddresses.prefix(2).joined(separator: ", ")
        let hiddenCount = resolvedIPAddresses.count - 2
        return hiddenCount > 0 ? "\(visible) +\(hiddenCount)" : visible
    }

    @ViewBuilder
    var dashboardIssueBadges: some View {
        let issues = currentDashboardHealthIssues
        if !issues.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(issues.prefix(2))) { issue in
                    dashboardIssueBadge(issue)
                }
                if issues.count > 2 {
                    Text("+\(issues.count - 2)")
                        .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
        }
    }

    func dashboardIssueBadge(_ issue: DashboardHealthIssue) -> some View {
        HStack(spacing: 3) {
            Image(systemName: issue.icon)
                .font(MidnightMacDesign.FontToken.caption)
            Text(issue.title.replacingOccurrences(of: "\(connectionLabel): ", with: ""))
                .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(issue.severity.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(issue.severity.color.opacity(0.12), in: Capsule())
        .help("\(issue.title): \(issue.detail)")
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
        switch connectionStatus {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        case .error:        return .red
        case nil:           return .secondary
        }
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
            return .green
        case .inactive, .open:
            return .orange
        case .unknown:
            return .yellow
        case .loading, .unavailable:
            return .secondary
        }
    }

}
