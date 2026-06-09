import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension SystemMonitorView {
    var currentDashboardHealthIssues: [DashboardHealthIssue] {
        dashboardHealthIssues(
            stats: stats,
            error: error,
            unsupportedOs: unsupportedOs,
            ufwSummary: ufwSummary,
            connectionStatus: connectionStatus
        )
    }

    func dashboardHealthIssues(
        stats: FfiSystemStats?,
        error: String?,
        unsupportedOs: String?,
        ufwSummary: UFWProtectionSummary,
        connectionStatus: TerminalConnectionStatus?
    ) -> [DashboardHealthIssue] {
        var issues: [DashboardHealthIssue] = []

        if let connectionStatus, connectionStatus != .connected {
            issues.append(DashboardHealthIssue(
                id: "status:\(connectionStatus.rawValue)",
                title: "\(connectionLabel): Connection",
                detail: connectionStatus.rawValue.capitalized,
                icon: connectionStatus == .error ? "exclamationmark.circle.fill" : "wifi.slash",
                severity: connectionStatus == .error ? .critical : .warning
            ))
        }

        if let unsupportedOs {
            issues.append(DashboardHealthIssue(
                id: "unsupported-os",
                title: "\(connectionLabel): Monitor",
                detail: "Unsupported OS \(unsupportedOs)",
                icon: "questionmark.circle",
                severity: .warning
            ))
        } else if let error, !error.isEmpty {
            issues.append(DashboardHealthIssue(
                id: "monitor-error",
                title: "\(connectionLabel): Monitor",
                detail: error,
                icon: "exclamationmark.triangle.fill",
                severity: .warning
            ))
        }

        switch ufwSummary.level {
        case .inactive:
            issues.append(DashboardHealthIssue(
                id: "ufw-inactive",
                title: "\(connectionLabel): UFW",
                detail: "Firewall inactive",
                icon: "shield.slash",
                severity: .warning
            ))
        case .open:
            let detail = ufwSummary.extraOpenRules.isEmpty
                ? "Public exposure detected"
                : "Open: \(ufwSummary.extraOpenRules.prefix(3).joined(separator: ", "))"
            issues.append(DashboardHealthIssue(
                id: "ufw-open",
                title: "\(connectionLabel): UFW",
                detail: detail,
                icon: "shield.lefthalf.filled",
                severity: .warning
            ))
        case .unknown:
            issues.append(DashboardHealthIssue(
                id: "ufw-unknown",
                title: "\(connectionLabel): UFW",
                detail: ufwSummary.error ?? ufwSummary.statusText,
                icon: "shield",
                severity: .warning
            ))
        case .loading, .unavailable, .protected:
            break
        }

        if let stats {
            let cpuFraction = stats.cpuPercent / 100
            if cpuFraction >= 0.85 {
                issues.append(DashboardHealthIssue(
                    id: "cpu",
                    title: "\(connectionLabel): CPU",
                    detail: String(format: "%.1f%%", stats.cpuPercent),
                    icon: "cpu",
                    severity: cpuFraction >= 0.95 ? .critical : .warning
                ))
            }

            let memoryFraction = stats.memoryTotal > 0
                ? Double(stats.memoryUsed) / Double(stats.memoryTotal)
                : 0
            if memoryFraction >= 0.85 {
                issues.append(DashboardHealthIssue(
                    id: "memory",
                    title: "\(connectionLabel): Memory",
                    detail: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                    icon: "memorychip",
                    severity: memoryFraction >= 0.95 ? .critical : .warning
                ))
            }

            let diskIssues = stats.disks
                .compactMap { disk -> (FfiDiskMount, Double)? in
                    guard disk.total > 0 else { return nil }
                    let fraction = Double(disk.used) / Double(disk.total)
                    return fraction >= 0.85 ? (disk, fraction) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(2)

            for (disk, fraction) in diskIssues {
                issues.append(DashboardHealthIssue(
                    id: "disk:\(disk.mount)",
                    title: "\(connectionLabel): Disk",
                    detail: "\(disk.mount) \(Int(fraction * 100))%",
                    icon: "internaldrive",
                    severity: fraction >= 0.95 ? .critical : .warning
                ))
            }
        }

        return issues.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func publishDashboardHealthSnapshot() {
        guard dashboardMode, let onDashboardHealthChange else { return }
        onDashboardHealthChange(DashboardHealthSnapshot(
            id: dashboardIdentity ?? connectionId ?? connectionLabel,
            hostName: connectionLabel,
            issues: currentDashboardHealthIssues
        ))
    }

}
