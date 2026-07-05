import Foundation

/// One importable host from an OpenSSH client configuration: a concrete
/// (wildcard-free) `Host` alias with its effective settings resolved.
public struct SSHConfigHostEntry: Equatable, Sendable {
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: UInt16?
    public let identityFile: String?

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: UInt16? = nil,
        identityFile: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// Parser for OpenSSH `ssh_config` files, scoped to what a connection
/// import needs: `Host` stanzas, `HostName`, `User`, `Port`,
/// `IdentityFile`, and `Include`.
///
/// Semantics follow `ssh_config(5)` (validated against `ssh -G`):
/// - For each option, the first obtained value wins, scanning stanzas in
///   file order — `Host *` defaults at the top override later stanzas,
///   exactly as they do for ssh itself.
/// - A stanza applies when the alias matches at least one of its positive
///   patterns and none of its negated (`!`) patterns. Pattern matching is
///   case-SENSITIVE, like OpenSSH's.
/// - Only concrete aliases (no `*` or `?`) become entries; pattern stanzas
///   contribute settings but are not importable hosts themselves.
/// - `Match` blocks are skipped — their conditions cannot be evaluated
///   outside a live ssh invocation.
/// - `Include` inside a `Host` block scopes the included content to hosts
///   matching that block (ssh reads such includes only while the block
///   matches), and the outer block's context resumes after the include —
///   both behaviors verified against `ssh -G`.
public enum SSHConfigParser {
    /// Maximum `Include` nesting depth; matches OpenSSH's own guard
    /// against include loops.
    private static let maxIncludeDepth = 16

    /// A run of options under one `Host` pattern set. `enclosing` carries
    /// the pattern sets of any `Host` blocks that were active at the
    /// `Include` sites this stanza arrived through; every level must also
    /// match for the stanza to apply.
    private struct Stanza {
        var patterns: [String]
        var enclosing: [[String]]
        var options: [(key: String, value: String)]
    }

    /// Parses config text into importable host entries.
    ///
    /// - Parameter includeResolver: maps an `Include` pattern (verbatim from
    ///   the file) to the contents of each matched file, in glob order.
    ///   File-system resolution, tilde expansion, and read limits are the
    ///   resolver's job; the default resolves nothing. Cycles terminate via
    ///   the parser's depth cap — resolvers should additionally bound total
    ///   reads if they accept untrusted input.
    public static func parse(
        _ text: String,
        includeResolver: (String) -> [String] = { _ in [] }
    ) -> [SSHConfigHostEntry] {
        var stanzas: [Stanza] = []
        parseFile(
            text,
            startPatterns: ["*"],
            enclosing: [],
            includeResolver: includeResolver,
            depth: 0,
            into: &stanzas
        )

        // Concrete aliases in first-seen order. An alias introduced inside
        // an include that is scoped to a non-matching Host block is not
        // reachable for ssh, so it is not importable either.
        var aliases: [String] = []
        var seen = Set<String>()
        for stanza in stanzas {
            for pattern in stanza.patterns
            where !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?") {
                guard !pattern.isEmpty, !seen.contains(pattern) else { continue }
                guard stanza.enclosing.allSatisfy({ stanzaApplies($0, to: pattern) }) else { continue }
                seen.insert(pattern)
                aliases.append(pattern)
            }
        }

        // Effective options per alias, first-obtained-wins.
        return aliases.map { alias in
            var resolved: [String: String] = [:]
            for stanza in stanzas
            where stanzaApplies(stanza.patterns, to: alias)
                && stanza.enclosing.allSatisfy({ stanzaApplies($0, to: alias) }) {
                for (key, value) in stanza.options where resolved[key] == nil {
                    resolved[key] = value
                }
            }
            return SSHConfigHostEntry(
                alias: alias,
                hostName: resolved["hostname"],
                user: resolved["user"],
                port: resolved["port"].flatMap(UInt16.init),
                identityFile: resolved["identityfile"]
            )
        }
    }

    // MARK: - File walking

