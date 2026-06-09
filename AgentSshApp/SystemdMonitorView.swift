import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct SystemdTimer: Identifiable, Hashable {
    let timer: String
    let next: String
    let left: String
    let last: String
    let passed: String
    let unit: String
    let activates: String

    var id: String { timer }
    var nextSortKey: String { systemdTimerTimestampSortKey(next) }
    var leftSortSeconds: Int64 { systemdTimerRelativeDurationSortKey(left) }
    var lastSortKey: String { systemdTimerTimestampSortKey(last) }
}

func systemdTimerTimestampSortKey(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "n/a" else { return "~" }
    let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.count >= 3,
       isSystemdWeekday(fields[0]),
       looksLikeSystemdDate(fields[1]),
       looksLikeSystemdTime(fields[2]) {
        return "\(fields[1]) \(fields[2]) \(fields.count >= 4 ? fields[3] : "")"
    }
    if fields.count >= 2,
       looksLikeSystemdDate(fields[0]),
       looksLikeSystemdTime(fields[1]) {
        return "\(fields[0]) \(fields[1]) \(fields.count >= 3 ? fields[2] : "")"
    }
    return trimmed
}

func systemdTimerRelativeDurationSortKey(_ value: String) -> Int64 {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty, trimmed != "n/a" else { return Int64.max }

    var total: Int64 = 0
    var pendingNumber: Int64?
    for rawPart in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
        let part = rawPart.trimmingCharacters(in: CharacterSet(charactersIn: ",.;()[]"))
        guard part != "left", part != "ago" else { continue }

        let digits = part.prefix { $0.isNumber }
        if !digits.isEmpty, let number = Int64(digits) {
            let unit = String(part.dropFirst(digits.count))
            if unit.isEmpty {
                pendingNumber = number
            } else {
                total += number * systemdTimerDurationMultiplier(unit)
                pendingNumber = nil
            }
            continue
        }

        if let number = pendingNumber {
            total += number * systemdTimerDurationMultiplier(part)
            pendingNumber = nil
        }
    }

    return total == 0 && trimmed != "0" ? Int64.max - 1 : total
}

func systemdTimerDurationMultiplier(_ rawUnit: String) -> Int64 {
    let unit = rawUnit.lowercased()
    if unit.hasPrefix("us") { return 0 }
    if unit.hasPrefix("ms") { return 0 }
    if unit == "s" || unit.hasPrefix("sec") { return 1 }
    if unit.hasPrefix("min") { return 60 }
    if unit == "m" { return 60 }
    if unit == "h" || unit.hasPrefix("hour") { return 3_600 }
    if unit == "d" || unit.hasPrefix("day") { return 86_400 }
    if unit == "w" || unit.hasPrefix("week") { return 604_800 }
    if unit.hasPrefix("month") { return 2_592_000 }
    if unit == "y" || unit.hasPrefix("year") { return 31_536_000 }
    return 1
}

func parseSystemdUnitLine(_ line: String, unitFileStates: [String: String] = [:]) -> SystemdUnit? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard fields.count >= 4, fields[0].hasSuffix(".service") else { return nil }

    return SystemdUnit(
        name: fields[0],
        load: fields[1],
        active: fields[2],
        sub: fields[3],
        unitFileState: unitFileStates[fields[0]] ?? "",
        description: fields.count >= 5 ? fields[4] : ""
    )
}

func parseSystemdUnitFileStates(_ output: String) -> [String: String] {
    var states: [String: String] = [:]
    for line in output.lines() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, fields[0].hasSuffix(".service") else { continue }
        states[fields[0]] = fields[1]
    }
    return states
}

func parseSystemdProperties(_ output: String) -> [String: String] {
    var properties: [String: String] = [:]
    for line in output.lines() {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        properties[String(parts[0])] = String(parts[1])
    }
    return properties
}

