import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct PostgresSettings: Equatable {
    var database: String = "postgres"
    var host: String = ""
    var port: String = ""
    var user: String = ""
    var extraArgs: String = ""
    var runAsPostgresUser: Bool = true
    var osUser: String = "postgres"

    func baseArgs(binary: String) -> [String] {
        var args = [binary]
        if binary == "psql" {
            args += ["-X", "-v", "ON_ERROR_STOP=1", "-qAt"]
        } else if binary == "pg_dump" {
            args += ["-Fc"]
        }
        if !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-d", RemoteCommandRunner.shellQuote(database)]
        }
        if !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-h", RemoteCommandRunner.shellQuote(host)]
        }
        if !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-p", RemoteCommandRunner.shellQuote(port)]
        }
        if !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-U", RemoteCommandRunner.shellQuote(user)]
        }
        if !extraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(extraArgs)
        }
        return args
    }

    func queryScript(_ sql: String) -> String {
        let command = (baseArgs(binary: "psql") + [
            "-F", "\"$(printf '\\037')\"",
            "-c", RemoteCommandRunner.shellQuote(sql),
        ]).joined(separator: " ")
        return runInConfiguredUser(command, binary: "psql")
    }

    func dumpScript(path: String) -> String {
        let command = (baseArgs(binary: "pg_dump") + [
            "-f", RemoteCommandRunner.shellQuote(path),
        ]).joined(separator: " ")
        return runInConfiguredUser(command, binary: "pg_dump")
    }

    func runInConfiguredUser(_ command: String, binary: String) -> String {
        let inner = """
        cd /tmp 2>/dev/null || cd / 2>/dev/null || true
        command -v \(binary) >/dev/null || { echo \(binary) not found for $(id -un); exit 127; }
        \(command) 2>&1
        """
        guard runAsPostgresUser else { return inner }

        let user = osUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "postgres"
            : osUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedUser = RemoteCommandRunner.shellQuote(user)
        let quotedInner = RemoteCommandRunner.shellQuote(inner)
        let suCommand = "sh -lc \(quotedInner)"
        let quotedSuCommand = RemoteCommandRunner.shellQuote(suCommand)
        return """
        cd /tmp 2>/dev/null || cd / 2>/dev/null || true

        if [ "$(id -un)" = \(quotedUser) ]; then
          sh -lc \(quotedInner)
          exit $?
        fi

        rc=127
        if command -v sudo >/dev/null; then
          sudo -n -u \(quotedUser) sh -lc \(quotedInner)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0
        fi

        if command -v su >/dev/null; then
          su \(quotedUser) -c \(quotedSuCommand)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0

          su - \(quotedUser) -c \(quotedSuCommand)
          rc=$?
          [ "$rc" -eq 0 ] && exit 0
        fi

        echo "Could not run \(binary) as \(user). Tried current user, sudo -n -u \(user), su \(user), and su - \(user). Last exit: $rc"
        exit "$rc"
        """
    }
}

struct SQLResult {
    let columns: [String]
    let rows: [[String]]
}

struct PGDashboardSnapshot {
    var metrics: [String: String]
    var largestTables: [PGDashboardTable]
    var maintenance: [PGDashboardMaintenanceRow]
    var rawText: String
    var refreshedAt: Date?

    static let empty = PGDashboardSnapshot(
        metrics: [:],
        largestTables: [],
        maintenance: [],
        rawText: "",
        refreshedAt: nil
    )

    func value(_ key: String) -> String {
        metrics[key] ?? "-"
    }
}

struct PGDashboardTable: Identifiable, Hashable {
    let schema: String
    let name: String
    let size: String
    let sizeBytes: Int64
    let rowEstimate: Int64

    var id: String { "\(schema).\(name)" }
}

struct PGDashboardMaintenanceRow: Identifiable, Hashable {
    let schema: String
    let name: String
    let deadTuples: Int64
    let liveTuples: Int64
    let lastAutovacuum: String
    let lastAutoanalyze: String

