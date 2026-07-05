import Foundation
import OSLog
import AgentSshMacOS

/// Imports connection profiles from an OpenSSH client configuration
/// (`~/.ssh/config` by default), so first-run doesn't mean retyping every
/// host by hand.
///
/// Only concrete `Host` aliases become profiles; wildcard stanzas and
/// `Host *` defaults contribute settings the way ssh itself resolves them
/// (see `SSHConfigParser`). Private keys are never read — an `IdentityFile`
/// is carried across as a key *path* reference, and hosts without one
/// default to SSH-agent authentication.
class ImportManager {
    static let shared = ImportManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "import")

    private init() {}

    /// `~/.ssh/config`, the overwhelmingly common location.
    static var defaultSSHConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    /// Ceiling on files read through `Include` resolution per import. The
    /// parser's depth cap terminates cycles; this bounds the total work a
    /// pathological config (e.g. exponential self-includes) can cause.
    private static let maxIncludeReads = 256

    /// Parses the given OpenSSH config and returns importable profiles.
    /// Relative `Include` patterns resolve against `~/.ssh` regardless of
    /// where the config itself lives — that is what ssh does for user
    /// configs, and it keeps configs imported from Downloads etc. finding
    /// their `conf.d` fragments. `~` expands; a trailing component may glob.
    func importFromSSHConfig(url: URL) throws -> ConnectionStoreData {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError.unreadableConfig(url.path)
        }

        var includeReads = 0
        let entries = SSHConfigParser.parse(text, includeResolver: { pattern in
            Self.resolveInclude(pattern, readBudget: &includeReads)
        })

        guard !entries.isEmpty else {
            throw ImportError.noHostsFound(url.path)
        }

        let profiles = entries.map { entry -> ConnectionProfile in
            let identityPath = entry.identityFile.map { NSString(string: $0).expandingTildeInPath }
            return ConnectionProfile(
                id: "ssh-config:\(entry.alias)",
                name: entry.alias,
                host: entry.hostName ?? entry.alias,
                port: entry.port ?? 22,
                username: entry.user ?? NSUserName(),
                authMethod: .publicKey,
                privateKeyPath: identityPath,
                sshKeyReference: identityPath == nil ? .agent(identityHint: nil) : nil,
                notes: "Imported from \(url.path)"
            )
        }
        return ConnectionStoreData(connections: profiles, folders: [])
    }

    // MARK: - Include resolution

    private static func resolveInclude(
        _ pattern: String,
        readBudget: inout Int
    ) -> [String] {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let patternURL = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh")
                .appendingPathComponent(expanded)

        let directory = patternURL.deletingLastPathComponent()
        let filePattern = patternURL.lastPathComponent

        let candidates: [URL]
        if filePattern.contains("*") || filePattern.contains("?") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            candidates = names.sorted()
                .filter { SSHConfigParser.glob(filePattern, matches: $0) }
                .map { directory.appendingPathComponent($0) }
        } else {
            candidates = [patternURL]
        }

        return candidates.compactMap { fileURL in
            guard readBudget < maxIncludeReads else { return nil }
            readBudget += 1
            return try? String(contentsOf: fileURL, encoding: .utf8)
        }
    }
}

enum ImportError: LocalizedError {
    case unreadableConfig(String)
    case noHostsFound(String)

    var errorDescription: String? {
        switch self {
        case .unreadableConfig(let path):
            return "Could not read the SSH config at \(path)."
        case .noHostsFound(let path):
            return "No importable Host entries were found in \(path). Wildcard-only patterns (like Host *) can't be imported directly."
        }
    }
}
