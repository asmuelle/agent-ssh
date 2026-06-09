import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct JournalIssueCounts: Equatable {
    var errors: Int
    var warnings: Int

    static let zero = JournalIssueCounts(errors: 0, warnings: 0)

    var hasIssues: Bool {
        errors > 0 || warnings > 0
    }
}

enum JournalIssueClassifier {
    enum Issue {
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

    static func classify(_ line: String) -> Issue? {
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

    static func journalMessage(in line: String) -> String {
        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        if fields.count == 4, isLikelyJournalTimestamp(fields[0]) {
            return fields[3]
        }
        return line
    }

    static func isLikelyJournalTimestamp(_ value: String) -> Bool {
        (value.contains("-") || value.contains(":")) && value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    static let errorRegex = try? NSRegularExpression(
        pattern: #"\b(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)\b"#,
        options: [.caseInsensitive]
    )

    static let warningRegex = try? NSRegularExpression(
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

    func issueBadge(count: Int, icon: String, color: Color, help: String) -> some View {
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

