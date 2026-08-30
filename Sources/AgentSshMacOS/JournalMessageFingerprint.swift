import Foundation

/// A journal message reduced to its stable shape: volatile tokens
/// (timestamps, object ids, addresses, counters) are masked out of
/// `template` and collected in `captures`, in order of appearance.
///
/// Two messages with equal templates are the same log statement fired
/// with different parameters — `Failed to validate connection
/// PgConnection@8295ff9` and `…@1c9ad066` collapse to one template with
/// one capture each. Journal views group runs of equal-template lines
/// into a single row and list the captures per occurrence.
public struct JournalMessageFingerprint: Equatable {
    public let template: String
    public let captures: [String]

    public init(template: String, captures: [String]) {
        self.template = template
        self.captures = captures
    }
}

public enum JournalMessageFingerprinting {
    /// Placeholder marking a masked token inside `template`. U+FFFC is
    /// the Unicode object-replacement character — it cannot appear in
    /// journalctl output, so templates never collide with real text.
    public static let placeholder = "\u{FFFC}"

    // MARK: - Cache

    private final class Box {
        let value: JournalMessageFingerprint
        init(_ value: JournalMessageFingerprint) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 8192
        return cache
    }()

    // MARK: - Volatile token patterns

    /// Ordered by specificity; earlier matches win and later patterns
    /// never override an already-claimed range (same discipline as the
    /// syntax-highlighting pass).
    ///
    /// The final bare-number pattern deliberately requires 2+ digits:
    /// single digits are usually structural ("attempt 1 of 3" varies,
    /// but "HTTP/2" and "IPv4" don't), and under-masking only costs a
    /// missed grouping while over-masking merges genuinely different
    /// messages.
    private static let patterns: [NSRegularExpression] = [
        // ISO timestamps, with optional fraction and zone.
        #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#,
        // Bare clock times.
        #"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"#,
        // UUIDs.
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
        // Java-style identity hashes: PgConnection@8295ff9.
        #"(?<=@)[0-9a-fA-F]{4,}\b"#,
        // Hex literals and long hex runs (hashes, request ids). The
        // lookahead requires a digit so ordinary words never match.
        #"\b0x[0-9a-fA-F]+\b"#,
        #"\b(?=[0-9a-fA-F]*\d)[0-9a-fA-F]{12,}\b"#,
        // IPv4, optionally with port.
        #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?::\d{1,5})?\b"#,
        // Numbers of 2+ digits, or any number carrying a decimal part
        // or unit suffix (durations, sizes, percentages).
        #"\b\d+\.\d+(?:ms|s|m|h|%|[KMGT]i?B)?(?!\w)"#,
        #"\b\d{2,}(?:ms|s|m|h|%|[KMGT]i?B)?(?!\w)"#,
        #"\b\d(?:ms|s|m|h|%|[KMGT]i?B)(?!\w)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // MARK: - API

    /// The fingerprint of `message`. Deterministic and memoized —
    /// grouping passes re-run on every search keystroke.
    public static func fingerprint(_ message: String) -> JournalMessageFingerprint {
        let key = message as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = compute(message)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    private static func compute(_ message: String) -> JournalMessageFingerprint {
        structuralJSONFingerprint(message) ?? regexFingerprint(message)
    }

    // MARK: - Structured (JSON) messages

    /// Keys that carry the statement's identity — part of the template,
    /// never captures.
    private static let statementKeys: Set<String> = ["msg", "message", "level", "severity", "lvl"]

    /// Keys whose values are per-line noise with a dedicated column in
    /// every journal view — excluded from captures entirely so the
    /// occurrence list doesn't repeat the time column.
    private static let ignoredKeys: Set<String> = ["timestamp", "@timestamp", "time", "ts", "t"]

    /// Fingerprint for messages carrying a JSON payload. Two structured
    /// lines are the same statement when their `msg`/`level` and key
    /// sets match; every other field value is a capture (`plugin_id=…`),
    /// so lines that differ only in parameters group even though the
    /// varying parts are arbitrary strings the regex masks can't see.
    private static func structuralJSONFingerprint(_ message: String) -> JournalMessageFingerprint? {
        guard let range = JournalSyntaxHighlighting.jsonPayloadRange(in: message),
              let data = message[range].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }

        let prefix = regexFingerprint(String(message[..<range.lowerBound]))
        let suffix = regexFingerprint(String(message[range.upperBound...]))
        var template = prefix.template + "{"
        var captures = prefix.captures

        if let level = statementValue(in: dictionary, keys: ["level", "severity", "lvl"]) {
            template += "level=\(level) "
        }
        if let msg = statementValue(in: dictionary, keys: ["msg", "message"]) {
            // The msg text itself can embed volatile tokens ("retried
            // 12 times") — mask those too instead of splitting groups.
            let masked = regexFingerprint(msg)
            template += "msg=\(masked.template) "
            captures += masked.captures
        }

        let parameterKeys = dictionary.keys
            .filter { !statementKeys.contains($0.lowercased()) && !ignoredKeys.contains($0.lowercased()) }
            .sorted()
        template += "keys=\(parameterKeys.joined(separator: ","))}" + suffix.template
        for key in parameterKeys {
            captures.append("\(key)=\(stringify(dictionary[key]))")
        }
        captures += suffix.captures
        return JournalMessageFingerprint(template: template, captures: captures)
    }

    private static func statementValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            let value = dictionary[key] ?? dictionary.first { $0.key.lowercased() == key }?.value
            if let value { return stringify(value) }
        }
        return nil
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let value?:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(
                   withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
               ),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        case nil: return ""
        }
    }

    // MARK: - Plain-text messages

    private static func regexFingerprint(_ message: String) -> JournalMessageFingerprint {
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        var claimed: [Range<String.Index>] = []
        for regex in patterns {
            regex.enumerateMatches(in: message, range: fullRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: message) else { return }
                if !claimed.contains(where: { $0.overlaps(range) }) {
                    claimed.append(range)
                }
            }
        }
        guard !claimed.isEmpty else {
            return JournalMessageFingerprint(template: message, captures: [])
        }

        claimed.sort { $0.lowerBound < $1.lowerBound }
        var template = ""
        var captures: [String] = []
        var cursor = message.startIndex
        for range in claimed {
            template += message[cursor..<range.lowerBound]
            template += placeholder
            captures.append(String(message[range]))
            cursor = range.upperBound
        }
        template += message[cursor...]
        return JournalMessageFingerprint(template: template, captures: captures)
    }

    /// Indices of capture slots whose values actually differ across a
    /// group of same-template fingerprints — the columns worth showing
    /// in an expanded occurrence list. Slots that repeat the same value
    /// in every line (a shared port, a constant size) are noise there.
    public static func variedCaptureIndices(of group: [JournalMessageFingerprint]) -> [Int] {
        guard let first = group.first else { return [] }
        return first.captures.indices.filter { index in
            group.contains { $0.captures.indices.contains(index) && $0.captures[index] != first.captures[index] }
        }
    }
}

// MARK: - Process identity

/// The process name journald tags a line with, minus the PID:
/// `sshd[1234]` → `sshd`.
///
/// A daemon that forks per connection emits every line under a different
/// PID, so grouping repeated messages on the raw field produces a wall of
/// one-line "groups" for precisely the repetitive logs — failed SSH
/// logins, per-request workers — that collapsing exists to tame. Only a
/// wholly numeric bracket is stripped, so a name that legitimately
/// contains brackets is left alone.
public func journalProcessGroupKey(_ process: String) -> String {
    guard process.hasSuffix("]"),
          let open = process.lastIndex(of: "["),
          open > process.startIndex
    else { return process }

    let pid = process[process.index(after: open)..<process.index(before: process.endIndex)]
    guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { return process }
    return String(process[process.startIndex..<open])
}
