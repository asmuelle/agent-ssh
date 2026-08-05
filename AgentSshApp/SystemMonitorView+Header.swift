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
                // Dashboard mode: the refresh timestamp lives once in
                // the dashboard toolbar instead of on every card.
                if !dashboardMode, stats != nil {
                    Text("Updated \(Date().formatted(.dateTime.hour().minute().second()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if dashboardMode {
                // Always render all three meta lines (with blank
                // placeholders while values resolve) so every card's
                // header has the same height and the CPU/Memory/Disk
                // rows line up across the grid.
                dashboardMetaLine(
                    endpointLine,
                    font: MidnightMacDesign.FontToken.metadataMono,
                    tint: .secondary
                )
                dashboardMetaLine(osInfo, font: .caption, tint: .secondary)
                dashboardMetaLine(
                    resolvedIPLine.map { "IP \($0)" },
                    font: MidnightMacDesign.FontToken.metadataMono,
                    tint: .tertiary,
                    help: resolvedIPAddresses.joined(separator: ", ")
                )
            } else if let osInfo {
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

    /// One fixed-height metadata line in the dashboard card header.
    /// Renders a non-empty placeholder when the value hasn't resolved
    /// yet so the header never changes height.
    func dashboardMetaLine(
        _ text: String?,
        font: Font,
        tint: HierarchicalShapeStyle,
        help: String? = nil
    ) -> some View {
        Text(text ?? " ")
            .font(font)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help ?? text ?? "")
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
