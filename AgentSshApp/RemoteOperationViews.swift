import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

enum RawOutputHighlightMode {
    case generic
    case systemdUnit
}

struct HighlightedRawOutputText: View {
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

func highlightedRawOutput(_ value: String, mode: RawOutputHighlightMode = .generic) -> AttributedString {
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

func highlightedSystemdUnitLine(_ line: String) -> AttributedString {
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

func highlightedGenericOutputLine(_ line: String) -> AttributedString {
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

func highlightedKeyValueLine(_ line: String, systemdMode: Bool) -> AttributedString {
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

func keyValueSeparatorIndex(in text: String) -> String.Index? {
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

func isLikelyRawOutputKey(_ key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
    return trimmed.allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." || character == " "
    }
}

func highlightedRawOutputValue(_ value: String, fallbackColor: Color? = nil) -> AttributedString {
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

func rawOutputWordCharacter(_ character: Character) -> Bool {
    character.isLetter
        || character.isNumber
        || character == "_"
        || character == "-"
        || character == "."
        || character == "/"
        || character == "@"
        || character == ":"
}

func rawOutputSeverityColor(_ text: String) -> Color? {
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

func rawOutputTokenColor(_ token: String) -> Color? {
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

func rawOutputSegment(_ text: String, color: Color? = nil, weight: Font.Weight? = nil) -> AttributedString {
    var segment = AttributedString(text)
    if let color {
        segment.foregroundColor = color
    }
    if let weight {
        segment.font = .system(.caption, design: .monospaced).weight(weight)
    }
    return segment
}

enum RemoteOperationState {
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

struct RemoteOperationFeedback: Identifiable {
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

func formatOperationDuration(_ interval: TimeInterval) -> String {
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

struct RemoteOperationBanner: View {
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

struct RemoteOperationOutputSheet: View {
    let operation: RemoteOperationFeedback
    @Environment(\.dismiss) var dismiss

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

func monoCell(_ text: String, width: CGFloat? = nil, color: Color = .primary) -> some View {
    Text(text.isEmpty ? "-" : text)
        .font(.caption.monospaced())
        .foregroundStyle(color)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: width, alignment: .leading)
}

@ViewBuilder
func rowOperationIndicator(isActive: Bool) -> some View {
    if isActive {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 16, height: 16)
    } else {
        Color.clear
            .frame(width: 16, height: 16)
    }
}

func statusColor(_ value: String) -> Color {
    let lower = value.lowercased()
    if lower.contains("running") || lower == "active" || lower == "healthy" { return .green }
    if lower.contains("failed") || lower.contains("exited") || lower.contains("dead") || lower == "unhealthy" { return .red }
    if lower.contains("activating") || lower.contains("restarting") || lower.contains("paused") { return .orange }
    return .secondary
}

// MARK: - UFW

