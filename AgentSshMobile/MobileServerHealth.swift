import Foundation

/// Severity of a single health signal or of a server overall.
///
/// Ordered so that `max(...)` over a set of issues yields the worst severity,
/// and so the dashboard can sort servers worst-first.
enum MobileServerSeverity: Int, Comparable, Sendable {
    case ok = 0
    case warning = 1
    case critical = 2

    static func < (lhs: MobileServerSeverity, rhs: MobileServerSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var needsAttention: Bool { self != .ok }
}

/// A single reason a server needs attention (or an informational note).
struct MobileServerHealthIssue: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: MobileServerSeverity
    let systemImage: String

    init(
        id: String,
        title: String,
        detail: String,
        severity: MobileServerSeverity,
        systemImage: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.systemImage = systemImage
    }
}

/// Firewall (UFW) state, decoupled from the heavier rule-parsing in the
/// per-server dashboard so the evaluator stays pure and testable.
enum MobileServerFirewallState: Equatable, Sendable {
    /// UFW is active and only expected ports are open.
    case protected
    /// UFW reports inactive.
    case inactive
    /// UFW is active but exposes unexpected open ports.
    case open([String])
    /// UFW is not installed on the host.
    case unavailable
    /// Status could not be determined (e.g. permission denied).
    case unknown
}

/// A pure, FFI-free snapshot of a connected server's resource usage. The store
/// converts `FfiSystemStats` into this so the evaluator can be unit-tested
/// without linking the Rust bridge.
struct MobileServerResourceSample: Equatable, Sendable {
    struct Disk: Equatable, Sendable {
        let mount: String
        let used: UInt64
        let total: UInt64

        var usedPercent: Double {
            guard total > 0 else { return 0 }
            return Double(used) / Double(total) * 100
        }
    }

    let cpuPercent: Double
    let loadAverage1m: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let disks: [Disk]
    let uptimeSeconds: UInt64

