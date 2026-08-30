import Foundation

/// What a slot value will be interpreted *as* once the command reaches
/// the host — and therefore which grammar decides whether it is safe.
///
/// There is deliberately no single "safe string" validator. A value bound
/// for a shell operand, a systemd unit argument, an apt operand and an
/// sshd_config body are four different languages, and a rule that fits
/// one is wrong for the others: shell quoting does nothing for a config
/// body, and a path charset would reject `hmac-sha1`.
///
/// Two properties hold for every kind, because they are the attacks
/// quoting cannot stop:
///
/// - **No leading `-`.** A perfectly quoted `'-delete'` is still one
///   argv word that `find` reads as an action. Option injection survives
///   escaping, so it has to be refused at validation.
/// - **No control characters.** Every producer in the app is
///   line-oriented, so a newline in a value is never a real observation;
///   it is the injection vector for anything that lands in a file.
///
/// Validation returns the value unchanged or `nil`. It never normalizes:
/// the bytes checked must be the bytes rendered, or the check describes a
/// different string than the one that runs.
public enum CommandSlotKind: String, CaseIterable, Sendable {
    /// A generic operand passed to a command as one word.
    case shellWord
    /// An absolute filesystem path.
    case absolutePath
    /// A systemd unit name, as `systemctl` would accept it.
    case systemdUnit
    /// A package name for apt/dnf/pacman and friends.
    case packageName
    /// A bare token written into an sshd_config body — an algorithm name.
    case sshdConfigToken

    /// Longest value each kind may take, in unicode scalars.
    private var maximumLength: Int {
        switch self {
        case .shellWord: return 255
        case .absolutePath: return 4096
        case .systemdUnit: return 255
        case .packageName: return 128
        case .sshdConfigToken: return 64
        }
    }

    /// Systemd's own unit-name suffixes. Requiring one means a bare word
    /// can never be promoted into a unit argument by a catalog mistake.
    private static let unitSuffixes = [
        ".service", ".socket", ".target", ".timer", ".mount", ".automount",
        ".swap", ".path", ".slice", ".scope", ".device",
    ]

    /// The root mount is the one real unit whose name starts with `-`.
    /// Allowed by exact match rather than by relaxing the leading-dash
    /// rule for every unit.
    private static let rootMountUnit = "-.mount"

    public func validate(_ value: String) -> String? {
        guard !value.isEmpty, value.unicodeScalars.count <= maximumLength else { return nil }
        // Rejected for every kind: C0/C1 controls (newline included), the
        // replacement character (a lossy UTF-8 decode is not a name), and
        // unpaired-surrogate-shaped nonsense.
        guard value.unicodeScalars.allSatisfy({ !isForbiddenEverywhere($0) }) else { return nil }

        if self == .systemdUnit, value == Self.rootMountUnit { return value }
        guard !value.hasPrefix("-") else { return nil }

        switch self {
        case .shellWord:
            // Anything printable and non-blank; the shell sees it as one
            // word thanks to quoting, and the leading-dash rule above is
            // what actually keeps it an operand.
            guard value.unicodeScalars.allSatisfy({ !isBlank($0) }) else { return nil }

        case .absolutePath:
            guard value.hasPrefix("/") else { return nil }
            // `/` is the one path that is both absolute and
            // trailing-slashed, and it is the commonest target of all.
            // Exempted by exact match rather than by dropping the
            // canonical-form rule, as with `-.mount` above.
            guard value == "/" || !value.hasSuffix("/") else { return nil }
            // `..` anywhere means the rendered target is not the path the
            // catalog entry believes it is describing.
            let segments = value.split(separator: "/", omittingEmptySubsequences: true)
            guard !segments.contains("..") , !segments.contains(".") else { return nil }

        case .systemdUnit:
            guard Self.unitSuffixes.contains(where: { value.hasSuffix($0) }) else { return nil }
            guard !value.hasPrefix(".") else { return nil }
            // systemd's grammar. Excluding `*`, `?` and `[` is the point:
            // systemctl globs its own arguments, so `'*.service'` is one
            // well-quoted word that still stops every unit on the host.
            guard value.unicodeScalars.allSatisfy({ isUnitScalar($0) }) else { return nil }

        case .packageName:
            // dpkg/rpm shapes: `libssl3:amd64`, `containerd.io`, `g++-12`.
            // `/` and `=` are excluded because apt reads them as a local
            // .deb path and a version pin.
            //
            // The last character matters as much as the first: apt-get
            // reads a trailing `-` on an operand as *remove this* and a
            // trailing `+` as *install this*, whichever verb the template
            // wrote. `--` does not help — that is getopt's marker, while
            // this is apt's own operand grammar, applied afterwards. So
            // `apt-get install -- 'openssh-server-'` uninstalls the SSH
            // server.
            //
            // This does NOT make an apt operand fully safe: when no
            // package matches exactly, apt applies the operand as an
            // unanchored regex, and `.` has to stay legal mid-name for
            // `containerd.io`. A template that installs or removes
            // packages must additionally require the value to be one the
            // scan actually observed.
            guard let first = value.unicodeScalars.first, isASCIILowerAlnum(first) else { return nil }
            guard let last = value.unicodeScalars.last, isASCIIAlnum(last) else { return nil }
            guard value.unicodeScalars.allSatisfy({ isPackageScalar($0) }) else { return nil }

        case .sshdConfigToken:
            // RFC 4250 algorithm names: printable US-ASCII, no comma, no
            // whitespace. This value lands in a file body where quoting
            // means nothing, so the charset is the entire defence.
            guard let first = value.unicodeScalars.first, isASCIIAlnum(first) else { return nil }
            guard value.unicodeScalars.allSatisfy({ isConfigTokenScalar($0) }) else { return nil }
        }
        return value
    }

    // MARK: Scalar predicates
    //
    // Written as scalar checks rather than regexes on purpose: ICU treats
    // `$` as matching before a trailing newline, so `^[a-z.]+$` accepts
    // "nginx.service\n" — exactly the payload the validator exists to
    // refuse.

    private func isForbiddenEverywhere(_ s: Unicode.Scalar) -> Bool {
        if s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value) { return true }
        if s == "\u{FFFD}" { return true }
        // Bidi overrides and Unicode separators let a value render in the
        // confirmation dialog as something other than what will run — the
        // user consents to one command and a different one executes.
        switch s.value {
        case 0x200E, 0x200F,           // LRM, RLM
             0x202A...0x202E,          // LRE, RLE, PDF, LRO, RLO
             0x2066...0x2069,          // isolates
             0x2028, 0x2029,           // line / paragraph separator
             0x00A0, 0x1680, 0x2000...0x200D, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private func isBlank(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t"
    }

    private func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }

    private func isASCIILowerAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s)
    }

    private func isUnitScalar(_ s: Unicode.Scalar) -> Bool {
        isASCIIAlnum(s) || s == ":" || s == "-" || s == "_" || s == "." || s == "\\" || s == "@"
    }

    private func isPackageScalar(_ s: Unicode.Scalar) -> Bool {
        isASCIIAlnum(s) || s == "+" || s == "-" || s == "." || s == ":" || s == "_"
    }

    private func isConfigTokenScalar(_ s: Unicode.Scalar) -> Bool {
        isASCIIAlnum(s) || s == "-" || s == "_" || s == "." || s == "@" || s == "+"
    }
}
