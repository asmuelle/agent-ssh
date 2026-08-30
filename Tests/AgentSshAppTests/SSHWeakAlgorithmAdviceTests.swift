@testable import AgentSshApp
import Testing

/// The sidebar's orange rows open this advice, so every weak algorithm
/// `SSHAlgorithmStrength` flags must map to wording that actually
/// describes *that* weakness — and to a config line that removes only
/// the offending entry.
struct SSHWeakAlgorithmAdviceTests {
    @Test func group1KexCallsOutTheSmallGroup() {
        let advice = SSHWeakAlgorithmAdvice.advice(
            for: "diffie-hellman-group1-sha1",
            category: .kex
        )

        #expect(advice.headline.contains("1024-bit"))
        #expect(advice.detail.contains("SHA-1"))
        #expect(!advice.compatibilityNote.isEmpty)
    }

    @Test func otherSha1KexFallsBackToTheTranscriptExplanation() {
        let advice = SSHWeakAlgorithmAdvice.advice(
            for: "diffie-hellman-group-exchange-sha1",
            category: .kex
        )

        #expect(advice.headline.contains("SHA-1"))
        #expect(!advice.headline.contains("1024-bit"))
    }

    @Test(arguments: [
        ("hmac-md5", "MD5"),
        ("hmac-ripemd160@openssh.com", "RIPEMD"),
        ("hmac-sha2-256-96", "96-bit"),
        ("hmac-sha1-etm@openssh.com", "SHA-1"),
    ])
    func macAdviceMatchesTheFamily(algorithm: String, expected: String) {
        let advice = SSHWeakAlgorithmAdvice.advice(for: algorithm, category: .mac)
        #expect(advice.headline.contains(expected))
    }

    @Test func snippetSubtractsOnlyTheOffendingAlgorithm() {
        let kex = SSHWeakAlgorithmAdvice.advice(
            for: "diffie-hellman-group1-sha1",
            category: .kex
        )
        #expect(kex.sshdSnippet.contains("KexAlgorithms -diffie-hellman-group1-sha1"))

        let mac = SSHWeakAlgorithmAdvice.advice(for: "hmac-sha1", category: .mac)
        #expect(mac.sshdSnippet.contains("MACs -hmac-sha1"))
    }

    /// The reload half is the part that breaks per-distro: `ssh.service`
    /// only exists on Debian/Ubuntu. Pin both unit names and the
    /// validate-first gate, since a wrong command here is lockout-shaped.
    @Test func applyCommandValidatesFirstAndReloadsOnAnyDistro() {
        for category in [SSHWeakAlgorithmAdvice.Category.kex, .mac] {
            let command = SSHWeakAlgorithmAdvice
                .advice(for: "hmac-sha1", category: category)
                .applyCommand

            // Nothing reloads unless the config parses.
            #expect(command.hasPrefix("sudo sshd -t &&"))
            // Debian/Ubuntu unit, then the RHEL/Fedora/Arch/SUSE fallback.
            #expect(command.contains("systemctl reload ssh "))
            #expect(command.contains("systemctl reload sshd"))
            #expect(command.contains("||"))
        }
    }

    @Test func identityIsUniquePerCategoryAndAlgorithm() {
        let kex = SSHWeakAlgorithmAdvice.advice(for: "hmac-sha1", category: .kex)
        let mac = SSHWeakAlgorithmAdvice.advice(for: "hmac-sha1", category: .mac)
        #expect(kex.id != mac.id)
    }
}