    var id: String { "\(schema).\(name)" }
}

let postgresDashboardSQL = """
with metrics(key, value) as (
  select 'version', version()
  union all select 'database', current_database()
  union all select 'user', current_user
  union all select 'server',
    case
      when inet_server_addr() is null then 'local'
      when inet_server_port() is null then inet_server_addr()::text
      else inet_server_addr()::text || ':' || inet_server_port()::text
    end
  union all select 'ssl', current_setting('ssl', true)
  union all select 'uptime', (now() - pg_postmaster_start_time())::text
  union all select 'read_only', current_setting('transaction_read_only')
  union all select 'sessions', (select count(*)::text from pg_stat_activity)
  union all select 'active_sessions', (select count(*)::text from pg_stat_activity where state='active')
  union all select 'idle_in_transaction', (select count(*)::text from pg_stat_activity where state='idle in transaction')
  union all select 'longest_query',
    coalesce((
      select (now() - query_start)::text
      from pg_stat_activity
      where state='active' and query_start is not null and pid <> pg_backend_pid()
      order by query_start
      limit 1
    ), 'none')
  union all select 'locks_waiting', (select count(*)::text from pg_locks where not granted)
  union all select 'database_size', pg_size_pretty(pg_database_size(current_database()))
  union all select 'cache_hit_ratio',
    coalesce(round((100.0 * blks_hit / nullif(blks_hit + blks_read, 0))::numeric, 2)::text, 'n/a')
    from pg_stat_database
    where datname=current_database()
  union all select 'max_connections', current_setting('max_connections', true)
),
largest_tables as (
  select n.nspname as schema_name,
         c.relname as table_name,
         pg_size_pretty(pg_total_relation_size(c.oid)) as total_size,
         pg_total_relation_size(c.oid)::bigint as total_bytes,
         coalesce(c.reltuples::bigint,0)::bigint as row_estimate
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname not in ('pg_catalog','information_schema')
    and c.relkind in ('r','p','m')
  order by pg_total_relation_size(c.oid) desc
  limit 6
),
maintenance as (
  select schemaname,
         relname,
         n_dead_tup::bigint as dead_tuples,
         n_live_tup::bigint as live_tuples,
         coalesce(last_autovacuum::text,'never') as last_autovacuum,
         coalesce(last_autoanalyze::text,'never') as last_autoanalyze
  from pg_stat_user_tables
  order by n_dead_tup desc
  limit 6
)
select 'metric', key, value, '', '', '', '' from metrics
union all
select 'table', schema_name, table_name, total_size, total_bytes::text, row_estimate::text, '' from largest_tables
union all
select 'maintenance', schemaname, relname, dead_tuples::text, live_tuples::text, last_autovacuum, last_autoanalyze from maintenance;
"""

func parsePostgresDashboard(_ output: String) -> PGDashboardSnapshot {
    var snapshot = PGDashboardSnapshot.empty

    for line in output.lines() {
        let fields = splitFields(line)
        guard let section = fields.first else { continue }
        switch section {
        case "metric" where fields.count >= 3:
            snapshot.metrics[fields[1]] = fields[2]
        case "table" where fields.count >= 6:
            snapshot.largestTables.append(
                PGDashboardTable(
                    schema: fields[1],
                    name: fields[2],
                    size: fields[3],
                    sizeBytes: Int64(fields[4]) ?? 0,
                    rowEstimate: Int64(fields[5]) ?? 0
                )
            )
        case "maintenance" where fields.count >= 7:
            snapshot.maintenance.append(
                PGDashboardMaintenanceRow(
                    schema: fields[1],
                    name: fields[2],
                    deadTuples: Int64(fields[3]) ?? 0,
                    liveTuples: Int64(fields[4]) ?? 0,
                    lastAutovacuum: fields[5],
                    lastAutoanalyze: fields[6]
                )
            )
        default:
            continue
        }
    }

    snapshot.refreshedAt = Date()
    snapshot.rawText = postgresDashboardRawText(snapshot)
    return snapshot
}

