import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct UFWStatusSnapshot {
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

struct UFWRule: Identifiable, Hashable {
    let number: Int
    let action: String
    let target: String
    let source: String
    let comment: String
    let raw: String

    var id: Int { number }
}

struct UFWLogEntry: Identifiable, Hashable {
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

struct UFWTopTalker: Identifiable, Hashable {
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

