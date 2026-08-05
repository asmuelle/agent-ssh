import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension SystemMonitorView {
    // MARK: - Polling

    func pollLoop() async {
        // Drop the previous connection's history and any sticky error /
        // unsupported flag only when this view is retargeted to a different
        // connection. When it merely becomes inactive and active again, keep
        // its chart history as part of the tab's preserved workspace state.
        if lastConnectionId != connectionId {
            history.removeAll()
            unsupportedOs = nil
            error = nil
            lastConnectionId = connectionId
        }

        guard let connectionId else { return }
        while !Task.isCancelled {
            await fetchOnce(connectionId: connectionId)
            // If we know the host is unsupported, stop polling — the
            // result won't change without a reconnect, and the timer
            // would just churn on the same uname/parser.
            if unsupportedOs != nil { return }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    func ufwPollLoop(connectionId: String) async {
        await fetchUFWStatus(connectionId: connectionId)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.ufwPollInterval)
            await fetchUFWStatus(connectionId: connectionId)
        }
    }

    func hygienePollLoop(connectionId: String) async {
        await fetchHygiene(connectionId: connectionId)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.hygienePollInterval)
            await fetchHygiene(connectionId: connectionId)
        }
    }

    /// One combined command per tick — three problem sources, one SSH
    /// round-trip. Each section degrades to empty output when the tool
    /// is missing or permission is denied; that's "no findings", not
    /// an error, so hosts without docker or journald never nag.
    func fetchHygiene(connectionId: String) async {
        defer { publishDashboardHealthSnapshot() }

        let separator = "__AGENT_SSH_HYGIENE_SEP__"
        let script = """
        systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null | head -5
        echo \(separator)
        if command -v docker >/dev/null 2>&1; then
          docker ps --filter health=unhealthy --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -5
          docker ps --filter status=restarting --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -5
        fi
        echo \(separator)
        journalctl -p warning --since '-15 min' --no-pager -q -n 200 2>/dev/null
        """

        guard let result = try? await RemoteCommandRunner.runShell(
            connectionId: connectionId,
            script: script
        ) else {
            // Transient transport failure: keep the previous snapshot
            // rather than flapping issues off and back on.
            return
        }

        hygiene = Self.parseHygieneOutput(result.output, separator: separator)
    }

    /// Split on the separator and parse each section. Static and pure
    /// so it can be unit-tested without a connection.
    static func parseHygieneOutput(_ output: String, separator: String) -> HygieneSnapshot {
        let sections = output.components(separatedBy: separator)
        let failedSection = sections.indices.contains(0) ? sections[0] : ""
        let dockerSection = sections.indices.contains(1) ? sections[1] : ""
        let journalSection = sections.indices.contains(2) ? sections[2] : ""

        // `systemctl list-units --plain --no-legend`: unit name is the
        // first column; ● markers are already suppressed by --plain.
        let failedUnits = failedSection
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let unit = line.trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: \.isWhitespace)
                    .first
                    .map(String.init)
                guard let unit, unit.contains(".") else { return nil }
                return unit
            }

        var seenContainers = Set<String>()
        let dockerProblems = dockerSection
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard let name = parts.first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
                      !name.isEmpty,
                      seenContainers.insert(name).inserted
                else { return nil }
                let status = parts.count > 1
                    ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                    : ""
                return status.isEmpty ? name : "\(name) (\(status))"
            }

        let journalLines = journalSection
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let counts = JournalIssueClassifier.counts(in: journalLines)

        return HygieneSnapshot(
            failedUnits: failedUnits,
            dockerProblems: dockerProblems,
            journalErrors: counts.errors,
            journalWarnings: counts.warnings
        )
    }

    /// One-shot probe for distro / kernel / arch. We only re-run on
    /// connection change — host identity doesn't shift between polls,
    /// and kernel upgrades require a reconnect to take effect anyway.
    func loadOsInfo() async {
        guard let connectionId else { return }
        let script = """
        pretty=""
        if [ -r /etc/os-release ]; then
          pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:+$NAME ${VERSION:-}}}")
        fi
        if [ -z "$pretty" ] && command -v sw_vers >/dev/null 2>&1; then
          pretty="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
        fi
        if [ -z "$pretty" ] && command -v lsb_release >/dev/null 2>&1; then
          pretty=$(lsb_release -ds 2>/dev/null)
        fi
        if [ -z "$pretty" ]; then
          pretty=$(uname -s 2>/dev/null)
        fi
        kernel=$(uname -sr 2>/dev/null)
        arch=$(uname -m 2>/dev/null)
        printf '%s\\n%s\\n%s\\n' "${pretty:-Unknown}" "${kernel:-}" "${arch:-}"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: script
            )
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let parts = [
                lines.indices.contains(0) ? lines[0] : "",
                lines.indices.contains(1) ? lines[1] : "",
                lines.indices.contains(2) ? lines[2] : "",
            ].filter { !$0.isEmpty }
            osInfo = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } catch {
            osInfo = nil
        }
    }

    func fetchUFWStatus(connectionId: String) async {
        defer { publishDashboardHealthSnapshot() }

        let script = """
        if command -v ufw >/dev/null 2>&1; then
          sudo -n ufw status numbered 2>&1
        else
          echo \(ufwUnavailableMarker)
        fi
        """

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: script
            )
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !result.succeeded {
                ufwSummary = UFWProtectionSummary(
                    level: .unknown,
                    statusText: "Unable to read UFW status",
                    extraOpenRules: [],
                    error: "Remote command failed with exit code \(result.exitCode)."
                )
            } else {
                ufwSummary = summarizeUFWStatusOutput(result.output, sshPort: sshPort)
            }
        } catch {
            ufwSummary = UFWProtectionSummary(
                level: .unknown,
                statusText: "Unable to read UFW status",
                extraOpenRules: [],
                error: friendlyUFWError(error.localizedDescription)
            )
        }
    }

    func friendlyUFWError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required")
            || (lower.contains("sudo") && lower.contains("password")) {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw status, or run the command manually in the terminal."
        }
        return message
    }

    /// Append a sample, capping the buffer to `maxHistory`. Memory %
    /// is derived once here so the chart's series lookup stays cheap.
    func recordSample(_ s: FfiSystemStats) {
        let memoryPct = s.memoryTotal > 0
            ? Double(s.memoryUsed) / Double(s.memoryTotal) * 100
            : 0
        history.append(StatSample(
            timestamp: Date(),
            cpuPercent: s.cpuPercent,
            memoryPercent: memoryPct
        ))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    func fetchOnce(connectionId: String) async {
        defer { publishDashboardHealthSnapshot() }

        do {
            let s = try await BridgeManager.shared.getSystemStats(connectionId: connectionId)
            stats = s
            error = nil
            unsupportedOs = nil
            recordSample(s)
        } catch let err as MonitorError {
            switch err {
            case .Unsupported(let os):
                // The Rust side detected the OS via `uname -s` and
                // doesn't have parsers for it. Surface the kernel
                // name so the user knows whether to file a request.
                unsupportedOs = os
                error = nil
            case .ParseError(let detail):
                // Output didn't match the expected shape — usually
                // a transient command timeout or a sysctl that's
                // missing on a stripped-down host. Show the detail
                // and let the next poll retry.
                error = "Couldn't parse host stats: \(detail)"
            case .NotConnected:
                error = "Not connected to this host."
            case .Other(let detail):
                error = detail
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Formatting

    func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