func postgresDashboardRawText(_ snapshot: PGDashboardSnapshot) -> String {
    var lines: [String] = []
    let metricOrder = [
        "version", "database", "user", "server", "ssl", "uptime", "read_only",
        "sessions", "active_sessions", "idle_in_transaction", "longest_query",
        "locks_waiting", "database_size", "cache_hit_ratio", "max_connections"
    ]
    for key in metricOrder {
        if let value = snapshot.metrics[key] {
            lines.append("\(key): \(value)")
        }
    }

    if !snapshot.largestTables.isEmpty {
        lines.append("")
        lines.append("largest_tables:")
        for table in snapshot.largestTables {
            lines.append("  \(table.schema).\(table.name)  \(table.size)  rows~\(formatPostgresDashboardCount(table.rowEstimate))")
        }
    }

    if !snapshot.maintenance.isEmpty {
        lines.append("")
        lines.append("maintenance:")
        for row in snapshot.maintenance {
            lines.append("  \(row.schema).\(row.name)  dead=\(formatPostgresDashboardCount(row.deadTuples)) live=\(formatPostgresDashboardCount(row.liveTuples)) autovacuum=\(row.lastAutovacuum)")
        }
    }

    return lines.joined(separator: "\n")
}

func formatPostgresDashboardCount(_ value: Int64) -> String {
    value.formatted()
}

func postgresDashboardVersionShort(_ snapshot: PGDashboardSnapshot) -> String {
    let value = snapshot.value("version")
    let parts = value.split(separator: " ")
    if parts.count >= 2, parts[0] == "PostgreSQL" {
        return String(parts[1])
    }
    return value
}

func compactPostgresDashboardInterval(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ")
    if parts.count >= 3, let days = Int(parts[0]), parts[1].hasPrefix("day") {
        let hours = parts[2].split(separator: ":").first.map(String.init) ?? "0"
        return "\(days)d \(hours)h"
    }
    return String(trimmed.split(separator: ".").first ?? "-")
}

func postgresDashboardLockColor(_ snapshot: PGDashboardSnapshot) -> Color {
    postgresDashboardIntMetric(snapshot, "locks_waiting") > 0 ? .red : .green
}

func postgresDashboardCacheHitText(_ snapshot: PGDashboardSnapshot) -> String {
    guard let ratio = postgresDashboardDoubleMetric(snapshot, "cache_hit_ratio") else {
        return snapshot.value("cache_hit_ratio")
    }
    return String(format: "%.2f%%", ratio)
}

func postgresDashboardCacheHitColor(_ snapshot: PGDashboardSnapshot) -> Color {
    guard let ratio = postgresDashboardDoubleMetric(snapshot, "cache_hit_ratio") else { return .secondary }
    if ratio < 90 { return .red }
    if ratio < 95 { return .orange }
    return .green
}

func postgresDashboardReadOnlyColor(_ snapshot: PGDashboardSnapshot) -> Color {
    snapshot.value("read_only").lowercased() == "on" ? .orange : .green
}

func postgresDashboardSSLColor(_ snapshot: PGDashboardSnapshot) -> Color {
    snapshot.value("ssl").lowercased() == "on" ? .green : .orange
}

func postgresDashboardIntMetric(_ snapshot: PGDashboardSnapshot, _ key: String) -> Int {
    Int(snapshot.value(key)) ?? 0
}

func postgresDashboardDoubleMetric(_ snapshot: PGDashboardSnapshot, _ key: String) -> Double? {
    Double(snapshot.value(key))
}

func sanitizePostgresCommandOutput(_ output: String) -> (output: String, warnings: [String]) {
    var body: [String] = []
    var warnings: [String] = []
    for line in output.lines() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("could not change directory to ") {
            warnings.append(trimmed)
        } else {
            body.append(line)
        }
    }
    return (body.joined(separator: "\n"), warnings)
}

enum PGVacuumScope: String, CaseIterable, Identifiable {
    case userTables = "User"
    case needsAttention = "Attention"
    case highDead = "High dead"
    case neverAnalyzed = "Never analyzed"
    case currentSchema = "Current"
    case systemTables = "System"

