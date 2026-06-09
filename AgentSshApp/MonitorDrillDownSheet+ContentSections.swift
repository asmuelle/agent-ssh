import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension MonitorDrillDownSheet {
    // MARK: - Typed panes

    @ViewBuilder
    func cpuContent(_ diagnostic: CPUDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Load", diagnostic.load.isEmpty ? "Unavailable" : diagnostic.load),
                ("CPU Cores", diagnostic.cores.isEmpty ? "Unknown" : diagnostic.cores),
                ("Processes", "\(diagnostic.processes.count)"),
                ("Threads", "\(diagnostic.threads.count)"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: diagnostic.threads
            )
        case .details:
            selectedProcessDetail(diagnostic.processes)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    func memoryContent(_ diagnostic: MemoryDiagnostic) -> some View {
        switch mode {
        case .overview:
            memoryOverviewPane(diagnostic)
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: []
            )
        case .details:
            VStack(alignment: .leading, spacing: 12) {
                selectedProcessDetail(diagnostic.processes)
                if !diagnostic.events.isEmpty {
                    sectionBox("Memory Pressure Events") {
                        rawText(diagnostic.events.joined(separator: "\n"))
                    }
                    .frame(height: 180)
                }
            }
        case .raw:
            rawPane(rawOutput)
        }
    }

    func memoryOverviewPane(_ diagnostic: MemoryDiagnostic) -> some View {
        let topProcess = diagnostic.processes.first

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCards([
                    ("Largest RSS", topProcess.map { formatKilobytes($0.rssKB) } ?? "Unknown"),
                    ("Top Process", topProcess?.command ?? "Unknown"),
                    ("Processes", "\(diagnostic.processes.count)"),
                    ("Pressure Events", "\(diagnostic.events.count)"),
                ])
                sectionBox("Memory Summary") {
                    rawText(diagnostic.summary.joined(separator: "\n"))
                        .frame(minHeight: 110, maxHeight: 220)
                }
                if !diagnostic.events.isEmpty {
                    sectionBox("Pressure Events") {
                        rawText(diagnostic.events.joined(separator: "\n"))
                            .frame(minHeight: 90, maxHeight: 180)
                    }
                }
                if !diagnostic.warnings.isEmpty {
                    warningList(diagnostic.warnings)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    func diskContent(_ diagnostic: DiskDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Mount", diagnostic.mount.isEmpty ? "Unknown" : diagnostic.mount),
                ("Usage", diagnostic.usage.isEmpty ? "Unavailable" : diagnostic.usage),
                ("Recent Large Files", "\(diagnostic.files.count)"),
                ("Largest File", diagnostic.files.first.map { formatBytes($0.size) } ?? "None"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            diskFilePane(diagnostic)
        case .details:
            selectedDiskFileDetail(diagnostic.files)
                .padding(16)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    func systemdContent(_ diagnostic: SystemdDiagnostic) -> some View {
        switch mode {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(diagnostic.value(for: "Id") ?? "Service Unit")
                                .font(.headline)
                            Text(diagnostic.value(for: "Description") ?? "No description available.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            state: diagnostic.value(for: "ActiveState") ?? "Unknown",
                            substate: diagnostic.value(for: "SubState") ?? "Unknown"
                        )
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    overviewCards([
                        ("User", diagnostic.value(for: "User") ?? "Default"),
                        ("Main PID", diagnostic.value(for: "MainPID") ?? "Unknown"),
                        ("Tasks", diagnostic.value(for: "TasksCurrent") ?? "-"),
                        ("Memory", formatMemoryProperty(diagnostic.value(for: "MemoryCurrent"))),
                    ])
                    if diagnostic.journalIssueCounts.hasIssues {
                        journalIssueSummary(diagnostic.journalIssueCounts)
                    }
                    serviceSpecificPane(diagnostic)
                    keyValuePane(diagnostic.properties)
                }
                .padding(16)
            }
        case .hotspots:
            systemdFilesPane(diagnostic)
        case .details:
            systemdJournalPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    func ufwContent(_ diagnostic: UFWDiagnostic) -> some View {
        switch mode {
        case .overview:
            ufwOverviewPane(diagnostic)
        case .hotspots:
            ufwBlockedSourcesPane(diagnostic)
        case .details:
            ufwRulesPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    func ufwOverviewPane(_ diagnostic: UFWDiagnostic) -> some View {
        let publicRules = ufwPublicOpenRules(diagnostic)
        let findings = ufwFindings(diagnostic)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ufwSummaryCards([
                    ("Firewall", ufwFirewallStatus(diagnostic), ufwFirewallColor(diagnostic)),
                    ("Incoming", ufwDefaultPolicy(diagnostic, direction: "incoming"), ufwPolicyColor(ufwDefaultPolicy(diagnostic, direction: "incoming"))),
                    ("Outgoing", ufwDefaultPolicy(diagnostic, direction: "outgoing"), ufwPolicyColor(ufwDefaultPolicy(diagnostic, direction: "outgoing"))),
                    ("SSH", ufwSSHSummary(diagnostic), ufwSSHSummaryColor(diagnostic)),
                    ("Logging", ufwStatusValue(diagnostic, key: "Logging") ?? "-", .secondary),
                    ("IPv6", ufwConfigValue(diagnostic, key: "IPV6") ?? ufwIPv6Summary(diagnostic), ufwIPv6Color(diagnostic)),
                    ("Rules", "\(diagnostic.rules.count)", .secondary),
                    ("Public Rules", "\(publicRules.count)", publicRules.isEmpty ? .green : .orange),
                ])

                ufwFindingsSection(findings)
                ufwPublicRulesSection(publicRules)
            }
            .padding(16)
        }
    }

    func ufwSummaryCards(_ items: [(String, String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.1.isEmpty ? "-" : item.1)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(item.2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    func ufwFindingsSection(_ findings: [String]) -> some View {
        sectionBox("Findings") {
            if findings.isEmpty {
                Label("No high-risk public UFW exposure found in the numbered rules.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings, id: \.self) { finding in
                        Label(finding, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    func ufwPublicRulesSection(_ rules: [UFWDiagnosticRule]) -> some View {
        let shownRules = Array(rules.prefix(10))

        return sectionBox("Public Rules") {
            if rules.isEmpty {
                Text("No public ALLOW or LIMIT rules were detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ufwPublicRuleHeader
                    Divider()
                    ForEach(shownRules) { rule in
                        ufwPublicRuleRow(rule)
                        if rule.id != (shownRules.last?.id ?? rule.id) {
                            Divider()
                        }
                    }
                    if rules.count > shownRules.count {
                        Text("\(rules.count - shownRules.count) more public rules are listed in Rules.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    var ufwPublicRuleHeader: some View {
        HStack(spacing: 8) {
            Text("Port")
                .frame(width: 110, alignment: .leading)
            Text("Service")
                .frame(width: 90, alignment: .leading)
            Text("Source")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Version")
                .frame(width: 58, alignment: .leading)
            Text("Risk")
                .frame(width: 112, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    func ufwPublicRuleRow(_ rule: UFWDiagnosticRule) -> some View {
        HStack(spacing: 8) {
            ufwMonoCell(rule.target, width: 110)
            Text(ufwServiceName(for: rule))
                .font(.caption)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            ufwMonoCell(rule.source)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ufwRuleVersion(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            ufwRiskBadge(ufwRisk(for: rule))
                .frame(width: 112, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    func ufwFindings(_ diagnostic: UFWDiagnostic) -> [String] {
        var findings = diagnostic.warnings
        let publicRules = ufwPublicOpenRules(diagnostic)

        if ufwIsInactive(diagnostic) {
            findings.append("UFW is inactive; firewall rules are not being enforced.")
        }
        if ufwDefaultPolicy(diagnostic, direction: "incoming").lowercased().contains("allow") {
            findings.append("The default incoming policy allows traffic.")
        }
        if publicRules.contains(where: ufwIsSSHRule) {
            findings.append("SSH is open to anywhere on port \(effectiveSSHPort).")
        }
        if publicRules.contains(where: ufwIsDatabaseRule) {
            findings.append("Postgres is open to anywhere on port 5432.")
        }
        if publicRules.contains(where: { ufwRuleVersion($0) == "IPv6" }) {
            findings.append("IPv6 public allow rules are enabled.")
        }

        var unique: [String] = []
        for finding in findings where !unique.contains(finding) {
            unique.append(finding)
        }
        return unique
    }

    func ufwPublicOpenRules(_ diagnostic: UFWDiagnostic) -> [UFWDiagnosticRule] {
        diagnostic.rules
            .filter { rule in
                let action = rule.action.lowercased()
                return (action.contains("allow") || action.contains("limit"))
                    && ufwIsPublicSource(rule.source)
            }
            .sorted {
                let lhsRisk = ufwRisk(for: $0)
                let rhsRisk = ufwRisk(for: $1)
                if lhsRisk.rank != rhsRisk.rank {
                    return lhsRisk.rank < rhsRisk.rank
                }
                return $0.number < $1.number
            }
    }

    var effectiveSSHPort: Int {
        Int(sshPort ?? 22)
    }

    func ufwStatusValue(_ diagnostic: UFWDiagnostic, key: String) -> String? {
        let prefix = "\(key):".lowercased()
        for line in diagnostic.statusLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func ufwConfigValue(_ diagnostic: UFWDiagnostic, key: String) -> String? {
        let prefix = "\(key)=".lowercased()
        for line in diagnostic.configLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func ufwIsActive(_ diagnostic: UFWDiagnostic) -> Bool {
        let value = ufwStatusValue(diagnostic, key: "Status")?.lowercased() ?? ""
        return value.contains("active") && !value.contains("inactive")
    }

    func ufwIsInactive(_ diagnostic: UFWDiagnostic) -> Bool {
        ufwStatusValue(diagnostic, key: "Status")?.lowercased().contains("inactive") == true
    }

    func ufwFirewallStatus(_ diagnostic: UFWDiagnostic) -> String {
        guard let value = ufwStatusValue(diagnostic, key: "Status"), !value.isEmpty else {
            return "Unknown"
        }
        return value.capitalized
    }

    func ufwFirewallColor(_ diagnostic: UFWDiagnostic) -> Color {
        if ufwIsActive(diagnostic) { return .green }
        if ufwIsInactive(diagnostic) { return .orange }
        return .secondary
    }

    func ufwDefaultPolicy(_ diagnostic: UFWDiagnostic, direction: String) -> String {
        guard let value = ufwStatusValue(diagnostic, key: "Default") else { return "-" }
        let directionNeedle = "(\(direction.lowercased()))"
        for component in value.split(separator: ",") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains(directionNeedle) {
                return trimmed.replacingOccurrences(of: directionNeedle, with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .capitalized
            }
        }
        return value
    }

    func ufwPolicyColor(_ policy: String) -> Color {
        let lower = policy.lowercased()
        if lower.contains("deny") || lower.contains("reject") { return .green }
        if lower.contains("allow") { return .orange }
        return .secondary
    }

    func ufwSSHSummary(_ diagnostic: UFWDiagnostic) -> String {
        if ufwPublicOpenRules(diagnostic).contains(where: ufwIsSSHRule) {
            return "Public on \(effectiveSSHPort)"
        }
        let restrictedSSH = diagnostic.rules.contains { rule in
            let action = rule.action.lowercased()
            return (action.contains("allow") || action.contains("limit"))
                && ufwIsSSHRule(rule)
        }
        return restrictedSSH ? "Restricted" : "No allow rule"
    }

    func ufwSSHSummaryColor(_ diagnostic: UFWDiagnostic) -> Color {
        let summary = ufwSSHSummary(diagnostic).lowercased()
        if summary.contains("public") { return .orange }
        if summary.contains("restricted") { return .green }
        return .secondary
    }

    func ufwIPv6Summary(_ diagnostic: UFWDiagnostic) -> String {
        diagnostic.rules.contains { ufwRuleVersion($0) == "IPv6" } ? "yes" : "no"
    }

    func ufwIPv6Color(_ diagnostic: UFWDiagnostic) -> Color {
        ufwPublicOpenRules(diagnostic).contains { ufwRuleVersion($0) == "IPv6" } ? .orange : .secondary
    }

    func ufwRisk(for rule: UFWDiagnosticRule) -> UFWRuleRisk {
        let action = rule.action.lowercased()
        guard action.contains("allow") || action.contains("limit") else {
            return action.contains("deny") || action.contains("reject") ? .blocked : .neutral
        }
        guard ufwIsPublicSource(rule.source) else { return .restricted }
        if ufwIsSSHRule(rule) { return .sshExposed }
        if ufwIsDatabaseRule(rule) { return .databaseExposed }
        if ufwIsMailRule(rule) { return .publicMail }
        if ufwIsWebRule(rule) { return .publicWeb }
        return .publicRule
    }

    func ufwIsSSHRule(_ rule: UFWDiagnosticRule) -> Bool {
        let target = rule.target.lowercased()
        return target.contains("openssh")
            || target.contains("ssh")
            || ufwPorts(in: rule.target).contains(effectiveSSHPort)
    }

    func ufwIsDatabaseRule(_ rule: UFWDiagnosticRule) -> Bool {
        let target = rule.target.lowercased()
        return target.contains("postgres")
            || target.contains("pgsql")
            || ufwPorts(in: rule.target).contains(5432)
    }

    func ufwIsWebRule(_ rule: UFWDiagnosticRule) -> Bool {
        let ports = ufwPorts(in: rule.target)
        let target = rule.target.lowercased()
        return ports.contains(80)
            || ports.contains(443)
            || target.contains("http")
            || target.contains("nginx")
            || target.contains("apache")
    }

    func ufwIsMailRule(_ rule: UFWDiagnosticRule) -> Bool {
        let ports = ufwPorts(in: rule.target)
        return ports.contains(25)
            || ports.contains(143)
            || ports.contains(465)
            || ports.contains(587)
            || ports.contains(993)
            || ports.contains(995)
    }

    func ufwServiceName(for rule: UFWDiagnosticRule) -> String {
        let target = rule.target.lowercased()
        let ports = ufwPorts(in: rule.target)
        if ufwIsSSHRule(rule) { return "SSH" }
        if ports.contains(80) { return "HTTP" }
        if ports.contains(443) { return "HTTPS" }
        if ufwIsDatabaseRule(rule) { return "Postgres" }
        if ports.contains(25) { return "SMTP" }
        if ports.contains(143) { return "IMAP" }
        if ports.contains(993) { return "IMAPS" }
        if ports.contains(5672) { return "AMQP" }
        if target.contains("dns") || ports.contains(53) { return "DNS" }
        return "-"
    }

    func ufwPorts(in target: String) -> [Int] {
        target
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }

    func ufwRuleVersion(_ rule: UFWDiagnosticRule) -> String {
        let value = "\(rule.target) \(rule.source)"
        return value.localizedCaseInsensitiveContains("(v6)") || value.contains(":") ? "IPv6" : "IPv4"
    }

    func ufwIsPublicSource(_ source: String) -> Bool {
        let sourceOnly = source.components(separatedBy: " # ").first ?? source
        let normalized = sourceOnly
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return [
            "any",
            "anyone",
            "anywhere",
            "anywhere (v6)",
            "0.0.0.0/0",
            "::/0",
            "::/0 (v6)",
        ].contains(normalized)
    }

    func ufwRiskBadge(_ risk: UFWRuleRisk) -> some View {
        Text(risk.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(risk.color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(risk.color.opacity(0.12), in: Capsule())
    }

    func ufwMonoCell(_ text: String, width: CGFloat? = nil, color: Color = .primary) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
    }

}
