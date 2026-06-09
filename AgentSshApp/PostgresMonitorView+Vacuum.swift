import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension PostgresMonitorView {
    // MARK: - Vacuum & analyze

    var vacuumPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Autovacuum Health")
                        .font(.headline)
                    if let vacuumRefreshedAt {
                        Text("Updated \(DateFormatter.localizedString(from: vacuumRefreshedAt, dateStyle: .none, timeStyle: .medium))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        RemoteCommandRunner.copy(vacuumExportText(filteredVacuumRows.sorted(using: vacuumSortOrder)))
                    } label: {
                        Label("Copy Table", systemImage: "doc.on.doc")
                    }
                    .disabled(filteredVacuumRows.isEmpty)
                }

                if !vacuumWarnings.isEmpty {
                    vacuumWarningBanner
                }

                LazyVGrid(columns: vacuumSummaryColumns, alignment: .leading, spacing: 8) {
                    vacuumSummaryTile(
                        title: "Need vacuum",
                        value: "\(vacuumNeedsVacuumCount)",
                        subtitle: "\(formatCount(vacuumTotalDeadTuples)) dead tuples",
                        systemImage: "arrow.triangle.2.circlepath",
                        color: vacuumNeedsVacuumCount > 0 ? .orange : .green
                    )
                    vacuumSummaryTile(
                        title: "Never analyzed",
                        value: "\(vacuumNeverAnalyzedCount)",
                        subtitle: "planner stats missing",
                        systemImage: "chart.bar",
                        color: vacuumNeverAnalyzedCount > 0 ? .red : .green
                    )
                    vacuumSummaryTile(
                        title: "Worst dead %",
                        value: vacuumWorstDeadPercentText,
                        subtitle: vacuumWorstDeadPercentTable,
                        systemImage: "percent",
                        color: vacuumWorstDeadPercentColor
                    )
                    vacuumSummaryTile(
                        title: "Oldest autovacuum",
                        value: vacuumOldestAutovacuumText,
                        subtitle: vacuumOldestAutovacuumTable,
                        systemImage: "clock",
                        color: .blue
                    )
                    vacuumSummaryTile(
                        title: "Current schema",
                        value: vacuumCurrentSchema,
                        subtitle: "\(vacuumRowsInCurrentSchema) tables loaded",
                        systemImage: "square.stack.3d.up",
                        color: .teal
                    )
                }

                HStack(spacing: 8) {
                    Picker("", selection: $vacuumScope) {
                        ForEach(PGVacuumScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 590)

                    Spacer(minLength: 12)

                    Text("\(filteredVacuumRows.count) of \(vacuumRows.count) tables")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    vacuumSelectionActions
                        .controlSize(.small)
                }
            }
            .padding(10)

            Divider()

            if filteredVacuumRows.isEmpty {
                placeholderView(icon: "tablecells", title: "No table statistics", message: "No PostgreSQL table maintenance rows match the current filters.")
            } else {
                vacuumTable
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var vacuumWarningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(vacuumWarnings.joined(separator: "\n"))
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                RemoteCommandRunner.copy(vacuumWarnings.joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy warning")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        )
    }

    var vacuumSummaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8, alignment: .top)]
    }

    func vacuumSummaryTile(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .frame(width: 15)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value.isEmpty ? "-" : value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle.isEmpty ? "-" : subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    var vacuumSelectionActions: some View {
        if let row = selectedVacuumRow {
            Button {
                queueVacuumAction("VACUUM", row: row)
            } label: {
                Label("Vacuum", systemImage: "arrow.clockwise")
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)

            Button {
                queueVacuumAction("VACUUM ANALYZE", row: row)
            } label: {
                Label("Vacuum Analyze", systemImage: "chart.bar.doc.horizontal")
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)

            Button {
                queueVacuumAction("ANALYZE", row: row)
            } label: {
                Label("Analyze", systemImage: "chart.bar")
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)

            Menu {
                Button("Copy VACUUM ANALYZE SQL") {
                    RemoteCommandRunner.copy(vacuumSQL("VACUUM ANALYZE", row: row))
                }
                Divider()
                Button("VACUUM FULL", role: .destructive) {
                    queueVacuumAction("VACUUM FULL", row: row, destructive: true)
                }
                .disabled(row.isSystemTable || isMaintenanceOperationRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More maintenance actions")
        } else {
            Button {} label: {
                Label("Vacuum", systemImage: "arrow.clockwise")
            }
            .disabled(true)
            Button {} label: {
                Label("Vacuum Analyze", systemImage: "chart.bar.doc.horizontal")
            }
            .disabled(true)
            Button {} label: {
                Label("Analyze", systemImage: "chart.bar")
            }
            .disabled(true)
        }
    }

    var vacuumTable: some View {
        Table(filteredVacuumRows.sorted(using: vacuumSortOrder), selection: $selectedVacuumTableId, sortOrder: $vacuumSortOrder) {
            TableColumn("") { row in
                rowOperationIndicator(isActive: maintenanceOperationTargets(row.id))
            }
            .width(min: 22, ideal: 26, max: 30)

            TableColumn("Schema", value: \.schema) { row in
                Text(row.schema)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Table", value: \.name) { row in
                Text(row.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 170, ideal: 240)

            TableColumn("Dead", value: \.deadTuples) { row in
                Text(formatCount(row.deadTuples))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Live", value: \.liveTuples) { row in
                Text(formatCount(row.liveTuples))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Dead %", value: \.deadPercent) { row in
                Text(formatPercent(row.deadPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(row.needsVacuum ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 82)

            TableColumn("Last autovacuum", value: \.lastAutovacuum) { row in
                Text(compactPostgresTimestamp(row.lastAutovacuum, date: row.lastAutovacuumDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.lastAutovacuum)
            }
            .width(min: 105, ideal: 125)

            TableColumn("Last analyze", value: \.lastAutoanalyze) { row in
                Text(compactPostgresTimestamp(row.lastAutoanalyze, date: row.lastAutoanalyzeDate))
                    .font(.caption)
                    .foregroundStyle(row.neverAnalyzed ? .red : .secondary)
                    .lineLimit(1)
                    .help(row.lastAutoanalyze)
            }
            .width(min: 105, ideal: 125)

            TableColumn("Status", value: \.statusTitle) { row in
                vacuumStatusChip(row)
            }
            .width(min: 105, ideal: 125)

            TableColumn("Actions") { row in
                vacuumRowMenu(row)
            }
            .width(min: 54, ideal: 64, max: 72)
        }
    }

    func vacuumStatusChip(_ row: PGVacuumRow) -> some View {
        let color = vacuumStatusColor(row)
        return Text(row.statusTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    func vacuumStatusColor(_ row: PGVacuumRow) -> Color {
        if row.needsVacuum { return .orange }
        if row.neverAnalyzed { return .red }
        if row.staleAnalyze { return .blue }
        return .green
    }

    func vacuumRowMenu(_ row: PGVacuumRow) -> some View {
        Menu {
            Button("VACUUM") {
                queueVacuumAction("VACUUM", row: row)
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)
            Button("VACUUM ANALYZE") {
                queueVacuumAction("VACUUM ANALYZE", row: row)
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)
            Button("ANALYZE") {
                queueVacuumAction("ANALYZE", row: row)
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)
            Divider()
            Button("Copy VACUUM ANALYZE SQL") {
                RemoteCommandRunner.copy(vacuumSQL("VACUUM ANALYZE", row: row))
            }
            Divider()
            Button("VACUUM FULL", role: .destructive) {
                queueVacuumAction("VACUUM FULL", row: row, destructive: true)
            }
            .disabled(row.isSystemTable || isMaintenanceOperationRunning)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Maintenance actions")
    }

    var selectedVacuumRow: PGVacuumRow? {
        vacuumRows.first { $0.id == selectedVacuumTableId }
    }

    var userVacuumRows: [PGVacuumRow] {
        vacuumRows.filter { !$0.isSystemTable }
    }

    var filteredVacuumRows: [PGVacuumRow] {
        let scoped: [PGVacuumRow]
        switch vacuumScope {
        case .userTables:
            scoped = userVacuumRows
        case .needsAttention:
            scoped = userVacuumRows.filter { $0.needsVacuum || $0.neverAnalyzed || $0.staleAnalyze }
        case .highDead:
            scoped = userVacuumRows.filter(\.highDeadTuples)
        case .neverAnalyzed:
            scoped = userVacuumRows.filter(\.neverAnalyzed)
        case .currentSchema:
            scoped = vacuumRows.filter { $0.schema == vacuumCurrentSchema }
        case .systemTables:
            scoped = vacuumRows.filter(\.isSystemTable)
        }

        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return scoped }
        return scoped.filter { row in
            row.schema.lowercased().contains(needle)
                || row.name.lowercased().contains(needle)
                || row.statusTitle.lowercased().contains(needle)
        }
    }

    func ensureVisibleVacuumSelection() {
        let visibleRows = filteredVacuumRows.sorted(using: vacuumSortOrder)
        guard !visibleRows.isEmpty else {
            selectedVacuumTableId = nil
            return
        }
        if let selectedVacuumTableId, visibleRows.contains(where: { $0.id == selectedVacuumTableId }) {
            return
        }
        selectedVacuumTableId = visibleRows.first?.id
    }

    var vacuumNeedsVacuumCount: Int {
        userVacuumRows.filter(\.needsVacuum).count
    }

    var vacuumNeverAnalyzedCount: Int {
        userVacuumRows.filter(\.neverAnalyzed).count
    }

    var vacuumTotalDeadTuples: Int64 {
        userVacuumRows.reduce(Int64(0)) { $0 + max(0, $1.deadTuples) }
    }

    var vacuumRowsInCurrentSchema: Int {
        vacuumRows.filter { $0.schema == vacuumCurrentSchema }.count
    }

    var vacuumWorstDeadPercentRow: PGVacuumRow? {
        userVacuumRows.max { $0.deadPercent < $1.deadPercent }
    }

    var vacuumWorstDeadPercentText: String {
        guard let row = vacuumWorstDeadPercentRow else { return "-" }
        return formatPercent(row.deadPercent)
    }

    var vacuumWorstDeadPercentTable: String {
        guard let row = vacuumWorstDeadPercentRow else { return "No user tables" }
        return "\(row.schema).\(row.name)"
    }

    var vacuumWorstDeadPercentColor: Color {
        guard let row = vacuumWorstDeadPercentRow else { return .secondary }
        if row.needsVacuum { return .orange }
        if row.deadPercent >= 10 { return .red }
        return .green
    }

    var vacuumOldestAutovacuumRow: PGVacuumRow? {
        if let never = userVacuumRows.first(where: { $0.lastAutovacuumDate == nil && $0.lastAutovacuum.lowercased() == "never" }) {
            return never
        }
        return userVacuumRows.compactMap { row -> (PGVacuumRow, Date)? in
            guard let date = row.lastAutovacuumDate else { return nil }
            return (row, date)
        }
        .min { $0.1 < $1.1 }?
        .0
    }

    var vacuumOldestAutovacuumText: String {
        guard let row = vacuumOldestAutovacuumRow else { return "-" }
        return compactPostgresTimestamp(row.lastAutovacuum, date: row.lastAutovacuumDate)
    }

    var vacuumOldestAutovacuumTable: String {
        guard let row = vacuumOldestAutovacuumRow else { return "No autovacuum sample" }
        return "\(row.schema).\(row.name)"
    }

}
