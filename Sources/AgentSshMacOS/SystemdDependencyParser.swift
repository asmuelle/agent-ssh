import Foundation

/// One unit in a `systemctl list-dependencies` tree, with its indentation
/// depth (root = 0, direct dependency = 1, …).
public struct SystemdDependencyNode: Equatable, Sendable {
    public var name: String
    public var depth: Int

    public init(name: String, depth: Int) {
        self.name = name
        self.depth = depth
    }
}

/// Parsed output of one `systemctl list-dependencies` invocation. The same
/// shape serves both directions: a forward listing answers "what does this
/// unit need", a `--reverse` listing answers "what needs this unit" — the
/// dependents an inexperienced admin must see before stopping something.
public struct SystemdDependencyListing: Equatable, Sendable {
    public var rootUnit: String?
    public var nodes: [SystemdDependencyNode]

    public init(rootUnit: String? = nil, nodes: [SystemdDependencyNode] = []) {
        self.rootUnit = rootUnit
        self.nodes = nodes
    }

    /// The units directly attached to the root (depth 1).
    public var directDependencies: [String] {
        nodes.filter { $0.depth == 1 }.map(\.name)
    }

    /// Every unit in the listing (root included), deduplicated,
    /// first-appearance order preserved.
    public var allUnits: [String] {
        var seen = Set<String>()
        var units: [String] = []
        for name in [rootUnit].compactMap({ $0 }) + nodes.map(\.name)
            where seen.insert(name).inserted
        {
            units.append(name)
        }
        return units
    }

    /// `allUnits` narrowed to `.service` units — the subset a beginner
    /// recognizes, without the target/slice/socket zoo.
    public var services: [String] {
        allUnits.filter { $0.hasSuffix(".service") }
    }
}

/// Parses `systemctl list-dependencies [--reverse] [--plain]` output into
/// typed dependency data — the app's first structured "what depends on
/// what" model. Tolerates both `--plain` indentation and the UTF-8 tree
/// glyphs / state bullets of default output, and skips anything that does
/// not look like a unit name — error lines, prompts, and the `|-` / `` `- ``
/// ASCII-fallback trees of non-UTF-8 locales — rather than mis-parsing it.
/// (The in-app collector always passes `--plain`, which is locale-proof.)
///
/// Certainty (Requires vs. Wants — "will stop" vs. "may be affected")
/// is not derivable from this listing; it needs `systemctl show` data and
/// arrives with the blast-radius work.
public enum SystemdDependencyParser {
    public static func parse(_ output: String) -> SystemdDependencyListing {
        var listing = SystemdDependencyListing()

        for line in output.components(separatedBy: .newlines) {
            guard let (name, depth) = parseLine(line) else { continue }
            if listing.rootUnit == nil, depth == 0 {
                listing.rootUnit = name
            } else {
                listing.nodes.append(SystemdDependencyNode(name: name, depth: depth))
            }
        }
        return listing
    }

    // MARK: Line parsing

    /// State bullets systemd prefixes lines with on a tty (●○×↻…), plus
    /// tree branch glyphs from non-`--plain` output. Neither carries depth
    /// information beyond its character width.
    private static let bulletCharacters = Set("●○×↻*•!")
    private static let branchCharacters = Set("│├└─")

    private static let unitTypes: Set<Substring> = [
        "service", "socket", "target", "timer", "mount", "automount",
        "swap", "path", "slice", "scope", "device",
    ]

    private static func parseLine(_ line: String) -> (name: String, depth: Int)? {
        var rest = Substring(line)

        // A leading state bullet (plus its trailing space) marks unit
        // state, not depth — strip it before counting columns.
        if let first = rest.first, bulletCharacters.contains(first) {
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }

        // Every remaining leading space or branch glyph is an indentation
        // column; systemd emits two columns per depth level in both plain
        // and tree output.
        var columns = 0
        while let first = rest.first, first == " " || branchCharacters.contains(first) {
            columns += 1
            rest = rest.dropFirst()
        }

        let token = rest.trimmingCharacters(in: .whitespaces)
        guard isUnitName(token) else { return nil }
        return (token, (columns + 1) / 2)
    }

    /// A unit name is a single token ending in a known unit-type suffix.
    /// Anything else (error messages, empty lines, ASCII-fallback tree
    /// prefixes like `|-unit` from non-UTF-8 locales) is noise to skip —
    /// skipping is honest; mis-parsing would invent unit names.
    private static func isUnitName(_ token: String) -> Bool {
        guard !token.isEmpty, !token.contains(" ") else { return false }
        guard !token.contains("|"), !token.contains("`") else { return false }
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let suffix = parts.last else { return false }
        return unitTypes.contains(suffix)
    }
}
