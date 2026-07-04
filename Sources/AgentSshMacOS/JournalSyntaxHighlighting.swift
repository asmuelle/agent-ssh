import Foundation
import SwiftUI

/// Severity extracted from a structured (JSON) log entry's `level` field.
public enum JournalJSONLevel: Equatable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func parse(_ raw: String) -> JournalJSONLevel? {
        switch raw.uppercased() {
        case "TRACE": return .trace
        case "DEBUG", "DBG": return .debug
        case "INFO", "INFORMATIONAL": return .info
        case "NOTICE": return .notice
        case "WARN", "WARNING": return .warning
        case "ERROR", "ERR": return .error
        case "FATAL", "CRITICAL", "CRIT", "PANIC", "EMERG", "ALERT": return .critical
        default: return nil
        }
    }

    /// Bunyan-style numeric levels (10 trace … 60 fatal).
    public static func parse(numeric: Int) -> JournalJSONLevel? {
        switch numeric {
        case 10: return .trace
        case 20: return .debug
        case 30: return .info
        case 40: return .warning
        case 50: return .error
        case 60: return .critical
        default: return nil
        }
    }
}

/// The structured-severity assessment of a journal message.
///
/// When the message carries a valid JSON payload with an explicit top-level
/// `level`, `level` is set and `residualText` is the message text *outside*
/// the payload — the part keyword heuristics should still scan (a wrapper
/// like `Failed to deliver webhook: {"level":"info",…}` is an error even
/// though the embedded payload says info). Without an explicit level the
/// whole message remains in `residualText`.
public struct JournalEntryAssessment: Equatable {
    public let level: JournalJSONLevel?
    public let residualText: String
}

/// Syntax highlighting for journal / log entries.
///
/// Structured entries (JSON payloads, e.g. `tracing_subscriber` output) get a
/// full token pass: keys, string values, numbers, `true`/`false`/`null`, and
/// punctuation are colored separately, and the human-relevant `message` /
/// `msg` value is emphasized. Plain-text entries get a lighter pass covering
/// logfmt `key=` names, quoted strings, IPv4 addresses, and numbers.
///
/// All colors are adaptive system colors so both light and dark appearances
/// stay readable on `textBackgroundColor` surfaces. Results are memoized —
/// journal views re-render rows on every search keystroke, and highlighting
/// is deterministic per message.
public enum JournalSyntaxHighlighting {
    // MARK: - Palette

    enum TokenColor {
        static let key = Color.purple
        static let string = Color.teal
        static let number = Color.orange
        static let keyword = Color.pink
        static let punctuation = Color.secondary
    }

    /// Keys whose string value carries the human-readable log text; their
    /// values keep the surrounding foreground color and are emphasized so
    /// they stand out from the structured noise around them.
    private static let messageKeys: Set<String> = ["message", "msg"]

    /// Candidate openers tried per message before giving up on payload
    /// detection. Bounds JSONSerialization attempts on pathological lines
    /// full of braces.
    private static let maxPayloadCandidates = 8