func formatSystemdBytes(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "-", trimmed != "[not set]", let bytes = Int64(trimmed) else {
        return "-"
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}

func formatSystemdNanoseconds(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "-", let nanoseconds = Double(trimmed), nanoseconds > 0 else {
        return "-"
    }
    let seconds = nanoseconds / 1_000_000_000
    if seconds < 1 {
        return String(format: "%.0f ms", seconds * 1_000)
    }
    if seconds < 60 {
        return String(format: "%.1f s", seconds)
    }
    let minutes = Int(seconds / 60)
    let remaining = Int(seconds.truncatingRemainder(dividingBy: 60))
    return "\(minutes)m \(remaining)s"
}

func parseSystemdTimerLine(_ line: String) -> SystemdTimer? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard let timerIndex = fields.firstIndex(where: { $0.hasSuffix(".timer") }) else { return nil }

    let timer = fields[timerIndex]
    let activates = fields.dropFirst(timerIndex + 1).joined(separator: " ")
    let schedule = Array(fields[..<timerIndex])
    let parsedSchedule = parseSystemdTimerSchedule(schedule)

    return SystemdTimer(
        timer: timer,
        next: parsedSchedule.next,
        left: parsedSchedule.left,
        last: parsedSchedule.last,
        passed: parsedSchedule.passed,
        unit: timer,
        activates: activates
    )
}

func parseSystemdTimerSchedule(_ fields: [String]) -> (next: String, left: String, last: String, passed: String) {
    guard !fields.isEmpty else {
        return ("", "", "", "")
    }
    if fields.count >= 4 && fields.prefix(4).allSatisfy({ $0 == "n/a" }) {
        return ("n/a", "n/a", "n/a", "n/a")
    }

    let nextEnd = systemdTimestampEnd(in: fields, from: 0)
    let next = fields[0..<nextEnd].joined(separator: " ")

    var cursor = nextEnd
    let left: String
    let lastStart: Int
    if next == "n/a", cursor < fields.count {
        left = fields[cursor]
        cursor += 1
        lastStart = cursor
    } else if let foundLastStart = systemdTimestampStart(in: fields, from: cursor) {
        lastStart = foundLastStart
        left = fields[cursor..<foundLastStart].joined(separator: " ")
    } else {
        return (next, fields[cursor...].joined(separator: " "), "", "")
    }

    guard lastStart < fields.count else {
        return (next, left, "", "")
    }
    let lastEnd = systemdTimestampEnd(in: fields, from: lastStart)
    let last = fields[lastStart..<lastEnd].joined(separator: " ")
    let passed = lastEnd < fields.count ? fields[lastEnd...].joined(separator: " ") : ""
    return (next, left, last, passed)
}

func systemdTimestampStart(in fields: [String], from start: Int) -> Int? {
    guard start < fields.count else { return nil }
    for index in start..<fields.count {
        if fields[index] == "n/a" {
            return index
        }
        if isSystemdWeekday(fields[index]),
           index + 2 < fields.count,
           looksLikeSystemdDate(fields[index + 1]),
           looksLikeSystemdTime(fields[index + 2]) {
            return index
        }
        if looksLikeSystemdDate(fields[index]),
           index + 1 < fields.count,
           looksLikeSystemdTime(fields[index + 1]) {
            return index
        }
    }
    return nil
}

func systemdTimestampEnd(in fields: [String], from start: Int) -> Int {
    guard start < fields.count else { return start }
    if fields[start] == "n/a" {
        return start + 1
    }
    if isSystemdWeekday(fields[start]),
       start + 2 < fields.count,
       looksLikeSystemdDate(fields[start + 1]),
       looksLikeSystemdTime(fields[start + 2]) {
        return min(start + 4, fields.count)
    }
    if looksLikeSystemdDate(fields[start]),
       start + 1 < fields.count,
       looksLikeSystemdTime(fields[start + 1]) {
        return min(start + 3, fields.count)
    }
    return start + 1
}

func isSystemdWeekday(_ value: String) -> Bool {
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(value)
}

func looksLikeSystemdDate(_ value: String) -> Bool {
    value.count == 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-"
}

func looksLikeSystemdTime(_ value: String) -> Bool {
    value.contains(":")
}

struct SystemdMonitorView: View {
    let connectionId: String?
    let profileId: String?
    let connectionLabel: String

    enum Mode: String, CaseIterable {
        case services = "Services"
        case failed = "Failed"
        case timers = "Timers"
        case journal = "System Journal"
    }

    enum UnitDetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case dependencies = "Dependencies"
        case unitFile = "Unit File"
        case properties = "Properties"

        var id: String { rawValue }

