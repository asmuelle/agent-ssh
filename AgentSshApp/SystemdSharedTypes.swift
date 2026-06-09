import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct SystemdUnit: Identifiable, Hashable {
    let name: String
    let load: String
    let active: String
    let sub: String
    let unitFileState: String
    let description: String

    var id: String { name }
    var statusSortKey: String { "\(active) \(sub)" }

    var statusSortRank: Int {
        if isFailed { return 0 }
        if isTransitional { return 1 }
        if !isLoaded { return 2 }
        if isActive { return 3 }
        return 4
    }

    var hasOperationalProblem: Bool {
        isFailed || isTransitional || !isLoaded
    }

    var isFailed: Bool {
        active.lowercased() == "failed" || sub.lowercased() == "failed"
    }

    var isActive: Bool {
        active.lowercased() == "active"
    }

    var isTransitional: Bool {
        let active = active.lowercased()
        let sub = sub.lowercased()
        return active == "activating"
            || active == "deactivating"
            || active == "reloading"
            || sub == "reloading"
            || sub == "auto-restart"
            || sub == "start"
            || sub == "stop"
    }

    var isLoaded: Bool {
        load.lowercased() == "loaded"
    }

    var isEnabled: Bool {
        ["enabled", "enabled-runtime", "linked", "linked-runtime", "alias"].contains(unitFileState.lowercased())
    }

    var isDisabled: Bool {
        unitFileState.lowercased() == "disabled"
    }
}

struct MonitoredSystemdServiceStatus: Identifiable, Equatable {
    let name: String
    let active: String
    let sub: String
    let uptimeSeconds: UInt64?
    let journalIssueCounts: JournalIssueCounts

    var id: String { name }

    var isRunning: Bool {
        active.lowercased() == "active"
    }

    var indicatorColor: Color {
        systemdIndicatorColor(active: active, sub: sub)
    }
}

struct PostgresDashboardPreviewItem: Identifiable {
    let id: String
    let label: String
    let value: String
    let color: Color
}

func systemdIndicatorColor(active: String, sub: String) -> Color {
    let active = active.lowercased()
    let sub = sub.lowercased()
    if active == "failed" || sub == "failed" {
        return .red
    }
    if active == "active" {
        return .green
    }
    if active == "activating" || active == "deactivating" || active == "reloading"
        || sub == "reloading" || sub == "auto-restart" || sub == "start" || sub == "stop" {
        return .orange
    }
    return .secondary
}

func systemdStateColor(_ value: String, unit: SystemdUnit) -> Color {
    let lower = value.lowercased()
    if unit.isFailed || lower == "failed" {
        return .red
    }
    if unit.isTransitional || lower == "activating" || lower == "deactivating" || lower == "reloading" {
        return .orange
    }
    if unit.isActive || lower == "running" || lower == "listening" {
        return .green
    }
    return .secondary
}

func systemdLoadColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "loaded":
        return .secondary
    case "not-found", "error", "bad-setting", "masked":
        return .red
    default:
        return .orange
    }
}

func systemdFileStateColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "enabled", "enabled-runtime", "linked", "linked-runtime", "alias":
        return .green
    case "masked", "bad":
        return .red
    case "disabled":
        return .secondary
    case "static", "generated", "transient", "indirect":
        return .blue
    default:
        return .secondary
    }
}