    var id: String { rawValue }
}

struct PGVacuumRow: Identifiable, Hashable {
    let schema: String
    let name: String
    let deadTuples: Int64
    let liveTuples: Int64
    let lastAutovacuum: String
    let lastAutoanalyze: String
    let lastAutovacuumDate: Date?
    let lastAutoanalyzeDate: Date?
    let vacuumCount: Int64
    let autovacuumCount: Int64
    let analyzeCount: Int64
    let autoanalyzeCount: Int64

    var id: String { "\(schema).\(name)" }

    var isSystemTable: Bool {
        schema == "pg_catalog"
            || schema == "information_schema"
            || schema.hasPrefix("pg_toast")
            || schema.hasPrefix("pg_temp")
    }

    var totalTuples: Int64 {
        max(0, deadTuples) + max(0, liveTuples)
    }

    var deadPercent: Double {
        guard totalTuples > 0 else { return 0 }
        return (Double(deadTuples) / Double(totalTuples)) * 100
    }

    var neverAnalyzed: Bool {
        lastAutoanalyzeDate == nil && lastAutoanalyze.lowercased() == "never"
    }

    var needsVacuum: Bool {
        deadTuples >= 1_000_000
            || (deadTuples >= 50_000 && deadPercent >= 5)
            || (deadTuples >= 1_000 && deadPercent >= 20)
    }

    var highDeadTuples: Bool {
        deadTuples >= 100_000 || (deadTuples > 0 && deadPercent >= 10)
    }

    var staleAnalyze: Bool {
        guard liveTuples > 0, let lastAutoanalyzeDate else { return false }
        return Date().timeIntervalSince(lastAutoanalyzeDate) > 7 * 24 * 60 * 60
    }

    var statusTitle: String {
        if needsVacuum { return "Needs vacuum" }
        if neverAnalyzed { return "Never analyzed" }
        if staleAnalyze { return "Stale analyze" }
        return "Healthy"
    }

    var statusRank: Int {
        if needsVacuum { return 0 }
        if neverAnalyzed { return 1 }
        if staleAnalyze { return 2 }
        return 3
    }
}

struct PGSlowQuery: Identifiable, Hashable {
    let id: String
    let query: String
    let calls: Int64
    let totalMs: Double
    let meanMs: Double
    let maxMs: Double
    let rows: Int64

    var totalMsText: String { formatPostgresMilliseconds(totalMs) }
    var meanMsText: String { formatPostgresMilliseconds(meanMs) }
    var maxMsText: String { formatPostgresMilliseconds(maxMs) }
}

struct PGReplicationSnapshot {
    var role: String
    var database: String
    var replicas: [PGReplicaRow]
    var slots: [PGReplicationSlot]
    var rawText: String
    var refreshedAt: Date?

    static let empty = PGReplicationSnapshot(
        role: "-",
        database: "-",
        replicas: [],
        slots: [],
        rawText: "",
        refreshedAt: nil
    )
}

struct PGReplicaRow: Identifiable, Hashable {
    let id: String
    let user: String
    let application: String
    let client: String
    let state: String
    let syncState: String
    let sentLsn: String
    let writeLsn: String
    let flushLsn: String
    let replayLsn: String
    let writeLag: String
    let flushLag: String
    let replayLag: String
}

struct PGReplicationSlot: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let database: String
    let active: String
    let plugin: String
    let restartLsn: String
    let confirmedFlushLsn: String
}

struct PGSession: Identifiable, Hashable {
    let pid: String
    let user: String
    let app: String
    let client: String
    let state: String
    let wait: String
    let age: String
    let query: String

    var id: String { pid }
}

struct PGTableInfo: Identifiable, Hashable {
    let schema: String
    let name: String
    let kind: String
    let size: String
    let sizeBytes: Int64
    let estimate: String
    let estimateCount: Int64

    var id: String { "\(schema).\(name)" }
}

