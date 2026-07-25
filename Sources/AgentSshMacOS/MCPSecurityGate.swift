import Foundation
import LocalAuthentication

public class MCPSecurityGate {
    public static let shared = MCPSecurityGate()
    private init() {}

    public enum ActionRisk {
        case safe
        case modifying(reason: String)
    }

    public func classify(tool: String, arguments: [String: Any]) -> ActionRisk {
        switch tool {
        case "list_dir", "read_file":
            return .safe

        case "write_file":
            let path = arguments["path"] as? String ?? "file"
            return .modifying(reason: "Write file content to '\(path)'")

        case "run_command":
            guard let command = arguments["command"] as? String else {
                // An unparseable/absent command is not provably safe — require approval.
                return .modifying(reason: "Execute command with no readable command string")
            }
            switch ShellCommandClassifier.classify(command) {
            case .safe:
                return .safe
            case .modifying(let reason):
                // Show the actual command in the prompt, not just the risk
                // class, so the user authorizes what will really run.
                return .modifying(reason: "Run: \(preview(of: command)) — \(reason)")
            }

        case "postgres_query":
            guard let query = arguments["query"] as? String else {
                return .modifying(reason: "Execute query with no readable query string")
            }
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .modifying(reason: "Execute an empty database query")
            }
            // PostgreSQL SELECT expressions can invoke user-defined functions,
            // casts, and operators with side effects. Without a PostgreSQL parser
            // and catalog resolution, no arbitrary query is provably read-only.
            // The Rust execution layer additionally validates the query is a
            // single read-only statement and runs it in a read-only session.
            //
            // Surface the actual SQL in the reason so the biometric prompt shows
            // the user *what* they are authorizing — otherwise "approve a
            // database query?" is a blind rubber-stamp an injected agent can
            // abuse. See `preview(of:)`.
            return .modifying(reason: "Run SQL: \(preview(of: query))")

        default:
            return .modifying(reason: "Execute unknown tool '\(tool)'")
        }
    }


    /// A compact, single-line preview of a command or query for the biometric
    /// approval prompt. Collapses runs of whitespace/newlines and truncates, so
    /// the reason stays legible and can't be padded with leading whitespace to
    /// push the operative part out of view.
    func preview(of text: String, limit: Int = 160) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// Requests biometric authentication for the modifying action.
    /// Returns true if approved, false otherwise.
    public func requestApproval(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        // If no local authentication is available at all — no Touch ID / Face ID
        // and no passcode enrolled — we cannot obtain informed human approval.
        // Fail closed and deny the modifying action rather than let it run
        // unauthenticated.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        return await evaluatePolicy(context: context, reason: reason)
    }

    private func evaluatePolicy(context: LAContext, reason: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authorize AI action: \(reason)") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Classifies a raw shell command string as read-only-`safe` or `modifying`.
///
/// This is a security gate, not a full shell parser: it decides whether an
/// AI-driven `run_command` runs silently or requires biometric approval. It is
/// deliberately conservative — anything it cannot prove read-only is treated as
/// modifying. A first-token denylist (the previous approach) was trivially
/// bypassed by chaining (`echo hi; rm -rf ~`), absolute paths (`/bin/rm`),
/// interpreter wrappers (`sh -c '…'`), and substitution (`$(…)`); this evaluates
/// every sub-command, resolves basenames, and peels wrapper commands.
public enum ShellCommandClassifier {
    /// Commands whose process behavior is read-only for all supported argument
    /// shapes. Anything outside this allowlist requires local approval.
    static let readOnlyCommands: Set<String> = [
        "cat", "cut", "date", "df", "du", "echo", "free", "grep", "head",
        "docker", "git", "hostname", "id", "ls", "lsof", "podman", "printf", "ps", "pwd", "sort",
        "stat", "tail", "uname", "uniq", "uptime", "wc", "who", "whoami",
    ]
    /// Commands that create, destroy, move, or mutate state on the host.
    /// Kept close to the original gate's denylist (whole-command granularity,
    /// e.g. `systemctl`/`apt` always require approval) plus unambiguous
    /// destructive additions. Deliberately excludes pipeline staples with
    /// common read-only uses (`sed`, `awk`, `grep`, package-manager queries)
    /// so the gate doesn't train users to approve reflexively.
    static let denylist: Set<String> = [
        "rm", "rmdir", "mv", "cp", "ln", "dd", "shred", "truncate", "install",
        "kill", "killall", "pkill", "shutdown", "reboot", "halt", "poweroff",
        "systemctl", "service", "launchctl",
        "apt", "apt-get", "yum", "dnf", "pacman", "zypper",
        "chmod", "chown", "chgrp", "chattr", "setfacl",
        "mkfs", "fdisk", "parted", "mount", "umount",
        "tee", "iptables", "nft", "ufw", "crontab",
        "useradd", "userdel", "usermod", "groupadd", "passwd", "visudo",
    ]

    /// Wrapper commands that run *another* command — the risk lives in what
    /// they wrap, so we peel them and re-inspect the wrapped command. `do`,
    /// `then`, `else` cover loop/conditional bodies our tokenizer surfaces as
    /// their own segments (e.g. `for f in *; do rm $f; done`).
    static let wrappers: Set<String> = [
        "env", "command", "nice", "nohup", "time", "timeout", "stdbuf",
        "setsid", "ionice", "xargs", "then", "else", "do",
    ]

    /// Privileged escalators — always require approval, regardless of what they wrap.
    static let privileged: Set<String> = ["sudo", "doas", "su", "pkexec"]

    /// Interpreters that can run arbitrary inline code (`sh -c`, `python -c`,
    /// `perl -e`). Treated as modifying — we cannot statically know what the
    /// script does. Excludes `awk`/`sed`, which are overwhelmingly used as
    /// read-only pipeline filters.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "python", "python2", "python3", "perl", "ruby", "node", "nodejs",
        "php", "lua", "rscript", "osascript",
    ]

    /// Shell builtins that execute or source arbitrary code.
    static let codeBuiltins: Set<String> = ["eval", "exec", "source", "."]

    /// Redirect targets that don't actually persist data.
    static let nullSinks: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr"]

    public static func classify(_ command: String) -> MCPSecurityGate.ActionRisk {
        let scan = Tokenizer.scan(command)

        guard !scan.segments.isEmpty else {
            return .modifying(reason: "Execute an empty or unparseable command")
        }

        // Command substitution / process substitution can smuggle any command
        // past per-segment inspection — treat its presence as modifying.
        if scan.hasCommandSubstitution {
            return .modifying(reason: "Command uses command substitution ($(…) or backticks)")
        }
        // A redirection to a real file writes to disk.
        if scan.hasFileRedirection {
            return .modifying(reason: "Command contains file redirection to a file")
        }

        for segment in scan.segments {
            if let risk = classifySegment(segment) {
                return risk
            }
        }
        return .safe
    }

    /// Returns a `.modifying` risk if the segment's effective command is
    /// dangerous, or `nil` if the segment looks read-only.
    private static func classifySegment(_ words: [String]) -> MCPSecurityGate.ActionRisk? {
        guard let commandToken = words.first else { return nil }
        if isAssignment(commandToken) {
            return .modifying(reason: "Execute command with environment assignment")
        }
        // Resolve the command to classify. A bare name (`ls`) or an absolute
        // path (`/usr/bin/ls`, `/opt/homebrew/bin/ls`) is classified by its
        // basename against the allow/deny lists below: the directory doesn't
        // change whether a command *named* `ls` is read-only, and a remote host
        // that has trojaned its own `/usr/bin/ls` is already fully compromised —
        // beyond what a client-side gate can address. Requiring an absolute path
        // under a fixed set of system directories (the previous approach) forced
        // approval on essentially every AI-issued command — agents emit `ls`,
        // `git status`, `cat …`, not `/usr/bin/ls` — and broke Homebrew, Nix,
        // and `/usr/local/bin` layouts, defeating the "safe, no-prompt" tier and
        // training users to approve reflexively. A *relative* path with a slash
        // (`./x`, `../x`, `a/b`) targets a specific local file we can't identify
        // by name, so it stays modifying.
        if commandToken.contains("/") && !commandToken.hasPrefix("/") {
            return .modifying(reason: "Execute command from a relative path '\(commandToken)'")
        }

        let firstCmd = basename(commandToken)
        if privileged.contains(firstCmd) {
            return .modifying(reason: "Execute privileged command '\(firstCmd)'")
        }

        let rest = Array(words.dropFirst())

        // A wrapper (env, xargs, timeout, nice, loop bodies, …) runs *another*
        // command. Wrapper argument shapes vary too much to parse precisely
        // (`timeout 5 rm`, `nice -n 10 rm`, `xargs -I{} rm`), so scan every
        // following token's basename for a dangerous command. Errs toward
        // requiring approval, which is the safe direction for a security gate.
        if wrappers.contains(firstCmd) {
            for token in rest {
                if let risk = riskForBareCommand(basename(token)) {
                    return risk
                }
            }
            if restContainsFindMutation(rest) {
                return .modifying(reason: "Execute filesystem-mutating 'find'")
            }
            return .modifying(reason: "Execute wrapper command '\(firstCmd)' that is not provably read-only")
        }

        // Non-wrapper: the command is `firstCmd`; its arguments are data/paths,
        // not commands, so we classify the command itself (a path arg that
        // merely basename-matches a denylist entry must not trip the gate).
        if let risk = riskForBareCommand(firstCmd) {
            return risk
        }
        if firstCmd == "find", restContainsFindMutation(rest) {
            return .modifying(reason: "Execute filesystem-mutating 'find'")
        }
        if let subcommandRisk = subcommandRisk(command: firstCmd, rest: rest) {
            return subcommandRisk
        }
        if let argumentRisk = argumentRisk(command: firstCmd, rest: rest) {
            return argumentRisk
        }
        if firstCmd == "find" || readOnlyCommands.contains(firstCmd) {
            return nil
        }
        return .modifying(reason: "Execute command '\(firstCmd)' that is not on the read-only allowlist")
    }

    /// Risk for a command identified purely by its (basename'd) name.
    private static func riskForBareCommand(_ name: String) -> MCPSecurityGate.ActionRisk? {
        if codeBuiltins.contains(name) {
            return .modifying(reason: "Execute inline/sourced code via '\(name)'")
        }
        if interpreters.contains(name) {
            return .modifying(reason: "Run interpreter '\(name)' (arbitrary code)")
        }
        if denylist.contains(name) || name.hasPrefix("mkfs.") {
            return .modifying(reason: "Execute high-risk command '\(name)'")
        }
        return nil
    }

    /// git/docker subcommand risk for a wrapped command whose first non-flag
    /// token is the command name (used on the wrapper's remaining tokens).
    private static func subcommandRisk(after tokens: [String]) -> MCPSecurityGate.ActionRisk? {
        guard let cmdIdx = tokens.firstIndex(where: { !$0.hasPrefix("-") && !isAssignment($0) }) else {
            return nil
        }
        return subcommandRisk(command: basename(tokens[cmdIdx]), rest: Array(tokens[(cmdIdx + 1)...]))
    }

    /// git/docker subcommand risk for an explicit command name + its args.
    private static func subcommandRisk(command: String, rest: [String]) -> MCPSecurityGate.ActionRisk? {
        if command == "git" {
            guard let sub = firstNonFlag(rest),
                  ["diff", "log", "show", "status"].contains(sub)
            else {
                return .modifying(reason: "Execute git operation that is not provably read-only")
            }
            if rest.contains(where: { $0 == "--output" || $0.hasPrefix("--output=") }) {
                return .modifying(reason: "Execute git operation that writes an output file")
            }
            if rest.contains(where: { $0 == "--ext-diff" || $0 == "--textconv" }) {
                return .modifying(reason: "Execute git operation that may invoke an external helper")
            }
            return nil
        }
        if command == "docker" || command == "podman" {
            guard let sub = firstNonFlag(rest),
                  ["diff", "events", "images", "info", "inspect", "logs", "ps", "stats", "top", "version"].contains(sub)
            else {
                return .modifying(reason: "Execute \(command) operation that is not provably read-only")
            }
            return nil
        }
        return nil
    }

    private static func argumentRisk(command: String, rest: [String]) -> MCPSecurityGate.ActionRisk? {
        switch command {
        case "date":
            let safeFlags: Set<String> = ["-u", "--utc", "--universal", "--version", "--help", "-r", "-j"]
            for argument in rest {
                if argument.hasPrefix("+") || safeFlags.contains(argument) { continue }
                return .modifying(reason: "Execute date operation that may change the system clock")
            }
        case "hostname":
            let readOnlyFlags: Set<String> = [
                "-f", "--fqdn", "-s", "--short", "-d", "--domain",
                "-i", "--ip-address", "-I", "--all-ip-addresses",
            ]
            guard rest.allSatisfy({ readOnlyFlags.contains($0) }) else {
                return .modifying(reason: "Execute hostname operation that may change the system hostname")
            }
        case "sort":
            if rest.contains(where: { $0 == "-o" || $0 == "--output" || $0.hasPrefix("--output=") }) {
                return .modifying(reason: "Execute sort operation that writes an output file")
            }
        default:
            break
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "=") else { return false }
        let name = word[word.startIndex..<eq]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func firstNonFlag(_ words: [String]) -> String? {
        words.first(where: { !$0.hasPrefix("-") }).map(basename)
    }

    private static func restContainsFindMutation(_ words: [String]) -> Bool {
        let mutating: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprintf", "-fprint", "-fprint0"]
        return words.contains(where: { mutating.contains($0) })
    }

    /// Last path component, lowercased. `/bin/RM` → `rm`, `./rm` → `rm`.
    static func basename(_ token: String) -> String {
        let name = token.split(separator: "/").last.map(String.init) ?? token
        return name.lowercased()
    }

    /// Quote-aware single pass: splits a command line into control-operator
    /// segments (each a list of words) and flags unquoted substitution and
    /// file redirection.
    enum Tokenizer {
        struct Scan {
            var segments: [[String]]
            var hasCommandSubstitution: Bool
            var hasFileRedirection: Bool
        }

        static func scan(_ command: String) -> Scan {
            var segments: [[String]] = []
            var currentWords: [String] = []
            var currentWord = ""
            var hasSubstitution = false
            var hasRedirection = false

            // When we see an unquoted redirection operator, the next word is its
            // target; check it against the null-sink allowlist before flagging.
            var pendingRedirectTarget = false

            var inSingle = false
            var inDouble = false

            let chars = Array(command)
            var i = 0

            func endWord() {
                if !currentWord.isEmpty {
                    if pendingRedirectTarget {
                        if !nullSinks.contains(currentWord) { hasRedirection = true }
                        pendingRedirectTarget = false
                    }
                    currentWords.append(currentWord)
                    currentWord = ""
                }
            }
            func endSegment() {
                endWord()
                segments.append(currentWords)
                currentWords = []
            }

            while i < chars.count {
                let c = chars[i]

                if inSingle {
                    if c == "'" { inSingle = false } else { currentWord.append(c) }
                    i += 1
                    continue
                }
                if inDouble {
                    // Inside double quotes, $( and backtick still execute.
                    if c == "\\", i + 1 < chars.count {
                        currentWord.append(chars[i + 1]); i += 2; continue
                    }
                    if c == "\"" { inDouble = false; i += 1; continue }
                    if c == "`" { hasSubstitution = true }
                    if c == "$", i + 1 < chars.count, chars[i + 1] == "(" { hasSubstitution = true }
                    currentWord.append(c)
                    i += 1
                    continue
                }

                switch c {
                case "'":
                    inSingle = true
                case "\"":
                    inDouble = true
                case "\\":
                    if i + 1 < chars.count { currentWord.append(chars[i + 1]); i += 1 }
                case "`":
                    hasSubstitution = true
                case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                    hasSubstitution = true
                    currentWord.append(c)
                case "<" where i + 1 < chars.count && chars[i + 1] == "(":
                    // Process substitution <(…) / >(…) — treat as substitution.
                    hasSubstitution = true
                case ">":
                    // Redirection: `>`, `>>`, and the `N>` form (any leading fd
                    // digit is already sitting as its own word). Distinguish a
                    // real file target from fd duplication (`2>&1`, `>&-`),
                    // which merges/closes descriptors and writes nothing.
                    endWord()
                    while i + 1 < chars.count, chars[i + 1] == ">" { i += 1 }
                    var j = i + 1
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    if j < chars.count, chars[j] == "&" {
                        // `>&1` / `2>&1` / `>&-` — fd duplication, not a file.
                        i = j
                        while i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" { i += 1 }
                    } else {
                        pendingRedirectTarget = true
                    }
                case ";", "\n":
                    endSegment()
                case "&":
                    // `&&` and background `&` both break the command.
                    endSegment()
                    if i + 1 < chars.count, chars[i + 1] == "&" { i += 1 }
                case "|":
                    endSegment()
                    if i + 1 < chars.count, chars[i + 1] == "|" { i += 1 }
                case " ", "\t":
                    endWord()
                default:
                    currentWord.append(c)
                }
                i += 1
            }
            endSegment()

            return Scan(
                segments: segments.filter { !$0.isEmpty },
                hasCommandSubstitution: hasSubstitution,
                hasFileRedirection: hasRedirection
            )
        }
    }
}