    var memoryPercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }

    /// The root mount if present, otherwise the fullest mount. Matches the
    /// per-server dashboard's primary-disk selection.
    var primaryDisk: Disk? {
        disks.first { $0.mount == "/" }
            ?? disks.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Resource thresholds, mirroring the macOS `dashboardHealthIssues` heuristics
/// so both platforms agree on what "needs attention" means.
enum MobileServerHealthThresholds {
    static let warningPercent: Double = 85
    static let criticalPercent: Double = 95
}

/// Pure evaluation of a connected server's resource/firewall/service signals
/// into health issues. Connection-state issues (failed/connecting) are composed
/// separately by the dashboard from the session store.
enum MobileServerHealthEvaluator {
    static func evaluate(
        sample: MobileServerResourceSample?,
        firewall: MobileServerFirewallState,
        failedServices: [String]
    ) -> [MobileServerHealthIssue] {
        var issues: [MobileServerHealthIssue] = []

        if let sample {
            issues.append(contentsOf: resourceIssues(sample))
        }
        if let firewallIssue = firewallIssue(firewall) {
            issues.append(firewallIssue)
        }
        if let serviceIssue = failedServiceIssue(failedServices) {
            issues.append(serviceIssue)
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    /// Worst severity across a set of issues (`.ok` when empty).
    static func overallSeverity(_ issues: [MobileServerHealthIssue]) -> MobileServerSeverity {
        issues.map(\.severity).max() ?? .ok
    }

    // MARK: - Resource signals

    private static func resourceIssues(_ sample: MobileServerResourceSample) -> [MobileServerHealthIssue] {
        var issues: [MobileServerHealthIssue] = []

        if let cpu = thresholdSeverity(sample.cpuPercent) {
            issues.append(
                MobileServerHealthIssue(
                    id: "cpu",
                    title: "CPU \(percent(sample.cpuPercent))",
                    detail: "Load \(String(format: "%.2f", sample.loadAverage1m))",
                    severity: cpu,
                    systemImage: "cpu"
                )
            )
        }

        if let memory = thresholdSeverity(sample.memoryPercent) {
            issues.append(
                MobileServerHealthIssue(
                    id: "memory",
                    title: "Memory \(percent(sample.memoryPercent))",
                    detail: "\(bytes(sample.memoryUsed)) / \(bytes(sample.memoryTotal)) used",
                    severity: memory,
                    systemImage: "memorychip"
                )
            )
        }

        // Surface the two fullest mounts that cross a threshold, matching macOS.
        let diskIssues = sample.disks
            .compactMap { disk -> MobileServerHealthIssue? in
                guard let severity = thresholdSeverity(disk.usedPercent) else { return nil }
                return MobileServerHealthIssue(
                    id: "disk:\(disk.mount)",
                    title: "Disk \(disk.mount) \(percent(disk.usedPercent))",
                    detail: "\(bytes(disk.used)) / \(bytes(disk.total)) used",
                    severity: severity,
                    systemImage: "internaldrive"
                )
            }
            .sorted { $0.severity > $1.severity }
            .prefix(2)
        issues.append(contentsOf: diskIssues)

        return issues
    }

    private static func thresholdSeverity(_ percent: Double) -> MobileServerSeverity? {
        if percent >= MobileServerHealthThresholds.criticalPercent { return .critical }
        if percent >= MobileServerHealthThresholds.warningPercent { return .warning }
        return nil
    }

    // MARK: - Firewall signal

    private static func firewallIssue(_ state: MobileServerFirewallState) -> MobileServerHealthIssue? {
        switch state {
        case .protected, .unavailable, .unknown:
            // Don't nag when UFW isn't installed or status is indeterminate.
            return nil
        case .inactive:
            return MobileServerHealthIssue(
                id: "firewall",
                title: "Firewall off",
                detail: "UFW is inactive — the host is exposed.",
                severity: .warning,
                systemImage: "lock.open"
            )
        case .open(let ports):
            let list = ports.prefix(3).joined(separator: ", ")
            return MobileServerHealthIssue(
                id: "firewall",
                title: "Unexpected open ports",
                detail: list.isEmpty ? "UFW exposes unexpected ports." : "Open to anywhere: \(list)",
                severity: .warning,
                systemImage: "lock.open"
            )
        }
    }

    // MARK: - Failed services signal

    private static func failedServiceIssue(_ failedServices: [String]) -> MobileServerHealthIssue? {
        let names = failedServices.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !names.isEmpty else { return nil }

        let count = names.count
        let preview = names.prefix(3).joined(separator: ", ")
        let detail = count > 3 ? "\(preview), +\(count - 3) more" : preview
        return MobileServerHealthIssue(
            id: "services",
            title: "\(count) failed service\(count == 1 ? "" : "s")",
            detail: detail,
            severity: .warning,
            systemImage: "exclamationmark.octagon"
        )
    }

    // MARK: - Formatting

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

/// Sentinel echoed by the probe script when UFW is not installed.
let mobileUFWUnavailableMarker = "__MIDNIGHT_SSH_UFW_UNAVAILABLE__"

/// Pure parser turning `ufw status` output into a `MobileServerFirewallState`.
/// FFI-free and unit-tested; the store feeds it the remote command output.
enum MobileFirewallStatusParser {
    private struct OpenRuleExposure {
        let target: String
        let source: String
    }

    static func parse(output: String, sshPort: UInt16?) -> MobileServerFirewallState {
        if output.contains(mobileUFWUnavailableMarker) {
            return .unavailable
        }

        let statusLine = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let lower = statusLine.lowercased()

        if lower.contains("inactive") {
            return .inactive
        }

        if lower.contains("active") {
            let openPorts = collectExtraOpenRules(from: output, sshPort: sshPort)
            return openPorts.isEmpty ? .protected : .open(openPorts)
        }

        return .unknown
    }

    private static func collectExtraOpenRules(from output: String, sshPort: UInt16?) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { extractOpenRuleExposure(from: String($0)) }
            .filter { isPublicSource($0.source) && !isAllowedOpenRule($0.target, sshPort: sshPort) }
            .map(\.target)
    }

    private static func extractOpenRuleExposure(from line: String) -> OpenRuleExposure? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("Status:"),
              !trimmed.hasPrefix("To "),
              !trimmed.hasPrefix("--")
        else { return nil }

        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            trimmed = String(trimmed[trimmed.index(after: end)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let pattern = #"^(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 4,
              let targetRange = Range(match.range(at: 1), in: trimmed),
              let sourceRange = Range(match.range(at: 3), in: trimmed)
        else { return nil }

        let target = trimmed[targetRange].trimmingCharacters(in: .whitespaces)
        let source = stripRuleComment(String(trimmed[sourceRange]))
        guard !target.isEmpty, !source.isEmpty else { return nil }
        return OpenRuleExposure(target: target, source: source)
    }

    private static func isPublicSource(_ source: String) -> Bool {
        let normalized = stripRuleComment(source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        return [
            "any", "anyone", "anyone (v6)", "anywhere", "anywhere (v6)",
            "0.0.0.0/0", "::/0", "::/0 (v6)",
        ].contains(normalized)
    }

    private static func stripRuleComment(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commentRange = trimmed.range(of: " # ") else { return trimmed }
        return String(trimmed[..<commentRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedOpenRule(_ rule: String, sshPort: UInt16?) -> Bool {
        let normalized = rule
            .replacingOccurrences(of: "(v6)", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        let allowedServices: Set<String> = [
            "http", "https", "ssh", "openssh", "www", "www full", "www secure",
            "apache", "apache full", "apache secure",
            "nginx http", "nginx https", "nginx full",
        ]
        if allowedServices.contains(normalized) { return true }

        guard let portSpec = normalized.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        let portPart = portSpec.split(separator: "/").first.map(String.init) ?? String(portSpec)
        let ports = portPart.split(separator: ",").map(String.init)
        guard !ports.isEmpty else { return false }

        var allowedPorts: Set<String> = ["22", "80", "443"]
        allowedPorts.insert(String(sshPort ?? 22))
        return ports.allSatisfy { allowedPorts.contains($0) }
    }
}
