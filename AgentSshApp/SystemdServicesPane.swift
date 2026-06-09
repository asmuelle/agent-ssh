import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct MonitoredSystemdServicesPane: View {
    let connectionId: String?
    let profileId: String?
    var isActive: Bool = true
    var onSelectService: (String) -> Void = { _ in }
    var onOpenSystemd: () -> Void = {}
    var onOpenDocker: () -> Void = {}
    var onOpenPostgres: () -> Void = {}

    @ObservedObject var connectionStore = ConnectionStoreManager.shared
    @State var statuses: [MonitoredSystemdServiceStatus] = []
    @State var error: String?
    @State var loading = false
    @State var hasDocker = false
    @State var hasPostgres = false
    @State var postgresDashboard = PGDashboardSnapshot.empty
    @State var postgresDashboardError: String?
    @State var postgresDashboardLoading = false

    static let pollInterval: UInt64 = 5_000_000_000
    static let detectInterval: UInt64 = 30_000_000_000
    static let postgresDashboardInterval: UInt64 = 30_000_000_000
    static let unavailableMarker = "__MIDNIGHT_SSH_SYSTEMD_UNAVAILABLE__"

    var serviceNames: [String] {
        connectionStore.monitoredSystemdServices(profileId: profileId)
    }

    var pollKey: String {
        "\(connectionId ?? "none"):\(profileId ?? "none"):\(isActive):\(serviceNames.joined(separator: ","))"
    }

    var detectKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    var postgresDashboardKey: String {
        "\(connectionId ?? "none"):\(isActive):\(hasPostgres)"
    }

    var rows: [MonitoredSystemdServiceStatus] {
        let byName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        return serviceNames.map {
            byName[$0] ?? MonitoredSystemdServiceStatus(
                name: $0,
                active: "unknown",
                sub: "unknown",
                uptimeSeconds: nil,
                journalIssueCounts: .zero
            )
        }
    }

    var body: some View {
        if connectionId != nil {
            VStack(alignment: .leading, spacing: 8) {
                if hasDocker {
                    shortcutHeader(
                        icon: "shippingbox",
                        label: "Docker",
                        help: "Open Docker inspector",
                        action: onOpenDocker
                    )
                }

                if hasPostgres {
                    postgresShortcutHeader
                }

                shortcutHeader(
                    icon: "switch.2",
                    label: "systemd",
                    help: "Open systemd inspector",
                    showsProgress: loading,
                    action: onOpenSystemd
                )

                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                if !serviceNames.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(rows) { service in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(service.indicatorColor)
                                    .frame(width: 8, height: 8)
                                Text(service.name)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if service.journalIssueCounts.hasIssues {
                                    JournalIssueBadges(
                                        counts: service.journalIssueCounts,
                                        compact: true
                                    )
                                }
                                Text(formatServiceUptime(service.uptimeSeconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectService(service.name)
                            }
                            .help(serviceHelp(service))
                        }
                    }
                }
            }
            .task(id: pollKey) {
                guard isActive, connectionId != nil else { return }
                guard !serviceNames.isEmpty else {
                    publishSystemdWidgetSnapshots(statuses: [], error: nil)
                    return
                }
                await pollLoop()
            }
            .task(id: detectKey) {
                guard isActive, connectionId != nil else { return }
                await detectLoop()
            }
            .task(id: postgresDashboardKey) {
                guard isActive, connectionId != nil, hasPostgres else {
                    postgresDashboard = .empty
                    postgresDashboardError = nil
                    return
                }
                await postgresDashboardLoop()
            }
        }
    }

    @ViewBuilder
    func shortcutHeader(
        icon: String,
        label: String,
        help: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func serviceHelp(_ service: MonitoredSystemdServiceStatus) -> String {
        var parts = ["\(service.name): \(service.active) \(service.sub)"]
        if service.journalIssueCounts.errors > 0 {
            parts.append("\(service.journalIssueCounts.errors) journal errors")
        }
        if service.journalIssueCounts.warnings > 0 {
            parts.append("\(service.journalIssueCounts.warnings) journal warnings")
        }
        return parts.joined(separator: " - ")
    }

    var postgresShortcutHeader: some View {
        Button(action: onOpenPostgres) {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(.secondary)
                postgresDashboardPreview
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if postgresDashboardLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(postgresDashboardHelp)
        .accessibilityLabel("PostgreSQL")
    }

    @ViewBuilder
    var postgresDashboardPreview: some View {
        let items = postgresDashboardPreviewItems
        if !items.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        postgresDashboardPreviewChip(item)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Array(items.prefix(4))) { item in
                        postgresDashboardPreviewChip(item)
                    }
                }
                Text(postgresDashboardCompactLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let postgresDashboardError {
            Text(shortPostgresDashboardError(postgresDashboardError))
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    func postgresDashboardPreviewChip(_ item: PostgresDashboardPreviewItem) -> some View {
        HStack(spacing: 3) {
            Text(item.label)
                .foregroundStyle(.secondary)
            Text(item.value)
                .foregroundStyle(item.color)
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(item.color.opacity(0.10), in: Capsule())
    }

    func pollLoop() async {
        await refreshStatuses()
        while !Task.isCancelled && isActive && !serviceNames.isEmpty {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await refreshStatuses()
        }
    }

    func refreshStatuses() async {
        guard let connectionId, !serviceNames.isEmpty else {
            statuses = []
            error = nil
            publishSystemdWidgetSnapshots(statuses: [], error: nil)
            return
        }

        loading = true
        defer { loading = false }

        let units = serviceNames.map(RemoteCommandRunner.shellQuote).joined(separator: " ")
        let script = """
        command -v systemctl >/dev/null || { echo \(Self.unavailableMarker); exit 0; }
        now_usec=$(awk '{printf "%.0f", $1 * 1000000}' /proc/uptime 2>/dev/null || echo 0)
        for unit in \(units); do
          show=$(systemctl show "$unit" --no-pager -p ActiveState -p SubState -p ActiveEnterTimestampMonotonic 2>/dev/null || true)
          active=$(printf '%s\\n' "$show" | awk -F= '$1=="ActiveState"{print $2; exit}')
          sub=$(printf '%s\\n' "$show" | awk -F= '$1=="SubState"{print $2; exit}')
          mono=$(printf '%s\\n' "$show" | awk -F= '$1=="ActiveEnterTimestampMonotonic"{print $2; exit}')
          uptime="-"
          if [ "${active:-unknown}" = "active" ] && [ -n "$mono" ] && [ "$mono" -gt 0 ] 2>/dev/null && [ "$now_usec" -gt "$mono" ] 2>/dev/null; then
            uptime=$(( (now_usec - mono) / 1000000 ))
          fi
          journal_errors=0
          journal_warnings=0
          if command -v journalctl >/dev/null 2>&1; then
            journal_sample=$(journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>/dev/null || sudo -n journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>/dev/null || true)
            journal_counts=$(printf '%s\\n' "$journal_sample" | awk '
              {
                message=$0
                if ($1 ~ /[0-9]/ && $1 ~ /[-:]/) {
                  sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", message)
                }
                line=tolower(message)
                if (line ~ /(^|[^[:alnum:]_])(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)([^[:alnum:]_]|$)/) {
                  errors++
                } else if (line ~ /(^|[^[:alnum:]_])(warn|warning|deprecated|timeout|timed[[:space:]]*out|retry|retrying|deferred|refused|rejected)([^[:alnum:]_]|$)/) {
                  warnings++
                }
              }
              END { printf "%d %d", errors + 0, warnings + 0 }
            ')
            set -- $journal_counts
            journal_errors=${1:-0}
            journal_warnings=${2:-0}
          fi
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$unit" "${active:-unknown}" "${sub:-unknown}" "$uptime" "$journal_errors" "$journal_warnings"
        done
        """

        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            if output.lines().contains(Self.unavailableMarker) {
                statuses = []
                error = "systemd unavailable"
                publishSystemdWidgetSnapshots(statuses: [], error: "systemd unavailable")
            } else {
                statuses = parseMonitoredSystemdServiceStatuses(output)
                error = nil
                publishSystemdWidgetSnapshots(statuses: statuses, error: nil)
            }
        } catch {
            self.error = error.localizedDescription
            publishSystemdWidgetSnapshots(statuses: [], error: error.localizedDescription)
        }
    }

    func publishSystemdWidgetSnapshots(
        statuses: [MonitoredSystemdServiceStatus],
        error: String?
    ) {
        guard let prefix = widgetSnapshotPrefix else { return }
        guard !serviceNames.isEmpty else {
            WidgetMonitoringSnapshotCenter.shared.replaceSnapshots(matchingPrefix: prefix, with: [])
            return
        }

        let now = Date()
        let statusByName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        let profileName = profileId
            .flatMap { connectionStore.connection(withId: $0)?.name }
            ?? "SSH workspace"

        let snapshots = serviceNames.map { serviceName in
            let service = statusByName[serviceName]
            let active = service?.active ?? "unknown"
            let sub = service?.sub ?? "unknown"
            let state = error == nil
                ? WidgetSnapshotStateClassifier.stateForSystemdService(active: active, sub: sub)
                : .unknown
            let summary = error ?? "\(profileName): \(active) \(sub)"

            return WidgetMonitorSnapshot(
                id: "\(prefix)\(serviceName)",
                displayName: serviceName,
                kind: .custom,
                state: state,
                lastCheckedAt: now,
                lastChangedAt: now,
                summary: summary,
                detail: error,
                openURL: profileId.map { "agent-ssh://monitoring/\($0)" }
                    ?? WidgetSnapshotPresenter.monitoringOverviewURL
            )
        }

        WidgetMonitoringSnapshotCenter.shared.replaceSnapshots(matchingPrefix: prefix, with: snapshots)
    }

    var widgetSnapshotPrefix: String? {
        if let profileId {
            return "systemd:\(profileId):"
        }
        if let connectionId {
            return "systemd:\(connectionId):"
        }
        return nil
    }

    func parseMonitoredSystemdServiceStatuses(_ output: String) -> [MonitoredSystemdServiceStatus] {
        output.lines().compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return MonitoredSystemdServiceStatus(
                name: parts[0],
                active: parts[1],
                sub: parts[2],
                uptimeSeconds: UInt64(parts[3]),
                journalIssueCounts: JournalIssueCounts(
                    errors: parts.indices.contains(4) ? Int(parts[4]) ?? 0 : 0,
                    warnings: parts.indices.contains(5) ? Int(parts[5]) ?? 0 : 0
                )
            )
        }
    }

    func formatServiceUptime(_ seconds: UInt64?) -> String {
        guard let seconds else { return "-" }
        if seconds < 60 { return "\(seconds)s" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    func detectLoop() async {
        await detectAvailability()
        while !Task.isCancelled && isActive && connectionId != nil {
            try? await Task.sleep(nanoseconds: Self.detectInterval)
            await detectAvailability()
        }
    }

    func detectAvailability() async {
        guard let connectionId else { return }
        let script = """
        docker_ok=0
        if command -v docker >/dev/null 2>&1; then docker_ok=1; fi
        printf 'DOCKER=%s\\n' "$docker_ok"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: script
            )
            var docker = false
            for line in output.lines() {
                if line == "DOCKER=1" { docker = true }
            }
            hasDocker = docker
        } catch {
            // Probe failure shouldn't poison the pane — keep last-known
            // detection so a transient SSH hiccup doesn't make the icons
            // flicker away.
        }

        if let postgresAvailable = await detectPostgresAvailability(connectionId: connectionId) {
            hasPostgres = postgresAvailable
            if !postgresAvailable {
                postgresDashboard = .empty
                postgresDashboardError = nil
            }
        }
    }

    func detectPostgresAvailability(connectionId: String) async -> Bool? {
        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: PostgresSettings().queryScript("select 1;")
            )
            guard result.succeeded else { return false }
            let output = sanitizePostgresCommandOutput(result.output).output
            return output.lines().contains { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            }
        } catch {
            // Keep last-known detection when the SSH command itself fails.
            return nil
        }
    }

    func postgresDashboardLoop() async {
        await refreshPostgresDashboard()
        while !Task.isCancelled && isActive && connectionId != nil && hasPostgres {
            try? await Task.sleep(nanoseconds: Self.postgresDashboardInterval)
            await refreshPostgresDashboard()
        }
    }

    func refreshPostgresDashboard() async {
        guard let connectionId, hasPostgres else {
            postgresDashboard = .empty
            postgresDashboardError = nil
            return
        }

        postgresDashboardLoading = true
        defer { postgresDashboardLoading = false }

        do {
            let rawOutput = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: PostgresSettings().queryScript(postgresDashboardSQL)
            )
            let output = sanitizePostgresCommandOutput(rawOutput).output
            postgresDashboard = parsePostgresDashboard(output)
            postgresDashboardError = nil
        } catch {
            postgresDashboardError = error.localizedDescription
        }
    }

    var postgresDashboardPreviewItems: [PostgresDashboardPreviewItem] {
        guard !postgresDashboard.metrics.isEmpty else { return [] }
        return [
            PostgresDashboardPreviewItem(
                id: "version",
                label: "v",
                value: postgresDashboardVersionShort(postgresDashboard),
                color: .accentColor
            ),
            PostgresDashboardPreviewItem(
                id: "uptime",
                label: "up",
                value: compactPostgresDashboardInterval(postgresDashboard.value("uptime")),
                color: .green
            ),
            PostgresDashboardPreviewItem(
                id: "size",
                label: "db",
                value: postgresDashboard.value("database_size"),
                color: .blue
            ),
            PostgresDashboardPreviewItem(
                id: "sessions",
                label: "sess",
                value: postgresDashboard.value("sessions"),
                color: .teal
            ),
            PostgresDashboardPreviewItem(
                id: "locks",
                label: "locks",
                value: postgresDashboard.value("locks_waiting"),
                color: postgresDashboardLockColor(postgresDashboard)
            ),
            PostgresDashboardPreviewItem(
                id: "cache",
                label: "cache",
                value: postgresDashboardCacheHitText(postgresDashboard),
                color: postgresDashboardCacheHitColor(postgresDashboard)
            ),
            PostgresDashboardPreviewItem(
                id: "read_only",
                label: "ro",
                value: postgresDashboard.value("read_only"),
                color: postgresDashboardReadOnlyColor(postgresDashboard)
            ),
            PostgresDashboardPreviewItem(
                id: "ssl",
                label: "ssl",
                value: postgresDashboard.value("ssl"),
                color: postgresDashboardSSLColor(postgresDashboard)
            ),
        ]
    }

    var postgresDashboardCompactLine: String {
        [
            "v \(postgresDashboardVersionShort(postgresDashboard))",
            "\(postgresDashboard.value("database_size"))",
            "\(postgresDashboard.value("sessions")) sessions",
            "\(postgresDashboard.value("locks_waiting")) locks",
            "\(postgresDashboardCacheHitText(postgresDashboard)) cache",
        ].joined(separator: " · ")
    }

    var postgresDashboardHelp: String {
        var lines = ["PostgreSQL"]
        if !postgresDashboard.metrics.isEmpty {
            lines.append("Version: \(postgresDashboardVersionShort(postgresDashboard))")
            lines.append("Uptime: \(compactPostgresDashboardInterval(postgresDashboard.value("uptime")))")
            lines.append("Database size: \(postgresDashboard.value("database_size"))")
            lines.append("Sessions: \(postgresDashboard.value("sessions"))")
            lines.append("Waiting locks: \(postgresDashboard.value("locks_waiting"))")
            lines.append("Cache hit: \(postgresDashboardCacheHitText(postgresDashboard))")
            lines.append("Read only: \(postgresDashboard.value("read_only"))")
            lines.append("SSL: \(postgresDashboard.value("ssl"))")
        } else if let postgresDashboardError {
            lines.append(shortPostgresDashboardError(postgresDashboardError))
        }
        return lines.joined(separator: "\n")
    }

    func shortPostgresDashboardError(_ value: String) -> String {
        let firstLine = value.lines()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Dashboard unavailable"
        return String(firstLine.prefix(120))
    }
}

