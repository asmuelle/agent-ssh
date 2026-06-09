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

let fieldSeparator = "\u{1F}"

func splitFields(_ line: String) -> [String] {
    line.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
}

func formatPostgresMilliseconds(_ value: Double) -> String {
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

func placeholderView(icon: String, title: String, message: String) -> some View {
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


extension String {
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
