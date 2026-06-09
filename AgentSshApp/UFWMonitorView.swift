import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct UFWMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    let sshPort: UInt16?

    enum Mode: String, CaseIterable {
        case status = "Status"
        case rules = "Rules"
        case logs = "Logs"
    }

    enum ActionFilter: String, CaseIterable {
        case all = "All"
        case allow = "Allow"
        case deny = "Deny"
        case reject = "Reject"
        case limit = "Limit"
    }

    @State var mode: Mode = .status
    @State var actionFilter: ActionFilter = .all
    @State var snapshot = UFWStatusSnapshot()
    @State var rules: [UFWRule] = []
    @State var logs: [UFWLogEntry] = []
    @State var selectedRules: Set<Int> = []
    @State var ruleSortOrder: [KeyPathComparator<UFWRule>] = [
        .init(\.number)
    ]
    @State var search = ""
    @State var loading = false
    @State var error: String?

    static let refreshInterval: UInt64 = 30_000_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(
                    icon: "network.slash",
                    title: "No connection",
                    message: "Open an SSH workspace to inspect UFW."
                )
            } else if let error {
                placeholderView(
                    icon: "exclamationmark.triangle",
                    title: "UFW unavailable",
                    message: error
                )
            } else {
                content
            }
        }
        .task(id: connectionId) {
            await refreshLoop()
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("UFW")
                .font(.subheadline.weight(.medium))
            statusBadge
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            if mode == .rules {
                Picker("", selection: $actionFilter) {
                    ForEach(ActionFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            TextField(mode == .logs ? "Filter src/dst/port" : "Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Spacer()
            Text("30s")
                .font(.caption)
                .foregroundStyle(.secondary)
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
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

    var statusBadge: some View {
        let summary = ufwProtectionSummary
        let color = ufwProtectionColor(summary)
        return Text(summary.badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
            .help(summary.helpText)
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .status:
            statusPane
        case .rules:
            rulesPane
        case .logs:
            logsPane
        }
    }

    var statusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let warning = sshLockoutWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ufwMetric("Status", snapshot.active ? "Active" : "Inactive", color: ufwProtectionColor(ufwProtectionSummary))
                    ufwMetric("Incoming", snapshot.incomingPolicy, color: policyColor(snapshot.incomingPolicy))
                    ufwMetric("Outgoing", snapshot.outgoingPolicy, color: policyColor(snapshot.outgoingPolicy))
                    ufwMetric("Forward", snapshot.routedPolicy, color: policyColor(snapshot.routedPolicy))
                    ufwMetric("IPv6", snapshot.ipv6, color: snapshot.ipv6.lowercased().contains("yes") ? .green : .secondary)
                    ufwMetric("Logging", snapshot.logging, color: .secondary)
                    ufwMetric("Rules", "\(rules.count)", color: .secondary)
                    ufwMetric("Blocked Logs", "\(logs.filter { $0.action == "BLOCK" }.count)", color: .red)
                }

                HStack(spacing: 10) {
                    topTalkersCard
                    rawStatusCard
                }
            }
            .padding(12)
        }
    }

    func ufwMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    var topTalkersCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Blocked Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let talkers = topBlockedSources
            if talkers.isEmpty {
                Text("No blocked source IPs in the sampled log window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(talkers) { item in
                    HStack {
                        monoCell(item.source)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    var rawStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raw Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { RemoteCommandRunner.copy(snapshot.rawStatus) }
                    .disabled(snapshot.rawStatus.isEmpty)
            }
            logText(snapshot.rawStatus)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    var rulesPane: some View {
        HSplitView {
            Table(filteredRules.sorted(using: ruleSortOrder), selection: $selectedRules, sortOrder: $ruleSortOrder) {
                TableColumn("#", value: \.number) { rule in
                    Text("\(rule.number)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55, max: 70)

                TableColumn("Action", value: \.action) { rule in
                    Text(rule.action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ruleColor(rule.action))
                }
                .width(min: 90, ideal: 110)

                TableColumn("Port / Proto", value: \.target) { rule in
                    monoCell(rule.target)
                }
                .width(min: 150, ideal: 220)

                TableColumn("Source", value: \.source) { rule in
                    monoCell(rule.source)
                }
                .width(min: 160, ideal: 220)

                TableColumn("Comment", value: \.comment) { rule in
                    monoCell(rule.comment, color: .secondary)
                }
            }
            .contextMenu(forSelectionType: Int.self) { selected in
                if let number = selected.first, let rule = rules.first(where: { $0.number == number }) {
                    Button("Copy Rule") { RemoteCommandRunner.copy(rule.raw) }
                    Button("Copy Delete Command") { RemoteCommandRunner.copy("sudo ufw delete \(rule.number)") }
                }
            }
            .frame(minWidth: 520)

            ruleDetailPane
                .frame(minWidth: 320)
        }
    }

    var ruleDetailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rule = selectedRule {
                HStack {
                    Text("Rule \(rule.number)")
                        .font(.headline)
                    Spacer()
                    Button("Copy") { RemoteCommandRunner.copy(rule.raw) }
                }
                HighlightedRawOutputText(value: rule.raw)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                Text("iptables Matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                logText(iptablesMatches(for: rule))
            } else {
                placeholderView(
                    icon: "list.bullet.rectangle",
                    title: "Select a rule",
                    message: "Choose a numbered UFW rule to see its raw line and likely iptables chain entries."
                )
            }
        }
        .padding(10)
    }

    var logsPane: some View {
        HSplitView {
            List(filteredLogs) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.timestamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 155, alignment: .leading)
                        Text(entry.action)
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(entry.action == "BLOCK" ? .red : .green)
                            .frame(width: 52, alignment: .leading)
                        monoCell(entry.protocolName, width: 42, color: .secondary)
                        monoCell("\(entry.source):\(entry.sourcePort)", width: 165)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        monoCell("\(entry.destination):\(entry.destinationPort)")
                    }
                    Text(highlightedRawOutput(entry.raw))
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Log Line") { RemoteCommandRunner.copy(entry.raw) }
                    Button("Copy Source IP") { RemoteCommandRunner.copy(entry.source) }
                }
            }
            .listStyle(.plain)
            .frame(minWidth: 620)

            VStack(alignment: .leading, spacing: 8) {
                Text("Top Blocked Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(topBlockedSources) { item in
                    HStack {
                        monoCell(item.source)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Sample Window")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(logs.count) parsed UFW lines from the most recent log sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .frame(minWidth: 220)
        }
    }

    func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var filteredRules: [UFWRule] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rules.filter { rule in
            let actionMatches: Bool
            switch actionFilter {
            case .all:
                actionMatches = true
            case .allow:
                actionMatches = rule.action.lowercased().contains("allow")
            case .deny:
                actionMatches = rule.action.lowercased().contains("deny")
            case .reject:
                actionMatches = rule.action.lowercased().contains("reject")
            case .limit:
                actionMatches = rule.action.lowercased().contains("limit")
            }
            guard actionMatches else { return false }
            guard !needle.isEmpty else { return true }
            return rule.target.lowercased().contains(needle)
                || rule.source.lowercased().contains(needle)
                || rule.action.lowercased().contains(needle)
                || rule.comment.lowercased().contains(needle)
                || "\(rule.number)".contains(needle)
        }
    }

    var filteredLogs: [UFWLogEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return logs }
        return logs.filter {
            $0.source.lowercased().contains(needle)
                || $0.destination.lowercased().contains(needle)
                || $0.destinationPort.contains(needle)
                || $0.sourcePort.contains(needle)
                || $0.interface.lowercased().contains(needle)
                || $0.protocolName.lowercased().contains(needle)
        }
    }

    var selectedRule: UFWRule? {
        guard let number = selectedRules.sorted().first else { return nil }
        return rules.first { $0.number == number }
    }

    var ufwProtectionSummary: UFWProtectionSummary {
        let statusText = snapshot.rawStatus.lines()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? (snapshot.active ? "Status: active" : "Status: inactive")
        return summarizeUFWStatus(
            active: snapshot.active,
            statusText: statusText,
            openRules: rules
                .filter {
                    let action = $0.action.lowercased()
                    return action.contains("allow") || action.contains("limit")
                }
                .map { UFWOpenRuleExposure(target: $0.target, source: $0.source) },
            sshPort: sshPort
        )
    }

    func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
        switch summary.level {
        case .protected:
            return .green
        case .inactive, .open:
            return .orange
        case .unknown:
            return .yellow
        case .loading, .unavailable:
            return .secondary
        }
    }

    var topBlockedSources: [UFWTopTalker] {
        var counts: [String: Int] = [:]
        for entry in logs where entry.action == "BLOCK" && !entry.source.isEmpty {
            counts[entry.source, default: 0] += 1
        }
        var rows: [UFWTopTalker] = []
        for (source, count) in counts {
            rows.append(UFWTopTalker(source: source, count: count))
        }
        rows.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.source < rhs.source : lhs.count > rhs.count
        }
        let limit = min(5, rows.count)
        guard limit > 0 else { return [] }
        return Array(rows[0..<limit])
    }

    var sshLockoutWarning: String? {
        guard snapshot.active else { return nil }
        let port = snapshot.sshServerPort ?? Int(sshPort ?? 22)
        let allowed = rules.contains { rule in
            rule.action.lowercased().contains("allow")
                && (rule.target.lowercased().contains("openssh")
                    || rule.target.contains("\(port)")
                    || rule.target.lowercased().contains("ssh"))
        }
        guard !allowed else { return nil }
        let client = snapshot.sshClientIp.isEmpty ? "the current SSH client" : snapshot.sshClientIp
        return "UFW is active, but no ALLOW rule obviously covers SSH port \(port) for \(client). Enabling or deleting rules could lock out this session."
    }

    func policyColor(_ policy: String) -> Color {
        let lower = policy.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        return .secondary
    }

    func ruleColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        if lower.contains("limit") { return .orange }
        return .secondary
    }

    func iptablesMatches(for rule: UFWRule) -> String {
        let port = firstNumber(in: rule.target)
        let lines = snapshot.iptables.lines().filter { line in
            guard let port else { return line.localizedCaseInsensitiveContains(rule.target) }
            return line.contains("--dport \(port)")
                || line.contains("--sport \(port)")
                || line.contains(" \(port) ")
                || line.localizedCaseInsensitiveContains(rule.action)
        }
        if lines.isEmpty {
            return "No obvious iptables line matched this rule. UFW's generated chains can vary by distro and backend."
        }
        return lines.joined(separator: "\n")
    }

    func firstNumber(in text: String) -> String? {
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
            await refresh()
        }
    }

    func refresh() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v ufw >/dev/null || { echo ufw not found; exit 127; }
        echo '---STATUS---'
        status_out=$(sudo -n ufw status verbose 2>&1)
        status_rc=$?
        printf '%s\\n' "$status_out"
        [ "$status_rc" -eq 0 ] || exit "$status_rc"
        echo '---NUMBERED---'
        sudo -n ufw status numbered 2>&1 || true
        echo '---IPV6---'
        sudo -n sh -c "grep -E '^IPV6=' /etc/default/ufw 2>/dev/null || true" 2>&1 || true
        echo '---SSH---'
        printf 'SSH_CLIENT=%s\\nSSH_CONNECTION=%s\\n' "$SSH_CLIENT" "$SSH_CONNECTION"
        echo '---LOGS---'
        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n tail -n 300 /var/log/ufw.log 2>&1
        else
          sudo -n journalctl -k -n 300 --no-pager 2>/dev/null | grep -E 'UFW (BLOCK|ALLOW|AUDIT)' || true
        fi
        echo '---IPTABLES---'
        sudo -n iptables -S 2>/dev/null | nl -ba | sed -n '1,240p' || true
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            parseSnapshot(output)
            error = nil
        } catch {
            self.error = sudoFriendly(error.localizedDescription)
        }
    }

    func parseSnapshot(_ output: String) {
        let status = output.section(after: "---STATUS---", before: "---NUMBERED---")
        let numbered = output.section(after: "---NUMBERED---", before: "---IPV6---")
        let ipv6 = output.section(after: "---IPV6---", before: "---SSH---")
        let ssh = output.section(after: "---SSH---", before: "---LOGS---")
        let logOutput = output.section(after: "---LOGS---", before: "---IPTABLES---")
        let iptables = output.section(after: "---IPTABLES---", before: nil)

        snapshot = UFWStatusSnapshot(
            active: status.lines().contains { $0.lowercased().hasPrefix("status: active") },
            rawStatus: status,
            numberedRules: numbered,
            ipv6: parseIPv6(ipv6),
            incomingPolicy: parsePolicy(status, key: "incoming"),
            outgoingPolicy: parsePolicy(status, key: "outgoing"),
            routedPolicy: parsePolicy(status, key: "routed"),
            logging: parseLogging(status),
            sshClientIp: parseSSHValue(ssh, key: "SSH_CLIENT").split(separator: " ").first.map(String.init) ?? "",
            sshServerPort: parseSSHServerPort(ssh),
            iptables: iptables
        )
        rules = parseRules(numbered)
        logs = parseLogs(logOutput)
        selectedRules = selectedRules.intersection(Set(rules.map(\.number)))
    }

    func parseIPv6(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("ipv6=yes") { return "yes" }
        if lower.contains("ipv6=no") { return "no" }
        return "unknown"
    }

    func parsePolicy(_ status: String, key: String) -> String {
        guard let defaultLine = status.lines().first(where: { $0.lowercased().hasPrefix("default:") }) else {
            return "-"
        }
        let pattern = #"([A-Za-z]+)\s+\(\#(key)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: defaultLine, range: NSRange(defaultLine.startIndex..., in: defaultLine)),
              let range = Range(match.range(at: 1), in: defaultLine)
        else { return "-" }
        return String(defaultLine[range]).lowercased()
    }

    func parseLogging(_ status: String) -> String {
        guard let line = status.lines().first(where: { $0.lowercased().hasPrefix("logging:") }) else {
            return "-"
        }
        return line.replacingOccurrences(of: "Logging:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseSSHValue(_ ssh: String, key: String) -> String {
        ssh.lines()
            .first { $0.hasPrefix("\(key)=") }?
            .dropFirst(key.count + 1)
            .description ?? ""
    }

    func parseSSHServerPort(_ ssh: String) -> Int? {
        let connection = parseSSHValue(ssh, key: "SSH_CONNECTION")
        let parts = connection.split(separator: " ").map(String.init)
        if parts.count >= 4, let port = Int(parts[3]) {
            return port
        }
        let client = parseSSHValue(ssh, key: "SSH_CLIENT")
        let clientParts = client.split(separator: " ").map(String.init)
        if clientParts.count >= 3, let port = Int(clientParts[2]) {
            return port
        }
        return nil
    }

    func parseRules(_ text: String) -> [UFWRule] {
        text.lines().compactMap(parseRuleLine)
    }

    func parseRuleLine(_ line: String) -> UFWRule? {
        let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW(?:\s+IN|\s+OUT)?|DENY(?:\s+IN|\s+OUT)?|REJECT(?:\s+IN|\s+OUT)?|LIMIT(?:\s+IN|\s+OUT)?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 5,
              let numberRange = Range(match.range(at: 1), in: line),
              let targetRange = Range(match.range(at: 2), in: line),
              let actionRange = Range(match.range(at: 3), in: line),
              let sourceRange = Range(match.range(at: 4), in: line),
              let number = Int(line[numberRange].trimmingCharacters(in: .whitespaces))
        else { return nil }

        var source = String(line[sourceRange]).trimmingCharacters(in: .whitespaces)
        var comment = ""
        if let commentRange = source.range(of: " # ") {
            comment = String(source[commentRange.upperBound...])
            source = String(source[..<commentRange.lowerBound])
        }
        return UFWRule(
            number: number,
            action: String(line[actionRange]).trimmingCharacters(in: .whitespaces),
            target: String(line[targetRange]).trimmingCharacters(in: .whitespaces),
            source: source,
            comment: comment,
            raw: line
        )
    }

    func parseLogs(_ text: String) -> [UFWLogEntry] {
        text.lines().enumerated().compactMap { index, line in
            guard line.contains("[UFW ") else { return nil }
            let action = extractBracketAction(line)
            let kv = parseKeyValues(line)
            let timestamp = line.components(separatedBy: "[UFW ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return UFWLogEntry(
                id: "\(index):\(line.hashValue)",
                timestamp: timestamp,
                action: action,
                interface: kv["IN"] ?? kv["OUT"] ?? "",
                source: kv["SRC"] ?? "",
                destination: kv["DST"] ?? "",
                protocolName: kv["PROTO"] ?? "",
                sourcePort: kv["SPT"] ?? "",
                destinationPort: kv["DPT"] ?? "",
                raw: line
            )
        }
    }

    func extractBracketAction(_ line: String) -> String {
        guard let start = line.range(of: "[UFW "),
              let end = line[start.upperBound...].firstIndex(of: "]")
        else { return "UFW" }
        let content = String(line[start.upperBound..<end])
        return content.replacingOccurrences(of: "UFW ", with: "")
            .split(separator: " ")
            .first
            .map(String.init) ?? "UFW"
    }

    func parseKeyValues(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    func sudoFriendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required") || lower.contains("sudo") && lower.contains("password") {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw/log read commands, or run the commands manually in the terminal."
        }
        return message
    }
}

// MARK: - systemd

