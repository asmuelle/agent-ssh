import Foundation

/// Human-readable explanation for one weak algorithm the server offers,
/// plus the sshd_config change that removes it.
///
/// `SSHAlgorithmStrength` only answers "is this weak?" — the sidebar
/// needs the *why* and the *fix* when the user clicks an orange row, so
/// the wording lives here (pure data, unit-testable) rather than inline
/// in the view.
struct SSHWeakAlgorithmAdvice: Equatable, Identifiable {
    enum Category: String, Equatable {
        case kex
        case mac

        /// sshd_config keyword whose list the algorithm belongs to.
        var configKeyword: String {
            switch self {
            case .kex: return "KexAlgorithms"
            case .mac: return "MACs"
            }
        }

        var label: String {
            switch self {
            case .kex: return "Key exchange"
            case .mac: return "Message authentication (MAC)"
            }
        }
    }

    let algorithm: String
    let category: Category
    /// One line: what is wrong with it.
    let headline: String
    /// A paragraph on the concrete risk.
    let detail: String
    /// What removing it costs — mostly "which ancient clients break".
    let compatibilityNote: String

    var id: String { "\(category.rawValue):\(algorithm)" }

    /// Drop-in config that removes just this algorithm from the offered
    /// list. The leading `-` is OpenSSH 7.5+ list-subtraction syntax, so
    /// the rest of the server's defaults stay untouched.
    var sshdSnippet: String {
        """
        # /etc/ssh/sshd_config.d/50-harden-\(category.rawValue).conf
        \(category.configKeyword) -\(algorithm)
        """
    }

    /// Validate-then-reload, so a typo can't lock the user out.
    ///
    /// The unit is `ssh` on Debian/Ubuntu but `sshd` on RHEL/Fedora/Rocky,
    /// Arch and openSUSE, and the user pastes this into a shell we never
    /// see — so try one and fall back to the other rather than guessing a
    /// name that fails on half the fleet. `sshd -t` still gates both:
    /// nothing reloads unless the config parses.
    var applyCommand: String {
        "sudo sshd -t && (sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd)"
    }

    static func advice(for algorithm: String, category: Category) -> SSHWeakAlgorithmAdvice {
        let name = algorithm.lowercased()

        let (headline, detail, compatibility): (String, String, String)

        switch category {
        case .kex where name.contains("group1-"):
            headline = "1024-bit DH group with SHA-1"
            detail = """
                This exchange pins a fixed 1024-bit Diffie-Hellman group \
                (Oakley Group 2) and hashes it with SHA-1. Precomputation \
                against a well-known 1024-bit group is within reach of a \
                state-level adversary, and SHA-1 has practical collisions. \
                A recorded session could later be decrypted, or a \
                man-in-the-middle could forge the handshake transcript.
                """
            compatibility = """
                Only pre-2014 clients (OpenSSH < 6.7, old PuTTY, legacy \
                network gear) need this group. Everything modern \
                negotiates curve25519 instead.
                """

        case .kex:
            headline = "SHA-1 based key exchange"
            detail = """
                The handshake transcript for this exchange is hashed with \
                SHA-1, which is collision-broken. An attacker able to \
                forge a transcript collision can undermine the integrity \
                of the negotiation the rest of the session depends on.
                """
            compatibility = """
                SHA-2 variants of the same exchange \
                (…-sha256 / …-sha512) have been available since OpenSSH \
                6.7 and are what current clients pick anyway.
                """

        case .mac where name.contains("md5"):
            headline = "MD5-based message authentication"
            detail = """
                MD5 is comprehensively broken as a hash. As an HMAC key it \
                is not yet trivially forgeable, but it fails every current \
                compliance baseline (CIS, STIG, PCI) and leaves no margin \
                as attacks improve.
                """
            compatibility = """
                No client shipped in the last decade needs an MD5 MAC — \
                OpenSSH stopped offering these by default in 6.7.
                """

        case .mac where name.contains("ripemd"):
            headline = "RIPEMD-160 message authentication"
            detail = """
                RIPEMD-160 is an unmaintained legacy hash with a narrow \
                security margin and almost no review compared with the \
                SHA-2 family. It survives only for interoperability with \
                very old implementations.
                """
            compatibility = """
                Removing it affects only ancient third-party clients; \
                OpenSSH disabled it by default years ago.
                """

        case .mac where name.contains("-96"):
            headline = "Truncated 96-bit authentication tag"
            detail = """
                This variant truncates the MAC to 96 bits, so an attacker \
                forging a packet only has to win a 2^96 search instead of \
                the full tag length. The saving is a few bytes per packet; \
                the cost is integrity margin on every packet.
                """
            compatibility = """
                Safe to drop — the untruncated variant of the same \
                algorithm is offered alongside it and is what clients \
                choose by default.
                """

        case .mac:
            headline = "SHA-1 message authentication"
            detail = """
                HMAC-SHA-1 authenticates every packet with a hash that has \
                practical collisions. HMAC construction blunts the known \
                attacks, but SHA-1 MACs are flagged by CIS/STIG baselines \
                and are the weakest link left in an otherwise modern \
                cipher suite.
                """
            compatibility = """
                hmac-sha2-256/512 (preferably the -etm variants) are \
                universally supported and already offered by this server.
                """
        }

        return SSHWeakAlgorithmAdvice(
            algorithm: algorithm,
            category: category,
            headline: headline,
            detail: detail,
            compatibilityNote: compatibility
        )
    }
}
