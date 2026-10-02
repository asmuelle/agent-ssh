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
    /// Journal error/warning entry counts for the last hour, derived
    /// from journald priorities (err+ / warning) in one pass over the
    /// host journal. Zero until the counts fetch merges them in.
    var journalErrors: Int = 0
    var journalWarnings: Int = 0

    var id: String { name }
    var statusSortKey: String { "\(active) \(sub)" }

    var journalIssueCounts: JournalIssueCounts {
        JournalIssueCounts(errors: journalErrors, warnings: journalWarnings)
    }

    /// Errors dominate warnings in the column sort regardless of
    /// magnitude — one error outranks any pile of warnings.
    var journalIssueSortKey: Int {
        journalErrors * 100_000 + journalWarnings
    }

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
        return MidnightMacDesign.StatusTone.critical.color
    }
    if active == "active" {
        return MidnightMacDesign.StatusTone.ok.color
    }
    if active == "activating" || active == "deactivating" || active == "reloading"
        || sub == "reloading" || sub == "auto-restart" || sub == "start" || sub == "stop" {
        return MidnightMacDesign.StatusTone.pending.color
    }
    return MidnightMacDesign.StatusTone.inactive.color
}

func systemdStateColor(_ value: String, unit: SystemdUnit) -> Color {
    let lower = value.lowercased()
    if unit.isFailed || lower == "failed" {
        return MidnightMacDesign.StatusTone.critical.color
    }
    if unit.isTransitional || lower == "activating" || lower == "deactivating" || lower == "reloading" {
        return MidnightMacDesign.StatusTone.pending.color
    }
    if unit.isActive || lower == "running" || lower == "listening" {
        return MidnightMacDesign.StatusTone.ok.color
    }
    return MidnightMacDesign.StatusTone.inactive.color
}

func systemdLoadColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "loaded":
        return MidnightMacDesign.StatusTone.inactive.color
    case "not-found", "error", "bad-setting", "masked":
        return MidnightMacDesign.StatusTone.critical.color
    default:
        return MidnightMacDesign.StatusTone.warning.color
    }
}

func systemdFileStateColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "enabled", "enabled-runtime", "linked", "linked-runtime", "alias":
        return MidnightMacDesign.StatusTone.ok.color
    case "masked", "bad":
        return MidnightMacDesign.StatusTone.critical.color
    case "disabled":
        return MidnightMacDesign.StatusTone.inactive.color
    case "static", "generated", "transient", "indirect":
        return MidnightMacDesign.StatusTone.info.color
    default:
        return MidnightMacDesign.StatusTone.inactive.color
    }
}

