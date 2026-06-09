import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension SystemdMonitorView {
    // MARK: - Unit & timer lists, detail pane

    var unitList: some View {
        Table(sortedFilteredUnits, selection: selectedUnitId, sortOrder: $unitSortOrder) {
            TableColumn("Watch") { unit in
                let isWatching = connectionStore.isMonitoringSystemdService(unit.name, profileId: profileId)
                Button {
                    connectionStore.setMonitoringSystemdService(!isWatching, serviceName: unit.name, profileId: profileId)
                } label: {
                    Image(systemName: isWatching ? "eye.fill" : "eye")
                        .foregroundStyle(isWatching ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(connectionId == nil)
                .help(isWatching ? "Remove \(unit.name) from the monitor pane" : "Show \(unit.name) in the monitor pane")
            }
            .width(min: 38, ideal: 42, max: 48)

            TableColumn("Service", value: \.name) { unit in
                HStack(spacing: 6) {
                    Circle()
                        .fill(systemdIndicatorColor(active: unit.active, sub: unit.sub))
                        .frame(width: 8, height: 8)
                    Text(unit.name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            .width(min: 210, ideal: 320, max: 440)

            TableColumn("Status", value: \.statusSortKey) { unit in
                HStack(spacing: 4) {
                    statusBadge(
                        unit.active,
                        color: systemdStateColor(unit.active, unit: unit),
                        emphasized: unit.hasOperationalProblem
                    )
                    if !unit.sub.isEmpty && unit.sub != unit.active {
                        statusBadge(
                            unit.sub,
                            color: systemdStateColor(unit.sub, unit: unit),
                            emphasized: unit.hasOperationalProblem
                        )
                    }
                }
            }
            .width(min: 120, ideal: 150, max: 210)

            TableColumn("Enabled", value: \.unitFileState) { unit in
                statusBadge(
                    unit.unitFileState.isEmpty ? "-" : unit.unitFileState,
                    color: systemdFileStateColor(unit.unitFileState),
                    emphasized: unit.unitFileState.lowercased() == "masked"
                )
            }
            .width(min: 80, ideal: 94, max: 124)

            TableColumn("Description", value: \.description) { unit in
                Text(unit.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if let unit = selected.first.flatMap({ id in units.first { $0.id == id } }) {
                unitActions(unit)
            }
        }
    }

    var timerList: some View {
        Table(sortedFilteredTimers, selection: selectedTimerId, sortOrder: $timerSortOrder) {
            TableColumn("Timer", value: \.timer) { timer in
                monoCell(timer.timer)
            }
            .width(min: 190, ideal: 260)

            TableColumn("Next", value: \.nextSortKey) { timer in
                monoCell(timer.next, color: .secondary)
            }
            .width(min: 190, ideal: 260)

            TableColumn("Left", value: \.leftSortSeconds) { timer in
                monoCell(timer.left)
            }
            .width(min: 90, ideal: 125, max: 170)

            TableColumn("Activates", value: \.activates) { timer in
                monoCell(timer.activates)
            }
            .width(min: 190, ideal: 280)
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if let timer = selected.first.flatMap({ id in timers.first { $0.id == id } }) {
                Button("Show Linked Service") {
                    mode = .services
                    if let unit = units.first(where: { $0.name == timer.activates }) {
                        selectUnit(unit)
                    }
                }
                Button("Copy Timer") { RemoteCommandRunner.copy(timer.timer) }
                Button("Copy Activates") { RemoteCommandRunner.copy(timer.activates) }
            }
        }
    }

    var selectedTimerId: Binding<String?> {
        Binding(
            get: { selectedTimer?.id },
            set: { id in
                selectedTimer = id.flatMap { selectedId in
                    timers.first { $0.id == selectedId }
                }
            }
        )
    }

    var filteredTimers: [SystemdTimer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return timers }
        return timers.filter {
            $0.timer.lowercased().contains(needle)
                || $0.next.lowercased().contains(needle)
                || $0.left.lowercased().contains(needle)
                || $0.activates.lowercased().contains(needle)
        }
    }

    var sortedFilteredTimers: [SystemdTimer] {
        filteredTimers.sorted(using: timerSortOrder)
    }

    var unitDetailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedUnit {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedUnit.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(selectedUnit.description.isEmpty ? "No description" : selectedUnit.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    unitInlineActions(selectedUnit)
                    Menu {
                        unitActions(selectedUnit)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                Divider()
                Picker("", selection: $unitDetailTab) {
                    ForEach(UnitDetailTab.allCases) { tab in
                        Text(tab.compactTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .help(unitDetailTab.rawValue)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
                unitDetailContent(selectedUnit)
            } else {
                placeholderView(
                    icon: "list.bullet.rectangle",
                    title: "Select a unit",
                    message: "Choose a service to inspect properties, dependencies, and recent journal entries."
                )
            }
        }
    }

    @ViewBuilder
    func unitDetailContent(_ unit: SystemdUnit) -> some View {
        switch unitDetailTab {
        case .overview:
            unitOverview(unit)
        case .logs:
            if filteredUnitJournalLines.isEmpty {
                placeholderView(
                    icon: "doc.text",
                    title: "No unit logs",
                    message: "journalctl returned no recent entries for this unit."
                )
            } else {
                journalEntriesList(lines: filteredUnitJournalLines, autoScroll: false)
            }
        case .dependencies:
            detailScrollBlock(value: dependencies.isEmpty ? "-" : dependencies)
        case .unitFile:
            detailScrollBlock(value: unitFileText.isEmpty ? "-" : unitFileText, mode: .systemdUnit)
        case .properties:
            unitPropertiesView(unit)
        }
    }

    @ViewBuilder
    func unitInlineActions(_ unit: SystemdUnit) -> some View {
        HStack(spacing: 4) {
            Button {
                pendingAction = UnitAction(verb: "start", unit: unit.name)
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(unit.isActive || unit.isTransitional || !unit.isLoaded)
            .help("Start \(unit.name)")

            Button {
                pendingAction = UnitAction(verb: "stop", unit: unit.name)
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!unit.isActive && !unit.isTransitional)
            .help("Stop \(unit.name)")

            Button {
                pendingAction = UnitAction(verb: "restart", unit: unit.name)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!unit.isLoaded)
            .help("Restart \(unit.name)")

            Button {
                unitDetailTab = .logs
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help("Show recent logs")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    func unitOverview(_ unit: SystemdUnit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: unitSummaryColumns, alignment: .leading, spacing: 8) {
                    unitSummaryTile("Load", value: unit.load, color: systemdLoadColor(unit.load))
                    unitSummaryTile("Active", value: unit.active, color: systemdStateColor(unit.active, unit: unit))
                    unitSummaryTile("Sub", value: unit.sub, color: systemdStateColor(unit.sub, unit: unit))
                    unitSummaryTile("Enabled", value: unitEnabledState(unit), color: systemdFileStateColor(unitEnabledState(unit)))
                    unitSummaryTile("Main PID", value: unitProperty("MainPID"))
                    unitSummaryTile("Restarts", value: unitProperty("NRestarts"))
                    unitSummaryTile("Memory", value: formattedUnitMemory)
                    unitSummaryTile("CPU", value: formattedUnitCPU)
                }

                if unitJournalIssueCounts.hasIssues {
                    HStack(spacing: 8) {
                        Text("Recent journal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        JournalIssueBadges(counts: unitJournalIssueCounts)
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Unit file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(unitProperty("FragmentPath"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Raw properties", isExpanded: $showsRawProperties) {
                    detailScrollBlock(value: unitDetail.isEmpty ? "-" : unitDetail)
                        .frame(minHeight: 180)
                }
                .font(.caption.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    func unitPropertiesView(_ unit: SystemdUnit) -> some View {
        let rows = unitPropertyRows(for: unit)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        unitPropertyRow(label: row.label, value: row.value, highlighted: index.isMultiple(of: 2))
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                DisclosureGroup("Raw systemctl show output", isExpanded: $showsRawProperties) {
                    detailScrollBlock(value: unitDetail.isEmpty ? "-" : unitDetail)
                        .frame(minHeight: 180)
                }
                .font(.caption.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    func unitPropertyRows(for unit: SystemdUnit) -> [(label: String, value: String)] {
        [
            ("Unit", unitProperty("Id")),
            ("Description", unit.description.isEmpty ? unitProperty("Description") : unit.description),
            ("Load state", unitProperty("LoadState", fallback: unit.load)),
            ("Active state", unitProperty("ActiveState", fallback: unit.active)),
            ("Sub state", unitProperty("SubState", fallback: unit.sub)),
            ("Unit file state", unitEnabledState(unit)),
            ("Main PID", unitProperty("MainPID")),
            ("Restart count", unitProperty("NRestarts")),
            ("Memory", formattedUnitMemory),
            ("CPU", formattedUnitCPU),
            ("Started at", unitProperty("ActiveEnterTimestamp")),
            ("Fragment path", unitProperty("FragmentPath"))
        ]
    }

    func unitPropertyRow(label: String, value: String, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(normalizedUnitValue(value))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted ? Color(NSColor.textBackgroundColor).opacity(0.55) : Color.clear)
    }

    var unitSummaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 8, alignment: .top)]
    }

    func unitSummaryTile(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(normalizedUnitValue(value))
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    func unitProperty(_ key: String) -> String {
        unitProperties[key] ?? "-"
    }

    func unitProperty(_ key: String, fallback: String) -> String {
        let value = unitProperties[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    func unitEnabledState(_ unit: SystemdUnit) -> String {
        let fromList = unit.unitFileState.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromList.isEmpty {
            return fromList
        }
        return unitProperty("UnitFileState")
    }

    var unitProperties: [String: String] {
        parseSystemdProperties(unitDetail)
    }

    var formattedUnitMemory: String {
        formatSystemdBytes(unitProperty("MemoryCurrent"))
    }

    var formattedUnitCPU: String {
        formatSystemdNanoseconds(unitProperty("CPUUsageNSec"))
    }

    func normalizedUnitValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[not set]" || trimmed == "n/a" {
            return "-"
        }
        return trimmed
    }

    func detailScrollBlock(value: String, mode: RawOutputHighlightMode = .generic) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value, mode: mode)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

}