        var compactTitle: String {
            switch self {
            case .overview: return "Overview"
            case .logs: return "Logs"
            case .dependencies: return "Deps"
            case .unitFile: return "Unit"
            case .properties: return "Props"
            }
        }
    }

    enum ServiceScope: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Problems"
        case active = "Active"
        case enabled = "Enabled"
        case watched = "Watched"

        var id: String { rawValue }

        var emptyTitle: String {
            switch self {
            case .all: return "No services"
            case .problems: return "No problem services"
            case .active: return "No active services"
            case .enabled: return "No enabled services"
            case .watched: return "No watched services"
            }
        }
    }

    @State var mode: Mode = .services
    @State var units: [SystemdUnit] = []
    @State var timers: [SystemdTimer] = []
    @State var selectedUnit: SystemdUnit?
    @State var selectedTimer: SystemdTimer?
    @State var unitDetail: String = ""
    @State var dependencies: String = ""
    @State var unitFileText: String = ""
    @State var unitJournal: String = ""
    @State var journal: String = ""
    @State var search = ""
    @State var error: String?
    @State var loading = false
    @State var liveJournal = false
    @State var wrapJournalLines = true
    @State var journalPriority: JournalPriority = .all
    @State var journalTail: Int = 200
    @State var pendingAction: UnitAction?
    @State var unitDetailTab: UnitDetailTab = .overview
    @State var showsRawProperties = false
    @State var serviceScope: ServiceScope = .all

    static let journalTailOptions: [Int] = [100, 200, 500, 1000, 2000]

    enum JournalPriority: String, CaseIterable, Identifiable {
        case all = "All"
        case info = "Info+"
        case notice = "Notice+"
        case warning = "Warning+"
        case error = "Error+"
        case critical = "Critical+"
        var id: String { rawValue }
        var flagValue: String? {
            switch self {
            case .all: return nil
            case .info: return "info"
            case .notice: return "notice"
            case .warning: return "warning"
            case .error: return "err"
            case .critical: return "crit"
            }
        }
    }

    @State var unitSortOrder: [KeyPathComparator<SystemdUnit>] = [
        .init(\.statusSortRank),
        .init(\.name)
    ]
    @State var timerSortOrder: [KeyPathComparator<SystemdTimer>] = [
        .init(\.leftSortSeconds),
        .init(\.timer)
    ]
    @ObservedObject var connectionStore = ConnectionStoreManager.shared

    let logger = Logger(subsystem: "com.mc-ssh", category: "systemd-monitor")
    static let pollInterval: UInt64 = 5_000_000_000

    struct UnitAction: Identifiable {
        let id = UUID()
        let verb: String
        let unit: String
        var destructive: Bool {
            ["stop", "restart", "kill", "disable", "mask"].contains(verb)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(
                    icon: "network.slash",
                    title: "No connection",
                    message: "Open an SSH workspace to inspect systemd."
                )
            } else if let error {
                errorPane(error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue):\(liveJournal)") {
            await refresh()
            if mode == .journal && liveJournal {
                await journalLoop()
            }
        }
        .onChange(of: selectedUnit?.id) { _ in
            Task { await loadSelectedUnitDetail() }
        }
        .onChange(of: mode) { _ in
            ensureVisibleSelection()
        }
        .onChange(of: search) { _ in
            ensureVisibleSelection()
        }
        .onChange(of: serviceScope) { _ in
            ensureVisibleSelection()
        }
        .confirmationDialog(
            "Confirm systemd action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("\(action.verb) \(action.unit)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("Run systemctl \(action.verb) on \(connectionLabel)?")
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text("Services \(units.count)").tag(Mode.services)
                Text("Failed \(failedUnitCount)").tag(Mode.failed)
                Text("Timers \(timers.count)").tag(Mode.timers)
                Text(Mode.journal.rawValue).tag(Mode.journal)
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            if mode == .journal {
                Toggle("Live", isOn: $liveJournal)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var serviceScopeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Service scope")
            Picker("", selection: $serviceScope) {
                Text("All \(units.count)").tag(ServiceScope.all)
                Text("Problems \(problemUnitCount)").tag(ServiceScope.problems)
                Text("Active \(activeUnitCount)").tag(ServiceScope.active)
                Text("Enabled \(enabledUnitCount)").tag(ServiceScope.enabled)
                Text("Watched \(watchedUnitCount)").tag(ServiceScope.watched)
            }
            .pickerStyle(.segmented)
            .frame(width: 500)
            Spacer()
            Text("\(sortedFilteredUnits.count) shown")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .services, .failed:
            VStack(spacing: 0) {
                if mode == .services {
                    serviceScopeBar
                    Divider()
                }
                if sortedFilteredUnits.isEmpty {
                    unitEmptyState
                } else {
                    HSplitView {
                        unitList
                            .frame(minWidth: 560, idealWidth: 700)
                        unitDetailPane
                            .frame(minWidth: 420, idealWidth: 520)
                    }
                }
            }
        case .timers:
            if filteredTimers.isEmpty {
                placeholderView(
                    icon: search.isEmpty ? "timer" : "magnifyingglass",
                    title: search.isEmpty ? "No timers" : "No matching timers",
                    message: search.isEmpty
                        ? "systemctl returned no timer units."
                        : "No timer matches the current filter."
                )
            } else {
                timerList
            }
        case .journal:
            journalPane
        }
    }

    @ViewBuilder
    var unitEmptyState: some View {
        let hasFilter = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if loading {
            placeholderView(
                icon: "hourglass",
                title: "Loading services",
                message: "Fetching service units from \(connectionLabel)."
            )
        } else if hasFilter {
            placeholderView(
                icon: "magnifyingglass",
                title: "No matching services",
                message: "No service matches the current filter."
            )
        } else if mode == .services && serviceScope != .all {
            placeholderView(
                icon: "line.3.horizontal.decrease.circle",
                title: serviceScope.emptyTitle,
                message: "No service matches the selected service scope."
            )
        } else if mode == .failed {
            placeholderView(
                icon: "checkmark.circle",
                title: "No failed services",
                message: "systemctl reports no failed service units."
            )
        } else {
            placeholderView(
                icon: "list.bullet.rectangle",
                title: "No services",
                message: "systemctl returned no service units."
            )
        }
    }

    var filteredUnits: [SystemdUnit] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var base = mode == .failed ? units.filter(\.isFailed) : units
        if mode == .services {
            switch serviceScope {
            case .all:
                break
            case .problems:
                base = base.filter(\.hasOperationalProblem)
            case .active:
                base = base.filter(\.isActive)
            case .enabled:
                base = base.filter(\.isEnabled)
            case .watched:
                base = base.filter {
                    connectionStore.isMonitoringSystemdService($0.name, profileId: profileId)
                }
            }
        }
        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.active.lowercased().contains(needle)
                || $0.sub.lowercased().contains(needle)
                || $0.unitFileState.lowercased().contains(needle)
        }
    }

    var failedUnitCount: Int {
        units.filter(\.isFailed).count
    }

    var problemUnitCount: Int {
        units.filter(\.hasOperationalProblem).count
    }

    var activeUnitCount: Int {
        units.filter(\.isActive).count
    }

    var enabledUnitCount: Int {
        units.filter(\.isEnabled).count
    }

    var watchedUnitCount: Int {
        units.filter {
            connectionStore.isMonitoringSystemdService($0.name, profileId: profileId)
        }.count
    }

    var sortedFilteredUnits: [SystemdUnit] {
        filteredUnits.sorted(using: unitSortOrder)
    }

    var selectedUnitId: Binding<String?> {
        Binding(
            get: { selectedUnit?.id },
            set: { id in
                let unit = id.flatMap { selectedId in
                    sortedFilteredUnits.first { $0.id == selectedId }
                        ?? units.first { $0.id == selectedId }
                }
                selectUnit(unit)
            }
        )
    }

    func selectUnit(_ unit: SystemdUnit?, resetDetailTab: Bool = true) {
        let changed = selectedUnit?.id != unit?.id
        selectedUnit = unit
        if resetDetailTab, changed, let unit {
            unitDetailTab = preferredDetailTab(for: unit)
        }
    }

    func preferredDetailTab(for unit: SystemdUnit) -> UnitDetailTab {
        unit.hasOperationalProblem ? .logs : .overview
    }

    func ensureVisibleSelection() {
        guard mode == .services || mode == .failed else { return }
        let visibleUnits = sortedFilteredUnits
        guard !visibleUnits.isEmpty else {
            selectUnit(nil)
            return
        }
        if let selectedUnit, visibleUnits.contains(where: { $0.id == selectedUnit.id }) {
            return
        }
        selectUnit(visibleUnits.first)
    }

}
