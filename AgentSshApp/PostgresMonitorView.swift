import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct PostgresMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    enum Mode: String, CaseIterable {
        case dashboard = "Dashboard"
        case sessions = "Sessions"
        case locks = "Locks"
        case query = "Query"
        case schema = "Schema"
        case explain = "Explain"
        case slow = "Slow"
        case replication = "Replication"
        case vacuum = "Vacuum"
        case backup = "Backup"
    }

    @EnvironmentObject var transfers: TransferQueueStore
    @State var settings = PostgresSettings()
    @State var mode: Mode = .dashboard
    @State var dashboard = PGDashboardSnapshot.empty
    @State var showsConnectionSettings = false
    @State var showsRawDashboard = false
    @State var sessions: [PGSession] = []
    @State var selectedPid: String?
    @State var locks: String = ""
    @State var queryText: String = "select now(), current_database(), current_user;"
    @State var queryResult = SQLResult(columns: [], rows: [])
    @State var queryFilter = ""
    @State var queryWarnings: [String] = []
    @State var queryError: String?
    @State var queryStartedAt: Date?
    @State var queryLastDuration: TimeInterval?
    @State var queryIsRunning = false
    @State var schemaRows: [PGTableInfo] = []
    @State var selectedTableId: String?
    @State var schemaSortOrder: [KeyPathComparator<PGTableInfo>] = [
        .init(\.schema),
        .init(\.name)
    ]
    @State var explainText: String = ""
    @State var explainWarnings: [String] = []
    @State var explainError: String?
    @State var explainStartedAt: Date?
    @State var explainLastDuration: TimeInterval?
    @State var explainIsRunning = false
    @State var slowRows: [PGSlowQuery] = []
    @State var slowFilter = ""
    @State var slowWarnings: [String] = []
    @State var slowError: String?
    @State var slowDiagnostics = ""
    @State var slowSortOrder: [KeyPathComparator<PGSlowQuery>] = [
        .init(\.totalMs, order: .reverse),
        .init(\.meanMs, order: .reverse)
    ]
    @State var replicationSnapshot = PGReplicationSnapshot.empty
    @State var replicationWarnings: [String] = []
    @State var replicationError: String?
    @State var replicationReplicaSortOrder: [KeyPathComparator<PGReplicaRow>] = [
        .init(\.state),
        .init(\.user)
    ]
    @State var replicationSlotSortOrder: [KeyPathComparator<PGReplicationSlot>] = [
        .init(\.name)
    ]
    @State var vacuumRows: [PGVacuumRow] = []
    @State var vacuumWarnings: [String] = []
    @State var vacuumRefreshedAt: Date?
    @State var vacuumCurrentSchema: String = "public"
    @State var vacuumScope: PGVacuumScope = .userTables
    @State var selectedVacuumTableId: String?
    @State var vacuumSortOrder: [KeyPathComparator<PGVacuumRow>] = [
        .init(\.statusRank),
        .init(\.deadTuples, order: .reverse),
        .init(\.schema),
        .init(\.name)
    ]
    @State var backupPath: String = "/tmp/mc-ssh-postgres.dump"
    @State var search = ""
    @State var error: String?
    @State var loading = false
    @State var pendingBackendAction: BackendAction?
    @State var pendingVacuumAction: VacuumAction?
    @State var maintenanceOperation: RemoteOperationFeedback?
    @State var maintenanceOperationOutput: RemoteOperationFeedback?

    struct BackendAction: Identifiable {
        let id = UUID()
        let function: String
        let pid: String
    }

    struct VacuumAction: Identifiable {
        let id = UUID()
        let title: String
        let sql: String
        let command: String
        let tableId: String
        let destructive: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionControls
            Divider()
            if let maintenanceOperation {
                RemoteOperationBanner(
                    operation: maintenanceOperation,
                    onShowOutput: { maintenanceOperationOutput = maintenanceOperation },
                    onDismiss: { dismissMaintenanceOperation(maintenanceOperation.id) }
                )
                Divider()
            }
            if connectionId == nil {
                placeholderView(icon: "network.slash", title: "No connection", message: "Open an SSH workspace to inspect PostgreSQL.")
            } else if let error, !usesLocalPostgresError {
                placeholderView(icon: "exclamationmark.triangle", title: "PostgreSQL unavailable", message: error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue)") {
            await refresh()
        }
        .onChange(of: search) { _ in
            if mode == .vacuum {
                ensureVisibleVacuumSelection()
            }
        }
        .onChange(of: vacuumScope) { _ in
            ensureVisibleVacuumSelection()
        }
        .confirmationDialog(
            "Confirm backend action",
            isPresented: Binding(
                get: { pendingBackendAction != nil },
                set: { if !$0 { pendingBackendAction = nil } }
            ),
            presenting: pendingBackendAction
        ) { action in
            Button("\(action.function) \(action.pid)", role: action.function.contains("terminate") ? .destructive : nil) {
                Task { await runBackendAction(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("This executes SELECT \(action.function)(\(action.pid)) on \(settings.database).")
        }
        .confirmationDialog(
            "Confirm maintenance action",
            isPresented: Binding(
                get: { pendingVacuumAction != nil },
                set: { if !$0 { pendingVacuumAction = nil } }
            ),
            presenting: pendingVacuumAction
        ) { action in
            Button(action.title, role: action.destructive ? .destructive : nil) {
                Task { await runVacuumAction(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.destructive
                ? "\(action.sql)\n\nVACUUM FULL rewrites the table and can hold stronger locks while it runs."
                : action.sql)
        }
        .sheet(item: $maintenanceOperationOutput) { operation in
            RemoteOperationOutputSheet(operation: operation)
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 660)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var connectionControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(connectionSummary, systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(osUserSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsConnectionSettings.toggle()
                    }
                } label: {
                    Label("Connection", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer(minLength: 12)

                if showsPostgresModeFilter {
                    TextField("Filter", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showsConnectionSettings {
                Divider()
                connectionSettingsForm
            }
        }
    }

    var showsPostgresModeFilter: Bool {
        mode == .schema || mode == .vacuum
    }

    var usesLocalPostgresError: Bool {
        mode == .query || mode == .explain || mode == .slow || mode == .replication
    }

    var connectionSummary: String {
        let database = settings.database.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settings.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = host.isEmpty
            ? connectionLabel
            : "\(host)\(port.isEmpty ? "" : ":\(port)")"
        return "\(database.isEmpty ? "postgres" : database) on \(target)"
    }

    var osUserSummary: String {
        guard settings.runAsPostgresUser else { return "current OS user" }
        let user = settings.osUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return "as \(user.isEmpty ? "postgres" : user)"
    }

    var connectionSettingsForm: some View {
        HStack(spacing: 8) {
            TextField("Database", text: $settings.database)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            TextField("Host", text: $settings.host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            TextField("Port", text: $settings.port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            TextField("User", text: $settings.user)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Toggle("OS user", isOn: $settings.runAsPostgresUser)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Run psql/pg_dump as the selected OS account using sudo -n or su")
            TextField("OS user", text: $settings.osUser)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
                .disabled(!settings.runAsPostgresUser)
            TextField("Extra psql args", text: $settings.extraArgs)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .dashboard:
            postgresDashboard
        case .sessions:
            sessionsView
        case .locks:
            logText(locks)
        case .query:
            queryRunner
        case .schema:
            schemaBrowser
        case .explain:
            explainPane
        case .slow:
            slowPane
        case .replication:
            replicationPane
        case .vacuum:
            vacuumPane
        case .backup:
            backupPane
        }
    }

    var postgresDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Overview")
                        .font(.headline)
                    if let refreshedAt = dashboard.refreshedAt {
                        Text("Updated \(DateFormatter.localizedString(from: refreshedAt, dateStyle: .none, timeStyle: .medium))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy Raw") {
                        RemoteCommandRunner.copy(dashboard.rawText)
                    }
                    .disabled(dashboard.rawText.isEmpty)
                }

                LazyVGrid(columns: dashboardMetricColumns, alignment: .leading, spacing: 10) {
                    dashboardMetricTile(
                        title: "Version",
                        value: postgresVersionShort,
                        subtitle: dashboard.value("database"),
                        systemImage: "server.rack",
                        color: .accentColor
                    )
                    dashboardMetricTile(
                        title: "Uptime",
                        value: compactPostgresInterval(dashboard.value("uptime")),
                        subtitle: dashboard.value("server"),
                        systemImage: "clock",
                        color: .green
                    )
                    dashboardMetricTile(
                        title: "DB Size",
                        value: dashboard.value("database_size"),
                        subtitle: "Open schema sorted by size",
                        systemImage: "externaldrive",
                        color: .blue
                    ) {
                        openSchemaSortedBySize()
                    }
                    dashboardMetricTile(
                        title: "Sessions",
                        value: dashboard.value("sessions"),
                        subtitle: "\(dashboard.value("active_sessions")) active, \(dashboard.value("idle_in_transaction")) idle in tx",
                        systemImage: "person.2",
                        color: .teal
                    ) {
                        mode = .sessions
                    }
                    dashboardMetricTile(
                        title: "Waiting Locks",
                        value: dashboard.value("locks_waiting"),
                        subtitle: lockHealthText,
                        systemImage: "lock.trianglebadge.exclamationmark",
                        color: lockHealthColor
                    ) {
                        mode = .locks
                    }
                    dashboardMetricTile(
                        title: "Cache Hit",
                        value: cacheHitText,
                        subtitle: cacheHitHealthText,
                        systemImage: "memorychip",
                        color: cacheHitColor
                    )
                    dashboardMetricTile(
                        title: "Read Only",
                        value: dashboard.value("read_only"),
                        subtitle: dashboard.value("user"),
                        systemImage: "lock",
                        color: readOnlyColor
                    )
                    dashboardMetricTile(
                        title: "SSL",
                        value: dashboard.value("ssl"),
                        subtitle: sslHealthText,
                        systemImage: "checkmark.shield",
                        color: sslHealthColor
                    )
                }

                LazyVGrid(columns: dashboardPanelColumns, alignment: .leading, spacing: 10) {
                    largestTablesPanel
                    maintenancePanel
                }

                DisclosureGroup("Raw summary", isExpanded: $showsRawDashboard) {
                    HighlightedRawOutputText(value: dashboard.rawText.isEmpty ? "-" : dashboard.rawText)
                        .background(
                            Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .font(.caption.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var dashboardMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)]
    }

    var dashboardPanelColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 320), spacing: 10, alignment: .top)]
    }

    @ViewBuilder
    func dashboardMetricTile(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        color: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        if let action {
            Button(action: action) {
                dashboardMetricTileContent(
                    title: title,
                    value: value,
                    subtitle: subtitle,
                    systemImage: systemImage,
                    color: color
                )
            }
            .buttonStyle(.plain)
        } else {
            dashboardMetricTileContent(
                title: title,
                value: value,
                subtitle: subtitle,
                systemImage: systemImage,
                color: color
            )
        }
    }

    func dashboardMetricTileContent(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .frame(width: 16, height: 16)
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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    var largestTablesPanel: some View {
        dashboardPanel(title: "Largest Tables", actionTitle: "Open Schema") {
            openSchemaSortedBySize()
        } content: {
            if dashboard.largestTables.isEmpty {
                dashboardEmptyLine("No user tables returned.")
            } else {
                ForEach(dashboard.largestTables) { table in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(table.schema).\(table.name)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(formatCount(table.rowEstimate)) estimated rows")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(table.size)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    var maintenancePanel: some View {
        dashboardPanel(title: "Maintenance", actionTitle: "Open Vacuum") {
            mode = .vacuum
        } content: {
            if dashboard.maintenance.isEmpty {
                dashboardEmptyLine("No user table stats returned.")
            } else {
                ForEach(dashboard.maintenance) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.schema).\(row.name)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("auto vacuum \(row.lastAutovacuum), analyze \(row.lastAutoanalyze)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text("\(formatCount(row.deadTuples)) dead")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(row.deadTuples > 0 ? .orange : .secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    func dashboardPanel<Content: View>(
        title: String,
        actionTitle: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func dashboardEmptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    var postgresVersionShort: String {
        let value = dashboard.value("version")
        let parts = value.split(separator: " ")
        if parts.count >= 2, parts[0] == "PostgreSQL" {
            return String(parts[1])
        }
        return value
    }

    var lockHealthColor: Color {
        intMetric("locks_waiting") > 0 ? .red : .green
    }

    var lockHealthText: String {
        intMetric("locks_waiting") > 0 ? "Investigate blockers" : "No waits"
    }

    var cacheHitText: String {
        guard let ratio = doubleMetric("cache_hit_ratio") else {
            return dashboard.value("cache_hit_ratio")
        }
        return String(format: "%.2f%%", ratio)
    }

    var cacheHitColor: Color {
        guard let ratio = doubleMetric("cache_hit_ratio") else { return .secondary }
        if ratio < 90 { return .red }
        if ratio < 95 { return .orange }
        return .green
    }

    var cacheHitHealthText: String {
        guard let ratio = doubleMetric("cache_hit_ratio") else { return "No cache sample" }
        if ratio < 90 { return "Poor buffer locality" }
        if ratio < 95 { return "Below target" }
        return "Healthy"
    }

    var readOnlyColor: Color {
        dashboard.value("read_only").lowercased() == "on" ? .orange : .green
    }

    var sslHealthColor: Color {
        dashboard.value("ssl").lowercased() == "on" ? .green : .orange
    }

    var sslHealthText: String {
        dashboard.value("ssl").lowercased() == "on" ? "Enabled" : "Disabled"
    }

    func intMetric(_ key: String) -> Int {
        Int(dashboard.value(key)) ?? 0
    }

    func doubleMetric(_ key: String) -> Double? {
        Double(dashboard.value(key))
    }

    func compactPostgresInterval(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        if parts.count >= 3, let days = Int(parts[0]), parts[1].hasPrefix("day") {
            let hours = parts[2].split(separator: ":").first.map(String.init) ?? "0"
            return "\(days)d \(hours)h"
        }
        return String(trimmed.split(separator: ".").first ?? "-")
    }

    func parsePostgresTimestamp(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "never" else { return nil }

        var normalized = trimmed
        if let separator = normalized.firstIndex(of: " ") {
            normalized.replaceSubrange(separator...separator, with: "T")
        }
        normalized = normalizePostgresTimezone(normalized)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: normalized) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    func normalizePostgresTimezone(_ value: String) -> String {
        if value.count >= 3 {
            let signIndex = value.index(value.endIndex, offsetBy: -3)
            let sign = value[signIndex]
            let hour = value[value.index(after: signIndex)..<value.endIndex]
            if (sign == "+" || sign == "-") && hour.allSatisfy(\.isNumber) {
                return String(value[..<signIndex]) + "\(sign)\(hour):00"
            }
        }

        if value.count >= 5 {
            let signIndex = value.index(value.endIndex, offsetBy: -5)
            let sign = value[signIndex]
            let offset = value[value.index(after: signIndex)..<value.endIndex]
            if (sign == "+" || sign == "-") && offset.allSatisfy(\.isNumber) {
                let hourEnd = offset.index(offset.startIndex, offsetBy: 2)
                return String(value[..<signIndex]) + "\(sign)\(offset[..<hourEnd]):\(offset[hourEnd...])"
            }
        }

        return value
    }

    func compactPostgresTimestamp(_ value: String, date: Date?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "never" {
            return "Never"
        }
        guard let date else { return trimmed }

        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3_600)
        if hours < 48 { return "\(hours)h ago" }
        let days = Int(seconds / 86_400)
        if days < 90 { return "\(days)d ago" }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    }

    func formatCount(_ value: Int64) -> String {
        value.formatted()
    }

    func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    func openSchemaSortedBySize() {
        schemaSortOrder = [.init(\.sizeBytes, order: .reverse)]
        mode = .schema
    }

}