    // MARK: - Caches

    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let highlightCache: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 4096
        return cache
    }()

    private static let assessmentCache: NSCache<NSString, Box<JournalEntryAssessment>> = {
        let cache = NSCache<NSString, Box<JournalEntryAssessment>>()
        cache.countLimit = 8192
        return cache
    }()

    // MARK: - JSON payload detection

    /// Range of a JSON object/array payload inside `message`, if some tail of
    /// the message parses as valid JSON. Journal lines are frequently
    /// `prefix: {json}`; the prefix is left untouched.
    ///
    /// Detection anchors on the trailing `}`/`]` and tries successive
    /// occurrences of the matching opener, so prefixes containing brackets or
    /// braces (`myapp[7]:`, `handler {main}:`) don't mask the real payload.
    public static func jsonPayloadRange(in message: String) -> Range<String.Index>? {
        var end = message.endIndex
        while end > message.startIndex, message[message.index(before: end)].isWhitespace {
            end = message.index(before: end)
        }
        guard end > message.startIndex else { return nil }
        let opener: Character
        switch message[message.index(before: end)] {
        case "}": opener = "{"
        case "]": opener = "["
        default: return nil
        }
        var searchStart = message.startIndex
        for _ in 0..<maxPayloadCandidates {
            guard let start = message[searchStart..<end].firstIndex(of: opener) else { return nil }
            let candidate = message[start..<end]
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return start..<end
            }
            searchStart = message.index(after: start)
        }
        return nil
    }

    /// Structured-severity assessment of a journal message. The explicit
    /// `level` is read from the *top level* of the parsed payload (nested or
    /// quoted `level` keys don't leak through). Memoized.
    public static func assess(message: String) -> JournalEntryAssessment {
        let cacheKey = message as NSString
        if let cached = assessmentCache.object(forKey: cacheKey) {
            return cached.value
        }
        let assessment = computeAssessment(message: message)
        assessmentCache.setObject(Box(assessment), forKey: cacheKey)
        return assessment
    }

    /// Convenience: just the explicit level, if any.
    public static func jsonSeverity(in message: String) -> JournalJSONLevel? {
        assess(message: message).level
    }

    private static func computeAssessment(message: String) -> JournalEntryAssessment {
        guard let range = jsonPayloadRange(in: message),
              let data = message[range].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let level = topLevelLevel(in: dictionary)
        else {
            return JournalEntryAssessment(level: nil, residualText: message)
        }
        let residual = String(message[..<range.lowerBound]) + String(message[range.upperBound...])
        return JournalEntryAssessment(level: level, residualText: residual)
    }

    private static func topLevelLevel(in dictionary: [String: Any]) -> JournalJSONLevel? {
        for key in ["level", "severity", "lvl"] {
            let value = dictionary[key] ?? dictionary.first { $0.key.lowercased() == key }?.value
            if let text = value as? String, let level = JournalJSONLevel.parse(text) {
                return level
            }
            if let number = value as? Int, let level = JournalJSONLevel.parse(numeric: number) {
                return level
            }
        }
        return nil
    }

    /// Pretty-printed rendition of the JSON payload in `message`, for
    /// copy-to-clipboard affordances. Returns nil when the message carries no
    /// valid JSON payload. Key order follows `JSONSerialization`'s sorted
    /// output, not the original wire order.
    public static func prettyPrintedJSON(in message: String) -> String? {
        guard let range = jsonPayloadRange(in: message),
              let data = message[range].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    // MARK: - Highlighting

    /// Syntax-highlighted rendition of a journal message. Uncolored runs
    /// inherit the enclosing `Text`'s foreground style, so severity tinting
    /// of plain segments keeps working. Memoized.
    public static func highlighted(message: String) -> AttributedString {
        let cacheKey = message as NSString
        if let cached = highlightCache.object(forKey: cacheKey) {
            return cached.value
        }
        let highlighted = computeHighlighted(message: message)
        highlightCache.setObject(Box(highlighted), forKey: cacheKey)
        return highlighted
    }

    private static func computeHighlighted(message: String) -> AttributedString {
        if let jsonRange = jsonPayloadRange(in: message) {
            var result = AttributedString()
            if jsonRange.lowerBound > message.startIndex {
                result += segment(String(message[..<jsonRange.lowerBound]))
            }
            result += highlightedJSON(message[jsonRange])
            if jsonRange.upperBound < message.endIndex {
                result += segment(String(message[jsonRange.upperBound...]))
            }
            return result
        }
        return highlightedPlainText(message)
    }

    // MARK: - JSON tokenizer

    private static func highlightedJSON(_ json: Substring) -> AttributedString {
        var result = AttributedString()
        var plain = ""
        var pendingKey: String?
        var index = json.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result += segment(plain, color: TokenColor.punctuation)
            plain = ""
        }

        while index < json.endIndex {
            let character = json[index]
            switch character {
            case "\"":
                flushPlain()
                let (token, contents, next) = scanString(json, from: index)
                if isKey(json, valueEnd: next) {
                    result += segment(token, color: TokenColor.key)
                    pendingKey = contents
                } else if let key = pendingKey, messageKeys.contains(key) {
                    result += segment(token, emphasized: true)
                    pendingKey = nil
                } else {
                    result += segment(token, color: TokenColor.string)
                    pendingKey = nil
                }
                index = next
            case "-", "0"..."9":
                flushPlain()
                let (token, next) = scanNumber(json, from: index)
                result += segment(token, color: TokenColor.number)
                pendingKey = nil
                index = next
            case "t", "f", "n":
                flushPlain()
                if let (token, next) = scanKeyword(json, from: index) {
                    result += segment(token, color: TokenColor.keyword)
                    index = next
                } else {
                    plain.append(character)
                    index = json.index(after: index)
                }
                pendingKey = nil
            case "{", "[":
                pendingKey = nil
                plain.append(character)
                index = json.index(after: index)
            default:
                plain.append(character)
                index = json.index(after: index)
            }
        }
        flushPlain()
        return result
    }

    /// Scans a JSON string literal starting at the opening quote. Returns the
    /// literal including quotes, its inner text (raw, escapes preserved), and
    /// the index just past the closing quote.
    private static func scanString(
        _ json: Substring, from start: String.Index
    ) -> (token: String, contents: String, next: String.Index) {
        var index = json.index(after: start)
        while index < json.endIndex {
            let character = json[index]
            if character == "\\" {
                index = json.index(after: index)
                if index < json.endIndex { index = json.index(after: index) }
                continue
            }
            if character == "\"" {
                let next = json.index(after: index)
                let contents = String(json[json.index(after: start)..<index])
                return (String(json[start..<next]), contents, next)
            }
            index = json.index(after: index)
        }
        return (String(json[start...]), String(json[json.index(after: start)...]), json.endIndex)
    }

    /// A string literal is a key when the next non-whitespace character after
    /// its closing quote is a colon.
    private static func isKey(_ json: Substring, valueEnd: String.Index) -> Bool {
        var index = valueEnd
        while index < json.endIndex, json[index].isWhitespace {
            index = json.index(after: index)
        }
        return index < json.endIndex && json[index] == ":"
    }

    private static func scanNumber(
        _ json: Substring, from start: String.Index
    ) -> (token: String, next: String.Index) {
        var index = json.index(after: start)
        while index < json.endIndex, "0123456789+-.eE".contains(json[index]) {
            index = json.index(after: index)
        }
        return (String(json[start..<index]), index)
    }

    private static func scanKeyword(
        _ json: Substring, from start: String.Index
    ) -> (token: String, next: String.Index)? {
        for keyword in ["true", "false", "null"] where json[start...].hasPrefix(keyword) {
            let next = json.index(start, offsetBy: keyword.count)
            return (keyword, next)
        }
        return nil
    }

    // MARK: - Plain-text pass

    /// Matches, in priority order: quoted strings, logfmt `key=` names,
    /// IPv4 addresses (with optional port), and bare numbers with common
    /// unit suffixes. Later patterns never override earlier matches.
    /// The trailing `(?!\w)` (instead of `\b`) keeps unit suffixes like `%`
    /// inside the match — `\b` cannot sit between `%` and a space.
    private static let plainTextPatterns: [(regex: NSRegularExpression?, color: Color, group: Int)] = [
        (try? NSRegularExpression(pattern: #""[^"\n]*""#), TokenColor.string, 0),
        (try? NSRegularExpression(pattern: #"(?<=^|[\s(\[])([A-Za-z_][\w.\-]*)="#), TokenColor.key, 1),
        (try? NSRegularExpression(
            pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?::\d{1,5})?\b"#
        ), TokenColor.number, 0),
        (try? NSRegularExpression(
            pattern: #"\b\d+(?:\.\d+)?(?:ms|s|m|h|%|[KMGT]i?B)?(?!\w)"#
        ), TokenColor.number, 0),
    ]

    private static func highlightedPlainText(_ message: String) -> AttributedString {
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        var colored: [(range: Range<String.Index>, color: Color)] = []
        for (regex, color, group) in plainTextPatterns {
            guard let regex else { continue }
            regex.enumerateMatches(in: message, range: fullRange) { match, _, _ in
                guard let match, let range = Range(match.range(at: group), in: message) else { return }
                let overlaps = colored.contains { $0.range.overlaps(range) }
                if !overlaps { colored.append((range, color)) }
            }
        }
        guard !colored.isEmpty else { return AttributedString(message) }

        colored.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result = AttributedString()
        var cursor = message.startIndex
        for (range, color) in colored {
            if cursor < range.lowerBound {
                result += segment(String(message[cursor..<range.lowerBound]))
            }
            result += segment(String(message[range]), color: color)
            cursor = range.upperBound
        }
        if cursor < message.endIndex {
            result += segment(String(message[cursor...]))
        }
        return result
    }

    // MARK: - Segments

    private static func segment(
        _ text: String, color: Color? = nil, emphasized: Bool = false
    ) -> AttributedString {
        var piece = AttributedString(text)
        if let color {
            piece.foregroundColor = color
        }
        if emphasized {
            piece.inlinePresentationIntent = .stronglyEmphasized
        }
        return piece
    }
}
