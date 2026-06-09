import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension PostgresMonitorView {
    // MARK: - Loading, parsing, actions

    func refresh() async {
        switch mode {
        case .dashboard:
            await loadDashboard()
        case .sessions:
            await loadSessions()
        case .locks:
            await loadLocks()
        case .query:
            break
        case .schema:
            await loadSchema()
        case .explain:
            break
        case .slow:
            await loadSlowQueries()
        case .replication:
            await loadReplication()
        case .vacuum:
            await loadVacuum()
        case .backup:
            break
        }
    }

    func psql(_ sql: String) async throws -> String {
        let result = try await psqlOutput(sql)
        return result.output
    }

    func psqlOutput(_ sql: String) async throws -> (output: String, warnings: [String]) {
        guard let connectionId else { return ("", []) }
        let rawOutput = try await RemoteCommandRunner.runChecked(
            connectionId: connectionId,
            script: settings.queryScript(sql)
        )
        return sanitizedPostgresOutput(rawOutput)
    }

    func sanitizedPostgresOutput(_ output: String) -> (output: String, warnings: [String]) {
        sanitizePostgresCommandOutput(output)
    }

    func sanitizedPostgresError(_ error: Error) -> (message: String, warnings: [String], diagnostics: String) {
        let diagnostics = error.localizedDescription
        let sanitized = sanitizedPostgresOutput(diagnostics)
        let message = sanitized.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            message: message.isEmpty ? diagnostics : message,
            warnings: sanitized.warnings,
            diagnostics: diagnostics
        )
    }

    func loadDashboard() async {
        loading = true
        defer { loading = false }
        do {
            let output = try await psql(postgresDashboardSQL)
            dashboard = parsePostgresDashboard(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSessions() async {
        loading = true
        defer { loading = false }
        let sql = """
        select pid, usename, coalesce(application_name,''), coalesce(client_addr::text,''), coalesce(state,''), coalesce(wait_event_type||':'||wait_event,''), coalesce(now()-query_start, interval '0')::text, left(regexp_replace(query, E'[\\n\\r\\t]+', ' ', 'g'), 500)
        from pg_stat_activity
        order by query_start nulls last
        limit 300;
        """
        do {
            let output = try await psql(sql)
            sessions = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 8 else { return nil }
                return PGSession(pid: p[0], user: p[1], app: p[2], client: p[3], state: p[4], wait: p[5], age: p[6], query: p[7])
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadLocks() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'blocked='||blocked.pid||' blocking='||blocking.pid||' age='||coalesce(now()-blocked.query_start, interval '0')||E'\\nblocked query: '||left(blocked.query,300)||E'\\nblocking query: '||left(blocking.query,300)||E'\\n'
        from pg_catalog.pg_locks blocked_locks
        join pg_catalog.pg_stat_activity blocked on blocked.pid = blocked_locks.pid
        join pg_catalog.pg_locks blocking_locks
          on blocking_locks.locktype = blocked_locks.locktype
         and blocking_locks.database is not distinct from blocked_locks.database
         and blocking_locks.relation is not distinct from blocked_locks.relation
         and blocking_locks.page is not distinct from blocked_locks.page
         and blocking_locks.tuple is not distinct from blocked_locks.tuple
         and blocking_locks.virtualxid is not distinct from blocked_locks.virtualxid
         and blocking_locks.transactionid is not distinct from blocked_locks.transactionid
         and blocking_locks.classid is not distinct from blocked_locks.classid
         and blocking_locks.objid is not distinct from blocked_locks.objid
         and blocking_locks.objsubid is not distinct from blocked_locks.objsubid
         and blocking_locks.pid != blocked_locks.pid
        join pg_catalog.pg_stat_activity blocking on blocking.pid = blocking_locks.pid
        where not blocked_locks.granted and blocking_locks.granted;
        """
        do {
            locks = try await psql(sql)
            if locks.isEmpty { locks = "No blocking locks reported." }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runQuery() async {
        let startedAt = Date()
        queryStartedAt = startedAt
        queryLastDuration = nil
        queryIsRunning = true
        queryError = nil
        queryWarnings = []
        loading = true
        defer {
            queryIsRunning = false
            queryStartedAt = nil
            loading = false
        }
        do {
            let limited = """
            \(queryText)
            """
            let result = try await psqlOutput(limited)
            queryResult = parseSQLResult(result.output)
            queryWarnings = result.warnings
            queryLastDuration = Date().timeIntervalSince(startedAt)
            error = nil
        } catch {
            queryLastDuration = Date().timeIntervalSince(startedAt)
            queryError = error.localizedDescription
            self.error = nil
        }
    }

    func parseSQLResult(_ output: String) -> SQLResult {
        let lines = output.lines()
        guard !lines.isEmpty else { return SQLResult(columns: [], rows: []) }
        let rows = lines.map(splitFields)
        let width = rows.map(\.count).max() ?? 0
        let columns = (0..<width).map { "col\($0 + 1)" }
        return SQLResult(columns: columns, rows: rows)
    }

    func resultText(_ result: SQLResult) -> String {
        ([result.columns.joined(separator: "\t")] + result.rows.map { $0.joined(separator: "\t") }).joined(separator: "\n")
    }

    func parseSlowQueries(_ output: String) -> [PGSlowQuery] {
        output.lines().enumerated().compactMap { index, line in
            let fields = splitFields(line)
            guard fields.count >= 7 else { return nil }
            return PGSlowQuery(
                id: fields[0].isEmpty ? "\(index):\(fields[1])" : fields[0],
                query: fields[1],
                calls: Int64(fields[2]) ?? 0,
                totalMs: Double(fields[3]) ?? 0,
                meanMs: Double(fields[4]) ?? 0,
                maxMs: Double(fields[5]) ?? 0,
                rows: Int64(fields[6]) ?? 0
            )
        }
    }

    func slowErrorMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("pg_stat_statements") {
            return "pg_stat_statements is not enabled or not visible to this user."
        }
        let uniqueLines = message.lines().reduce(into: [String]()) { result, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        return uniqueLines.prefix(3).joined(separator: "\n")
    }

    func parseReplication(_ output: String) -> PGReplicationSnapshot {
        var snapshot = PGReplicationSnapshot.empty
        for (index, line) in output.lines().enumerated() {
            let fields = splitFields(line)
            switch fields.first {
            case "role" where fields.count >= 3:
                snapshot.role = fields[1].isEmpty ? "-" : fields[1]
                snapshot.database = fields[2].isEmpty ? "-" : fields[2]
            case "replica" where fields.count >= 13:
                snapshot.replicas.append(
                    PGReplicaRow(
                        id: "\(index):\(fields[1]):\(fields[3])",
                        user: fields[1],
                        application: fields[2],
                        client: fields[3],
                        state: fields[4],
                        syncState: fields[5],
                        sentLsn: fields[6],
                        writeLsn: fields[7],
                        flushLsn: fields[8],
                        replayLsn: fields[9],
                        writeLag: fields[10],
                        flushLag: fields[11],
                        replayLag: fields[12]
                    )
                )
            case "slot" where fields.count >= 8:
                snapshot.slots.append(
                    PGReplicationSlot(
                        id: fields[1].isEmpty ? "\(index)" : fields[1],
                        name: fields[1],
                        type: fields[2],
                        database: fields[3],
                        active: fields[4],
                        plugin: fields[5],
                        restartLsn: fields[6],
                        confirmedFlushLsn: fields[7]
                    )
                )
            default:
                continue
            }
        }
        snapshot.refreshedAt = Date()
        snapshot.rawText = replicationRawText(snapshot)
        return snapshot
    }

    func replicationRawText(_ snapshot: PGReplicationSnapshot) -> String {
        var lines = [
            "role: \(snapshot.role)",
            "database: \(snapshot.database)",
            ""
        ]

        lines.append("connected_replicas:")
        if snapshot.replicas.isEmpty {
            lines.append("  none")
        } else {
            for replica in snapshot.replicas {
                lines.append("  \(replica.user) \(replica.application) \(replica.client) state=\(replica.state) sync=\(replica.syncState) replay_lag=\(replica.replayLag)")
            }
        }

        lines.append("")
        lines.append("replication_slots:")
        if snapshot.slots.isEmpty {
            lines.append("  none")
        } else {
            for slot in snapshot.slots {
                lines.append("  \(slot.name) type=\(slot.type) database=\(slot.database) active=\(slot.active) restart=\(slot.restartLsn) confirmed_flush=\(slot.confirmedFlushLsn)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func loadSchema() async {
        loading = true
        defer { loading = false }
        let sql = """
        select n.nspname, c.relname, c.relkind::text,
               pg_size_pretty(pg_total_relation_size(c.oid)),
               pg_total_relation_size(c.oid)::bigint::text,
               coalesce(c.reltuples::bigint::text,''),
               coalesce(c.reltuples::bigint,0)::bigint::text
        from pg_class c
        join pg_namespace n on n.oid=c.relnamespace
        where n.nspname not in ('pg_catalog','information_schema') and c.relkind in ('r','p','v','m','f')
        order by n.nspname, c.relname
        limit 1000;
        """
        do {
            let output = try await psql(sql)
            schemaRows = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 7 else { return nil }
                return PGTableInfo(
                    schema: p[0],
                    name: p[1],
                    kind: p[2],
                    size: p[3],
                    sizeBytes: Int64(p[4]) ?? 0,
                    estimate: p[5],
                    estimateCount: Int64(p[6]) ?? 0
                )
            }
            if selectedTableId == nil { selectedTableId = schemaRows.first?.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runExplain() async {
        let startedAt = Date()
        explainStartedAt = startedAt
        explainLastDuration = nil
        explainIsRunning = true
        explainError = nil
        explainWarnings = []
        loading = true
        defer {
            explainIsRunning = false
            explainStartedAt = nil
            loading = false
        }
        do {
            let result = try await psqlOutput("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(queryText)")
            explainText = result.output
            explainWarnings = result.warnings
            explainLastDuration = Date().timeIntervalSince(startedAt)
            error = nil
        } catch {
            let details = sanitizedPostgresError(error)
            explainError = details.message
            explainWarnings = details.warnings
            explainLastDuration = Date().timeIntervalSince(startedAt)
            self.error = nil
        }
    }

    func loadSlowQueries() async {
        loading = true
        defer { loading = false }
        let sql = """
        select queryid::text,
               left(regexp_replace(query, E'[\\n\\r\\t]+', ' ', 'g'), 500),
               calls::bigint::text,
               round(total_exec_time::numeric, 3)::text,
               round(mean_exec_time::numeric, 3)::text,
               round(max_exec_time::numeric, 3)::text,
               rows::bigint::text
        from pg_stat_statements
        order by total_exec_time desc
        limit 40;
        """
        do {
            let result = try await psqlOutput(sql)
            slowRows = parseSlowQueries(result.output)
            slowWarnings = result.warnings
            slowError = nil
            slowDiagnostics = result.output
            error = nil
        } catch {
            let details = sanitizedPostgresError(error)
            slowRows = []
            slowWarnings = details.warnings
            slowError = slowErrorMessage(details.message)
            slowDiagnostics = details.diagnostics
            self.error = nil
        }
    }

    func loadReplication() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'role',
               case when pg_is_in_recovery() then 'standby' else 'primary' end,
               current_database();
        select 'replica',
               coalesce(usename, ''),
               coalesce(application_name, ''),
               coalesce(client_addr::text, ''),
               coalesce(state, ''),
               coalesce(sync_state, ''),
               coalesce(sent_lsn::text, ''),
               coalesce(write_lsn::text, ''),
               coalesce(flush_lsn::text, ''),
               coalesce(replay_lsn::text, ''),
               coalesce(write_lag::text, ''),
               coalesce(flush_lag::text, ''),
               coalesce(replay_lag::text, '')
        from pg_stat_replication;
        select 'slot',
               slot_name,
               coalesce(slot_type, ''),
               coalesce(database, ''),
               active::text,
               coalesce(plugin, ''),
               coalesce(restart_lsn::text, ''),
               coalesce(confirmed_flush_lsn::text, '')
        from pg_replication_slots;
        """
        do {
            let result = try await psqlOutput(sql)
            replicationSnapshot = parseReplication(result.output)
            replicationWarnings = result.warnings
            replicationError = nil
            error = nil
        } catch {
            let details = sanitizedPostgresError(error)
            replicationSnapshot.rawText = details.diagnostics
            replicationWarnings = details.warnings
            replicationError = details.message
            self.error = nil
        }
    }

    func loadVacuum() async {
        loading = true
        defer { loading = false }
        let sql = """
        select 'meta', current_schema(), current_database(), '', '', '', '', '', '', '', '';
        select 'table',
               schemaname,
               relname,
               n_dead_tup::bigint::text,
               n_live_tup::bigint::text,
               coalesce(last_autovacuum::text,'never'),
               coalesce(last_autoanalyze::text,'never'),
               vacuum_count::bigint::text,
               autovacuum_count::bigint::text,
               analyze_count::bigint::text,
               autoanalyze_count::bigint::text
        from pg_stat_all_tables
        where schemaname <> 'pg_toast'
        order by case when schemaname in ('pg_catalog','information_schema') or schemaname like 'pg_toast%' or schemaname like 'pg_temp%' then 1 else 0 end,
                 n_dead_tup desc,
                 schemaname,
                 relname
        limit 500;
        """
        do {
            let output = try await psql(sql)
            parseVacuumOutput(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func parseVacuumOutput(_ output: String) {
        var rows: [PGVacuumRow] = []
        var warnings: [String] = []
        var currentSchema = vacuumCurrentSchema

        for line in output.lines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = splitFields(line)

            switch fields.first {
            case "meta" where fields.count >= 2:
                currentSchema = fields[1].isEmpty ? "public" : fields[1]
            case "table" where fields.count >= 11:
                let lastAutovacuum = fields[5]
                let lastAutoanalyze = fields[6]
                rows.append(
                    PGVacuumRow(
                        schema: fields[1],
                        name: fields[2],
                        deadTuples: Int64(fields[3]) ?? 0,
                        liveTuples: Int64(fields[4]) ?? 0,
                        lastAutovacuum: lastAutovacuum,
                        lastAutoanalyze: lastAutoanalyze,
                        lastAutovacuumDate: parsePostgresTimestamp(lastAutovacuum),
                        lastAutoanalyzeDate: parsePostgresTimestamp(lastAutoanalyze),
                        vacuumCount: Int64(fields[7]) ?? 0,
                        autovacuumCount: Int64(fields[8]) ?? 0,
                        analyzeCount: Int64(fields[9]) ?? 0,
                        autoanalyzeCount: Int64(fields[10]) ?? 0
                    )
                )
            default:
                warnings.append(trimmed)
            }
        }

        vacuumRows = rows
        vacuumWarnings = warnings
        vacuumCurrentSchema = currentSchema
        vacuumRefreshedAt = Date()

        ensureVisibleVacuumSelection()
    }

    func vacuumExportText(_ rows: [PGVacuumRow]) -> String {
        let header = [
            "schema", "table", "dead_tuples", "live_tuples", "dead_percent",
            "last_autovacuum", "last_autoanalyze", "status",
            "vacuum_count", "autovacuum_count", "analyze_count", "autoanalyze_count"
        ].joined(separator: "\t")

        let body = rows.map { row in
            [
                row.schema,
                row.name,
                "\(row.deadTuples)",
                "\(row.liveTuples)",
                formatPercent(row.deadPercent),
                row.lastAutovacuum,
                row.lastAutoanalyze,
                row.statusTitle,
                "\(row.vacuumCount)",
                "\(row.autovacuumCount)",
                "\(row.analyzeCount)",
                "\(row.autoanalyzeCount)"
            ].joined(separator: "\t")
        }

        let warningText: [String] = vacuumWarnings.isEmpty
            ? []
            : ["warnings:", vacuumWarnings.joined(separator: "\n"), ""]
        return (warningText + [header] + body).joined(separator: "\n")
    }

    func runBackendAction(_ action: BackendAction) async {
        pendingBackendAction = nil
        do {
            _ = try await psql("select \(action.function)(\(action.pid));")
            await loadSessions()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func queueVacuumAction(_ command: String, row: PGVacuumRow, destructive: Bool = false) {
        pendingVacuumAction = VacuumAction(
            title: "Run \(command)",
            sql: vacuumSQL(command, row: row),
            command: command,
            tableId: row.id,
            destructive: destructive
        )
    }

    func runVacuumAction(_ action: VacuumAction) async {
        pendingVacuumAction = nil
        guard !isMaintenanceOperationRunning else { return }
        let operationId = startMaintenanceOperation(
            title: action.title,
            detail: action.sql,
            target: action.tableId
        )
        loading = true
        defer { loading = false }
        do {
            let output = try await psql(action.sql)
            await loadVacuum()
            error = nil
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Completed \(action.command) on \(action.tableId)."
                : output
            finishMaintenanceOperation(
                operationId,
                state: .succeeded,
                detail: detail,
                output: output,
                completedCount: 1
            )
            if let connectionId {
                ActivityLogStore.shared.record(
                    title: action.title,
                    detail: detail,
                    connectionId: connectionId,
                    icon: "tablecells",
                    severity: .success
                )
            }
        } catch {
            let message = error.localizedDescription
            finishMaintenanceOperation(
                operationId,
                state: .failed,
                detail: "Failed \(action.command) on \(action.tableId).",
                output: "",
                completedCount: 0,
                errorMessage: message
            )
            if let connectionId {
                ActivityLogStore.shared.record(
                    title: "\(action.title) failed",
                    detail: message,
                    connectionId: connectionId,
                    icon: "tablecells",
                    severity: .critical
                )
            }
        }
    }

    var isMaintenanceOperationRunning: Bool {
        maintenanceOperation?.isRunning == true
    }

    func maintenanceOperationTargets(_ target: String) -> Bool {
        guard let maintenanceOperation, maintenanceOperation.isRunning else { return false }
        return maintenanceOperation.targetIds.contains(target)
    }

    func startMaintenanceOperation(
        title: String,
        detail: String,
        target: String
    ) -> UUID {
        let operation = RemoteOperationFeedback(
            title: title,
            detail: detail,
            targetIds: [target],
            totalCount: 1
        )
        maintenanceOperation = operation
        return operation.id
    }

    func finishMaintenanceOperation(
        _ id: UUID,
        state: RemoteOperationState,
        detail: String,
        output: String,
        completedCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        guard var operation = maintenanceOperation, operation.id == id else { return }
        operation.state = state
        operation.detail = detail
        operation.output = output
        operation.errorMessage = errorMessage
        operation.completedCount = completedCount ?? operation.completedCount
        operation.endedAt = Date()
        maintenanceOperation = operation
    }

    func dismissMaintenanceOperation(_ id: UUID) {
        guard maintenanceOperation?.id == id, maintenanceOperation?.isRunning == false else { return }
        maintenanceOperation = nil
    }

    func vacuumSQL(_ command: String, row: PGVacuumRow) -> String {
        "\(command) \(postgresQualifiedName(schema: row.schema, name: row.name));"
    }

    func postgresQualifiedName(schema: String, name: String) -> String {
        "\(postgresIdentifier(schema)).\(postgresIdentifier(name))"
    }

    func postgresIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func runBackup(download: Bool) async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            _ = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: settings.dumpScript(path: backupPath)
            )
            if download {
                let local = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                    .first?
                    .appendingPathComponent((backupPath as NSString).lastPathComponent)
                    .path ?? (NSHomeDirectory() + "/Downloads/" + (backupPath as NSString).lastPathComponent)
                transfers.enqueueDownload(
                    connectionId: connectionId,
                    remotePath: backupPath,
                    localPath: local,
                    expectedSize: 0
                )
            }
            dashboard.rawText = "Backup completed at \(backupPath)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
