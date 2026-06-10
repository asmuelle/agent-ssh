import AgentSshMacOS
import Foundation
import OSLog

/// Direct server→server copy: instead of relaying bytes through the
/// Mac, the source host pushes the file straight to the destination
/// over SFTP, authenticated by an ephemeral keypair that exists only
/// for the duration of the transfer.
///
/// Sequence (every remote step runs over the app's *existing* SSH
/// sessions):
///
/// 1. Source host: `ssh-keygen` an ed25519 keypair into a `mktemp -d`
///    directory. The private key never leaves the source host; the Mac
///    only ever sees the public half.
/// 2. Destination host: sweep any expired `agent-ssh-ephemeral-*`
///    lines (crash leftovers from earlier runs), then append the new
///    public key to `~/.ssh/authorized_keys` as
///    `restrict,command="internal-sftp" …` — no PTY, no forwarding,
///    no shell; SFTP file access only. The comment embeds a unique id
///    and an absolute expiry timestamp so the key is removable and
///    self-describing even if cleanup never runs.
/// 3. Source host: `ssh-keyscan` the destination into a temp
///    known_hosts and require a non-empty result — the transfer never
///    runs with host key checking disabled.
/// 4. Source host: `sftp -r -b -` batch `put` to the destination.
/// 5. Cleanup both sides (best-effort, runs on success *and* failure):
///    delete the key line by its unique comment on the destination,
///    `rm -rf` the temp dir on the source.
///
/// Trade-offs vs. the relay (`RemoteCopyCoordinator`): 1× transfer
/// instead of 2×, nothing buffered on the Mac — but the source must be
/// able to resolve and reach the destination's address, the source
/// needs shell access (SFTP-only tabs can't drive it), and for ~15
/// minutes a restricted key exists on the destination. The Files panel
/// only offers this path for large payloads where the relay tax bites.
@MainActor
enum DirectServerCopyCoordinator {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "direct-copy")

    /// How long an injected key stays valid before the lazy sweep
    /// removes it. Long enough for a big transfer's tail; short enough
    /// that a crash mid-copy doesn't leave a usable key around for long.
    static let keyLifetime: TimeInterval = 15 * 60

    static func copy(
        drag: RemoteFileDrag,
        sourceLabel: String,
        destProfile: ConnectionProfile,
        destConnectionId: String,
        destDir: String,
        store: DirectCopyStore
    ) {
        let copyId = store.begin(
            name: drag.name,
            sourceLabel: sourceLabel,
            destLabel: destProfile.name
        )

        Task {
            await run(
                drag: drag,
                destProfile: destProfile,
                destConnectionId: destConnectionId,
                destDir: destDir,
                store: store,
                copyId: copyId
            )
        }
    }

    private static func run(
        drag: RemoteFileDrag,
        destProfile: ConnectionProfile,
        destConnectionId: String,
        destDir: String,
        store: DirectCopyStore,
        copyId: UUID
    ) async {
        let sourceConnectionId = drag.connectionId
        let keyId = DirectCopyShell.makeKeyId()
        let comment = DirectCopyShell.keyComment(
            keyId: keyId,
            expiry: Date().addingTimeInterval(keyLifetime)
        )

        var tempDir: String?
        var keyInstalled = false

        /// Best-effort teardown for every exit path. The expiry sweep in
        /// the install step is the backstop for the cases this can't
        /// reach (app quit mid-copy, source connection lost).
        func cleanUp() async {
            if keyInstalled {
                let removal = DirectCopyShell.removeKeyCommand(keyId: keyId)
                _ = try? await BridgeManager.shared.executeCommand(
                    connectionId: destConnectionId, command: removal
                )
            }
            if let tempDir {
                _ = try? await BridgeManager.shared.executeCommand(
                    connectionId: sourceConnectionId,
                    command: "rm -rf \(DirectCopyShell.quote(tempDir))"
                )
            }
        }

        do {
            // 1. Ephemeral keypair on the source host.
            store.update(copyId, step: "Generating ephemeral key on source")
            let keygenOutput = try await BridgeManager.shared.executeCommand(
                connectionId: sourceConnectionId,
                command: DirectCopyShell.keygenCommand(comment: comment)
            )
            guard let material = DirectCopyShell.parseKeygenOutput(keygenOutput, comment: comment) else {
                throw DirectCopyError.step(
                    "key generation on source",
                    detail: DirectCopyShell.failureDetail(from: keygenOutput)
                )
            }
            tempDir = material.tempDir

            // 2. Sweep expired keys + install the new one on the destination.
            store.update(copyId, step: "Installing restricted key on destination")
            let installOutput = try await BridgeManager.shared.executeCommand(
                connectionId: destConnectionId,
                command: DirectCopyShell.installKeyCommand(publicKeyLine: material.publicKeyLine)
            )
            guard DirectCopyShell.succeeded(installOutput) else {
                throw DirectCopyError.step(
                    "key install on destination",
                    detail: DirectCopyShell.failureDetail(from: installOutput)
                )
            }
            keyInstalled = true

            // 3. Pin the destination's host key from the source's vantage.
            store.update(copyId, step: "Verifying destination host key")
            let scanOutput = try await BridgeManager.shared.executeCommand(
                connectionId: sourceConnectionId,
                command: DirectCopyShell.keyscanCommand(
                    tempDir: material.tempDir,
                    host: destProfile.host,
                    port: destProfile.port
                )
            )
            guard DirectCopyShell.succeeded(scanOutput) else {
                throw DirectCopyError.step(
                    "host key scan",
                    detail: "\(destProfile.host):\(destProfile.port) is not reachable from the source host. "
                        + "Direct copy needs the source to reach the destination directly — use the relay copy instead."
                )
            }

            // 4. The transfer itself.
            store.update(copyId, step: "Transferring \(drag.name) server → server")
            let transferOutput = try await BridgeManager.shared.executeCommand(
                connectionId: sourceConnectionId,
                command: DirectCopyShell.transferCommand(
                    tempDir: material.tempDir,
                    sourcePath: drag.remotePath,
                    destPath: RemoteCopyCoordinator.joinRemotePath(destDir, drag.name),
                    user: destProfile.username,
                    host: destProfile.host,
                    port: destProfile.port
                )
            )
            guard DirectCopyShell.succeeded(transferOutput) else {
                throw DirectCopyError.step(
                    "transfer",
                    detail: DirectCopyShell.failureDetail(from: transferOutput)
                )
            }

            await cleanUp()
            store.complete(copyId)
            logger.info("Direct copy of \(drag.name, privacy: .public) completed")
        } catch {
            await cleanUp()
            store.fail(copyId, message: error.localizedDescription)
            logger.error("Direct copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum DirectCopyError: LocalizedError {
    case step(String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .step(step, detail):
            return "Failed at \(step): \(detail)"
        }
    }
}

// MARK: - Shell command construction

/// Pure builders for every remote command the direct copy runs, plus
/// validation of everything that comes *back* from a server before it
/// gets embedded into a follow-up command. Server output is untrusted
/// input: a hostile or compromised source host must not be able to
/// inject shell into the commands we subsequently run on either side.
enum DirectCopyShell {
    static let okMarker = "__AGENT_SSH_OK__"
    static let failMarker = "__AGENT_SSH_FAIL__"
    static let keyMarkerPrefix = "agent-ssh-ephemeral-"

    // MARK: Identity

    static func makeKeyId() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func keyComment(keyId: String, expiry: Date) -> String {
        "\(keyMarkerPrefix)\(keyId)-expires-\(Int(expiry.timeIntervalSince1970))"
    }

    // MARK: Quoting / validation

    /// POSIX single-quote escaping: `'` → `'\''`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes a path for sftp's own batch-line lexer (distinct from the
    /// outer shell layer, which `quote` handles). sftp splits on
    /// whitespace and honors backslash escapes inside double quotes, so
    /// a literal `"` or `\` in a filename — e.g. served by a hostile
    /// SFTP listing — must be escaped or it corrupts the batch command.
    static func sftpQuote(_ path: String) -> String {
        "\"" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// A temp dir path echoed back by the source host is only accepted
    /// if it looks like an actual `mktemp -d` result: absolute, short,
    /// and made of benign path characters. Anything else is discarded
    /// rather than quoted-and-hoped.
    static func isSafeTempPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count < 256, !path.contains("..") else { return false }
        return path.range(of: "^[A-Za-z0-9/._-]+$", options: .regularExpression) != nil
    }

    /// The public key line echoed back by the source must be exactly
    /// one ed25519 key carrying exactly the comment we asked for.
    static func isValidEphemeralPublicKey(_ line: String, comment: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: comment)
        return line.range(
            of: "^ssh-ed25519 [A-Za-z0-9+/=]+ \(escaped)$",
            options: .regularExpression
        ) != nil
    }

    static func succeeded(_ output: String) -> Bool {
        !output.contains(failMarker) && output.contains(okMarker)
    }

    /// Last few lines of command output, markers stripped — enough
    /// context for the error alert without dumping a transcript.
    static func failureDetail(from output: String) -> String {
        let cleaned = output
            .replacingOccurrences(of: okMarker, with: "")
            .replacingOccurrences(of: failMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "no output from remote command" }
        return cleaned.split(separator: "\n").suffix(4).joined(separator: "\n")
    }

    // MARK: Step commands

    /// Generate the keypair on the source. Prints `TMPDIR:<path>`, the
    /// public key line, and the success marker — all parsed by
    /// `parseKeygenOutput`.
    static func keygenCommand(comment: String) -> String {
        """
        (
          tmpdir=$(mktemp -d) &&
          ssh-keygen -q -t ed25519 -N "" -C \(quote(comment)) -f "$tmpdir/key" &&
          printf 'TMPDIR:%s\\n' "$tmpdir" &&
          cat "$tmpdir/key.pub" &&
          printf '\(okMarker)'
        ) 2>&1 || printf '\(failMarker)'
        """
    }

    struct KeyMaterial {
        let tempDir: String
        let publicKeyLine: String
    }

    static func parseKeygenOutput(_ output: String, comment: String) -> KeyMaterial? {
        guard succeeded(output) else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        guard
            let tempDirLine = lines.first(where: { $0.hasPrefix("TMPDIR:") }),
            let keyLine = lines.first(where: { $0.hasPrefix("ssh-ed25519 ") })
        else { return nil }

        let tempDir = String(tempDirLine.dropFirst("TMPDIR:".count))
        let publicKey = keyLine.trimmingCharacters(in: .whitespaces)

        guard isSafeTempPath(tempDir),
              isValidEphemeralPublicKey(publicKey, comment: comment)
        else { return nil }
        return KeyMaterial(tempDir: tempDir, publicKeyLine: publicKey)
    }

    /// Build the `authorized_keys` line: `restrict` kills PTY, agent /
    /// port forwarding, and X11; `command="internal-sftp"` pins the key
    /// to in-process SFTP — even a leaked private key buys file access
    /// only, never a shell.
    static func restrictedAuthorizedKeysLine(publicKeyLine: String) -> String {
        "restrict,command=\"internal-sftp\" \(publicKeyLine)"
    }

    /// Sweep expired ephemeral keys, then append the new one. The awk
    /// pass keeps every non-ephemeral line untouched, keeps ephemeral
    /// lines whose expiry is in the future, and drops expired or
    /// unparsable ephemeral lines (fail-closed).
    static func installKeyCommand(publicKeyLine: String) -> String {
        let line = restrictedAuthorizedKeysLine(publicKeyLine: publicKeyLine)
        return """
        (
          umask 077
          f="$HOME/.ssh/authorized_keys"
          mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 1
          if [ -f "$f" ]; then
            now=$(date +%s)
            tmp=$(mktemp) || exit 1
            awk -v now="$now" '{
              if (index($0, "\(keyMarkerPrefix)") == 0) { print; next }
              n = split($0, parts, "-expires-")
              if (n < 2) { next }
              split(parts[2], tail, " ")
              if (tail[1] + 0 > now) { print }
            }' "$f" > "$tmp" && cat "$tmp" > "$f"
            rm -f "$tmp"
          fi
          printf '%s\\n' \(quote(line)) >> "$f" && chmod 600 "$f"
        ) 2>&1 && printf '\(okMarker)' || printf '\(failMarker)'
        """
    }

    /// Remove the injected key by its unique id. `grep -v` + `cat`
    /// (not `mv`) keeps the file's inode, ownership, and mode intact.
    static func removeKeyCommand(keyId: String) -> String {
        """
        (
          f="$HOME/.ssh/authorized_keys"
          [ -f "$f" ] || exit 0
          tmp=$(mktemp) || exit 1
          grep -v \(quote(keyMarkerPrefix + keyId)) "$f" > "$tmp"
          cat "$tmp" > "$f"
          rm -f "$tmp"
        ) 2>&1 && printf '\(okMarker)' || printf '\(failMarker)'
        """
    }

    /// Pin the destination's host key from the source host. `test -s`
    /// makes an unreachable destination fail loudly here, with a clear
    /// message, instead of inside the transfer step.
    static func keyscanCommand(tempDir: String, host: String, port: UInt16) -> String {
        """
        (
          ssh-keyscan -p \(port) -T 10 \(quote(host)) > \(quote(tempDir + "/kh")) 2>/dev/null &&
          test -s \(quote(tempDir + "/kh")) &&
          printf '\(okMarker)'
        ) || printf '\(failMarker)'
        """
    }

    /// The push itself: batch-mode sftp so it can never hang on a
    /// prompt, pinned known_hosts, the ephemeral identity only, and
    /// keepalives so a dead link aborts instead of blocking forever.
    /// `-r` recurses into directories (OpenSSH creates the destination
    /// directory, merging if it exists); plain files ignore it.
    static func transferCommand(
        tempDir: String,
        sourcePath: String,
        destPath: String,
        user: String,
        host: String,
        port: UInt16
    ) -> String {
        // Inside the sftp batch line, paths are quoted with double
        // quotes (sftp's own lexer); the printf that produces the line
        // is itself single-quote escaped for the outer shell.
        let batchLine = "put \(sftpQuote(sourcePath)) \(sftpQuote(destPath))"
        return """
        (
          printf '%s\\n' \(quote(batchLine)) | sftp -r -b - \
            -i \(quote(tempDir + "/key")) \
            -P \(port) \
            -o UserKnownHostsFile=\(quote(tempDir + "/kh")) \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=4 \
            \(quote("\(user)@\(host)"))
        ) 2>&1 && printf '\(okMarker)' || printf '\(failMarker)'
        """
    }
}