    /// Parses one file's lines into stanzas. `startPatterns` is the `Host`
    /// context active at the point of inclusion; after an `Include`
    /// directive, the surrounding context resumes (verified `ssh -G`
    /// behavior), which is why includes recurse here instead of splicing
    /// text.
    private static func parseFile(
        _ text: String,
        startPatterns: [String],
        enclosing: [[String]],
        includeResolver: (String) -> [String],
        depth: Int,
        into stanzas: inout [Stanza]
    ) {
        var currentPatterns = startPatterns
        var currentOptions: [(key: String, value: String)] = []
        var insideMatchBlock = false

        func flush() {
            if !currentPatterns.isEmpty {
                stanzas.append(Stanza(
                    patterns: currentPatterns,
                    enclosing: enclosing,
                    options: currentOptions
                ))
            }
            currentOptions = []
        }

        // `\r\n` is a single Character in Swift, so splitting on
        // `isNewline` handles LF, CRLF, and stray CR files alike.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, arguments) = tokenize(String(rawLine)) else { continue }
            switch keyword {
            case "host":
                flush()
                currentPatterns = arguments
                insideMatchBlock = false
            case "match":
                flush()
                currentPatterns = []
                insideMatchBlock = true
            case "include" where !insideMatchBlock && depth < maxIncludeDepth:
                flush()
                for pattern in arguments {
                    for included in includeResolver(pattern) {
                        parseFile(
                            included,
                            startPatterns: currentPatterns,
                            enclosing: enclosing + [currentPatterns],
                            includeResolver: includeResolver,
                            depth: depth + 1,
                            into: &stanzas
                        )
                    }
                }
            default:
                guard !insideMatchBlock, let value = arguments.first else { continue }
                currentOptions.append((keyword, value))
            }
        }
        flush()
    }

    // MARK: - Tokenizing

    /// Splits a config line into a lowercased keyword plus arguments.
    /// Returns nil for blank lines and comments. Handles all separator
    /// spellings ssh accepts (`Port 22`, `Port=22`, `Port = 22`,
    /// `Port =22`) and double-quoted arguments.
    private static func tokenize(_ line: String) -> (keyword: String, arguments: [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var tokens: [String] = []
        var current = ""
        var insideQuotes = false
        var pastKeyword = false

        for character in trimmed {
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }
            if !insideQuotes, character == " " || character == "\t" || (!pastKeyword && character == "=") {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    pastKeyword = true
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }

        guard let keyword = tokens.first else { return nil }
        var arguments = Array(tokens.dropFirst())
        // `Keyword = value` and `Keyword =value`: a first argument that is
        // or starts with "=" is the separator, not part of the value.
        if let first = arguments.first, first.hasPrefix("=") {
            let stripped = String(first.dropFirst())
            if stripped.isEmpty {
                arguments.removeFirst()
            } else {
                arguments[0] = stripped
            }
        }
        return (keyword.lowercased(), arguments)
    }

    // MARK: - Pattern matching

    private static func stanzaApplies(_ patterns: [String], to alias: String) -> Bool {
        var matchedPositive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: alias) { return false }
            } else if glob(pattern, matches: alias) {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    /// `ssh_config` pattern matching: `*` any run, `?` any single
    /// character. Case-sensitive, like OpenSSH's `match_pattern` (verified:
    /// `Host WEB*` does not apply to `web1` for ssh). Public so the
    /// importer can reuse it for `Include` file globs.
    public static func glob(_ pattern: String, matches candidate: String) -> Bool {
        let p = Array(pattern)
        let c = Array(candidate)

        // Iterative fnmatch with backtracking over the last `*`.
        var pi = 0, ci = 0
        var starPi = -1, starCi = -1
        while ci < c.count {
            if pi < p.count, p[pi] == "?" || p[pi] == c[ci] {
                pi += 1
                ci += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starCi = ci
                pi += 1
            } else if starPi >= 0 {
                starCi += 1
                pi = starPi + 1
                ci = starCi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
