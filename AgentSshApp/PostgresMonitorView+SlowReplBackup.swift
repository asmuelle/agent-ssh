import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension PostgresMonitorView {
    // MARK: - Slow queries, replication, backup, result helpers

    var slowPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(slowSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !slowWarnings.isEmpty {
                    postgresWarningsLabel(slowWarnings)
                }

                Spacer()

                TextField("Filter slow queries", text: $slowFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .disabled(slowRows.isEmpty)

                Button {
                    RemoteCommandRunner.copy(slowExportText(filteredSlowRows.sorted(using: slowSortOrder)))
                } label: {
                    Label("Copy Table", systemImage: "doc.on.doc")
                }
                .disabled(filteredSlowRows.isEmpty)

                Button {
                    RemoteCommandRunner.copy(slowDiagnostics)
                } label: {
                    Label("Copy Diagnostics", systemImage: "stethoscope")
                }
                .disabled(slowDiagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let slowError {
                Divider()
                postgresInlineNotice(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Slow query stats unavailable",
                    message: slowError,
                    color: .orange
                )
            }

            Divider()

            if slowRows.isEmpty {
                placeholderView(
                    icon: slowError == nil ? "timer" : "exclamationmark.triangle",
                    title: slowError == nil ? "No slow queries" : "No slow query table",
                    message: slowError == nil
                        ? "pg_stat_statements returned no rows."
                        : "Use Copy Diagnostics for the raw PostgreSQL output."
                )
            } else {
                Table(filteredSlowRows.sorted(using: slowSortOrder), sortOrder: $slowSortOrder) {
                    TableColumn("Total", value: \.totalMs) { row in
                        monoCell(row.totalMsText, width: 88)
                    }
                    .width(min: 80, ideal: 92, max: 115)

                    TableColumn("Mean", value: \.meanMs) { row in
                        monoCell(row.meanMsText, width: 88)
                    }
                    .width(min: 80, ideal: 92, max: 115)

                    TableColumn("Max", value: \.maxMs) { row in
                        monoCell(row.maxMsText, width: 88)
                    }
                    .width(min: 80, ideal: 92, max: 115)

                    TableColumn("Calls", value: \.calls) { row in
                        monoCell(formatCount(row.calls), width: 72)
                    }
                    .width(min: 70, ideal: 84, max: 100)

                    TableColumn("Rows", value: \.rows) { row in
                        monoCell(formatCount(row.rows), width: 72)
                    }
                    .width(min: 70, ideal: 84, max: 100)

                    TableColumn("Query", value: \.query) { row in
                        monoCell(row.query)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var replicationPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(replicationSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !replicationWarnings.isEmpty {
                    postgresWarningsLabel(replicationWarnings)
                }

                Spacer()

                Button {
                    RemoteCommandRunner.copy(replicationSnapshot.rawText)
                } label: {
                    Label("Copy Status", systemImage: "doc.on.doc")
                }
                .disabled(replicationSnapshot.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let replicationError {
                Divider()
                postgresInlineNotice(
                    systemImage: "xmark.octagon.fill",
                    title: "Replication status unavailable",
                    message: replicationError,
                    color: .red
                )
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    replicationOverview
                    replicationReplicaSection
                    replicationSlotSection
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    var replicationOverview: some View {
        HStack(spacing: 12) {
            postgresSummaryChip(
                title: "Role",
                value: replicationSnapshot.role.capitalized,
                systemImage: replicationSnapshot.role == "standby" ? "arrow.down.forward.circle" : "server.rack",
                color: replicationSnapshot.role == "standby" ? .blue : .green
            )
            postgresSummaryChip(
                title: "Replicas",
                value: "\(replicationSnapshot.replicas.count)",
                systemImage: "point.3.connected.trianglepath.dotted",
                color: replicationSnapshot.replicas.isEmpty ? .secondary : .blue
            )
            postgresSummaryChip(
                title: "Slots",
                value: "\(replicationSnapshot.slots.count)",
                systemImage: "rectangle.stack",
                color: replicationSnapshot.slots.isEmpty ? .secondary : .purple
            )
            postgresSummaryChip(
                title: "Database",
                value: replicationSnapshot.database,
                systemImage: "cylinder.split.1x2",
                color: .secondary
            )
        }
    }

    var replicationReplicaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected Replicas")
                .font(.headline)
            if replicationSnapshot.replicas.isEmpty {
                postgresCompactNotice(systemImage: "point.3.connected.trianglepath.dotted", text: "No connected replicas.")
            } else {
                Table(replicationSnapshot.replicas.sorted(using: replicationReplicaSortOrder), sortOrder: $replicationReplicaSortOrder) {
                    TableColumn("User", value: \.user) { row in
                        monoCell(row.user)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("App", value: \.application) { row in
                        monoCell(row.application, color: .secondary)
                    }
                    .width(min: 100, ideal: 140)

                    TableColumn("Client", value: \.client) { row in
                        monoCell(row.client, color: .secondary)
                    }
                    .width(min: 105, ideal: 130)

                    TableColumn("State", value: \.state) { row in
                        monoCell(row.state, color: statusColor(row.state))
                    }
                    .width(min: 80, ideal: 95)

                    TableColumn("Sync", value: \.syncState) { row in
                        monoCell(row.syncState, color: .secondary)
                    }
                    .width(min: 70, ideal: 85)

                    TableColumn("Replay Lag", value: \.replayLag) { row in
                        monoCell(row.replayLag)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Replay LSN", value: \.replayLsn) { row in
                        monoCell(row.replayLsn, color: .secondary)
                    }
                }
                .frame(height: postgresTableHeight(rowCount: replicationSnapshot.replicas.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var replicationSlotSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replication Slots")
                .font(.headline)
            if replicationSnapshot.slots.isEmpty {
                postgresCompactNotice(systemImage: "rectangle.stack", text: "No replication slots.")
            } else {
                Table(replicationSnapshot.slots.sorted(using: replicationSlotSortOrder), sortOrder: $replicationSlotSortOrder) {
                    TableColumn("Slot", value: \.name) { row in
                        monoCell(row.name)
                    }
                    .width(min: 140, ideal: 170)

                    TableColumn("Type", value: \.type) { row in
                        monoCell(row.type, color: .secondary)
                    }
                    .width(min: 75, ideal: 90)

                    TableColumn("Database", value: \.database) { row in
                        monoCell(row.database, color: .secondary)
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Active", value: \.active) { row in
                        monoCell(row.active, color: row.active == "true" ? .green : .secondary)
                    }
                    .width(min: 70, ideal: 85)

                    TableColumn("Plugin", value: \.plugin) { row in
                        monoCell(row.plugin, color: .secondary)
                    }
                    .width(min: 90, ideal: 115)

                    TableColumn("Restart LSN", value: \.restartLsn) { row in
                        monoCell(row.restartLsn)
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Confirmed Flush", value: \.confirmedFlushLsn) { row in
                        monoCell(row.confirmedFlushLsn, color: .secondary)
                    }
                }
                .frame(height: postgresTableHeight(rowCount: replicationSnapshot.slots.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var backupPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup")
                .font(.headline)
            TextField("Remote dump path", text: $backupPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            HStack {
                Button("Run pg_dump") { Task { await runBackup(download: false) } }
                Button("Run pg_dump and download") { Task { await runBackup(download: true) } }
            }
            Text("Uses pg_dump -Fc on the remote host. Downloads use the existing SFTP transfer queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var visibleQueryResult: SQLResult {
        let needle = queryFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return queryResult }
        return SQLResult(
            columns: queryResult.columns,
            rows: queryResult.rows.filter { row in
                row.joined(separator: " ").lowercased().contains(needle)
            }
        )
    }

    var queryResultsSummary: String {
        let total = queryResult.rows.count
        let visible = visibleQueryResult.rows.count
        if total == 0 { return "No rows" }
        if queryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(total) row\(total == 1 ? "" : "s")"
        }
        return "\(visible) of \(total) row\(total == 1 ? "" : "s")"
    }

    func queryStatusText(now: Date) -> String {
        if queryIsRunning, let started = queryStartedAt {
            return "Running \(formatQueryDuration(now.timeIntervalSince(started)))"
        }
        if let queryLastDuration {
            return "\(queryResult.rows.count) row\(queryResult.rows.count == 1 ? "" : "s") · \(formatQueryDuration(queryLastDuration))"
        }
        return "Ready"
    }

    func formatQueryDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", max(0, duration) * 1_000)
        }
        if duration < 60 {
            return String(format: "%.1f s", duration)
        }
        return formatOperationDuration(duration)
    }

    func resultTable(_ result: SQLResult) -> some View {
        VStack(spacing: 0) {
            if result.columns.isEmpty {
                placeholderView(icon: "tablecells", title: "No results", message: "Run a query to see rows.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            ForEach(result.columns, id: \.self) { column in
                                Text(column)
                                    .font(.caption.weight(.semibold).monospaced())
                                    .frame(minWidth: 120, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider()
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    Text(value)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(minWidth: 120, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

    func postgresWarningsLabel(_ warnings: [String]) -> some View {
        Label("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .help(warnings.joined(separator: "\n"))
    }

    func postgresInlineNotice(systemImage: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.07))
    }

    func postgresCompactNotice(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    func postgresSummaryChip(title: String, value: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "-" : value)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func postgresTableHeight(rowCount: Int) -> CGFloat {
        Swift.min(320, Swift.max(112, CGFloat(rowCount + 1) * 28 + 18))
    }

    var filteredSlowRows: [PGSlowQuery] {
        let needle = slowFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return slowRows }
        return slowRows.filter { row in
            row.query.lowercased().contains(needle)
                || row.totalMsText.lowercased().contains(needle)
                || row.meanMsText.lowercased().contains(needle)
                || "\(row.calls)".contains(needle)
        }
    }

    var slowSummaryText: String {
        if let slowError, slowRows.isEmpty { return slowError }
        let total = slowRows.count
        let visible = filteredSlowRows.count
        if total == 0 { return "No slow queries" }
        if slowFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(total) slow quer\(total == 1 ? "y" : "ies")"
        }
        return "\(visible) of \(total) slow quer\(total == 1 ? "y" : "ies")"
    }

    var replicationSummaryText: String {
        if let replicationError { return replicationError }
        let role = replicationSnapshot.role == "-" ? "Unknown role" : replicationSnapshot.role.capitalized
        let replicas = replicationSnapshot.replicas.count
        let slots = replicationSnapshot.slots.count
        return "\(role) · \(replicas) replica\(replicas == 1 ? "" : "s") · \(slots) slot\(slots == 1 ? "" : "s")"
    }

    var explainSummaryText: String {
        let items = explainSummaryItems
        if !items.isEmpty { return items.joined(separator: " · ") }
        if explainIsRunning { return "Running explain" }
        if explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No plan" }
        return "Plan ready"
    }

    var explainSummaryItems: [String] {
        var items: [String] = []
        if let execution = explainMetric(after: "Execution Time:") {
            items.append("Execution \(execution)")
        }
        if let planning = explainMetric(after: "Planning Time:") {
            items.append("Planning \(planning)")
        }
        if let rows = explainRowsText {
            items.append("Rows \(rows)")
        }
        return items
    }

    func explainStatusText(now: Date) -> String {
        if explainIsRunning, let started = explainStartedAt {
            return "Running \(formatQueryDuration(now.timeIntervalSince(started)))"
        }
        if let explainLastDuration {
            return "Finished \(formatQueryDuration(explainLastDuration))"
        }
        return "Ready"
    }

    func explainMetric(after prefix: String) -> String? {
        for line in explainText.lines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    var explainRowsText: String? {
        for line in explainText.lines() {
            let parts = line.components(separatedBy: " rows=")
            guard parts.count > 1 else { continue }
            let tokenSource = parts.count > 2 ? parts[2] : parts[1]
            let token = tokenSource.prefix { $0.isNumber }
            if !token.isEmpty { return String(token) }
        }
        return nil
    }

    func slowExportText(_ rows: [PGSlowQuery]) -> String {
        let header = "total_ms\tmean_ms\tmax_ms\tcalls\trows\tquery"
        let body = rows.map { row in
            [
                String(format: "%.3f", row.totalMs),
                String(format: "%.3f", row.meanMs),
                String(format: "%.3f", row.maxMs),
                "\(row.calls)",
                "\(row.rows)",
                row.query
            ].joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n")
    }

}
