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
            connectionStatus: connectionStatus,
            hygiene: hygiene
        )
    }

    func dashboardHealthIssues(
        stats: FfiSystemStats?,
        error: String?,
        unsupportedOs: String?,
        ufwSummary: UFWProtectionSummary,
        connectionStatus: TerminalConnectionStatus?,
        hygiene: HygieneSnapshot? = nil
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

        if let hygiene {
            if !hygiene.failedUnits.isEmpty {
                let count = hygiene.failedUnits.count
                issues.append(DashboardHealthIssue(
                    id: "services-failed",
                    title: "\(connectionLabel): Services",
                    detail: "\(count) failed · \(hygiene.failedUnits.prefix(3).joined(separator: ", "))",
                    icon: "gearshape.2",
                    severity: .warning
                ))
            }
            if !hygiene.dockerProblems.isEmpty {
                let count = hygiene.dockerProblems.count
                issues.append(DashboardHealthIssue(
                    id: "docker",
                    title: "\(connectionLabel): Docker",
                    detail: "\(count) container\(count == 1 ? "" : "s") · \(hygiene.dockerProblems.prefix(2).joined(separator: ", "))",
                    icon: "shippingbox",
                    severity: .warning
                ))
            }
            if hygiene.journalErrors >= Self.journalErrorThreshold {
                issues.append(DashboardHealthIssue(
                    id: "journal",
                    title: "\(connectionLabel): Journal",
                    detail: "\(hygiene.journalErrors) errors / 15 min",
                    icon: "exclamationmark.bubble",
                    severity: .warning
                ))
            }
        }

        return issues.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            let lhsFamily = Self.issueFamilyPriority($0.id)
            let rhsFamily = Self.issueFamilyPriority($1.id)
            if lhsFamily != rhsFamily {
                return lhsFamily < rhsFamily
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Which family wins a chip slot when severities tie: connection
    /// problems before down services, before containers, before
    /// firewall exposure, before resource pressure, before log noise.
    static func issueFamilyPriority(_ id: String) -> Int {
        if id.hasPrefix("status:") { return 0 }
        if id == "services-failed" { return 1 }
        if id == "docker" { return 2 }
        if id.hasPrefix("ufw") { return 3 }
        if id == "cpu" || id == "memory" || id.hasPrefix("disk:") { return 4 }
        if id == "journal" { return 5 }
        return 6
    }

    func publishDashboardHealthSnapshot() {
        guard dashboardMode, let onDashboardHealthChange else { return }
        onDashboardHealthChange(DashboardHealthSnapshot(
            id: dashboardIdentity ?? connectionId ?? connectionLabel,
            hostName: connectionLabel,
            issues: currentDashboardHealthIssues,
            metrics: stats.map(dashboardHostMetrics)
        ))
    }

    func dashboardHostMetrics(_ stats: FfiSystemStats) -> DashboardHostMetrics {
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0
        let worstDisk = stats.disks
            .compactMap { disk -> (String, Double)? in
                guard disk.total > 0 else { return nil }
                return (disk.mount, Double(disk.used) / Double(disk.total))
            }
            .max { $0.1 < $1.1 }
        return DashboardHostMetrics(
            cpuPercent: stats.cpuPercent,
            memoryPercent: memoryPercent,
            memoryUsed: stats.memoryUsed,
            memoryTotal: stats.memoryTotal,
            swapUsed: stats.swapUsed,
            swapTotal: stats.swapTotal,
            worstDiskFraction: worstDisk?.1,
            worstDiskMount: worstDisk?.0,
            loadAverage1m: stats.loadAverage1m,
            uptimeSeconds: stats.uptimeSeconds,
            disks: stats.disks
        )
    }

}