// MARK: - Status store

/// Observable list of in-flight and finished direct copies, rendered
/// by the Files panel. Direct copies don't go through
/// `TransferQueueStore` (no SFTP progress events exist for a transfer
/// the Mac never sees), so they get their own minimal status surface:
/// current step while running, success/failure when done.
@MainActor
final class DirectCopyStore: ObservableObject {
    struct DirectCopy: Identifiable {
        enum Status: Equatable {
            case running(step: String)
            case completed
            case failed(String)
        }

        let id: UUID
        let name: String
        let sourceLabel: String
        let destLabel: String
        var status: Status
        let startedAt: Date
    }

    @Published private(set) var copies: [DirectCopy] = []

    func begin(name: String, sourceLabel: String, destLabel: String) -> UUID {
        let copy = DirectCopy(
            id: UUID(),
            name: name,
            sourceLabel: sourceLabel,
            destLabel: destLabel,
            status: .running(step: "Starting"),
            startedAt: Date()
        )
        copies.append(copy)
        return copy.id
    }

    func update(_ id: UUID, step: String) {
        guard let idx = copies.firstIndex(where: { $0.id == id }) else { return }
        copies[idx].status = .running(step: step)
    }

    func complete(_ id: UUID) {
        guard let idx = copies.firstIndex(where: { $0.id == id }) else { return }
        copies[idx].status = .completed
    }

    func fail(_ id: UUID, message: String) {
        guard let idx = copies.firstIndex(where: { $0.id == id }) else { return }
        copies[idx].status = .failed(message)
    }

    func dismiss(_ id: UUID) {
        copies.removeAll { $0.id == id }
    }
}
