import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

// MARK: - Remote command runner

struct RemoteCommandResult {
    let output: String
    let exitCode: Int

    var succeeded: Bool { exitCode == 0 }
}

enum RemoteCommandError: LocalizedError {
    case ffi(String)
    case missingExitMarker(String)
    case failed(RemoteCommandResult)

    var errorDescription: String? {
        switch self {
        case .ffi(let detail):
            return detail
        case .missingExitMarker(let output):
            return output.isEmpty ? "Remote command did not return an exit status." : output
        case .failed(let result):
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Remote command failed with exit code \(result.exitCode)."
                : detail
        }
    }
}

enum RemoteCommandRunner {
    static func runRaw(connectionId: String, command: String) async throws -> String {
        do {
            return try await BridgeManager.shared.executeCommand(
                connectionId: connectionId,
                command: command
            )
        } catch {
            throw RemoteCommandError.ffi(error.localizedDescription)
        }
    }

    static func runShell(connectionId: String, script: String) async throws -> RemoteCommandResult {
        let marker = "__RSHELL_EXIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let wrapped = """
        (
        \(script)
        ) 2>&1
        status=$?
        printf '\\n\(marker)%s\\n' "$status"
        """
        let output = try await runRaw(
            connectionId: connectionId,
            command: "sh -lc \(shellQuote(wrapped))"
        )
        guard let range = output.range(of: marker, options: .backwards) else {
            throw RemoteCommandError.missingExitMarker(output)
        }
        let body = String(output[..<range.lowerBound])
        let suffix = output[range.upperBound...]
        let statusToken = suffix.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let exitCode = Int(statusToken.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 127
        return RemoteCommandResult(
            output: body.trimmingCharacters(in: .newlines),
            exitCode: exitCode
        )
    }

    static func runChecked(connectionId: String, script: String) async throws -> String {
        let result = try await runShell(connectionId: connectionId, script: script)
        guard result.succeeded else { throw RemoteCommandError.failed(result) }
        return result.output
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private let fieldSeparator = "\u{1F}"

private func splitFields(_ line: String) -> [String] {
    line.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
}

private func formatPostgresMilliseconds(_ value: Double) -> String {
    if value < 1 {
        return String(format: "%.2f ms", max(0, value))
    }
    if value < 100 {
        return String(format: "%.1f ms", value)
    }
    if value < 10_000 {
        return String(format: "%.0f ms", value)
    }
    return String(format: "%.1f s", value / 1_000)
}

private func placeholderView(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.callout.weight(.medium))
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private enum RawOutputHighlightMode {
    case generic
    case systemdUnit
}

private struct HighlightedRawOutputText: View {
    let value: String
    var mode: RawOutputHighlightMode = .generic

    var body: some View {
        Text(highlightedRawOutput(value.isEmpty ? "-" : value, mode: mode))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }
}

private func highlightedRawOutput(_ value: String, mode: RawOutputHighlightMode = .generic) -> AttributedString {
    var result = AttributedString()
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, line) in lines.enumerated() {
        switch mode {
        case .generic:
            result += highlightedGenericOutputLine(line)
        case .systemdUnit:
            result += highlightedSystemdUnitLine(line)
        }
        if index < lines.count - 1 {
            result += rawOutputSegment("\n")
        }
    }
    return result
}

private func highlightedSystemdUnitLine(_ line: String) -> AttributedString {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rawOutputSegment(line) }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
        return rawOutputSegment(line, color: .secondary)
    }
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        var result = AttributedString()
        let leading = String(line.prefix { $0.isWhitespace })
        let section = String(line.dropFirst(leading.count))
        result += rawOutputSegment(leading)
        result += rawOutputSegment(section, color: .accentColor, weight: .semibold)
        return result
    }
    return highlightedKeyValueLine(line, systemdMode: true)
}

private func highlightedGenericOutputLine(_ line: String) -> AttributedString {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rawOutputSegment(line) }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
        return rawOutputSegment(line, color: .secondary)
    }
    if trimmed.hasPrefix("---") && trimmed.hasSuffix("---") {
        return rawOutputSegment(line, color: .purple, weight: .semibold)
    }
    if trimmed.hasPrefix("$ ") {
        var result = AttributedString()
        let leading = String(line.prefix { $0.isWhitespace })
        let body = String(line.dropFirst(leading.count))
        result += rawOutputSegment(leading)
        result += rawOutputSegment("$", color: .secondary)
        result += rawOutputSegment(String(body.dropFirst()), color: .accentColor)
        return result
    }
    return highlightedKeyValueLine(line, systemdMode: false)
}

private func highlightedKeyValueLine(_ line: String, systemdMode: Bool) -> AttributedString {
    let leading = String(line.prefix { $0.isWhitespace })
    let body = String(line.dropFirst(leading.count))
    let separatorIndex = keyValueSeparatorIndex(in: body)

    guard let separatorIndex else {
        let severityColor = rawOutputSeverityColor(line)
        return highlightedRawOutputValue(line, fallbackColor: severityColor)
    }

    let key = String(body[..<separatorIndex])
    let valueStart = body.index(after: separatorIndex)
    let separator = String(body[separatorIndex])
    let value = String(body[valueStart...])
    guard isLikelyRawOutputKey(key) else {
        let severityColor = rawOutputSeverityColor(line)
        return highlightedRawOutputValue(line, fallbackColor: severityColor)
    }

    var result = AttributedString()
    result += rawOutputSegment(leading)
    result += rawOutputSegment(key, color: systemdMode ? .accentColor : .blue, weight: .semibold)
    result += rawOutputSegment(separator, color: .secondary)
    result += highlightedRawOutputValue(value, fallbackColor: rawOutputSeverityColor(line))
    return result
}

private func keyValueSeparatorIndex(in text: String) -> String.Index? {
    let equals = text.firstIndex(of: "=")
    let colon = text.firstIndex(of: ":")
    switch (equals, colon) {
    case let (equals?, colon?):
        return equals < colon ? equals : colon
    case let (equals?, nil):
        return equals
    case let (nil, colon?):
        return colon
    case (nil, nil):
        return nil
    }
}

private func isLikelyRawOutputKey(_ key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
    return trimmed.allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." || character == " "
    }
}

private func highlightedRawOutputValue(_ value: String, fallbackColor: Color? = nil) -> AttributedString {
    var result = AttributedString()
    var token = ""
    var tokenIsWord: Bool?

    func flush() {
        guard !token.isEmpty else { return }
        let color = tokenIsWord == true ? rawOutputTokenColor(token) ?? fallbackColor : fallbackColor
        result += rawOutputSegment(token, color: color)
        token = ""
    }

    for character in value {
        let isWord = rawOutputWordCharacter(character)
        if let tokenIsWord, tokenIsWord != isWord {
            flush()
        }
        tokenIsWord = isWord
        token.append(character)
    }
    flush()
    return result
}

private func rawOutputWordCharacter(_ character: Character) -> Bool {
    character.isLetter
        || character.isNumber
        || character == "_"
        || character == "-"
        || character == "."
        || character == "/"
        || character == "@"
        || character == ":"
}

private func rawOutputSeverityColor(_ text: String) -> Color? {
    let lower = text.lowercased()
    if lower.contains("fatal") || lower.contains("error") || lower.contains("failed") || lower.contains("denied") {
        return .red
    }
    if lower.contains("warning") || lower.contains("warn") || lower.contains("deprecated") {
        return .orange
    }
    if lower.contains("success") || lower.contains("succeeded") || lower.contains(" ok") {
        return .green
    }
    return nil
}

private func rawOutputTokenColor(_ token: String) -> Color? {
    let normalized = token
        .trimmingCharacters(in: CharacterSet(charactersIn: "'\"`()[]{}<>,;"))
        .lowercased()

    if normalized.hasSuffix(".service")
        || normalized.hasSuffix(".target")
        || normalized.hasSuffix(".timer")
        || normalized.hasSuffix(".socket")
        || normalized.hasSuffix(".mount")
        || normalized.hasSuffix(".path")
        || normalized.hasSuffix(".slice")
        || normalized.hasSuffix(".scope") {
        return .accentColor
    }
    if normalized.hasPrefix("/") {
        return .blue
    }
    if ["true", "yes", "active", "running", "enabled", "loaded", "healthy", "succeeded", "success", "ok"].contains(normalized) {
        return .green
    }
    if ["false", "no", "inactive", "disabled", "dead", "exited", "skipped"].contains(normalized) {
        return .secondary
    }
    if ["error", "failed", "failure", "fatal", "denied", "unavailable", "masked", "not-found"].contains(normalized) {
        return .red
    }
    if ["warning", "warn", "deprecated", "restarting", "activating", "deactivating"].contains(normalized) {
        return .orange
    }
    return nil
}

private func rawOutputSegment(_ text: String, color: Color? = nil, weight: Font.Weight? = nil) -> AttributedString {
    var segment = AttributedString(text)
    if let color {
        segment.foregroundColor = color
    }
    if let weight {
        segment.font = .system(.caption, design: .monospaced).weight(weight)
    }
    return segment
}

private enum RemoteOperationState {
    case running
    case succeeded
    case warning
    case failed

    var color: Color {
        switch self {
        case .running: return .blue
        case .succeeded: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

private struct RemoteOperationFeedback: Identifiable {
    let id = UUID()
    let title: String
    let startedAt = Date()
    let targetIds: Set<String>
    let totalCount: Int?
    var state: RemoteOperationState = .running
    var detail: String
    var completedCount: Int?
    var output: String = ""
    var errorMessage: String?
    var endedAt: Date?

    init(
        title: String,
        detail: String,
        targetIds: Set<String> = [],
        totalCount: Int? = nil
    ) {
        self.title = title
        self.detail = detail
        self.targetIds = targetIds
        self.totalCount = totalCount
    }

    var isRunning: Bool { state == .running }

    var hasOutput: Bool {
        !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var outputText: String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty { return trimmedOutput }
        return (errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var countText: String? {
        guard let totalCount else { return nil }
        if let completedCount {
            return "\(completedCount)/\(totalCount)"
        }
        return "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }

    func elapsedText(now: Date) -> String {
        formatOperationDuration((endedAt ?? now).timeIntervalSince(startedAt))
    }
}

private func formatOperationDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes >= 60 {
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
    if minutes > 0 {
        return "\(minutes)m \(String(format: "%02d", remainingSeconds))s"
    }
    return "\(remainingSeconds)s"
}

private struct RemoteOperationBanner: View {
    let operation: RemoteOperationFeedback
    let onShowOutput: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: operation.startedAt, by: 1)) { context in
            HStack(spacing: 10) {
                if operation.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: operation.state.systemImage)
                        .foregroundStyle(operation.state.color)
                        .frame(width: 18, height: 18)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(operation.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let countText = operation.countText {
                            Text(countText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(operation.state.color)
                        }
                    }
                    Text(operation.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Text(operation.elapsedText(now: context.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if operation.hasOutput {
                    Button {
                        onShowOutput()
                    } label: {
                        Image(systemName: "text.page")
                    }
                    .buttonStyle(.borderless)
                    .help("Show command output")
                }

                if !operation.isRunning {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

private struct RemoteOperationOutputSheet: View {
    let operation: RemoteOperationFeedback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: operation.state.systemImage)
                    .foregroundStyle(operation.state.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title)
                        .font(.headline)
                    Text(operation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                HighlightedRawOutputText(value: operation.outputText.isEmpty ? "-" : operation.outputText)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 520, minHeight: 260)

            Divider()

            HStack {
                Spacer()
                Button("Copy Output") {
                    RemoteCommandRunner.copy(operation.outputText)
                }
                .disabled(operation.outputText.isEmpty)
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 420)
    }
}

private func monoCell(_ text: String, width: CGFloat? = nil, color: Color = .primary) -> some View {
    Text(text.isEmpty ? "-" : text)
        .font(.caption.monospaced())
        .foregroundStyle(color)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: width, alignment: .leading)
}

@ViewBuilder
private func rowOperationIndicator(isActive: Bool) -> some View {
    if isActive {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 16, height: 16)
    } else {
        Color.clear
            .frame(width: 16, height: 16)
    }
}

private func statusColor(_ value: String) -> Color {
    let lower = value.lowercased()
    if lower.contains("running") || lower == "active" || lower == "healthy" { return .green }
    if lower.contains("failed") || lower.contains("exited") || lower.contains("dead") || lower == "unhealthy" { return .red }
    if lower.contains("activating") || lower.contains("restarting") || lower.contains("paused") { return .orange }
    return .secondary
}

// MARK: - UFW

private struct UFWStatusSnapshot {
    var active: Bool = false
    var rawStatus: String = ""
    var numberedRules: String = ""
    var ipv6: String = "unknown"
    var incomingPolicy: String = "-"
    var outgoingPolicy: String = "-"
    var routedPolicy: String = "-"
    var logging: String = "-"
    var sshClientIp: String = ""
    var sshServerPort: Int?
    var iptables: String = ""
}

private struct UFWRule: Identifiable, Hashable {
    let number: Int
    let action: String
    let target: String
    let source: String
    let comment: String
    let raw: String

    var id: Int { number }
}

private struct UFWLogEntry: Identifiable, Hashable {
    let id: String
    let timestamp: String
    let action: String
    let interface: String
    let source: String
    let destination: String
    let protocolName: String
    let sourcePort: String
    let destinationPort: String
    let raw: String
}

private struct UFWTopTalker: Identifiable, Hashable {
    let source: String
    let count: Int

    var id: String { source }
}

enum UFWProtectionLevel: Equatable {
    case loading
    case unavailable
    case inactive
    case protected
    case open
    case unknown
}

struct UFWProtectionSummary: Equatable {
    let level: UFWProtectionLevel
    let statusText: String
    let extraOpenRules: [String]
    let error: String?

    static let loading = UFWProtectionSummary(
        level: .loading,
        statusText: "Loading UFW status",
        extraOpenRules: [],
        error: nil
    )

    var badgeText: String {
        switch level {
        case .loading: return "..."
        case .unavailable: return "n/a"
        case .inactive: return "off"
        case .protected: return "on"
        case .open: return "open"
        case .unknown: return "?"
        }
    }

    var helpText: String {
        switch level {
        case .open where !extraOpenRules.isEmpty:
            return "\(statusText). Extra open rules: \(extraOpenRules.joined(separator: ", "))"
        case .unknown:
            return error ?? statusText
        default:
            return statusText
        }
    }
}

let ufwUnavailableMarker = "__R_SHELL_UFW_UNAVAILABLE__"

struct UFWOpenRuleExposure: Equatable {
    let target: String
    let source: String
}

func summarizeUFWStatusOutput(_ output: String, sshPort: UInt16?) -> UFWProtectionSummary {
    let statusText = output
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Unknown"

    if statusText == ufwUnavailableMarker || output.contains(ufwUnavailableMarker) {
        return UFWProtectionSummary(
            level: .unavailable,
            statusText: "UFW not installed",
            extraOpenRules: [],
            error: nil
        )
    }

    let lower = statusText.lowercased()
    if lower.contains("inactive") {
        return UFWProtectionSummary(
            level: .inactive,
            statusText: statusText,
            extraOpenRules: [],
            error: nil
        )
    }

    if lower.contains("active") {
        let extraRules = collectExtraUFWOpenRules(from: output, sshPort: sshPort)
        return UFWProtectionSummary(
            level: extraRules.isEmpty ? .protected : .open,
            statusText: statusText,
            extraOpenRules: extraRules,
            error: nil
        )
    }

    let isPermissionError = lower.contains("permission")
        || lower.contains("need to be root")
        || lower.contains("must be root")
        || lower.contains("password")

    return UFWProtectionSummary(
        level: .unknown,
        statusText: statusText,
        extraOpenRules: [],
        error: isPermissionError ? statusText : nil
    )
}

func summarizeUFWStatus(
    active: Bool,
    statusText: String,
    openRules: [UFWOpenRuleExposure],
    sshPort: UInt16?
) -> UFWProtectionSummary {
    guard active else {
        return UFWProtectionSummary(
            level: .inactive,
            statusText: statusText,
            extraOpenRules: [],
            error: nil
        )
    }

    let extraRules = openRules
        .filter { isPublicUFWSource($0.source) && !isAllowedUFWOpenRule($0.target, sshPort: sshPort) }
        .map(\.target)
    return UFWProtectionSummary(
        level: extraRules.isEmpty ? .protected : .open,
        statusText: statusText,
        extraOpenRules: extraRules,
        error: nil
    )
}

func collectExtraUFWOpenRules(from output: String, sshPort: UInt16?) -> [String] {
    output
        .split(whereSeparator: \.isNewline)
        .compactMap { extractUFWOpenRuleExposure(from: String($0)) }
        .filter { isPublicUFWSource($0.source) && !isAllowedUFWOpenRule($0.target, sshPort: sshPort) }
        .map(\.target)
}

func extractUFWOpenRuleExposure(from line: String) -> UFWOpenRuleExposure? {
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

    let target = trimmed[targetRange]
        .trimmingCharacters(in: .whitespaces)
    let source = stripUFWRuleComment(String(trimmed[sourceRange]))
    guard !target.isEmpty, !source.isEmpty else { return nil }
    return UFWOpenRuleExposure(target: target, source: source)
}

func isPublicUFWSource(_ source: String) -> Bool {
    let normalized = stripUFWRuleComment(source)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()

    return [
        "any",
        "anyone",
        "anyone (v6)",
        "anywhere",
        "anywhere (v6)",
        "0.0.0.0/0",
        "::/0",
        "::/0 (v6)",
    ].contains(normalized)
}

func stripUFWRuleComment(_ source: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let commentRange = trimmed.range(of: " # ") else {
        return trimmed
    }
    return String(trimmed[..<commentRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func isAllowedUFWOpenRule(_ rule: String, sshPort: UInt16?) -> Bool {
    let normalized = rule
        .replacingOccurrences(of: "(v6)", with: "")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()

    let knownAllowedServices: Set<String> = [
        "http",
        "https",
        "ssh",
        "openssh",
        "www",
        "www full",
        "www secure",
        "apache",
        "apache full",
        "apache secure",
        "nginx http",
        "nginx https",
        "nginx full",
    ]
    if knownAllowedServices.contains(normalized) {
        return true
    }

    guard let portSpec = normalized.split(whereSeparator: \.isWhitespace).first else {
        return false
    }
    let portPart = portSpec.split(separator: "/").first.map(String.init) ?? String(portSpec)
    let ports = portPart.split(separator: ",").map(String.init)
    guard !ports.isEmpty else { return false }

    var allowedPorts: Set<String> = ["22", "80", "443"]
    if let sshPort {
        allowedPorts.insert(String(sshPort))
    }
    return ports.allSatisfy { allowedPorts.contains($0) }
}

struct UFWMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    let sshPort: UInt16?

    private enum Mode: String, CaseIterable {
        case status = "Status"
        case rules = "Rules"
        case logs = "Logs"
    }

    private enum ActionFilter: String, CaseIterable {
        case all = "All"
        case allow = "Allow"
        case deny = "Deny"
        case reject = "Reject"
        case limit = "Limit"
    }

    @State private var mode: Mode = .status
    @State private var actionFilter: ActionFilter = .all
    @State private var snapshot = UFWStatusSnapshot()
    @State private var rules: [UFWRule] = []
    @State private var logs: [UFWLogEntry] = []
    @State private var selectedRules: Set<Int> = []
    @State private var ruleSortOrder: [KeyPathComparator<UFWRule>] = [
        .init(\.number)
    ]
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    private static let refreshInterval: UInt64 = 30_000_000_000

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

    private var header: some View {
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

    private var statusBadge: some View {
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
    private var content: some View {
        switch mode {
        case .status:
            statusPane
        case .rules:
            rulesPane
        case .logs:
            logsPane
        }
    }

    private var statusPane: some View {
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

    private func ufwMetric(_ label: String, _ value: String, color: Color) -> some View {
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

    private var topTalkersCard: some View {
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

    private var rawStatusCard: some View {
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

    private var rulesPane: some View {
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

    private var ruleDetailPane: some View {
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

    private var logsPane: some View {
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

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filteredRules: [UFWRule] {
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

    private var filteredLogs: [UFWLogEntry] {
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

    private var selectedRule: UFWRule? {
        guard let number = selectedRules.sorted().first else { return nil }
        return rules.first { $0.number == number }
    }

    private var ufwProtectionSummary: UFWProtectionSummary {
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

    private func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
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

    private var topBlockedSources: [UFWTopTalker] {
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

    private var sshLockoutWarning: String? {
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

    private func policyColor(_ policy: String) -> Color {
        let lower = policy.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        return .secondary
    }

    private func ruleColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("allow") { return .green }
        if lower.contains("deny") || lower.contains("reject") { return .red }
        if lower.contains("limit") { return .orange }
        return .secondary
    }

    private func iptablesMatches(for rule: UFWRule) -> String {
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

    private func firstNumber(in text: String) -> String? {
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    private func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
            await refresh()
        }
    }

    private func refresh() async {
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

    private func parseSnapshot(_ output: String) {
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

    private func parseIPv6(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("ipv6=yes") { return "yes" }
        if lower.contains("ipv6=no") { return "no" }
        return "unknown"
    }

    private func parsePolicy(_ status: String, key: String) -> String {
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

    private func parseLogging(_ status: String) -> String {
        guard let line = status.lines().first(where: { $0.lowercased().hasPrefix("logging:") }) else {
            return "-"
        }
        return line.replacingOccurrences(of: "Logging:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseSSHValue(_ ssh: String, key: String) -> String {
        ssh.lines()
            .first { $0.hasPrefix("\(key)=") }?
            .dropFirst(key.count + 1)
            .description ?? ""
    }

    private func parseSSHServerPort(_ ssh: String) -> Int? {
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

    private func parseRules(_ text: String) -> [UFWRule] {
        text.lines().compactMap(parseRuleLine)
    }

    private func parseRuleLine(_ line: String) -> UFWRule? {
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

    private func parseLogs(_ text: String) -> [UFWLogEntry] {
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

    private func extractBracketAction(_ line: String) -> String {
        guard let start = line.range(of: "[UFW "),
              let end = line[start.upperBound...].firstIndex(of: "]")
        else { return "UFW" }
        let content = String(line[start.upperBound..<end])
        return content.replacingOccurrences(of: "UFW ", with: "")
            .split(separator: " ")
            .first
            .map(String.init) ?? "UFW"
    }

    private func parseKeyValues(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    private func sudoFriendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required") || lower.contains("sudo") && lower.contains("password") {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw/log read commands, or run the commands manually in the terminal."
        }
        return message
    }
}

// MARK: - systemd

private struct SystemdUnit: Identifiable, Hashable {
    let name: String
    let load: String
    let active: String
    let sub: String
    let unitFileState: String
    let description: String

    var id: String { name }
    var statusSortKey: String { "\(active) \(sub)" }

    var statusSortRank: Int {
        if isFailed { return 0 }
        if isTransitional { return 1 }
        if !isLoaded { return 2 }
        if isActive { return 3 }
        return 4
    }

    var hasOperationalProblem: Bool {
        isFailed || isTransitional || !isLoaded
    }

    var isFailed: Bool {
        active.lowercased() == "failed" || sub.lowercased() == "failed"
    }

    var isActive: Bool {
        active.lowercased() == "active"
    }

    var isTransitional: Bool {
        let active = active.lowercased()
        let sub = sub.lowercased()
        return active == "activating"
            || active == "deactivating"
            || active == "reloading"
            || sub == "reloading"
            || sub == "auto-restart"
            || sub == "start"
            || sub == "stop"
    }

    var isLoaded: Bool {
        load.lowercased() == "loaded"
    }

    var isEnabled: Bool {
        ["enabled", "enabled-runtime", "linked", "linked-runtime", "alias"].contains(unitFileState.lowercased())
    }

    var isDisabled: Bool {
        unitFileState.lowercased() == "disabled"
    }
}

struct MonitoredSystemdServiceStatus: Identifiable, Equatable {
    let name: String
    let active: String
    let sub: String
    let uptimeSeconds: UInt64?
    let journalIssueCounts: JournalIssueCounts

    var id: String { name }

    var isRunning: Bool {
        active.lowercased() == "active"
    }

    var indicatorColor: Color {
        systemdIndicatorColor(active: active, sub: sub)
    }
}

private struct PostgresDashboardPreviewItem: Identifiable {
    let id: String
    let label: String
    let value: String
    let color: Color
}

private func systemdIndicatorColor(active: String, sub: String) -> Color {
    let active = active.lowercased()
    let sub = sub.lowercased()
    if active == "failed" || sub == "failed" {
        return .red
    }
    if active == "active" {
        return .green
    }
    if active == "activating" || active == "deactivating" || active == "reloading"
        || sub == "reloading" || sub == "auto-restart" || sub == "start" || sub == "stop" {
        return .orange
    }
    return .secondary
}

private func systemdStateColor(_ value: String, unit: SystemdUnit) -> Color {
    let lower = value.lowercased()
    if unit.isFailed || lower == "failed" {
        return .red
    }
    if unit.isTransitional || lower == "activating" || lower == "deactivating" || lower == "reloading" {
        return .orange
    }
    if unit.isActive || lower == "running" || lower == "listening" {
        return .green
    }
    return .secondary
}

private func systemdLoadColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "loaded":
        return .secondary
    case "not-found", "error", "bad-setting", "masked":
        return .red
    default:
        return .orange
    }
}

private func systemdFileStateColor(_ value: String) -> Color {
    switch value.lowercased() {
    case "enabled", "enabled-runtime", "linked", "linked-runtime", "alias":
        return .green
    case "masked", "bad":
        return .red
    case "disabled":
        return .secondary
    case "static", "generated", "transient", "indirect":
        return .blue
    default:
        return .secondary
    }
}

struct JournalIssueCounts: Equatable {
    var errors: Int
    var warnings: Int

    static let zero = JournalIssueCounts(errors: 0, warnings: 0)

    var hasIssues: Bool {
        errors > 0 || warnings > 0
    }
}

enum JournalIssueClassifier {
    private enum Issue {
        case error
        case warning
    }

    static func counts(in lines: [String]) -> JournalIssueCounts {
        lines.reduce(into: .zero) { result, line in
            switch classify(line) {
            case .error:
                result.errors += 1
            case .warning:
                result.warnings += 1
            case nil:
                break
            }
        }
    }

    private static func classify(_ line: String) -> Issue? {
        let message = journalMessage(in: line)
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        if errorRegex?.firstMatch(in: message, range: range) != nil {
            return .error
        }
        if warningRegex?.firstMatch(in: message, range: range) != nil {
            return .warning
        }
        return nil
    }

    private static func journalMessage(in line: String) -> String {
        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        if fields.count == 4, isLikelyJournalTimestamp(fields[0]) {
            return fields[3]
        }
        return line
    }

    private static func isLikelyJournalTimestamp(_ value: String) -> Bool {
        (value.contains("-") || value.contains(":")) && value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static let errorRegex = try? NSRegularExpression(
        pattern: #"\b(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)\b"#,
        options: [.caseInsensitive]
    )

    private static let warningRegex = try? NSRegularExpression(
        pattern: #"\b(warn|warning|deprecated|timeout|timed\s*out|retry|retrying|deferred|refused|rejected)\b"#,
        options: [.caseInsensitive]
    )
}

struct JournalIssueBadges: View {
    let counts: JournalIssueCounts
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if counts.errors > 0 {
                issueBadge(
                    count: counts.errors,
                    icon: "xmark.octagon.fill",
                    color: .red,
                    help: "Journal errors in the recent sample: \(counts.errors)"
                )
            }
            if counts.warnings > 0 {
                issueBadge(
                    count: counts.warnings,
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    help: "Journal warnings in the recent sample: \(counts.warnings)"
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func issueBadge(count: Int, icon: String, color: Color, help: String) -> some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: icon)
                .font(compact ? .caption2 : .caption)
            Text("\(count)")
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

struct MonitoredSystemdServicesPane: View {
    let connectionId: String?
    let profileId: String?
    var isActive: Bool = true
    var onSelectService: (String) -> Void = { _ in }
    var onOpenSystemd: () -> Void = {}
    var onOpenDocker: () -> Void = {}
    var onOpenPostgres: () -> Void = {}

    @ObservedObject private var connectionStore = ConnectionStoreManager.shared
    @State private var statuses: [MonitoredSystemdServiceStatus] = []
    @State private var error: String?
    @State private var loading = false
    @State private var hasDocker = false
    @State private var hasPostgres = false
    @State private var postgresDashboard = PGDashboardSnapshot.empty
    @State private var postgresDashboardError: String?
    @State private var postgresDashboardLoading = false

    private static let pollInterval: UInt64 = 5_000_000_000
    private static let detectInterval: UInt64 = 30_000_000_000
    private static let postgresDashboardInterval: UInt64 = 30_000_000_000
    private static let unavailableMarker = "__MIDNIGHT_SSH_SYSTEMD_UNAVAILABLE__"

    private var serviceNames: [String] {
        connectionStore.monitoredSystemdServices(profileId: profileId)
    }

    private var pollKey: String {
        "\(connectionId ?? "none"):\(profileId ?? "none"):\(isActive):\(serviceNames.joined(separator: ","))"
    }

    private var detectKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    private var postgresDashboardKey: String {
        "\(connectionId ?? "none"):\(isActive):\(hasPostgres)"
    }

    private var rows: [MonitoredSystemdServiceStatus] {
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
    private func shortcutHeader(
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

    private func serviceHelp(_ service: MonitoredSystemdServiceStatus) -> String {
        var parts = ["\(service.name): \(service.active) \(service.sub)"]
        if service.journalIssueCounts.errors > 0 {
            parts.append("\(service.journalIssueCounts.errors) journal errors")
        }
        if service.journalIssueCounts.warnings > 0 {
            parts.append("\(service.journalIssueCounts.warnings) journal warnings")
        }
        return parts.joined(separator: " - ")
    }

    private var postgresShortcutHeader: some View {
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
    private var postgresDashboardPreview: some View {
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

    private func postgresDashboardPreviewChip(_ item: PostgresDashboardPreviewItem) -> some View {
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

    private func pollLoop() async {
        await refreshStatuses()
        while !Task.isCancelled && isActive && !serviceNames.isEmpty {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await refreshStatuses()
        }
    }

    private func refreshStatuses() async {
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

    private func publishSystemdWidgetSnapshots(
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

    private var widgetSnapshotPrefix: String? {
        if let profileId {
            return "systemd:\(profileId):"
        }
        if let connectionId {
            return "systemd:\(connectionId):"
        }
        return nil
    }

    private func parseMonitoredSystemdServiceStatuses(_ output: String) -> [MonitoredSystemdServiceStatus] {
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

    private func formatServiceUptime(_ seconds: UInt64?) -> String {
        guard let seconds else { return "-" }
        if seconds < 60 { return "\(seconds)s" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func detectLoop() async {
        await detectAvailability()
        while !Task.isCancelled && isActive && connectionId != nil {
            try? await Task.sleep(nanoseconds: Self.detectInterval)
            await detectAvailability()
        }
    }

    private func detectAvailability() async {
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

    private func detectPostgresAvailability(connectionId: String) async -> Bool? {
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

    private func postgresDashboardLoop() async {
        await refreshPostgresDashboard()
        while !Task.isCancelled && isActive && connectionId != nil && hasPostgres {
            try? await Task.sleep(nanoseconds: Self.postgresDashboardInterval)
            await refreshPostgresDashboard()
        }
    }

    private func refreshPostgresDashboard() async {
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

    private var postgresDashboardPreviewItems: [PostgresDashboardPreviewItem] {
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

    private var postgresDashboardCompactLine: String {
        [
            "v \(postgresDashboardVersionShort(postgresDashboard))",
            "\(postgresDashboard.value("database_size"))",
            "\(postgresDashboard.value("sessions")) sessions",
            "\(postgresDashboard.value("locks_waiting")) locks",
            "\(postgresDashboardCacheHitText(postgresDashboard)) cache",
        ].joined(separator: " · ")
    }

    private var postgresDashboardHelp: String {
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

    private func shortPostgresDashboardError(_ value: String) -> String {
        let firstLine = value.lines()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Dashboard unavailable"
        return String(firstLine.prefix(120))
    }
}

private struct SystemdTimer: Identifiable, Hashable {
    let timer: String
    let next: String
    let left: String
    let last: String
    let passed: String
    let unit: String
    let activates: String

    var id: String { timer }
    var nextSortKey: String { systemdTimerTimestampSortKey(next) }
    var leftSortSeconds: Int64 { systemdTimerRelativeDurationSortKey(left) }
    var lastSortKey: String { systemdTimerTimestampSortKey(last) }
}

private func systemdTimerTimestampSortKey(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "n/a" else { return "~" }
    let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.count >= 3,
       isSystemdWeekday(fields[0]),
       looksLikeSystemdDate(fields[1]),
       looksLikeSystemdTime(fields[2]) {
        return "\(fields[1]) \(fields[2]) \(fields.count >= 4 ? fields[3] : "")"
    }
    if fields.count >= 2,
       looksLikeSystemdDate(fields[0]),
       looksLikeSystemdTime(fields[1]) {
        return "\(fields[0]) \(fields[1]) \(fields.count >= 3 ? fields[2] : "")"
    }
    return trimmed
}

private func systemdTimerRelativeDurationSortKey(_ value: String) -> Int64 {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty, trimmed != "n/a" else { return Int64.max }

    var total: Int64 = 0
    var pendingNumber: Int64?
    for rawPart in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
        let part = rawPart.trimmingCharacters(in: CharacterSet(charactersIn: ",.;()[]"))
        guard part != "left", part != "ago" else { continue }

        let digits = part.prefix { $0.isNumber }
        if !digits.isEmpty, let number = Int64(digits) {
            let unit = String(part.dropFirst(digits.count))
            if unit.isEmpty {
                pendingNumber = number
            } else {
                total += number * systemdTimerDurationMultiplier(unit)
                pendingNumber = nil
            }
            continue
        }

        if let number = pendingNumber {
            total += number * systemdTimerDurationMultiplier(part)
            pendingNumber = nil
        }
    }

    return total == 0 && trimmed != "0" ? Int64.max - 1 : total
}

private func systemdTimerDurationMultiplier(_ rawUnit: String) -> Int64 {
    let unit = rawUnit.lowercased()
    if unit.hasPrefix("us") { return 0 }
    if unit.hasPrefix("ms") { return 0 }
    if unit == "s" || unit.hasPrefix("sec") { return 1 }
    if unit.hasPrefix("min") { return 60 }
    if unit == "m" { return 60 }
    if unit == "h" || unit.hasPrefix("hour") { return 3_600 }
    if unit == "d" || unit.hasPrefix("day") { return 86_400 }
    if unit == "w" || unit.hasPrefix("week") { return 604_800 }
    if unit.hasPrefix("month") { return 2_592_000 }
    if unit == "y" || unit.hasPrefix("year") { return 31_536_000 }
    return 1
}

private func parseSystemdUnitLine(_ line: String, unitFileStates: [String: String] = [:]) -> SystemdUnit? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard fields.count >= 4, fields[0].hasSuffix(".service") else { return nil }

    return SystemdUnit(
        name: fields[0],
        load: fields[1],
        active: fields[2],
        sub: fields[3],
        unitFileState: unitFileStates[fields[0]] ?? "",
        description: fields.count >= 5 ? fields[4] : ""
    )
}

private func parseSystemdUnitFileStates(_ output: String) -> [String: String] {
    var states: [String: String] = [:]
    for line in output.lines() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, fields[0].hasSuffix(".service") else { continue }
        states[fields[0]] = fields[1]
    }
    return states
}

private func parseSystemdProperties(_ output: String) -> [String: String] {
    var properties: [String: String] = [:]
    for line in output.lines() {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        properties[String(parts[0])] = String(parts[1])
    }
    return properties
}

private func formatSystemdBytes(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "-", trimmed != "[not set]", let bytes = Int64(trimmed) else {
        return "-"
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}

private func formatSystemdNanoseconds(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "-", let nanoseconds = Double(trimmed), nanoseconds > 0 else {
        return "-"
    }
    let seconds = nanoseconds / 1_000_000_000
    if seconds < 1 {
        return String(format: "%.0f ms", seconds * 1_000)
    }
    if seconds < 60 {
        return String(format: "%.1f s", seconds)
    }
    let minutes = Int(seconds / 60)
    let remaining = Int(seconds.truncatingRemainder(dividingBy: 60))
    return "\(minutes)m \(remaining)s"
}

private func parseSystemdTimerLine(_ line: String) -> SystemdTimer? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    if fields.first == "●" {
        fields.removeFirst()
    }
    guard let timerIndex = fields.firstIndex(where: { $0.hasSuffix(".timer") }) else { return nil }

    let timer = fields[timerIndex]
    let activates = fields.dropFirst(timerIndex + 1).joined(separator: " ")
    let schedule = Array(fields[..<timerIndex])
    let parsedSchedule = parseSystemdTimerSchedule(schedule)

    return SystemdTimer(
        timer: timer,
        next: parsedSchedule.next,
        left: parsedSchedule.left,
        last: parsedSchedule.last,
        passed: parsedSchedule.passed,
        unit: timer,
        activates: activates
    )
}

private func parseSystemdTimerSchedule(_ fields: [String]) -> (next: String, left: String, last: String, passed: String) {
    guard !fields.isEmpty else {
        return ("", "", "", "")
    }
    if fields.count >= 4 && fields.prefix(4).allSatisfy({ $0 == "n/a" }) {
        return ("n/a", "n/a", "n/a", "n/a")
    }

    let nextEnd = systemdTimestampEnd(in: fields, from: 0)
    let next = fields[0..<nextEnd].joined(separator: " ")

    var cursor = nextEnd
    let left: String
    let lastStart: Int
    if next == "n/a", cursor < fields.count {
        left = fields[cursor]
        cursor += 1
        lastStart = cursor
    } else if let foundLastStart = systemdTimestampStart(in: fields, from: cursor) {
        lastStart = foundLastStart
        left = fields[cursor..<foundLastStart].joined(separator: " ")
    } else {
        return (next, fields[cursor...].joined(separator: " "), "", "")
    }

    guard lastStart < fields.count else {
        return (next, left, "", "")
    }
    let lastEnd = systemdTimestampEnd(in: fields, from: lastStart)
    let last = fields[lastStart..<lastEnd].joined(separator: " ")
    let passed = lastEnd < fields.count ? fields[lastEnd...].joined(separator: " ") : ""
    return (next, left, last, passed)
}

private func systemdTimestampStart(in fields: [String], from start: Int) -> Int? {
    guard start < fields.count else { return nil }
    for index in start..<fields.count {
        if fields[index] == "n/a" {
            return index
        }
        if isSystemdWeekday(fields[index]),
           index + 2 < fields.count,
           looksLikeSystemdDate(fields[index + 1]),
           looksLikeSystemdTime(fields[index + 2]) {
            return index
        }
        if looksLikeSystemdDate(fields[index]),
           index + 1 < fields.count,
           looksLikeSystemdTime(fields[index + 1]) {
            return index
        }
    }
    return nil
}

private func systemdTimestampEnd(in fields: [String], from start: Int) -> Int {
    guard start < fields.count else { return start }
    if fields[start] == "n/a" {
        return start + 1
    }
    if isSystemdWeekday(fields[start]),
       start + 2 < fields.count,
       looksLikeSystemdDate(fields[start + 1]),
       looksLikeSystemdTime(fields[start + 2]) {
        return min(start + 4, fields.count)
    }
    if looksLikeSystemdDate(fields[start]),
       start + 1 < fields.count,
       looksLikeSystemdTime(fields[start + 1]) {
        return min(start + 3, fields.count)
    }
    return start + 1
}

private func isSystemdWeekday(_ value: String) -> Bool {
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(value)
}

private func looksLikeSystemdDate(_ value: String) -> Bool {
    value.count == 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-"
}

private func looksLikeSystemdTime(_ value: String) -> Bool {
    value.contains(":")
}

struct SystemdMonitorView: View {
    let connectionId: String?
    let profileId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
        case services = "Services"
        case failed = "Failed"
        case timers = "Timers"
        case journal = "System Journal"
    }

    private enum UnitDetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case dependencies = "Dependencies"
        case unitFile = "Unit File"
        case properties = "Properties"

        var id: String { rawValue }

        var compactTitle: String {
            switch self {
            case .overview: return "Overview"
            case .logs: return "Logs"
            case .dependencies: return "Deps"
            case .unitFile: return "Unit"
            case .properties: return "Props"
            }
        }
    }

    private enum ServiceScope: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Problems"
        case active = "Active"
        case enabled = "Enabled"
        case watched = "Watched"

        var id: String { rawValue }

        var emptyTitle: String {
            switch self {
            case .all: return "No services"
            case .problems: return "No problem services"
            case .active: return "No active services"
            case .enabled: return "No enabled services"
            case .watched: return "No watched services"
            }
        }
    }

    @State private var mode: Mode = .services
    @State private var units: [SystemdUnit] = []
    @State private var timers: [SystemdTimer] = []
    @State private var selectedUnit: SystemdUnit?
    @State private var selectedTimer: SystemdTimer?
    @State private var unitDetail: String = ""
    @State private var dependencies: String = ""
    @State private var unitFileText: String = ""
    @State private var unitJournal: String = ""
    @State private var journal: String = ""
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var liveJournal = false
    @State private var wrapJournalLines = true
    @State private var journalPriority: JournalPriority = .all
    @State private var journalTail: Int = 200
    @State private var pendingAction: UnitAction?
    @State private var unitDetailTab: UnitDetailTab = .overview
    @State private var showsRawProperties = false
    @State private var serviceScope: ServiceScope = .all

    private static let journalTailOptions: [Int] = [100, 200, 500, 1000, 2000]

    fileprivate enum JournalPriority: String, CaseIterable, Identifiable {
        case all = "All"
        case info = "Info+"
        case notice = "Notice+"
        case warning = "Warning+"
        case error = "Error+"
        case critical = "Critical+"
        var id: String { rawValue }
        var flagValue: String? {
            switch self {
            case .all: return nil
            case .info: return "info"
            case .notice: return "notice"
            case .warning: return "warning"
            case .error: return "err"
            case .critical: return "crit"
            }
        }
    }

    @State private var unitSortOrder: [KeyPathComparator<SystemdUnit>] = [
        .init(\.statusSortRank),
        .init(\.name)
    ]
    @State private var timerSortOrder: [KeyPathComparator<SystemdTimer>] = [
        .init(\.leftSortSeconds),
        .init(\.timer)
    ]
    @ObservedObject private var connectionStore = ConnectionStoreManager.shared

    private let logger = Logger(subsystem: "com.mc-ssh", category: "systemd-monitor")
    private static let pollInterval: UInt64 = 5_000_000_000

    fileprivate struct UnitAction: Identifiable {
        let id = UUID()
        let verb: String
        let unit: String
        var destructive: Bool {
            ["stop", "restart", "kill", "disable", "mask"].contains(verb)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if connectionId == nil {
                placeholderView(
                    icon: "network.slash",
                    title: "No connection",
                    message: "Open an SSH workspace to inspect systemd."
                )
            } else if let error {
                errorPane(error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue):\(liveJournal)") {
            await refresh()
            if mode == .journal && liveJournal {
                await journalLoop()
            }
        }
        .onChange(of: selectedUnit?.id) { _ in
            Task { await loadSelectedUnitDetail() }
        }
        .onChange(of: mode) { _ in
            ensureVisibleSelection()
        }
        .onChange(of: search) { _ in
            ensureVisibleSelection()
        }
        .onChange(of: serviceScope) { _ in
            ensureVisibleSelection()
        }
        .confirmationDialog(
            "Confirm systemd action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("\(action.verb) \(action.unit)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("Run systemctl \(action.verb) on \(connectionLabel)?")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text("Services \(units.count)").tag(Mode.services)
                Text("Failed \(failedUnitCount)").tag(Mode.failed)
                Text("Timers \(timers.count)").tag(Mode.timers)
                Text(Mode.journal.rawValue).tag(Mode.journal)
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            if mode == .journal {
                Toggle("Live", isOn: $liveJournal)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
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

    private var serviceScopeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Service scope")
            Picker("", selection: $serviceScope) {
                Text("All \(units.count)").tag(ServiceScope.all)
                Text("Problems \(problemUnitCount)").tag(ServiceScope.problems)
                Text("Active \(activeUnitCount)").tag(ServiceScope.active)
                Text("Enabled \(enabledUnitCount)").tag(ServiceScope.enabled)
                Text("Watched \(watchedUnitCount)").tag(ServiceScope.watched)
            }
            .pickerStyle(.segmented)
            .frame(width: 500)
            Spacer()
            Text("\(sortedFilteredUnits.count) shown")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .services, .failed:
            VStack(spacing: 0) {
                if mode == .services {
                    serviceScopeBar
                    Divider()
                }
                if sortedFilteredUnits.isEmpty {
                    unitEmptyState
                } else {
                    HSplitView {
                        unitList
                            .frame(minWidth: 560, idealWidth: 700)
                        unitDetailPane
                            .frame(minWidth: 420, idealWidth: 520)
                    }
                }
            }
        case .timers:
            if filteredTimers.isEmpty {
                placeholderView(
                    icon: search.isEmpty ? "timer" : "magnifyingglass",
                    title: search.isEmpty ? "No timers" : "No matching timers",
                    message: search.isEmpty
                        ? "systemctl returned no timer units."
                        : "No timer matches the current filter."
                )
            } else {
                timerList
            }
        case .journal:
            journalPane
        }
    }

    @ViewBuilder
    private var unitEmptyState: some View {
        let hasFilter = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if loading {
            placeholderView(
                icon: "hourglass",
                title: "Loading services",
                message: "Fetching service units from \(connectionLabel)."
            )
        } else if hasFilter {
            placeholderView(
                icon: "magnifyingglass",
                title: "No matching services",
                message: "No service matches the current filter."
            )
        } else if mode == .services && serviceScope != .all {
            placeholderView(
                icon: "line.3.horizontal.decrease.circle",
                title: serviceScope.emptyTitle,
                message: "No service matches the selected service scope."
            )
        } else if mode == .failed {
            placeholderView(
                icon: "checkmark.circle",
                title: "No failed services",
                message: "systemctl reports no failed service units."
            )
        } else {
            placeholderView(
                icon: "list.bullet.rectangle",
                title: "No services",
                message: "systemctl returned no service units."
            )
        }
    }

    private var filteredUnits: [SystemdUnit] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var base = mode == .failed ? units.filter(\.isFailed) : units
        if mode == .services {
            switch serviceScope {
            case .all:
                break
            case .problems:
                base = base.filter(\.hasOperationalProblem)
            case .active:
                base = base.filter(\.isActive)
            case .enabled:
                base = base.filter(\.isEnabled)
            case .watched:
                base = base.filter {
                    connectionStore.isMonitoringSystemdService($0.name, profileId: profileId)
                }
            }
        }
        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.active.lowercased().contains(needle)
                || $0.sub.lowercased().contains(needle)
                || $0.unitFileState.lowercased().contains(needle)
        }
    }

    private var failedUnitCount: Int {
        units.filter(\.isFailed).count
    }

    private var problemUnitCount: Int {
        units.filter(\.hasOperationalProblem).count
    }

    private var activeUnitCount: Int {
        units.filter(\.isActive).count
    }

    private var enabledUnitCount: Int {
        units.filter(\.isEnabled).count
    }

    private var watchedUnitCount: Int {
        units.filter {
            connectionStore.isMonitoringSystemdService($0.name, profileId: profileId)
        }.count
    }

    private var sortedFilteredUnits: [SystemdUnit] {
        filteredUnits.sorted(using: unitSortOrder)
    }

    private var selectedUnitId: Binding<String?> {
        Binding(
            get: { selectedUnit?.id },
            set: { id in
                let unit = id.flatMap { selectedId in
                    sortedFilteredUnits.first { $0.id == selectedId }
                        ?? units.first { $0.id == selectedId }
                }
                selectUnit(unit)
            }
        )
    }

    private func selectUnit(_ unit: SystemdUnit?, resetDetailTab: Bool = true) {
        let changed = selectedUnit?.id != unit?.id
        selectedUnit = unit
        if resetDetailTab, changed, let unit {
            unitDetailTab = preferredDetailTab(for: unit)
        }
    }

    private func preferredDetailTab(for unit: SystemdUnit) -> UnitDetailTab {
        unit.hasOperationalProblem ? .logs : .overview
    }

    private func ensureVisibleSelection() {
        guard mode == .services || mode == .failed else { return }
        let visibleUnits = sortedFilteredUnits
        guard !visibleUnits.isEmpty else {
            selectUnit(nil)
            return
        }
        if let selectedUnit, visibleUnits.contains(where: { $0.id == selectedUnit.id }) {
            return
        }
        selectUnit(visibleUnits.first)
    }

    private var unitList: some View {
        Table(sortedFilteredUnits, selection: selectedUnitId, sortOrder: $unitSortOrder) {
            TableColumn("Watch") { unit in
                let isWatching = connectionStore.isMonitoringSystemdService(unit.name, profileId: profileId)
                Button {
                    connectionStore.setMonitoringSystemdService(!isWatching, serviceName: unit.name, profileId: profileId)
                } label: {
                    Image(systemName: isWatching ? "eye.fill" : "eye")
                        .foregroundStyle(isWatching ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(connectionId == nil)
                .help(isWatching ? "Remove \(unit.name) from the monitor pane" : "Show \(unit.name) in the monitor pane")
            }
            .width(min: 38, ideal: 42, max: 48)

            TableColumn("Service", value: \.name) { unit in
                HStack(spacing: 6) {
                    Circle()
                        .fill(systemdIndicatorColor(active: unit.active, sub: unit.sub))
                        .frame(width: 8, height: 8)
                    Text(unit.name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            .width(min: 210, ideal: 320, max: 440)

            TableColumn("Status", value: \.statusSortKey) { unit in
                HStack(spacing: 4) {
                    statusBadge(
                        unit.active,
                        color: systemdStateColor(unit.active, unit: unit),
                        emphasized: unit.hasOperationalProblem
                    )
                    if !unit.sub.isEmpty && unit.sub != unit.active {
                        statusBadge(
                            unit.sub,
                            color: systemdStateColor(unit.sub, unit: unit),
                            emphasized: unit.hasOperationalProblem
                        )
                    }
                }
            }
            .width(min: 120, ideal: 150, max: 210)

            TableColumn("Enabled", value: \.unitFileState) { unit in
                statusBadge(
                    unit.unitFileState.isEmpty ? "-" : unit.unitFileState,
                    color: systemdFileStateColor(unit.unitFileState),
                    emphasized: unit.unitFileState.lowercased() == "masked"
                )
            }
            .width(min: 80, ideal: 94, max: 124)

            TableColumn("Description", value: \.description) { unit in
                Text(unit.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if let unit = selected.first.flatMap({ id in units.first { $0.id == id } }) {
                unitActions(unit)
            }
        }
    }

    private var timerList: some View {
        Table(sortedFilteredTimers, selection: selectedTimerId, sortOrder: $timerSortOrder) {
            TableColumn("Timer", value: \.timer) { timer in
                monoCell(timer.timer)
            }
            .width(min: 190, ideal: 260)

            TableColumn("Next", value: \.nextSortKey) { timer in
                monoCell(timer.next, color: .secondary)
            }
            .width(min: 190, ideal: 260)

            TableColumn("Left", value: \.leftSortSeconds) { timer in
                monoCell(timer.left)
            }
            .width(min: 90, ideal: 125, max: 170)

            TableColumn("Activates", value: \.activates) { timer in
                monoCell(timer.activates)
            }
            .width(min: 190, ideal: 280)
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if let timer = selected.first.flatMap({ id in timers.first { $0.id == id } }) {
                Button("Show Linked Service") {
                    mode = .services
                    if let unit = units.first(where: { $0.name == timer.activates }) {
                        selectUnit(unit)
                    }
                }
                Button("Copy Timer") { RemoteCommandRunner.copy(timer.timer) }
                Button("Copy Activates") { RemoteCommandRunner.copy(timer.activates) }
            }
        }
    }

    private var selectedTimerId: Binding<String?> {
        Binding(
            get: { selectedTimer?.id },
            set: { id in
                selectedTimer = id.flatMap { selectedId in
                    timers.first { $0.id == selectedId }
                }
            }
        )
    }

    private var filteredTimers: [SystemdTimer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return timers }
        return timers.filter {
            $0.timer.lowercased().contains(needle)
                || $0.next.lowercased().contains(needle)
                || $0.left.lowercased().contains(needle)
                || $0.activates.lowercased().contains(needle)
        }
    }

    private var sortedFilteredTimers: [SystemdTimer] {
        filteredTimers.sorted(using: timerSortOrder)
    }

    private var unitDetailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedUnit {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedUnit.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(selectedUnit.description.isEmpty ? "No description" : selectedUnit.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    unitInlineActions(selectedUnit)
                    Menu {
                        unitActions(selectedUnit)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                Divider()
                Picker("", selection: $unitDetailTab) {
                    ForEach(UnitDetailTab.allCases) { tab in
                        Text(tab.compactTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .help(unitDetailTab.rawValue)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
                unitDetailContent(selectedUnit)
            } else {
                placeholderView(
                    icon: "list.bullet.rectangle",
                    title: "Select a unit",
                    message: "Choose a service to inspect properties, dependencies, and recent journal entries."
                )
            }
        }
    }

    @ViewBuilder
    private func unitDetailContent(_ unit: SystemdUnit) -> some View {
        switch unitDetailTab {
        case .overview:
            unitOverview(unit)
        case .logs:
            if filteredUnitJournalLines.isEmpty {
                placeholderView(
                    icon: "doc.text",
                    title: "No unit logs",
                    message: "journalctl returned no recent entries for this unit."
                )
            } else {
                journalEntriesList(lines: filteredUnitJournalLines, autoScroll: false)
            }
        case .dependencies:
            detailScrollBlock(value: dependencies.isEmpty ? "-" : dependencies)
        case .unitFile:
            detailScrollBlock(value: unitFileText.isEmpty ? "-" : unitFileText, mode: .systemdUnit)
        case .properties:
            unitPropertiesView(unit)
        }
    }

    @ViewBuilder
    private func unitInlineActions(_ unit: SystemdUnit) -> some View {
        HStack(spacing: 4) {
            Button {
                pendingAction = UnitAction(verb: "start", unit: unit.name)
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(unit.isActive || unit.isTransitional || !unit.isLoaded)
            .help("Start \(unit.name)")

            Button {
                pendingAction = UnitAction(verb: "stop", unit: unit.name)
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!unit.isActive && !unit.isTransitional)
            .help("Stop \(unit.name)")

            Button {
                pendingAction = UnitAction(verb: "restart", unit: unit.name)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!unit.isLoaded)
            .help("Restart \(unit.name)")

            Button {
                unitDetailTab = .logs
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help("Show recent logs")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func unitOverview(_ unit: SystemdUnit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: unitSummaryColumns, alignment: .leading, spacing: 8) {
                    unitSummaryTile("Load", value: unit.load, color: systemdLoadColor(unit.load))
                    unitSummaryTile("Active", value: unit.active, color: systemdStateColor(unit.active, unit: unit))
                    unitSummaryTile("Sub", value: unit.sub, color: systemdStateColor(unit.sub, unit: unit))
                    unitSummaryTile("Enabled", value: unitEnabledState(unit), color: systemdFileStateColor(unitEnabledState(unit)))
                    unitSummaryTile("Main PID", value: unitProperty("MainPID"))
                    unitSummaryTile("Restarts", value: unitProperty("NRestarts"))
                    unitSummaryTile("Memory", value: formattedUnitMemory)
                    unitSummaryTile("CPU", value: formattedUnitCPU)
                }

                if unitJournalIssueCounts.hasIssues {
                    HStack(spacing: 8) {
                        Text("Recent journal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        JournalIssueBadges(counts: unitJournalIssueCounts)
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Unit file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(unitProperty("FragmentPath"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Raw properties", isExpanded: $showsRawProperties) {
                    detailScrollBlock(value: unitDetail.isEmpty ? "-" : unitDetail)
                        .frame(minHeight: 180)
                }
                .font(.caption.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func unitPropertiesView(_ unit: SystemdUnit) -> some View {
        let rows = unitPropertyRows(for: unit)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        unitPropertyRow(label: row.label, value: row.value, highlighted: index.isMultiple(of: 2))
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                DisclosureGroup("Raw systemctl show output", isExpanded: $showsRawProperties) {
                    detailScrollBlock(value: unitDetail.isEmpty ? "-" : unitDetail)
                        .frame(minHeight: 180)
                }
                .font(.caption.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func unitPropertyRows(for unit: SystemdUnit) -> [(label: String, value: String)] {
        [
            ("Unit", unitProperty("Id")),
            ("Description", unit.description.isEmpty ? unitProperty("Description") : unit.description),
            ("Load state", unitProperty("LoadState", fallback: unit.load)),
            ("Active state", unitProperty("ActiveState", fallback: unit.active)),
            ("Sub state", unitProperty("SubState", fallback: unit.sub)),
            ("Unit file state", unitEnabledState(unit)),
            ("Main PID", unitProperty("MainPID")),
            ("Restart count", unitProperty("NRestarts")),
            ("Memory", formattedUnitMemory),
            ("CPU", formattedUnitCPU),
            ("Started at", unitProperty("ActiveEnterTimestamp")),
            ("Fragment path", unitProperty("FragmentPath"))
        ]
    }

    private func unitPropertyRow(label: String, value: String, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(normalizedUnitValue(value))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted ? Color(NSColor.textBackgroundColor).opacity(0.55) : Color.clear)
    }

    private var unitSummaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 8, alignment: .top)]
    }

    private func unitSummaryTile(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(normalizedUnitValue(value))
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func unitProperty(_ key: String) -> String {
        unitProperties[key] ?? "-"
    }

    private func unitProperty(_ key: String, fallback: String) -> String {
        let value = unitProperties[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    private func unitEnabledState(_ unit: SystemdUnit) -> String {
        let fromList = unit.unitFileState.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromList.isEmpty {
            return fromList
        }
        return unitProperty("UnitFileState")
    }

    private var unitProperties: [String: String] {
        parseSystemdProperties(unitDetail)
    }

    private var formattedUnitMemory: String {
        formatSystemdBytes(unitProperty("MemoryCurrent"))
    }

    private var formattedUnitCPU: String {
        formatSystemdNanoseconds(unitProperty("CPUUsageNSec"))
    }

    private func normalizedUnitValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[not set]" || trimmed == "n/a" {
            return "-"
        }
        return trimmed
    }

    private func detailScrollBlock(value: String, mode: RawOutputHighlightMode = .generic) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value, mode: mode)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var journalPane: some View {
        VStack(spacing: 0) {
            journalToolbar
            Divider()
            if journal.isEmpty {
                placeholderView(
                    icon: "tray",
                    title: "No journal entries",
                    message: priorityFilteredEmptyMessage
                )
            } else if filteredJournalLines.isEmpty {
                placeholderView(
                    icon: "magnifyingglass",
                    title: "No matching journal entries",
                    message: "No entry matches the current filter."
                )
            } else {
                journalEntriesList
            }
        }
    }

    private var journalToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Picker("", selection: $journalPriority) {
                    ForEach(JournalPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .foregroundStyle(.secondary)
                Picker("", selection: $journalTail) {
                    ForEach(Self.journalTailOptions, id: \.self) { Text("\($0) lines").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            Text("System")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Wrap", isOn: $wrapJournalLines)
                .toggleStyle(.checkbox)
                .help("Wrap long journal messages")
            Text("\(filteredJournalLines.count) of \(rawJournalLines.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Copy") { RemoteCommandRunner.copy(filteredJournalLines.joined(separator: "\n")) }
                .disabled(filteredJournalLines.isEmpty)
                .controlSize(.small)
                .help("Copy visible journal entries")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onChange(of: journalPriority) { _ in Task { await loadJournal() } }
        .onChange(of: journalTail) { _ in Task { await loadJournal() } }
    }

    private var rawJournalLines: [String] {
        journal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var filteredJournalLines: [String] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = rawJournalLines.filter { !$0.isEmpty }
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(needle) }
    }

    private var rawUnitJournalLines: [String] {
        unitJournal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var filteredUnitJournalLines: [String] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = rawUnitJournalLines.filter { !$0.isEmpty }
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(needle) }
    }

    private var unitJournalIssueCounts: JournalIssueCounts {
        JournalIssueClassifier.counts(in: rawUnitJournalLines)
    }

    private var priorityFilteredEmptyMessage: String {
        switch journalPriority {
        case .all: return "journalctl returned nothing for this scope."
        case .info, .notice, .warning, .error, .critical:
            return "No entries at \(journalPriority.rawValue) or higher. Try lowering the priority filter."
        }
    }

    private var journalEntriesList: some View {
        journalEntriesList(lines: filteredJournalLines, autoScroll: liveJournal)
    }

    private func journalEntriesList(lines: [String], autoScroll: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(journalScrollAxes) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    journalColumnHeader
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        journalLineRow(line)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
                .frame(
                    minWidth: wrapJournalLines ? 0 : 1180,
                    maxWidth: wrapJournalLines ? .infinity : nil,
                    alignment: .leading
                )
            }
            .onChange(of: lines.count) { count in
                if autoScroll {
                    proxy.scrollTo(max(count - 1, 0), anchor: .bottom)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var journalScrollAxes: Axis.Set {
        wrapJournalLines ? .vertical : [.vertical, .horizontal]
    }

    private var journalColumnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear
                .frame(width: 3)
            Text("Time")
                .frame(width: 188, alignment: .leading)
            Text("Host")
                .frame(width: 74, alignment: .leading)
            Text("Process")
                .frame(width: 142, alignment: .leading)
            Text("Message")
                .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func journalLineRow(_ line: String) -> some View {
        let severityLevel = journalSeverity(line)
        let indicatorColor = severityLevel.accentColor
        let foregroundColor = severityLevel.foreground
        let backgroundColor = severityLevel.background
        let parts = splitJournalLine(line)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle()
                .fill(indicatorColor)
                .frame(width: 3)
            Text(parts.timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 188, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.timestamp)
            Text(parts.host)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 74, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.host)
            Text(parts.process)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 142, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.process)
            Text(parts.message)
                .font(.caption.monospaced())
                .foregroundStyle(foregroundColor)
                .textSelection(.enabled)
                .lineLimit(wrapJournalLines ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
                .fixedSize(horizontal: !wrapJournalLines, vertical: wrapJournalLines)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(backgroundColor)
    }

    private struct JournalLineParts {
        let timestamp: String
        let host: String
        let process: String
        let message: String
    }

    private func splitJournalLine(_ line: String) -> JournalLineParts {
        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, isLikelyJournalTimestamp(fields[0]) else {
            return JournalLineParts(timestamp: "", host: "", process: "", message: line)
        }

        let timestamp = fields[0]
        let host = fields.indices.contains(1) ? fields[1] : ""
        guard fields.count >= 3 else {
            return JournalLineParts(timestamp: timestamp, host: host, process: "", message: "")
        }

        var process = fields[2]
        var message = fields.indices.contains(3) ? fields[3] : ""
        if process.hasSuffix(":") {
            process.removeLast()
        } else if message.isEmpty {
            message = process
            process = ""
        } else {
            message = "\(process) \(message)"
            process = ""
        }

        return JournalLineParts(timestamp: timestamp, host: host, process: process, message: message)
    }

    private func isLikelyJournalTimestamp(_ value: String) -> Bool {
        (value.contains("-") || value.contains(":")) && value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func journalSeverity(_ line: String) -> JournalSeverity {
        let upper = line.uppercased()
        if upper.contains(" CRIT") || upper.contains("CRITICAL") || upper.contains(" EMERG") || upper.contains(" ALERT") {
            return .critical
        }
        if upper.contains(" ERR") || upper.contains("ERROR") || upper.contains("FAILED") || upper.contains("FATAL") {
            return .error
        }
        if upper.contains(" WARN") || upper.contains("WARNING") {
            return .warning
        }
        if upper.contains(" NOTICE") {
            return .notice
        }
        return .info
    }

    fileprivate enum JournalSeverity {
        case info, notice, warning, error, critical
        var accentColor: Color {
            switch self {
            case .info: return .clear
            case .notice: return .blue.opacity(0.6)
            case .warning: return .orange
            case .error: return .red
            case .critical: return .purple
            }
        }
        var foreground: Color {
            switch self {
            case .info, .notice: return .primary
            case .warning: return .orange
            case .error: return .red
            case .critical: return .purple
            }
        }
        var background: Color {
            switch self {
            case .info, .notice: return .clear
            case .warning: return Color.orange.opacity(0.06)
            case .error: return Color.red.opacity(0.07)
            case .critical: return Color.purple.opacity(0.1)
            }
        }
    }

    private func detailBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            logText(value.isEmpty ? "-" : value)
                .frame(minHeight: title == "Journal" ? 160 : 90)
        }
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statusBadge(_ text: String, color: Color, emphasized: Bool = true) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption2.weight(emphasized ? .semibold : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(emphasized ? 0.12 : 0.04), in: Capsule())
    }

    @ViewBuilder
    private func unitActions(_ unit: SystemdUnit) -> some View {
        let fragmentPath = unit.id == selectedUnit?.id ? unitProperties["FragmentPath", default: ""] : ""

        Button {
            pendingAction = UnitAction(verb: "start", unit: unit.name)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .disabled(unit.isActive || unit.isTransitional || !unit.isLoaded)

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "stop", unit: unit.name)
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .disabled(!unit.isActive && !unit.isTransitional)

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "restart", unit: unit.name)
        } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        .disabled(!unit.isLoaded)

        Button {
            pendingAction = UnitAction(verb: "reload", unit: unit.name)
        } label: {
            Label("Reload", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!unit.isActive)

        Divider()

        Button {
            pendingAction = UnitAction(verb: "enable", unit: unit.name)
        } label: {
            Label("Enable", systemImage: "checkmark.circle")
        }
        .disabled(unit.isEnabled || unit.unitFileState.lowercased() == "static" || unit.unitFileState.lowercased() == "generated")

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "disable", unit: unit.name)
        } label: {
            Label("Disable", systemImage: "slash.circle")
        }
        .disabled(!unit.isEnabled)

        Divider()

        Button {
            selectUnit(unit, resetDetailTab: false)
            unitDetailTab = .unitFile
            Task { await loadSelectedUnitDetail() }
        } label: {
            Label("View Unit File", systemImage: "doc.text.magnifyingglass")
        }

        Button {
            RemoteCommandRunner.copy(fragmentPath)
        } label: {
            Label("Copy Unit File Path", systemImage: "doc.on.doc")
        }
        .disabled(fragmentPath.isEmpty)

        Button {
            RemoteCommandRunner.copy(unit.name)
        } label: {
            Label("Copy Unit Name", systemImage: "doc.on.doc")
        }
    }

    private func refresh() async {
        guard connectionId != nil else { return }
        switch mode {
        case .services, .failed:
            await loadUnits()
        case .timers:
            await loadTimers()
        case .journal:
            await loadJournal()
        }
    }

    private func loadUnits() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        run_systemctl() {
          out=$(systemctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n systemctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        out=$(systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-units failed:\\n%s\\n\\nsudo -n systemctl list-units failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-units failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        files=$(run_systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true)
        echo '---UNITS---'
        printf '%s\\n' "$out"
        echo '---UNIT_FILES---'
        printf '%s\\n' "$files"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            let unitOutput = output.section(after: "---UNITS---", before: "---UNIT_FILES---")
            let fileOutput = output.section(after: "---UNIT_FILES---", before: nil)
            let fileStates = parseSystemdUnitFileStates(fileOutput)
            let parsed = unitOutput.lines().compactMap { parseSystemdUnitLine($0, unitFileStates: fileStates) }
            units = parsed
            if let selectedUnit,
               let refreshedSelection = parsed.first(where: { $0.id == selectedUnit.id }) {
                selectUnit(refreshedSelection, resetDetailTab: false)
            } else {
                selectUnit(parsed.first(where: \.hasOperationalProblem) ?? parsed.first)
            }
            ensureVisibleSelection()
            error = nil
            await loadSelectedUnitDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadTimers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        out=$(systemctl list-timers --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-timers --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-timers failed:\\n%s\\n\\nsudo -n systemctl list-timers failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-timers failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        printf '%s\\n' "$out"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            timers = output.lines().compactMap(parseSystemdTimerLine)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSelectedUnitDetail() async {
        guard let connectionId, let selectedUnit else { return }
        let unit = RemoteCommandRunner.shellQuote(selectedUnit.name)
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        run_systemctl() {
          out=$(systemctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n systemctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        run_journalctl() {
          out=$(journalctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n journalctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        echo '---PROPERTIES---'
        run_systemctl show \(unit) --no-pager -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID -p ActiveEnterTimestamp -p FragmentPath -p MemoryCurrent -p CPUUsageNSec || true
        echo '---DEPENDENCIES---'
        run_systemctl list-dependencies --plain --no-pager \(unit) | sed -n '1,120p' || true
        echo '---REVERSE---'
        run_systemctl list-dependencies --reverse --plain --no-pager \(unit) | sed -n '1,80p' || true
        echo '---UNIT_FILE---'
        run_systemctl cat \(unit) --no-pager || true
        echo '---JOURNAL---'
        run_journalctl -u \(unit) -n 160 --no-pager -o short-iso || true
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            unitDetail = output.section(after: "---PROPERTIES---", before: "---DEPENDENCIES---")
            dependencies = output.section(after: "---DEPENDENCIES---", before: "---UNIT_FILE---")
            unitFileText = output.section(after: "---UNIT_FILE---", before: "---JOURNAL---")
            unitJournal = output.section(after: "---JOURNAL---", before: nil)
            error = nil
        } catch {
            unitDetail = "Could not load unit details: \(error.localizedDescription)"
            dependencies = ""
            unitFileText = ""
            unitJournal = ""
        }
    }

    private func journalLoop() async {
        while !Task.isCancelled && liveJournal {
            await loadJournal()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func loadJournal() async {
        guard let connectionId else { return }
        let priorityArg = journalPriority.flagValue.map { "-p \($0)" } ?? ""
        loading = true
        defer { loading = false }
        let script = """
        command -v journalctl >/dev/null || { echo journalctl not found; exit 127; }
        run_journalctl() {
          out=$(journalctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n journalctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        run_journalctl \(priorityArg) -n \(journalTail) --no-pager -o short-iso || true
        """
        do {
            journal = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ action: UnitAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        let script = "systemctl \(action.verb) \(RemoteCommandRunner.shellQuote(action.unit)) 2>&1"
        do {
            _ = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            await loadUnits()
        } catch {
            logger.error("systemctl \(action.verb, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func errorPane(_ message: String) -> some View {
        placeholderView(icon: "exclamationmark.triangle", title: "systemd unavailable", message: message)
    }
}

// MARK: - Docker

private struct DockerContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: String
    let cpu: String
    let memory: String
    let netIO: String
    let health: String
    let restarts: String
    let composeProject: String
}

private struct DockerAsset: Identifiable, Hashable {
    let id: String
    let columns: [String]

    var imageName: String { column(0) }
    var imageId: String { column(1) }
    var imageSizeText: String { column(2) }
    var imageSizeBytes: Int64 { Self.parseByteSize(imageSizeText) }
    var imageCreated: String { column(3) }

    func column(_ index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        return columns[index]
    }

    private static func parseByteSize(_ value: String) -> Int64 {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return 0 }

        var numberPart = ""
        var unitPart = ""
        for character in token {
            if character.isNumber || character == "." {
                numberPart.append(character)
            } else if !numberPart.isEmpty {
                unitPart.append(character)
            }
        }

        guard let value = Double(numberPart) else { return 0 }
        let unit = unitPart.lowercased()
        let multiplier: Double
        if unit.hasPrefix("t") {
            multiplier = 1_000_000_000_000
        } else if unit.hasPrefix("g") {
            multiplier = 1_000_000_000
        } else if unit.hasPrefix("m") {
            multiplier = 1_000_000
        } else if unit.hasPrefix("k") {
            multiplier = 1_000
        } else {
            multiplier = 1
        }
        return Int64(value * multiplier)
    }
}

private struct DockerEvent: Identifiable, Hashable {
    let id: String
    let timestampRaw: String
    let kind: String
    let action: String
    let actorId: String
    let name: String
    let image: String
    let container: String
    let raw: String

    var date: Date? {
        if let seconds = TimeInterval(timestampRaw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: timestampRaw)
    }

    var displayTime: String {
        guard let date else { return timestampRaw.isEmpty ? "-" : timestampRaw }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    var fullTimestamp: String {
        guard let date else { return timestampRaw.isEmpty ? "-" : timestampRaw }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }

    var objectLabel: String {
        for value in [name, image, container, actorId] {
            let normalized = Self.normalized(value)
            if !normalized.isEmpty {
                return Self.compactIdentifier(normalized)
            }
        }
        return "-"
    }

    var rawText: String {
        [
            "time: \(fullTimestamp)",
            "type: \(kind.isEmpty ? "-" : kind)",
            "action: \(action.isEmpty ? "-" : action)",
            "object: \(objectLabel)",
            "actor_id: \(actorId.isEmpty ? "-" : actorId)",
            "name: \(name.isEmpty ? "-" : name)",
            "image: \(image.isEmpty ? "-" : image)",
            "container: \(container.isEmpty ? "-" : container)",
            "raw: \(raw)"
        ].joined(separator: "\n")
    }

    var searchText: String {
        [timestampRaw, fullTimestamp, kind, action, actorId, name, image, container, raw]
            .joined(separator: " ")
    }

    static func parse(_ line: String, index: Int) -> DockerEvent {
        let fields = splitFields(line)
        func field(_ offset: Int) -> String {
            guard fields.indices.contains(offset) else { return "" }
            return normalized(fields[offset])
        }
        return DockerEvent(
            id: "\(index):\(line)",
            timestampRaw: field(0),
            kind: field(1),
            action: field(2),
            actorId: field(3),
            name: field(4),
            image: field(5),
            container: field(6),
            raw: line
        )
    }

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "<no value>" ? "" : trimmed
    }

    static func compactIdentifier(_ value: String) -> String {
        guard value.count > 28 else { return value }
        let prefixCount = value.hasPrefix("sha256:") ? 19 : 16
        return "\(value.prefix(prefixCount))...\(value.suffix(8))"
    }
}

private struct DockerEventQuery {
    var terms: [String] = []
    var kind: String?
    var action: String?
    var resource: String?
    var identifier: String?
    var since: TimeInterval?
}

private enum DockerDiskSection: String, Hashable {
    case images
    case containers
    case volumes
    case buildCache

    var title: String {
        switch self {
        case .images: return "Images"
        case .containers: return "Containers"
        case .volumes: return "Volumes"
        case .buildCache: return "Build Cache"
        }
    }

    var emptyTitle: String {
        switch self {
        case .images: return "No image disk usage found"
        case .containers: return "No container disk usage found"
        case .volumes: return "No local volumes using space"
        case .buildCache: return "No build cache entries found"
        }
    }

    var emptyMessage: String {
        switch self {
        case .images: return "Docker did not report image rows for this host."
        case .containers: return "Docker did not report stopped or running containers using local space."
        case .volumes: return "There are no local volume rows in the disk report."
        case .buildCache: return "Build cache is empty, filtered out, or unavailable from this Docker version."
        }
    }
}

private enum DockerDiskQuickFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case large = "Large"
    case stale = "7+ days"
    case buildCache = "Build cache"

    var id: String { rawValue }
}

private struct DockerDiskSummaryItem: Identifiable, Hashable {
    let section: DockerDiskSection
    let total: String
    let active: String
    let size: String
    let sizeBytes: Int64
    let reclaimable: String
    let reclaimableBytes: Int64

    var id: String { section.rawValue }

    var activityText: String {
        if total.isEmpty && active.isEmpty { return "No activity counts" }
        if active.isEmpty { return "\(total) total" }
        return "\(total) total, \(active) active"
    }
}

private struct DockerDiskRow: Identifiable, Hashable {
    let id: String
    let section: DockerDiskSection
    let repository: String
    let tag: String
    let imageId: String
    let created: String
    let size: String
    let sizeBytes: Int64
    let sharedSize: String
    let uniqueSize: String
    let containers: String
    let containerId: String
    let image: String
    let command: String
    let localVolumes: String
    let status: String
    let name: String
    let volumeName: String
    let links: String
    let cacheId: String
    let cacheType: String
    let lastUsed: String
    let usage: String
    let shared: String

    var searchText: String {
        [
            repository, tag, imageId, created, size, sharedSize, uniqueSize, containers,
            containerId, image, command, localVolumes, status, name, volumeName, links,
            cacheId, cacheType, lastUsed, usage, shared
        ]
        .joined(separator: " ")
        .lowercased()
    }

    var previewName: String {
        switch section {
        case .images:
            return repository.isEmpty ? imageId : "\(repository):\(tag)"
        case .containers:
            return name.isEmpty ? containerId : name
        case .volumes:
            return volumeName
        case .buildCache:
            return cacheId
        }
    }

    var isLarge: Bool {
        sizeBytes >= 100_000_000
    }

    var isOlderThanWeek: Bool {
        Self.isOlderThanWeek(created) || Self.isOlderThanWeek(lastUsed)
    }

    private static func isOlderThanWeek(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("month") || lower.contains("year") { return true }
        let amount = Int(lower.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
        if lower.contains("week") { return amount >= 1 }
        if lower.contains("day") { return amount >= 7 }
        return false
    }
}

private struct DockerDiskSnapshot {
    var rawText: String = ""
    var summaries: [DockerDiskSummaryItem] = []
    var images: [DockerDiskRow] = []
    var containers: [DockerDiskRow] = []
    var volumes: [DockerDiskRow] = []
    var buildCache: [DockerDiskRow] = []
    var refreshedAt: Date?

    static let empty = DockerDiskSnapshot()

    var totalSizeBytes: Int64 {
        let summaryTotal = summaries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if summaryTotal > 0 { return summaryTotal }
        return [images, containers, volumes, buildCache]
            .flatMap { $0 }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    func rows(for section: DockerDiskSection) -> [DockerDiskRow] {
        switch section {
        case .images: return images
        case .containers: return containers
        case .volumes: return volumes
        case .buildCache: return buildCache
        }
    }

    func summary(for section: DockerDiskSection) -> DockerDiskSummaryItem? {
        summaries.first { $0.section == section }
    }

    func sizeText(for section: DockerDiskSection) -> String {
        if let summary = summary(for: section), !summary.size.isEmpty {
            return summary.size
        }
        let bytes = rows(for: section).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return bytes > 0 ? Self.formatBytes(bytes) : "0 B"
    }

    func reclaimableText(for section: DockerDiskSection) -> String {
        guard let summary = summary(for: section), !summary.reclaimable.isEmpty else {
            return "No reclaimable estimate"
        }
        return "\(summary.reclaimable) reclaimable"
    }

    static func parse(_ output: String, refreshedAt: Date = Date()) -> DockerDiskSnapshot {
        let lines = output.lines()
        var snapshot = DockerDiskSnapshot(
            rawText: output,
            summaries: parseSummary(lines),
            images: parseImages(lines),
            containers: parseContainers(lines),
            volumes: parseVolumes(lines),
            buildCache: parseBuildCache(lines),
            refreshedAt: refreshedAt
        )

        if snapshot.summary(for: .buildCache) == nil,
           let buildCacheSize = parseBuildCacheUsage(lines) {
            snapshot.summaries.append(
                DockerDiskSummaryItem(
                    section: .buildCache,
                    total: "\(snapshot.buildCache.count)",
                    active: "",
                    size: buildCacheSize,
                    sizeBytes: parseByteSize(buildCacheSize),
                    reclaimable: buildCacheSize,
                    reclaimableBytes: parseByteSize(buildCacheSize)
                )
            )
        }

        return snapshot
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func parseSummary(_ lines: [String]) -> [DockerDiskSummaryItem] {
        let summaryLines: [String]
        if let firstSection = lines.firstIndex(where: isSectionTitle) {
            summaryLines = Array(lines[..<firstSection])
        } else {
            summaryLines = lines
        }
        let rows = parseFixedWidthRows(
            summaryLines,
            labels: ["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"]
        )
        return rows.compactMap { row in
            let type = row["TYPE", default: ""].lowercased()
            let section: DockerDiskSection?
            if type.hasPrefix("image") {
                section = .images
            } else if type.hasPrefix("container") {
                section = .containers
            } else if type.hasPrefix("local volume") {
                section = .volumes
            } else if type.hasPrefix("build cache") {
                section = .buildCache
            } else {
                section = nil
            }
            guard let section else { return nil }
            let reclaimable = row["RECLAIMABLE", default: ""]
            return DockerDiskSummaryItem(
                section: section,
                total: row["TOTAL", default: ""],
                active: row["ACTIVE", default: ""],
                size: row["SIZE", default: ""],
                sizeBytes: parseByteSize(row["SIZE", default: ""]),
                reclaimable: reclaimable,
                reclaimableBytes: parseByteSize(reclaimable)
            )
        }
    }

    private static func parseImages(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Images space usage:"),
            labels: ["REPOSITORY", "TAG", "IMAGE ID", "CREATED", "SIZE", "SHARED SIZE", "UNIQUE SIZE", "CONTAINERS"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "images:\(index):\(row["IMAGE ID", default: ""])",
                section: .images,
                repository: row["REPOSITORY", default: ""],
                tag: row["TAG", default: ""],
                imageId: row["IMAGE ID", default: ""],
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                sharedSize: row["SHARED SIZE", default: ""],
                uniqueSize: row["UNIQUE SIZE", default: ""],
                containers: row["CONTAINERS", default: ""]
            )
        }
    }

    private static func parseContainers(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Containers space usage:"),
            labels: ["CONTAINER ID", "IMAGE", "COMMAND", "LOCAL VOLUMES", "SIZE", "CREATED", "STATUS", "NAMES"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "containers:\(index):\(row["CONTAINER ID", default: ""])",
                section: .containers,
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                containerId: row["CONTAINER ID", default: ""],
                image: row["IMAGE", default: ""],
                command: row["COMMAND", default: ""],
                localVolumes: row["LOCAL VOLUMES", default: ""],
                status: row["STATUS", default: ""],
                name: row["NAMES", default: ""]
            )
        }
    }

    private static func parseVolumes(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Local Volumes space usage:"),
            labels: ["VOLUME NAME", "LINKS", "SIZE"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "volumes:\(index):\(row["VOLUME NAME", default: ""])",
                section: .volumes,
                size: row["SIZE", default: ""],
                volumeName: row["VOLUME NAME", default: ""],
                links: row["LINKS", default: ""]
            )
        }
    }

    private static func parseBuildCache(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Build cache usage:"),
            labels: ["CACHE ID", "CACHE TYPE", "SIZE", "CREATED", "LAST USED", "USAGE", "SHARED"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "build-cache:\(index):\(row["CACHE ID", default: ""])",
                section: .buildCache,
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                cacheId: row["CACHE ID", default: ""],
                cacheType: row["CACHE TYPE", default: ""],
                lastUsed: row["LAST USED", default: ""],
                usage: row["USAGE", default: ""],
                shared: row["SHARED", default: ""]
            )
        }
    }

    private static func diskRow(
        id: String,
        section: DockerDiskSection,
        repository: String = "",
        tag: String = "",
        imageId: String = "",
        created: String = "",
        size: String = "",
        sharedSize: String = "",
        uniqueSize: String = "",
        containers: String = "",
        containerId: String = "",
        image: String = "",
        command: String = "",
        localVolumes: String = "",
        status: String = "",
        name: String = "",
        volumeName: String = "",
        links: String = "",
        cacheId: String = "",
        cacheType: String = "",
        lastUsed: String = "",
        usage: String = "",
        shared: String = ""
    ) -> DockerDiskRow {
        DockerDiskRow(
            id: id,
            section: section,
            repository: repository,
            tag: tag,
            imageId: imageId,
            created: created,
            size: size,
            sizeBytes: parseByteSize(size),
            sharedSize: sharedSize,
            uniqueSize: uniqueSize,
            containers: containers,
            containerId: containerId,
            image: image,
            command: command,
            localVolumes: localVolumes,
            status: status,
            name: name,
            volumeName: volumeName,
            links: links,
            cacheId: cacheId,
            cacheType: cacheType,
            lastUsed: lastUsed,
            usage: usage,
            shared: shared
        )
    }

    private static func parseFixedWidthRows(_ lines: [String], labels: [String]) -> [[String: String]] {
        guard let headerIndex = lines.firstIndex(where: { line in
            labels.allSatisfy { line.contains($0) }
        }) else {
            return []
        }
        let header = lines[headerIndex]
        guard let starts = columnStarts(in: header, labels: labels) else { return [] }
        return lines.dropFirst(headerIndex + 1).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isSectionTitle(line) else { return nil }
            var row: [String: String] = [:]
            for (index, label) in labels.enumerated() {
                row[label] = slice(line, start: starts[index], end: starts[safe: index + 1])
            }
            let hasValue = labels.contains { !(row[$0] ?? "").isEmpty }
            return hasValue ? row : nil
        }
    }

    private static func columnStarts(in header: String, labels: [String]) -> [Int]? {
        var starts: [Int] = []
        var searchStart = header.startIndex
        for label in labels {
            guard let range = header.range(of: label, range: searchStart..<header.endIndex) else {
                return nil
            }
            starts.append(header.distance(from: header.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
        }
        return starts
    }

    private static func slice(_ line: String, start: Int, end: Int?) -> String {
        guard start < line.count else { return "" }
        let lower = line.index(line.startIndex, offsetBy: start)
        let upperOffset = min(end ?? line.count, line.count)
        let upper = line.index(line.startIndex, offsetBy: upperOffset)
        return String(line[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sectionLines(in lines: [String], titlePrefix: String) -> [String] {
        guard let start = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix(titlePrefix.lowercased())
        }) else {
            return []
        }
        let afterStart = lines.index(after: start)
        let end = lines[afterStart...].firstIndex(where: isSectionTitle) ?? lines.endIndex
        return Array(lines[afterStart..<end])
    }

    private static func isSectionTitle(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("images space usage:")
            || lower.hasPrefix("containers space usage:")
            || lower.hasPrefix("local volumes space usage:")
            || lower.hasPrefix("build cache usage:")
    }

    private static func parseBuildCacheUsage(_ lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("build cache usage:") else { continue }
            return trimmed
                .dropFirst("Build cache usage:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func parseByteSize(_ value: String) -> Int64 {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return 0 }

        var numberPart = ""
        var unitPart = ""
        for character in token {
            if character.isNumber || character == "." {
                numberPart.append(character)
            } else if !numberPart.isEmpty {
                unitPart.append(character)
            }
        }
        guard let value = Double(numberPart) else { return 0 }
        let unit = unitPart.lowercased()
        let multiplier: Double
        if unit.hasPrefix("t") {
            multiplier = 1_000_000_000_000
        } else if unit.hasPrefix("g") {
            multiplier = 1_000_000_000
        } else if unit.hasPrefix("m") {
            multiplier = 1_000_000
        } else if unit.hasPrefix("k") {
            multiplier = 1_000
        } else {
            multiplier = 1
        }
        return Int64(value * multiplier)
    }
}

struct DockerMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
        case containers = "Containers"
        case logs = "Logs"
        case images = "Images"
        case volumes = "Volumes"
        case networks = "Networks"
        case events = "Events"
        case disk = "Disk"
    }

    @State private var mode: Mode = .containers
    @State private var containers: [DockerContainer] = []
    @State private var selectedContainerId: String?
    @State private var checkedContainerIds: Set<String> = []
    @State private var images: [DockerAsset] = []
    @State private var checkedImageIds: Set<String> = []
    @State private var imageSortOrder: [KeyPathComparator<DockerAsset>] = [
        .init(\.imageName)
    ]
    @State private var volumes: [DockerAsset] = []
    @State private var checkedVolumeIds: Set<String> = []
    @State private var networks: [DockerAsset] = []
    @State private var checkedNetworkIds: Set<String> = []
    @State private var events: [DockerEvent] = []
    @State private var selectedEventId: DockerEvent.ID?
    @State private var lastEventsRefresh: Date?
    @State private var diskSnapshot = DockerDiskSnapshot.empty
    @State private var diskQuickFilter: DockerDiskQuickFilter = .all
    @State private var showsRawDiskUsage = false
    @State private var diskImageSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State private var diskContainerSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State private var diskVolumeSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State private var diskBuildCacheSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State private var logs: String = ""
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var liveLogs = false
    @State private var liveEvents = false
    @State private var pendingAction: DockerAction?
    @State private var pendingBatch: DockerBatch?
    @State private var dockerOperation: RemoteOperationFeedback?
    @State private var dockerOperationOutput: RemoteOperationFeedback?

    private static let pollInterval: UInt64 = 5_000_000_000

    fileprivate struct DockerAction: Identifiable {
        let id = UUID()
        let verb: String
        let target: String
        var destructive: Bool {
            ["stop", "restart", "kill", "rm", "pause"].contains(verb)
        }
    }

    fileprivate enum BatchScope {
        case containers, images, volumes, networks, disk
    }

    fileprivate enum DockerDiskCleanup {
        case buildCache
        case danglingImages
        case stoppedContainers
        case unusedVolumes
    }

    fileprivate struct DockerBatch: Identifiable {
        let id = UUID()
        let title: String
        let summary: String
        let command: String
        let destructive: Bool
        let scope: BatchScope
        var targets: [String] = []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let dockerOperation {
                RemoteOperationBanner(
                    operation: dockerOperation,
                    onShowOutput: { dockerOperationOutput = dockerOperation },
                    onDismiss: { dismissDockerOperation(dockerOperation.id) }
                )
                Divider()
            }
            if connectionId == nil {
                placeholderView(icon: "network.slash", title: "No connection", message: "Open an SSH workspace to inspect Docker.")
            } else if let error {
                placeholderView(icon: "exclamationmark.triangle", title: "Docker unavailable", message: error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue):\(liveLogs):\(liveEvents)") {
            await refresh()
            if mode == .logs && liveLogs {
                await logsLoop()
            } else if mode == .events && liveEvents {
                await eventsLoop()
            }
        }
        .confirmationDialog(
            "Confirm Docker action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("docker \(action.verb) \(action.target)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This runs on \(connectionLabel).")
        }
        .confirmationDialog(
            "Confirm batch action",
            isPresented: Binding(
                get: { pendingBatch != nil },
                set: { if !$0 { pendingBatch = nil } }
            ),
            presenting: pendingBatch
        ) { batch in
            Button(batch.title, role: batch.destructive ? .destructive : nil) {
                Task { await runBatch(batch) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { batch in
            Text("\(batch.summary)\n\nRuns on \(connectionLabel).")
        }
        .sheet(item: $dockerOperationOutput) { operation in
            RemoteOperationOutputSheet(operation: operation)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
            if mode == .logs {
                Toggle("Live", isOn: $liveLogs)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            } else if mode == .events {
                Toggle("Live", isOn: $liveEvents)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
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

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .containers:
            containerList
        case .logs:
            logsPane
        case .images:
            imageTable
        case .volumes:
            assetList(
                volumes,
                headers: ["Volume", "Driver"],
                targetColumn: 0,
                selection: $checkedVolumeIds,
                scope: .volumes
            ) {
                volumeBatchActions
            }
        case .networks:
            assetList(
                networks,
                headers: ["Network", "Driver", "Scope"],
                targetColumn: 0,
                selection: $checkedNetworkIds,
                scope: .networks
            ) {
                networkBatchActions
            }
        case .events:
            eventsPane
        case .disk:
            dockerDiskPane
        }
    }

    private var filteredContainers: [DockerContainer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return containers }
        return containers.filter {
            $0.name.lowercased().contains(needle)
                || $0.image.lowercased().contains(needle)
                || $0.composeProject.lowercased().contains(needle)
        }
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            batchToolbar(
                count: checkedContainerIds.count,
                clear: { checkedContainerIds.removeAll() }
            ) {
                Button("Start") { pendingBatch = containerBatch(verb: "start", destructive: false) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Stop") { pendingBatch = containerBatch(verb: "stop", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Restart") { pendingBatch = containerBatch(verb: "restart", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Pause") { pendingBatch = containerBatch(verb: "pause", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Unpause") { pendingBatch = containerBatch(verb: "unpause", destructive: false) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Remove") { pendingBatch = containerBatch(verb: "rm", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
            }
            Divider()
            List(selection: $selectedContainerId) {
                ForEach(groupedContainers.keys.sorted(), id: \.self) { group in
                    Section(group.isEmpty ? "Standalone" : group) {
                        ForEach(groupedContainers[group] ?? []) { container in
                            HStack(spacing: 8) {
                                rowCheckbox(
                                    isOn: Binding(
                                        get: { checkedContainerIds.contains(container.id) },
                                        set: { isOn in
                                            if isOn { checkedContainerIds.insert(container.id) }
                                            else { checkedContainerIds.remove(container.id) }
                                        }
                                    )
                                )
                                Circle()
                                    .fill(statusColor(container.status + container.health))
                                    .frame(width: 8, height: 8)
                                rowOperationIndicator(isActive: dockerOperationTargets(container.id))
                                monoCell(container.name, width: 170)
                                monoCell(container.image, width: 180, color: .secondary)
                                monoCell(container.status, width: 170, color: statusColor(container.status))
                                monoCell(container.health, width: 70, color: statusColor(container.health))
                                monoCell(container.cpu, width: 70)
                                monoCell(container.memory, width: 140)
                                monoCell(container.netIO)
                            }
                            .tag(container.id)
                            .contextMenu { dockerActions(container) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func rowCheckbox(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 18)
    }

    private func batchToolbar<Actions: View>(
        count: Int,
        clear: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Text(count > 0 ? "\(count) selected" : "No selection")
                .font(.caption)
                .foregroundStyle(.secondary)
            if count > 0 {
                Button("Clear", action: clear)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Spacer()
            actions()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func containerBatch(verb: String, destructive: Bool) -> DockerBatch? {
        let ids = Array(checkedContainerIds)
        guard !ids.isEmpty else { return nil }
        return DockerBatch(
            title: "docker \(verb) \(ids.count) container\(ids.count == 1 ? "" : "s")",
            summary: "\(verb.capitalized) \(ids.count) container\(ids.count == 1 ? "" : "s").",
            command: "docker \(verb)",
            destructive: destructive,
            scope: .containers,
            targets: ids
        )
    }

    @ViewBuilder
    private var imageBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedImageIds),
                command: "docker rmi -f",
                noun: "image",
                destructive: true,
                scope: .images
            )
        }
        .disabled(checkedImageIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker image prune",
                summary: "Remove all dangling images.",
                command: "docker image prune -f",
                destructive: true,
                scope: .images
            )
        }
        .disabled(isDockerOperationRunning)
    }

    @ViewBuilder
    private var volumeBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedVolumeIds),
                command: "docker volume rm",
                noun: "volume",
                destructive: true,
                scope: .volumes
            )
        }
        .disabled(checkedVolumeIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker volume prune",
                summary: "Remove all unused volumes.",
                command: "docker volume prune -f",
                destructive: true,
                scope: .volumes
            )
        }
        .disabled(isDockerOperationRunning)
    }

    @ViewBuilder
    private var networkBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedNetworkIds),
                command: "docker network rm",
                noun: "network",
                destructive: true,
                scope: .networks
            )
        }
        .disabled(checkedNetworkIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker network prune",
                summary: "Remove all unused networks.",
                command: "docker network prune -f",
                destructive: true,
                scope: .networks
            )
        }
        .disabled(isDockerOperationRunning)
    }

    private func assetBatch(
        ids: [String],
        command: String,
        noun: String,
        destructive: Bool,
        scope: BatchScope
    ) -> DockerBatch? {
        guard !ids.isEmpty else { return nil }
        let plural = ids.count == 1 ? noun : "\(noun)s"
        return DockerBatch(
            title: "\(command) \(ids.count) \(plural)",
            summary: "Remove \(ids.count) \(plural).",
            command: command,
            destructive: destructive,
            scope: scope,
            targets: ids
        )
    }

    private var sortedImages: [DockerAsset] {
        images.sorted(using: imageSortOrder)
    }

    private var imageTable: some View {
        let allTargets = Set(images.compactMap { assetTarget($0, column: 1) })
        let allSelected = !allTargets.isEmpty && allTargets.isSubset(of: checkedImageIds)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(checkedImageIds.isEmpty ? "No selection" : "\(checkedImageIds.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(allSelected ? "Clear" : "Select All") {
                    if allSelected {
                        checkedImageIds.subtract(allTargets)
                    } else {
                        checkedImageIds.formUnion(allTargets)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(allTargets.isEmpty || isDockerOperationRunning)
                if !checkedImageIds.isEmpty {
                    Button("Clear") {
                        checkedImageIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isDockerOperationRunning)
                }
                Spacer()
                imageBatchActions
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            Table(sortedImages, sortOrder: $imageSortOrder) {
                TableColumn("") { asset in
                    let target = assetTarget(asset, column: 1)
                    HStack(spacing: 4) {
                        rowCheckbox(
                            isOn: Binding(
                                get: { target.map { checkedImageIds.contains($0) } ?? false },
                                set: { isOn in
                                    guard let target else { return }
                                    if isOn { checkedImageIds.insert(target) }
                                    else { checkedImageIds.remove(target) }
                                }
                            )
                        )
                        rowOperationIndicator(isActive: target.map(dockerOperationTargets) ?? false)
                    }
                }
                .width(min: 42, ideal: 48, max: 54)

                TableColumn("Image", value: \.imageName) { asset in
                    monoCell(asset.imageName)
                }
                .width(min: 190, ideal: 260)

                TableColumn("ID", value: \.imageId) { asset in
                    monoCell(asset.imageId, color: .secondary)
                }
                .width(min: 95, ideal: 120)

                TableColumn("Size", value: \.imageSizeBytes) { asset in
                    monoCell(asset.imageSizeText)
                }
                .width(min: 80, ideal: 95)

                TableColumn("Created", value: \.imageCreated) { asset in
                    monoCell(asset.imageCreated, color: .secondary)
                }
                .width(min: 105, ideal: 140)
            }
        }
    }

    private var groupedContainers: [String: [DockerContainer]] {
        Dictionary(grouping: filteredContainers) { $0.composeProject }
    }

    private var logsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Container", selection: $selectedContainerId) {
                    Text("Select a container").tag(nil as String?)
                    ForEach(containers) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 260)
                Spacer()
                Button("Exec Shell Command") {
                    if let container = selectedContainer {
                        runExecShell(container)
                    }
                }
                .disabled(selectedContainer == nil)
                Button("Copy Logs") { RemoteCommandRunner.copy(logs) }
                    .disabled(logs.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            logText(logs)
        }
    }

    private var selectedContainer: DockerContainer? {
        guard let selectedContainerId else { return containers.first }
        return containers.first { $0.id == selectedContainerId }
    }

    private var filteredEvents: [DockerEvent] {
        let query = dockerEventQuery(search)
        return events.filter { event in
            if let kind = query.kind, !event.kind.lowercased().contains(kind) {
                return false
            }
            if let action = query.action, !event.action.lowercased().contains(action) {
                return false
            }
            if let resource = query.resource, !event.objectLabel.lowercased().contains(resource) {
                return false
            }
            if let identifier = query.identifier, !event.actorId.lowercased().contains(identifier) {
                return false
            }
            if let since = query.since {
                guard let date = event.date, Date().timeIntervalSince(date) <= since else {
                    return false
                }
            }
            let haystack = event.searchText.lowercased()
            return query.terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var selectedEvent: DockerEvent? {
        if let selectedEventId,
           let event = filteredEvents.first(where: { $0.id == selectedEventId }) {
            return event
        }
        return filteredEvents.first
    }

    private var eventsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(filteredEvents.count) of \(events.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastEventsRefresh {
                    Text("Updated \(DateFormatter.localizedString(from: lastEventsRefresh, dateStyle: .none, timeStyle: .medium))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    RemoteCommandRunner.copy(events.map(\.rawText).joined(separator: "\n\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(events.isEmpty)
                Button {
                    events.removeAll()
                    selectedEventId = nil
                    lastEventsRefresh = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(events.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()

            if events.isEmpty {
                dockerEventEmptyState(
                    icon: "dot.radiowaves.left.and.right",
                    title: "No Docker events",
                    message: "No container, image, volume, or network events were returned for the last 30 minutes."
                )
            } else if filteredEvents.isEmpty {
                dockerEventEmptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No matching events",
                    message: "Try clearing the filter or using queries like type:image, action:delete, or since:10m."
                )
            } else {
                HSplitView {
                    dockerEventTable
                        .frame(minWidth: 560)
                    dockerEventDetails(selectedEvent)
                        .frame(minWidth: 280, idealWidth: 340)
                }
            }
        }
    }

    private var dockerEventTable: some View {
        Table(filteredEvents, selection: $selectedEventId) {
            TableColumn("Time") { event in
                Text(event.displayTime)
                    .font(.caption.monospacedDigit())
                    .help(event.fullTimestamp)
            }
            .width(min: 82, ideal: 92, max: 110)

            TableColumn("Resource") { event in
                dockerEventToken(event.kind, color: .blue)
            }
            .width(min: 78, ideal: 92, max: 120)

            TableColumn("Action") { event in
                dockerEventToken(event.action, color: dockerEventActionColor(event.action))
            }
            .width(min: 84, ideal: 104, max: 130)

            TableColumn("Object") { event in
                Text(event.objectLabel)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event.actorId.isEmpty ? event.objectLabel : event.actorId)
            }

            TableColumn("Details") { event in
                Text(dockerEventDetailSummary(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)
        }
    }

    private func dockerEventDetails(_ event: DockerEvent?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event Details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let event {
                    Button {
                        RemoteCommandRunner.copy(event.rawText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy event details")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()

            if let event {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        dockerEventDetailRow("Time", event.fullTimestamp)
                        dockerEventDetailRow("Resource", event.kind)
                        dockerEventDetailRow("Action", event.action)
                        dockerEventDetailRow("Object", event.objectLabel)
                        dockerEventDetailRow("Actor ID", event.actorId)
                        dockerEventDetailRow("Name", event.name)
                        dockerEventDetailRow("Image", event.image)
                        dockerEventDetailRow("Container", event.container)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Raw")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(highlightedRawOutput(event.raw))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                Text("Select an event to inspect its full Docker actor data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func dockerEventDetailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dockerEventEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var dockerDiskPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Disk Usage")
                        .font(.headline)
                    if let refreshedAt = diskSnapshot.refreshedAt {
                        Text("Updated \(DateFormatter.localizedString(from: refreshedAt, dateStyle: .none, timeStyle: .medium))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        RemoteCommandRunner.copy(diskSnapshot.rawText)
                    } label: {
                        Label("Copy Raw", systemImage: "doc.on.doc")
                    }
                    .disabled(diskSnapshot.rawText.isEmpty)
                }

                LazyVGrid(columns: dockerDiskMetricColumns, alignment: .leading, spacing: 10) {
                    dockerDiskMetricTile(
                        title: "Total",
                        value: DockerDiskSnapshot.formatBytes(diskSnapshot.totalSizeBytes),
                        subtitle: "Reported Docker disk usage",
                        systemImage: "internaldrive",
                        color: .accentColor
                    )
                    dockerDiskSummaryTile(section: .images, systemImage: "shippingbox", color: .blue)
                    dockerDiskSummaryTile(section: .containers, systemImage: "server.rack", color: .green)
                    dockerDiskSummaryTile(section: .volumes, systemImage: "externaldrive", color: .teal)
                    dockerDiskSummaryTile(section: .buildCache, systemImage: "hammer", color: .orange)
                }

                HStack(spacing: 8) {
                    Picker("", selection: $diskQuickFilter) {
                        ForEach(DockerDiskQuickFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)

                    Spacer()

                    Menu {
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.buildCache)
                        } label: {
                            Label("Prune unused build cache", systemImage: "hammer")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.danglingImages)
                        } label: {
                            Label("Prune dangling images", systemImage: "shippingbox")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.stoppedContainers)
                        } label: {
                            Label("Remove stopped containers", systemImage: "server.rack")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.unusedVolumes)
                        } label: {
                            Label("Remove unused volumes", systemImage: "externaldrive")
                        }
                    } label: {
                        Label("Cleanup", systemImage: "trash")
                    }
                    .disabled(diskSnapshot.rawText.isEmpty)
                }
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 12) {
                    if diskQuickFilter != .buildCache {
                        dockerDiskSectionView(
                            .images,
                            rows: diskSnapshot.images,
                            sortOrder: $diskImageSortOrder
                        )
                        dockerDiskSectionView(
                            .containers,
                            rows: diskSnapshot.containers,
                            sortOrder: $diskContainerSortOrder
                        )
                        dockerDiskSectionView(
                            .volumes,
                            rows: diskSnapshot.volumes,
                            sortOrder: $diskVolumeSortOrder
                        )
                    }
                    dockerDiskSectionView(
                        .buildCache,
                        rows: diskSnapshot.buildCache,
                        sortOrder: $diskBuildCacheSortOrder
                    )
                }

                DisclosureGroup("Raw output", isExpanded: $showsRawDiskUsage) {
                    HighlightedRawOutputText(value: diskSnapshot.rawText.isEmpty ? "-" : diskSnapshot.rawText)
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

    private var dockerDiskMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)]
    }

    private func dockerDiskSummaryTile(
        section: DockerDiskSection,
        systemImage: String,
        color: Color
    ) -> some View {
        let summary = diskSnapshot.summary(for: section)
        let rows = diskSnapshot.rows(for: section)
        let subtitle: String
        if let summary {
            subtitle = "\(summary.activityText) | \(diskSnapshot.reclaimableText(for: section))"
        } else {
            subtitle = rows.isEmpty ? "No rows reported" : "\(rows.count) row\(rows.count == 1 ? "" : "s") parsed"
        }
        return dockerDiskMetricTile(
            title: section.title,
            value: diskSnapshot.sizeText(for: section),
            subtitle: subtitle,
            systemImage: systemImage,
            color: color
        )
    }

    private func dockerDiskMetricTile(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value.isEmpty ? "-" : value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func dockerDiskSectionView(
        _ section: DockerDiskSection,
        rows: [DockerDiskRow],
        sortOrder: Binding<[KeyPathComparator<DockerDiskRow>]>
    ) -> some View {
        let filteredRows = filteredDiskRows(rows)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(filteredRows.count) of \(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(diskSnapshot.reclaimableText(for: section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredRows.isEmpty {
                dockerDiskEmptyState(section)
            } else {
                dockerDiskTable(filteredRows, section: section, sortOrder: sortOrder)
                    .frame(height: dockerDiskTableHeight(rowCount: filteredRows.count))
            }
        }
    }

    private func filteredDiskRows(_ rows: [DockerDiskRow]) -> [DockerDiskRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            let matchesSearch = needle.isEmpty || row.searchText.contains(needle)
            guard matchesSearch else { return false }
            switch diskQuickFilter {
            case .all:
                return true
            case .large:
                return row.isLarge
            case .stale:
                return row.isOlderThanWeek
            case .buildCache:
                return row.section == .buildCache
            }
        }
    }

    private func dockerDiskEmptyState(_ section: DockerDiskSection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.emptyTitle)
                    .font(.caption.weight(.semibold))
                Text(section.emptyMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    private func dockerDiskTable(
        _ rows: [DockerDiskRow],
        section: DockerDiskSection,
        sortOrder: Binding<[KeyPathComparator<DockerDiskRow>]>
    ) -> some View {
        switch section {
        case .images:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Repository", value: \.repository) { row in
                    monoCell(row.repository)
                }
                .width(min: 150, ideal: 220)
                TableColumn("Tag", value: \.tag) { row in
                    monoCell(row.tag, color: .secondary)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Image ID", value: \.imageId) { row in
                    monoCell(row.imageId, color: .secondary)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 95, ideal: 115)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Shared", value: \.sharedSize) { row in
                    monoCell(row.sharedSize, color: .secondary)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Unique", value: \.uniqueSize) { row in
                    monoCell(row.uniqueSize)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Containers", value: \.containers) { row in
                    monoCell(row.containers)
                }
                .width(min: 78, ideal: 90)
            }
        case .containers:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Container ID", value: \.containerId) { row in
                    monoCell(row.containerId)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Image", value: \.image) { row in
                    monoCell(row.image)
                }
                .width(min: 140, ideal: 190)
                TableColumn("Command", value: \.command) { row in
                    monoCell(row.command, color: .secondary)
                }
                .width(min: 140, ideal: 180)
                TableColumn("Volumes", value: \.localVolumes) { row in
                    monoCell(row.localVolumes)
                }
                .width(min: 70, ideal: 80)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 95, ideal: 115)
                TableColumn("Status", value: \.status) { row in
                    monoCell(row.status, color: statusColor(row.status))
                }
                .width(min: 95, ideal: 120)
                TableColumn("Name", value: \.name) { row in
                    monoCell(row.name)
                }
                .width(min: 120, ideal: 160)
            }
        case .volumes:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Volume", value: \.volumeName) { row in
                    monoCell(row.volumeName)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Links", value: \.links) { row in
                    monoCell(row.links)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
            }
        case .buildCache:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Cache ID", value: \.cacheId) { row in
                    monoCell(row.cacheId)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Type", value: \.cacheType) { row in
                    monoCell(row.cacheType, color: .secondary)
                }
                .width(min: 80, ideal: 95)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Last Used", value: \.lastUsed) { row in
                    monoCell(row.lastUsed)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Usage", value: \.usage) { row in
                    monoCell(row.usage)
                }
                .width(min: 65, ideal: 75)
                TableColumn("Shared", value: \.shared) { row in
                    monoCell(row.shared)
                }
                .width(min: 70, ideal: 85)
            }
        }
    }

    private func dockerDiskTableHeight(rowCount: Int) -> CGFloat {
        min(max(CGFloat(rowCount) * 24 + 34, 110), 340)
    }

    private func dockerDiskCleanupBatch(_ cleanup: DockerDiskCleanup) -> DockerBatch {
        switch cleanup {
        case .buildCache:
            return DockerBatch(
                title: "docker builder prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove unused Docker build cache.",
                    section: .buildCache,
                    rows: diskSnapshot.buildCache
                ),
                command: "docker builder prune -f",
                destructive: true,
                scope: .disk
            )
        case .danglingImages:
            let dangling = diskSnapshot.images.filter {
                $0.repository == "<none>" || $0.tag == "<none>"
            }
            return DockerBatch(
                title: "docker image prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove dangling images.",
                    section: .images,
                    rows: dangling
                ),
                command: "docker image prune -f",
                destructive: true,
                scope: .disk
            )
        case .stoppedContainers:
            let stopped = diskSnapshot.containers.filter {
                let status = $0.status.lowercased()
                return status.contains("exited") || status.contains("created") || status.contains("dead")
            }
            return DockerBatch(
                title: "docker container prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove stopped containers.",
                    section: .containers,
                    rows: stopped
                ),
                command: "docker container prune -f",
                destructive: true,
                scope: .disk
            )
        case .unusedVolumes:
            let unused = diskSnapshot.volumes.filter { $0.links == "0" }
            return DockerBatch(
                title: "docker volume prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove unused local volumes.",
                    section: .volumes,
                    rows: unused
                ),
                command: "docker volume prune -f",
                destructive: true,
                scope: .disk
            )
        }
    }

    private func dockerDiskCleanupSummary(
        lead: String,
        section: DockerDiskSection,
        rows: [DockerDiskRow]
    ) -> String {
        let reclaimable = diskSnapshot.summary(for: section)?.reclaimable ?? "unknown"
        let preview: String
        if rows.isEmpty {
            preview = "No detailed rows are currently reported for this cleanup scope."
        } else {
            let listed = rows
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(6)
                .map { row in
                    let name = row.previewName.isEmpty ? row.id : row.previewName
                    let size = row.size.isEmpty ? "" : " (\(row.size))"
                    return "- \(name)\(size)"
                }
                .joined(separator: "\n")
            let remaining = rows.count > 6 ? "\n- and \(rows.count - 6) more" : ""
            preview = "\(listed)\(remaining)"
        }
        return "\(lead)\nExpected reclaimable: \(reclaimable).\n\nPreview:\n\(preview)"
    }

    private func assetList<Actions: View>(
        _ assets: [DockerAsset],
        headers: [String],
        targetColumn: Int,
        selection: Binding<Set<String>>,
        scope: BatchScope,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let allTargets = Set(assets.compactMap { assetTarget($0, column: targetColumn) })
        let allSelected = !allTargets.isEmpty && allTargets.isSubset(of: selection.wrappedValue)
        let toggleAll = Binding(
            get: { allSelected },
            set: { isOn in
                if isOn { selection.wrappedValue.formUnion(allTargets) }
                else { selection.wrappedValue.subtract(allTargets) }
            }
        )
        return VStack(spacing: 0) {
            batchToolbar(
                count: selection.wrappedValue.count,
                clear: { selection.wrappedValue.removeAll() },
                actions: actions
            )
            Divider()
            HStack(spacing: 10) {
                Toggle("", isOn: toggleAll)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                ForEach(headers, id: \.self) { header in
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            List(assets) { asset in
                HStack(spacing: 10) {
                    let target = assetTarget(asset, column: targetColumn)
                    rowCheckbox(
                        isOn: Binding(
                            get: { target.map { selection.wrappedValue.contains($0) } ?? false },
                            set: { isOn in
                                guard let target else { return }
                                if isOn { selection.wrappedValue.insert(target) }
                                else { selection.wrappedValue.remove(target) }
                            }
                        )
                    )
                    rowOperationIndicator(isActive: target.map(dockerOperationTargets) ?? false)
                    ForEach(Array(asset.columns.enumerated()), id: \.offset) { _, column in
                        monoCell(column)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func assetTarget(_ asset: DockerAsset, column: Int) -> String? {
        guard asset.columns.indices.contains(column) else { return nil }
        let value = asset.columns[column].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func dockerEventToken(_ value: String, color: Color) -> some View {
        let isEmpty = value.isEmpty
        return Text(isEmpty ? "-" : value)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(isEmpty ? Color.secondary : color)
    }

    private func dockerEventActionColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("delete") || lower.contains("destroy") || lower.contains("die") || lower == "kill" || lower == "remove" {
            return .red
        }
        if lower.contains("start") || lower.contains("create") || lower.contains("connect") || lower.contains("pull") {
            return .green
        }
        if lower.contains("pause") || lower.contains("stop") || lower.contains("restart") || lower.contains("untag") {
            return .orange
        }
        return .secondary
    }

    private func dockerEventDetailSummary(_ event: DockerEvent) -> String {
        let parts = [event.name, event.image, event.container, event.actorId]
            .map(DockerEvent.normalized)
            .filter { !$0.isEmpty }
            .map(DockerEvent.compactIdentifier)
        return parts.isEmpty ? "-" : parts.joined(separator: "  ")
    }

    private func dockerEventQuery(_ value: String) -> DockerEventQuery {
        var query = DockerEventQuery()
        for token in value.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard let separator = token.firstIndex(of: ":") else {
                query.terms.append(token.lowercased())
                continue
            }
            let key = token[..<separator].lowercased()
            let rawValue = String(token[token.index(after: separator)...])
            let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedValue.isEmpty else { continue }
            switch key {
            case "type", "resource":
                query.kind = normalizedValue
            case "action":
                query.action = normalizedValue
            case "object", "name":
                query.resource = normalizedValue
            case "id", "actor":
                query.identifier = normalizedValue
            case "since":
                query.since = dockerEventSinceInterval(normalizedValue)
            default:
                query.terms.append(token.lowercased())
            }
        }
        return query
    }

    private func dockerEventSinceInterval(_ value: String) -> TimeInterval? {
        let digits = value.prefix { $0.isNumber }
        guard let amount = Double(digits), amount > 0 else { return nil }
        let unit = String(value.dropFirst(digits.count))
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return amount
        case "h", "hr", "hrs", "hour", "hours":
            return amount * 60 * 60
        case "d", "day", "days":
            return amount * 60 * 60 * 24
        default:
            return amount * 60
        }
    }

    private var isDockerOperationRunning: Bool {
        dockerOperation?.isRunning == true
    }

    private func dockerOperationTargets(_ target: String) -> Bool {
        guard let dockerOperation, dockerOperation.isRunning else { return false }
        return dockerOperation.targetIds.contains(target)
    }

    private func startDockerOperation(
        title: String,
        detail: String,
        targets: [String] = []
    ) -> UUID {
        let operation = RemoteOperationFeedback(
            title: title,
            detail: detail,
            targetIds: Set(targets),
            totalCount: targets.isEmpty ? nil : targets.count
        )
        dockerOperation = operation
        return operation.id
    }

    private func updateDockerOperation(
        _ id: UUID,
        detail: String,
        completedCount: Int? = nil
    ) {
        guard var operation = dockerOperation, operation.id == id else { return }
        operation.detail = detail
        if let completedCount {
            operation.completedCount = completedCount
        }
        dockerOperation = operation
    }

    private func finishDockerOperation(
        _ id: UUID,
        state: RemoteOperationState,
        detail: String,
        output: String,
        completedCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        guard var operation = dockerOperation, operation.id == id else { return }
        operation.state = state
        operation.detail = detail
        operation.output = output
        operation.errorMessage = errorMessage
        operation.completedCount = completedCount ?? operation.completedCount
        operation.endedAt = Date()
        dockerOperation = operation
    }

    private func dismissDockerOperation(_ id: UUID) {
        guard dockerOperation?.id == id, dockerOperation?.isRunning == false else { return }
        dockerOperation = nil
    }

    @ViewBuilder
    private func dockerActions(_ container: DockerContainer) -> some View {
        Button("Start") { pendingAction = DockerAction(verb: "start", target: container.id) }
        Button("Stop", role: .destructive) { pendingAction = DockerAction(verb: "stop", target: container.id) }
        Button("Restart", role: .destructive) { pendingAction = DockerAction(verb: "restart", target: container.id) }
        Button("Pause", role: .destructive) { pendingAction = DockerAction(verb: "pause", target: container.id) }
        Button("Unpause") { pendingAction = DockerAction(verb: "unpause", target: container.id) }
        Button("Kill", role: .destructive) { pendingAction = DockerAction(verb: "kill", target: container.id) }
        Button("Remove", role: .destructive) { pendingAction = DockerAction(verb: "rm", target: container.id) }
        Divider()
        Button("Show Logs") {
            selectedContainerId = container.id
            mode = .logs
            Task { await loadLogs() }
        }
        Button("Run Exec Shell in Terminal") {
            runExecShell(container)
        }
        Button("Copy Exec Shell Command") {
            RemoteCommandRunner.copy(execShellCommand(container))
        }
    }

    private func refresh() async {
        switch mode {
        case .containers, .logs:
            await loadContainers()
            if mode == .logs { await loadLogs() }
        case .images:
            await loadImages()
        case .volumes:
            await loadVolumes()
        case .networks:
            await loadNetworks()
        case .events:
            await loadEvents()
        case .disk:
            await loadDiskUsage()
        }
    }

    private func loadContainers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v docker >/dev/null || { echo docker not found; exit 127; }
        sep=$(printf '\\037')
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] || exit 0
        docker ps -a --format "{{.ID}}${sep}{{.Names}}${sep}{{.Image}}${sep}{{.Status}}${sep}{{.Ports}}" > /tmp/rshell_docker_ps_$$
        docker stats --no-stream --format "{{.Name}}${sep}{{.CPUPerc}}${sep}{{.MemUsage}}${sep}{{.NetIO}}" > /tmp/rshell_docker_stats_$$ 2>/dev/null || true
        while IFS="$sep" read -r id name image status ports; do
          stats=$(awk -F "$sep" -v n="$name" '$1==n {print $2 FS $3 FS $4; exit}' /tmp/rshell_docker_stats_$$)
          cpu=$(printf "%s" "$stats" | awk -F "$sep" '{print $1}')
          mem=$(printf "%s" "$stats" | awk -F "$sep" '{print $2}')
          net=$(printf "%s" "$stats" | awk -F "$sep" '{print $3}')
          inspect=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}${sep}{{.RestartCount}}${sep}{{index .Config.Labels \\"com.docker.compose.project\\"}}" "$id" 2>/dev/null || true)
          health=$(printf "%s" "$inspect" | awk -F "$sep" '{print $1}')
          restarts=$(printf "%s" "$inspect" | awk -F "$sep" '{print $2}')
          compose=$(printf "%s" "$inspect" | awk -F "$sep" '{print $3}')
          printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\\n" "$id" "$sep" "$name" "$sep" "$image" "$sep" "$status" "$sep" "$ports" "$sep" "$cpu" "$sep" "$mem" "$sep" "$net" "$sep" "$health" "$sep" "$restarts" "$sep" "$compose"
        done < /tmp/rshell_docker_ps_$$
        rm -f /tmp/rshell_docker_ps_$$ /tmp/rshell_docker_stats_$$
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            containers = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 11 else { return nil }
                return DockerContainer(id: p[0], name: p[1], image: p[2], status: p[3], ports: p[4], cpu: p[5], memory: p[6], netIO: p[7], health: p[8], restarts: p[9], composeProject: p[10])
            }
            if selectedContainerId == nil { selectedContainerId = containers.first?.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLogs() async {
        guard let connectionId, let container = selectedContainer else { return }
        let script = "docker logs --tail 240 --timestamps \(RemoteCommandRunner.shellQuote(container.id)) 2>&1"
        do {
            logs = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadImages() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker images --format \"{{.Repository}}:{{.Tag}}${sep}{{.ID}}${sep}{{.Size}}${sep}{{.CreatedSince}}\"",
            assign: { images = $0 }
        )
    }

    private func loadVolumes() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker volume ls --format \"{{.Name}}${sep}{{.Driver}}\"",
            assign: { volumes = $0 }
        )
    }

    private func loadNetworks() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker network ls --format \"{{.Name}}${sep}{{.Driver}}${sep}{{.Scope}}\"",
            assign: { networks = $0 }
        )
    }

    private func loadAsset(script: String, assign: ([DockerAsset]) -> Void) async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\n\(script) 2>&1"
            )
            let assets = output.lines().enumerated().map { index, line in
                DockerAsset(id: "\(index):\(line)", columns: splitFields(line))
            }
            assign(assets)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEvents() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v docker >/dev/null || { echo docker not found; exit 127; }
        sep=$(printf '\\037')
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        docker events --since 30m --until "$now" --format "{{.Time}}${sep}{{.Type}}${sep}{{.Action}}${sep}{{.Actor.ID}}${sep}{{.Actor.Attributes.name}}${sep}{{.Actor.Attributes.image}}${sep}{{.Actor.Attributes.container}}" 2>&1
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            events = output.lines().enumerated().map { index, line in
                DockerEvent.parse(line, index: index)
            }
            if selectedEventId == nil || !events.contains(where: { $0.id == selectedEventId }) {
                selectedEventId = events.first?.id
            }
            lastEventsRefresh = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiskUsage() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\ndocker system df -v 2>&1"
            )
            diskSnapshot = DockerDiskSnapshot.parse(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func logsLoop() async {
        while !Task.isCancelled && liveLogs {
            await loadLogs()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func eventsLoop() async {
        while !Task.isCancelled && liveEvents {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if !Task.isCancelled && liveEvents {
                await loadEvents()
            }
        }
    }

    private func run(_ action: DockerAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        guard !isDockerOperationRunning else { return }
        let title = "docker \(action.verb)"
        let operationId = startDockerOperation(
            title: title,
            detail: action.target,
            targets: [action.target]
        )
        let script = "docker \(action.verb) \(RemoteCommandRunner.shellQuote(action.target)) 2>&1"
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: script
            )
            await loadContainers()
            let detail = dockerCompletionDetail(
                fallback: "Completed \(title) for \(action.target).",
                output: output
            )
            finishDockerOperation(
                operationId,
                state: .succeeded,
                detail: detail,
                output: output,
                completedCount: 1
            )
            ActivityLogStore.shared.record(
                title: title,
                detail: detail,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .success
            )
        } catch {
            let message = error.localizedDescription
            finishDockerOperation(
                operationId,
                state: .failed,
                detail: "Failed \(title) for \(action.target).",
                output: "",
                completedCount: 0,
                errorMessage: message
            )
            ActivityLogStore.shared.record(
                title: "\(title) failed",
                detail: message,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .critical
            )
        }
    }

    private func runBatch(_ batch: DockerBatch) async {
        guard let connectionId else { return }
        pendingBatch = nil
        guard !isDockerOperationRunning else { return }
        let operationId = startDockerOperation(
            title: batch.title,
            detail: batch.summary,
            targets: batch.targets
        )

        if !batch.targets.isEmpty {
            await runTargetedDockerBatch(batch, connectionId: connectionId, operationId: operationId)
            return
        }

        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "\(batch.command) 2>&1"
            )
            switch batch.scope {
            case .containers: checkedContainerIds.removeAll()
            case .images: checkedImageIds.removeAll()
            case .volumes: checkedVolumeIds.removeAll()
            case .networks: checkedNetworkIds.removeAll()
            case .disk: break
            }
            await refresh()
            let detail = dockerCompletionDetail(
                fallback: "Completed \(batch.title).",
                output: output
            )
            finishDockerOperation(
                operationId,
                state: .succeeded,
                detail: detail,
                output: output
            )
            ActivityLogStore.shared.record(
                title: batch.title,
                detail: detail,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .success
            )
        } catch {
            let message = error.localizedDescription
            finishDockerOperation(
                operationId,
                state: .failed,
                detail: "Failed \(batch.title).",
                output: "",
                errorMessage: message
            )
            ActivityLogStore.shared.record(
                title: "\(batch.title) failed",
                detail: message,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .critical
            )
        }
    }

    private func runTargetedDockerBatch(
        _ batch: DockerBatch,
        connectionId: String,
        operationId: UUID
    ) async {
        var outputs: [String] = []
        var failedTargets: [(target: String, message: String)] = []
        var succeededTargets: [String] = []
        let total = batch.targets.count

        for (index, target) in batch.targets.enumerated() {
            let humanIndex = index + 1
            updateDockerOperation(
                operationId,
                detail: "\(batch.command) \(target) (\(humanIndex) of \(total))",
                completedCount: index
            )

            let script = "\(batch.command) \(RemoteCommandRunner.shellQuote(target)) 2>&1"
            do {
                let output = try await RemoteCommandRunner.runChecked(
                    connectionId: connectionId,
                    script: script
                )
                succeededTargets.append(target)
                outputs.append(dockerOutputBlock(command: script, output: output))
            } catch {
                let message = error.localizedDescription
                failedTargets.append((target, message))
                outputs.append(dockerOutputBlock(command: script, output: "FAILED: \(message)"))
            }

            updateDockerOperation(
                operationId,
                detail: "\(batch.command) \(target) (\(humanIndex) of \(total))",
                completedCount: humanIndex
            )
        }

        clearDockerSelection(scope: batch.scope, succeededTargets: Set(succeededTargets))
        await refresh()

        let failedCount = failedTargets.count
        let succeededCount = succeededTargets.count
        let state: RemoteOperationState
        let detail: String
        if failedCount == 0 {
            state = .succeeded
            detail = "Completed \(succeededCount) of \(total)."
        } else if succeededCount == 0 {
            state = .failed
            detail = "Failed all \(total) item\(total == 1 ? "" : "s")."
        } else {
            state = .warning
            detail = "Completed \(succeededCount) of \(total); \(failedCount) failed."
        }

        let failureSummary = failedTargets
            .map { "\($0.target): \($0.message)" }
            .joined(separator: "\n")
        let output = outputs.joined(separator: "\n\n")
        finishDockerOperation(
            operationId,
            state: state,
            detail: detail,
            output: output,
            completedCount: total,
            errorMessage: failureSummary.isEmpty ? nil : failureSummary
        )
        ActivityLogStore.shared.record(
            title: batch.title,
            detail: detail,
            connectionId: connectionId,
            icon: "shippingbox",
            severity: state == .succeeded ? .success : (state == .warning ? .warning : .critical)
        )
    }

    private func clearDockerSelection(scope: BatchScope, succeededTargets: Set<String>) {
        switch scope {
        case .containers:
            checkedContainerIds.subtract(succeededTargets)
        case .images:
            checkedImageIds.subtract(succeededTargets)
        case .volumes:
            checkedVolumeIds.subtract(succeededTargets)
        case .networks:
            checkedNetworkIds.subtract(succeededTargets)
        case .disk:
            break
        }
    }

    private func dockerCompletionDetail(fallback: String, output: String) -> String {
        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return firstLine ?? fallback
    }

    private func dockerOutputBlock(command: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "$ \(command)"
        }
        return "$ \(command)\n\(trimmed)"
    }

    private func execShellCommand(_ container: DockerContainer) -> String {
        "docker exec -it \(RemoteCommandRunner.shellQuote(container.name)) sh"
    }

    private func runExecShell(_ container: DockerContainer) {
        guard let connectionId else { return }
        guard let data = "\(execShellCommand(container))\n".data(using: .utf8) else { return }
        TerminalSessionManager.shared.sendInput(connectionId: connectionId, data: data)
    }
}

// MARK: - PostgreSQL

private struct PostgresSettings: Equatable {
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

    private func runInConfiguredUser(_ command: String, binary: String) -> String {
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

private struct SQLResult {
    let columns: [String]
    let rows: [[String]]
}

private struct PGDashboardSnapshot {
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

private struct PGDashboardTable: Identifiable, Hashable {
    let schema: String
    let name: String
    let size: String
    let sizeBytes: Int64
    let rowEstimate: Int64

    var id: String { "\(schema).\(name)" }
}

private struct PGDashboardMaintenanceRow: Identifiable, Hashable {
    let schema: String
    let name: String
    let deadTuples: Int64
    let liveTuples: Int64
    let lastAutovacuum: String
    let lastAutoanalyze: String

    var id: String { "\(schema).\(name)" }
}

private let postgresDashboardSQL = """
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

private func parsePostgresDashboard(_ output: String) -> PGDashboardSnapshot {
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

private func postgresDashboardRawText(_ snapshot: PGDashboardSnapshot) -> String {
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

private func formatPostgresDashboardCount(_ value: Int64) -> String {
    value.formatted()
}

private func postgresDashboardVersionShort(_ snapshot: PGDashboardSnapshot) -> String {
    let value = snapshot.value("version")
    let parts = value.split(separator: " ")
    if parts.count >= 2, parts[0] == "PostgreSQL" {
        return String(parts[1])
    }
    return value
}

private func compactPostgresDashboardInterval(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ")
    if parts.count >= 3, let days = Int(parts[0]), parts[1].hasPrefix("day") {
        let hours = parts[2].split(separator: ":").first.map(String.init) ?? "0"
        return "\(days)d \(hours)h"
    }
    return String(trimmed.split(separator: ".").first ?? "-")
}

private func postgresDashboardLockColor(_ snapshot: PGDashboardSnapshot) -> Color {
    postgresDashboardIntMetric(snapshot, "locks_waiting") > 0 ? .red : .green
}

private func postgresDashboardCacheHitText(_ snapshot: PGDashboardSnapshot) -> String {
    guard let ratio = postgresDashboardDoubleMetric(snapshot, "cache_hit_ratio") else {
        return snapshot.value("cache_hit_ratio")
    }
    return String(format: "%.2f%%", ratio)
}

private func postgresDashboardCacheHitColor(_ snapshot: PGDashboardSnapshot) -> Color {
    guard let ratio = postgresDashboardDoubleMetric(snapshot, "cache_hit_ratio") else { return .secondary }
    if ratio < 90 { return .red }
    if ratio < 95 { return .orange }
    return .green
}

private func postgresDashboardReadOnlyColor(_ snapshot: PGDashboardSnapshot) -> Color {
    snapshot.value("read_only").lowercased() == "on" ? .orange : .green
}

private func postgresDashboardSSLColor(_ snapshot: PGDashboardSnapshot) -> Color {
    snapshot.value("ssl").lowercased() == "on" ? .green : .orange
}

private func postgresDashboardIntMetric(_ snapshot: PGDashboardSnapshot, _ key: String) -> Int {
    Int(snapshot.value(key)) ?? 0
}

private func postgresDashboardDoubleMetric(_ snapshot: PGDashboardSnapshot, _ key: String) -> Double? {
    Double(snapshot.value(key))
}

private func sanitizePostgresCommandOutput(_ output: String) -> (output: String, warnings: [String]) {
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

private enum PGVacuumScope: String, CaseIterable, Identifiable {
    case userTables = "User"
    case needsAttention = "Attention"
    case highDead = "High dead"
    case neverAnalyzed = "Never analyzed"
    case currentSchema = "Current"
    case systemTables = "System"

    var id: String { rawValue }
}

private struct PGVacuumRow: Identifiable, Hashable {
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

private struct PGSlowQuery: Identifiable, Hashable {
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

private struct PGReplicationSnapshot {
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

private struct PGReplicaRow: Identifiable, Hashable {
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

private struct PGReplicationSlot: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let database: String
    let active: String
    let plugin: String
    let restartLsn: String
    let confirmedFlushLsn: String
}

private struct PGSession: Identifiable, Hashable {
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

private struct PGTableInfo: Identifiable, Hashable {
    let schema: String
    let name: String
    let kind: String
    let size: String
    let sizeBytes: Int64
    let estimate: String
    let estimateCount: Int64

    var id: String { "\(schema).\(name)" }
}

struct PostgresMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    private enum Mode: String, CaseIterable {
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
    @State private var settings = PostgresSettings()
    @State private var mode: Mode = .dashboard
    @State private var dashboard = PGDashboardSnapshot.empty
    @State private var showsConnectionSettings = false
    @State private var showsRawDashboard = false
    @State private var sessions: [PGSession] = []
    @State private var selectedPid: String?
    @State private var locks: String = ""
    @State private var queryText: String = "select now(), current_database(), current_user;"
    @State private var queryResult = SQLResult(columns: [], rows: [])
    @State private var queryFilter = ""
    @State private var queryWarnings: [String] = []
    @State private var queryError: String?
    @State private var queryStartedAt: Date?
    @State private var queryLastDuration: TimeInterval?
    @State private var queryIsRunning = false
    @State private var schemaRows: [PGTableInfo] = []
    @State private var selectedTableId: String?
    @State private var schemaSortOrder: [KeyPathComparator<PGTableInfo>] = [
        .init(\.schema),
        .init(\.name)
    ]
    @State private var explainText: String = ""
    @State private var explainWarnings: [String] = []
    @State private var explainError: String?
    @State private var explainStartedAt: Date?
    @State private var explainLastDuration: TimeInterval?
    @State private var explainIsRunning = false
    @State private var slowRows: [PGSlowQuery] = []
    @State private var slowFilter = ""
    @State private var slowWarnings: [String] = []
    @State private var slowError: String?
    @State private var slowDiagnostics = ""
    @State private var slowSortOrder: [KeyPathComparator<PGSlowQuery>] = [
        .init(\.totalMs, order: .reverse),
        .init(\.meanMs, order: .reverse)
    ]
    @State private var replicationSnapshot = PGReplicationSnapshot.empty
    @State private var replicationWarnings: [String] = []
    @State private var replicationError: String?
    @State private var replicationReplicaSortOrder: [KeyPathComparator<PGReplicaRow>] = [
        .init(\.state),
        .init(\.user)
    ]
    @State private var replicationSlotSortOrder: [KeyPathComparator<PGReplicationSlot>] = [
        .init(\.name)
    ]
    @State private var vacuumRows: [PGVacuumRow] = []
    @State private var vacuumWarnings: [String] = []
    @State private var vacuumRefreshedAt: Date?
    @State private var vacuumCurrentSchema: String = "public"
    @State private var vacuumScope: PGVacuumScope = .userTables
    @State private var selectedVacuumTableId: String?
    @State private var vacuumSortOrder: [KeyPathComparator<PGVacuumRow>] = [
        .init(\.statusRank),
        .init(\.deadTuples, order: .reverse),
        .init(\.schema),
        .init(\.name)
    ]
    @State private var backupPath: String = "/tmp/mc-ssh-postgres.dump"
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var pendingBackendAction: BackendAction?
    @State private var pendingVacuumAction: VacuumAction?
    @State private var maintenanceOperation: RemoteOperationFeedback?
    @State private var maintenanceOperationOutput: RemoteOperationFeedback?

    fileprivate struct BackendAction: Identifiable {
        let id = UUID()
        let function: String
        let pid: String
    }

    fileprivate struct VacuumAction: Identifiable {
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

    private var header: some View {
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

    private var connectionControls: some View {
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

    private var showsPostgresModeFilter: Bool {
        mode == .schema || mode == .vacuum
    }

    private var usesLocalPostgresError: Bool {
        mode == .query || mode == .explain || mode == .slow || mode == .replication
    }

    private var connectionSummary: String {
        let database = settings.database.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settings.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = host.isEmpty
            ? connectionLabel
            : "\(host)\(port.isEmpty ? "" : ":\(port)")"
        return "\(database.isEmpty ? "postgres" : database) on \(target)"
    }

    private var osUserSummary: String {
        guard settings.runAsPostgresUser else { return "current OS user" }
        let user = settings.osUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return "as \(user.isEmpty ? "postgres" : user)"
    }

    private var connectionSettingsForm: some View {
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
    private var content: some View {
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

    private var postgresDashboard: some View {
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

    private var dashboardMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)]
    }

    private var dashboardPanelColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 320), spacing: 10, alignment: .top)]
    }

    @ViewBuilder
    private func dashboardMetricTile(
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

    private func dashboardMetricTileContent(
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

    private var largestTablesPanel: some View {
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

    private var maintenancePanel: some View {
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

    private func dashboardPanel<Content: View>(
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

    private func dashboardEmptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var postgresVersionShort: String {
        let value = dashboard.value("version")
        let parts = value.split(separator: " ")
        if parts.count >= 2, parts[0] == "PostgreSQL" {
            return String(parts[1])
        }
        return value
    }

    private var lockHealthColor: Color {
        intMetric("locks_waiting") > 0 ? .red : .green
    }

    private var lockHealthText: String {
        intMetric("locks_waiting") > 0 ? "Investigate blockers" : "No waits"
    }

    private var cacheHitText: String {
        guard let ratio = doubleMetric("cache_hit_ratio") else {
            return dashboard.value("cache_hit_ratio")
        }
        return String(format: "%.2f%%", ratio)
    }

    private var cacheHitColor: Color {
        guard let ratio = doubleMetric("cache_hit_ratio") else { return .secondary }
        if ratio < 90 { return .red }
        if ratio < 95 { return .orange }
        return .green
    }

    private var cacheHitHealthText: String {
        guard let ratio = doubleMetric("cache_hit_ratio") else { return "No cache sample" }
        if ratio < 90 { return "Poor buffer locality" }
        if ratio < 95 { return "Below target" }
        return "Healthy"
    }

    private var readOnlyColor: Color {
        dashboard.value("read_only").lowercased() == "on" ? .orange : .green
    }

    private var sslHealthColor: Color {
        dashboard.value("ssl").lowercased() == "on" ? .green : .orange
    }

    private var sslHealthText: String {
        dashboard.value("ssl").lowercased() == "on" ? "Enabled" : "Disabled"
    }

    private func intMetric(_ key: String) -> Int {
        Int(dashboard.value(key)) ?? 0
    }

    private func doubleMetric(_ key: String) -> Double? {
        Double(dashboard.value(key))
    }

    private func compactPostgresInterval(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        if parts.count >= 3, let days = Int(parts[0]), parts[1].hasPrefix("day") {
            let hours = parts[2].split(separator: ":").first.map(String.init) ?? "0"
            return "\(days)d \(hours)h"
        }
        return String(trimmed.split(separator: ".").first ?? "-")
    }

    private func parsePostgresTimestamp(_ value: String) -> Date? {
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

    private func normalizePostgresTimezone(_ value: String) -> String {
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

    private func compactPostgresTimestamp(_ value: String, date: Date?) -> String {
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

    private func formatCount(_ value: Int64) -> String {
        value.formatted()
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func openSchemaSortedBySize() {
        schemaSortOrder = [.init(\.sizeBytes, order: .reverse)]
        mode = .schema
    }

    private var vacuumPane: some View {
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

    private var vacuumWarningBanner: some View {
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

    private var vacuumSummaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8, alignment: .top)]
    }

    private func vacuumSummaryTile(
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
    private var vacuumSelectionActions: some View {
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

    private var vacuumTable: some View {
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

    private func vacuumStatusChip(_ row: PGVacuumRow) -> some View {
        let color = vacuumStatusColor(row)
        return Text(row.statusTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func vacuumStatusColor(_ row: PGVacuumRow) -> Color {
        if row.needsVacuum { return .orange }
        if row.neverAnalyzed { return .red }
        if row.staleAnalyze { return .blue }
        return .green
    }

    private func vacuumRowMenu(_ row: PGVacuumRow) -> some View {
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

    private var selectedVacuumRow: PGVacuumRow? {
        vacuumRows.first { $0.id == selectedVacuumTableId }
    }

    private var userVacuumRows: [PGVacuumRow] {
        vacuumRows.filter { !$0.isSystemTable }
    }

    private var filteredVacuumRows: [PGVacuumRow] {
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

    private func ensureVisibleVacuumSelection() {
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

    private var vacuumNeedsVacuumCount: Int {
        userVacuumRows.filter(\.needsVacuum).count
    }

    private var vacuumNeverAnalyzedCount: Int {
        userVacuumRows.filter(\.neverAnalyzed).count
    }

    private var vacuumTotalDeadTuples: Int64 {
        userVacuumRows.reduce(Int64(0)) { $0 + max(0, $1.deadTuples) }
    }

    private var vacuumRowsInCurrentSchema: Int {
        vacuumRows.filter { $0.schema == vacuumCurrentSchema }.count
    }

    private var vacuumWorstDeadPercentRow: PGVacuumRow? {
        userVacuumRows.max { $0.deadPercent < $1.deadPercent }
    }

    private var vacuumWorstDeadPercentText: String {
        guard let row = vacuumWorstDeadPercentRow else { return "-" }
        return formatPercent(row.deadPercent)
    }

    private var vacuumWorstDeadPercentTable: String {
        guard let row = vacuumWorstDeadPercentRow else { return "No user tables" }
        return "\(row.schema).\(row.name)"
    }

    private var vacuumWorstDeadPercentColor: Color {
        guard let row = vacuumWorstDeadPercentRow else { return .secondary }
        if row.needsVacuum { return .orange }
        if row.deadPercent >= 10 { return .red }
        return .green
    }

    private var vacuumOldestAutovacuumRow: PGVacuumRow? {
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

    private var vacuumOldestAutovacuumText: String {
        guard let row = vacuumOldestAutovacuumRow else { return "-" }
        return compactPostgresTimestamp(row.lastAutovacuum, date: row.lastAutovacuumDate)
    }

    private var vacuumOldestAutovacuumTable: String {
        guard let row = vacuumOldestAutovacuumRow else { return "No autovacuum sample" }
        return "\(row.schema).\(row.name)"
    }

    private var sessionsView: some View {
        List(selection: $selectedPid) {
            ForEach(filteredSessions) { session in
                HStack(spacing: 8) {
                    monoCell(session.pid, width: 70)
                    monoCell(session.user, width: 90)
                    monoCell(session.state, width: 90, color: statusColor(session.state))
                    monoCell(session.wait, width: 130)
                    monoCell(session.age, width: 90)
                    monoCell(session.query)
                }
                .tag(session.pid)
                .contextMenu {
                    Button("Cancel Query") {
                        pendingBackendAction = BackendAction(function: "pg_cancel_backend", pid: session.pid)
                    }
                    Button("Terminate Backend", role: .destructive) {
                        pendingBackendAction = BackendAction(function: "pg_terminate_backend", pid: session.pid)
                    }
                    Button("Copy Query") { RemoteCommandRunner.copy(session.query) }
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredSessions: [PGSession] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.pid.contains(needle)
                || $0.user.lowercased().contains(needle)
                || $0.query.lowercased().contains(needle)
                || $0.state.lowercased().contains(needle)
        }
    }

    private var queryRunner: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                queryEditorToolbar
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 210)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            queryResultsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var queryEditorToolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runQuery() }
            } label: {
                Label(queryIsRunning ? "Running" : "Run", systemImage: queryIsRunning ? "hourglass" : "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(queryIsRunning || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                queryText = ""
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(queryIsRunning || queryText.isEmpty)

            Spacer()

            queryStatusView
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var queryStatusView: some View {
        TimelineView(.periodic(from: queryStartedAt ?? Date(), by: 1)) { context in
            HStack(spacing: 6) {
                if queryIsRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(queryStatusText(now: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(queryError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private var queryResultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(queryResultsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !queryWarnings.isEmpty {
                    Label("\(queryWarnings.count) warning\(queryWarnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(queryWarnings.joined(separator: "\n"))
                }

                Spacer()

                TextField("Filter results", text: $queryFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(queryResult.rows.isEmpty)

                Button {
                    RemoteCommandRunner.copy(resultText(visibleQueryResult))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(visibleQueryResult.rows.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let queryError {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(queryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.06))
            }

            Divider()

            resultTable(visibleQueryResult)
        }
    }

    private var schemaBrowser: some View {
        Table(filteredTables.sorted(using: schemaSortOrder), selection: $selectedTableId, sortOrder: $schemaSortOrder) {
            TableColumn("Schema", value: \.schema) { table in
                monoCell(table.schema, color: .secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Name", value: \.name) { table in
                monoCell(table.name)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Kind", value: \.kind) { table in
                monoCell(table.kind)
            }
            .width(min: 55, ideal: 70, max: 90)

            TableColumn("Size", value: \.sizeBytes) { table in
                monoCell(table.size)
            }
            .width(min: 75, ideal: 90, max: 120)

            TableColumn("Rows", value: \.estimateCount) { table in
                monoCell(table.estimate)
            }
            .width(min: 80, ideal: 100)
        }
    }

    private var filteredTables: [PGTableInfo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return schemaRows }
        return schemaRows.filter {
            $0.schema.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    private var explainPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                explainToolbar
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 210)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            explainResultsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var explainToolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runExplain() }
            } label: {
                Label(explainIsRunning ? "Running" : "Explain Analyze", systemImage: explainIsRunning ? "hourglass" : "chart.bar.doc.horizontal")
            }
            .disabled(explainIsRunning || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                RemoteCommandRunner.copy(explainText)
            } label: {
                Label("Copy Plan", systemImage: "doc.on.doc")
            }
            .disabled(explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            TimelineView(.periodic(from: explainStartedAt ?? Date(), by: 1)) { context in
                HStack(spacing: 6) {
                    if explainIsRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(explainStatusText(now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(explainError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var explainResultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(explainSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !explainWarnings.isEmpty {
                    postgresWarningsLabel(explainWarnings)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let explainError {
                Divider()
                postgresInlineNotice(
                    systemImage: "xmark.octagon.fill",
                    title: "Explain failed",
                    message: explainError,
                    color: .red
                )
            }

            Divider()

            if explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                placeholderView(icon: "chart.bar.doc.horizontal", title: "No plan", message: "Run Explain Analyze to inspect the current SQL.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    HighlightedRawOutputText(value: explainText)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var slowPane: some View {
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

    private var replicationPane: some View {
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

    private var replicationOverview: some View {
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

    private var replicationReplicaSection: some View {
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

    private var replicationSlotSection: some View {
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

    private var backupPane: some View {
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

    private func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var visibleQueryResult: SQLResult {
        let needle = queryFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return queryResult }
        return SQLResult(
            columns: queryResult.columns,
            rows: queryResult.rows.filter { row in
                row.joined(separator: " ").lowercased().contains(needle)
            }
        )
    }

    private var queryResultsSummary: String {
        let total = queryResult.rows.count
        let visible = visibleQueryResult.rows.count
        if total == 0 { return "No rows" }
        if queryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(total) row\(total == 1 ? "" : "s")"
        }
        return "\(visible) of \(total) row\(total == 1 ? "" : "s")"
    }

    private func queryStatusText(now: Date) -> String {
        if queryIsRunning, let started = queryStartedAt {
            return "Running \(formatQueryDuration(now.timeIntervalSince(started)))"
        }
        if let queryLastDuration {
            return "\(queryResult.rows.count) row\(queryResult.rows.count == 1 ? "" : "s") · \(formatQueryDuration(queryLastDuration))"
        }
        return "Ready"
    }

    private func formatQueryDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", max(0, duration) * 1_000)
        }
        if duration < 60 {
            return String(format: "%.1f s", duration)
        }
        return formatOperationDuration(duration)
    }

    private func resultTable(_ result: SQLResult) -> some View {
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

    private func postgresWarningsLabel(_ warnings: [String]) -> some View {
        Label("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .help(warnings.joined(separator: "\n"))
    }

    private func postgresInlineNotice(systemImage: String, title: String, message: String, color: Color) -> some View {
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

    private func postgresCompactNotice(systemImage: String, text: String) -> some View {
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

    private func postgresSummaryChip(title: String, value: String, systemImage: String, color: Color) -> some View {
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

    private func postgresTableHeight(rowCount: Int) -> CGFloat {
        Swift.min(320, Swift.max(112, CGFloat(rowCount + 1) * 28 + 18))
    }

    private var filteredSlowRows: [PGSlowQuery] {
        let needle = slowFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return slowRows }
        return slowRows.filter { row in
            row.query.lowercased().contains(needle)
                || row.totalMsText.lowercased().contains(needle)
                || row.meanMsText.lowercased().contains(needle)
                || "\(row.calls)".contains(needle)
        }
    }

    private var slowSummaryText: String {
        if let slowError, slowRows.isEmpty { return slowError }
        let total = slowRows.count
        let visible = filteredSlowRows.count
        if total == 0 { return "No slow queries" }
        if slowFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(total) slow quer\(total == 1 ? "y" : "ies")"
        }
        return "\(visible) of \(total) slow quer\(total == 1 ? "y" : "ies")"
    }

    private var replicationSummaryText: String {
        if let replicationError { return replicationError }
        let role = replicationSnapshot.role == "-" ? "Unknown role" : replicationSnapshot.role.capitalized
        let replicas = replicationSnapshot.replicas.count
        let slots = replicationSnapshot.slots.count
        return "\(role) · \(replicas) replica\(replicas == 1 ? "" : "s") · \(slots) slot\(slots == 1 ? "" : "s")"
    }

    private var explainSummaryText: String {
        let items = explainSummaryItems
        if !items.isEmpty { return items.joined(separator: " · ") }
        if explainIsRunning { return "Running explain" }
        if explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No plan" }
        return "Plan ready"
    }

    private var explainSummaryItems: [String] {
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

    private func explainStatusText(now: Date) -> String {
        if explainIsRunning, let started = explainStartedAt {
            return "Running \(formatQueryDuration(now.timeIntervalSince(started)))"
        }
        if let explainLastDuration {
            return "Finished \(formatQueryDuration(explainLastDuration))"
        }
        return "Ready"
    }

    private func explainMetric(after prefix: String) -> String? {
        for line in explainText.lines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private var explainRowsText: String? {
        for line in explainText.lines() {
            let parts = line.components(separatedBy: " rows=")
            guard parts.count > 1 else { continue }
            let tokenSource = parts.count > 2 ? parts[2] : parts[1]
            let token = tokenSource.prefix { $0.isNumber }
            if !token.isEmpty { return String(token) }
        }
        return nil
    }

    private func slowExportText(_ rows: [PGSlowQuery]) -> String {
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

    private func refresh() async {
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

    private func psql(_ sql: String) async throws -> String {
        let result = try await psqlOutput(sql)
        return result.output
    }

    private func psqlOutput(_ sql: String) async throws -> (output: String, warnings: [String]) {
        guard let connectionId else { return ("", []) }
        let rawOutput = try await RemoteCommandRunner.runChecked(
            connectionId: connectionId,
            script: settings.queryScript(sql)
        )
        return sanitizedPostgresOutput(rawOutput)
    }

    private func sanitizedPostgresOutput(_ output: String) -> (output: String, warnings: [String]) {
        sanitizePostgresCommandOutput(output)
    }

    private func sanitizedPostgresError(_ error: Error) -> (message: String, warnings: [String], diagnostics: String) {
        let diagnostics = error.localizedDescription
        let sanitized = sanitizedPostgresOutput(diagnostics)
        let message = sanitized.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            message: message.isEmpty ? diagnostics : message,
            warnings: sanitized.warnings,
            diagnostics: diagnostics
        )
    }

    private func loadDashboard() async {
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

    private func loadSessions() async {
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

    private func loadLocks() async {
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

    private func runQuery() async {
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

    private func parseSQLResult(_ output: String) -> SQLResult {
        let lines = output.lines()
        guard !lines.isEmpty else { return SQLResult(columns: [], rows: []) }
        let rows = lines.map(splitFields)
        let width = rows.map(\.count).max() ?? 0
        let columns = (0..<width).map { "col\($0 + 1)" }
        return SQLResult(columns: columns, rows: rows)
    }

    private func resultText(_ result: SQLResult) -> String {
        ([result.columns.joined(separator: "\t")] + result.rows.map { $0.joined(separator: "\t") }).joined(separator: "\n")
    }

    private func parseSlowQueries(_ output: String) -> [PGSlowQuery] {
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

    private func slowErrorMessage(_ message: String) -> String {
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

    private func parseReplication(_ output: String) -> PGReplicationSnapshot {
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

    private func replicationRawText(_ snapshot: PGReplicationSnapshot) -> String {
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

    private func loadSchema() async {
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

    private func runExplain() async {
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

    private func loadSlowQueries() async {
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

    private func loadReplication() async {
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

    private func loadVacuum() async {
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

    private func parseVacuumOutput(_ output: String) {
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

    private func vacuumExportText(_ rows: [PGVacuumRow]) -> String {
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

    private func runBackendAction(_ action: BackendAction) async {
        pendingBackendAction = nil
        do {
            _ = try await psql("select \(action.function)(\(action.pid));")
            await loadSessions()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func queueVacuumAction(_ command: String, row: PGVacuumRow, destructive: Bool = false) {
        pendingVacuumAction = VacuumAction(
            title: "Run \(command)",
            sql: vacuumSQL(command, row: row),
            command: command,
            tableId: row.id,
            destructive: destructive
        )
    }

    private func runVacuumAction(_ action: VacuumAction) async {
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

    private var isMaintenanceOperationRunning: Bool {
        maintenanceOperation?.isRunning == true
    }

    private func maintenanceOperationTargets(_ target: String) -> Bool {
        guard let maintenanceOperation, maintenanceOperation.isRunning else { return false }
        return maintenanceOperation.targetIds.contains(target)
    }

    private func startMaintenanceOperation(
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

    private func finishMaintenanceOperation(
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

    private func dismissMaintenanceOperation(_ id: UUID) {
        guard maintenanceOperation?.id == id, maintenanceOperation?.isRunning == false else { return }
        maintenanceOperation = nil
    }

    private func vacuumSQL(_ command: String, row: PGVacuumRow) -> String {
        "\(command) \(postgresQualifiedName(schema: row.schema, name: row.name));"
    }

    private func postgresQualifiedName(schema: String, name: String) -> String {
        "\(postgresIdentifier(schema)).\(postgresIdentifier(name))"
    }

    private func postgresIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func runBackup(download: Bool) async {
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

private extension String {
    func lines() -> [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }

    func section(after start: String, before end: String?) -> String {
        guard let startRange = range(of: start) else { return "" }
        let lower = startRange.upperBound
        let upper: String.Index
        if let end, let endRange = self[lower...].range(of: end) {
            upper = endRange.lowerBound
        } else {
            upper = endIndex
        }
        return String(self[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
