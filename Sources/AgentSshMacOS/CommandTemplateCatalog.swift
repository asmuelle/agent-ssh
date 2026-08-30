import Foundation

/// The allowlist: every command a guided fix is permitted to run.
///
/// Nothing outside this list can be executed through the guarded path, so
/// adding an entry is the deliberate act of vetting a command — reviewed
/// once, here, rather than argued about at each call site. The invariants
/// in `CommandTemplateCatalogTests` are checked across the whole list, so
/// a new entry inherits them automatically.
///
/// Entries are read-only or narrowly-scoped mutations of things the app
/// already inspects. The wider remediation catalog belongs with the fix
/// runner; this is the machinery plus enough real entries to exercise it.
public enum CommandTemplateCatalog {
    public static let all: [CommandTemplate] = [
        CommandTemplate(
            id: "systemd.status",
            segments: [
                .literal("systemctl"), .literal("status"), .literal("--no-pager"),
                .literal("--"), .slot(.init(name: "unit", kind: .systemdUnit)),
            ],
            risk: .readOnly
        ),
        CommandTemplate(
            id: "systemd.restart",
            segments: [
                .literal("systemctl"), .literal("restart"),
                .literal("--"), .slot(.init(name: "unit", kind: .systemdUnit)),
            ],
            risk: .modifiesService,
            requiresPrivilege: true
        ),
        CommandTemplate(
            id: "systemd.start",
            segments: [
                .literal("systemctl"), .literal("start"),
                .literal("--"), .slot(.init(name: "unit", kind: .systemdUnit)),
            ],
            risk: .modifiesService,
            requiresPrivilege: true
        ),
        CommandTemplate(
            id: "systemd.stop",
            segments: [
                .literal("systemctl"), .literal("stop"),
                .literal("--"), .slot(.init(name: "unit", kind: .systemdUnit)),
            ],
            risk: .modifiesService,
            requiresPrivilege: true
        ),
        CommandTemplate(
            id: "journal.unit-recent",
            segments: [
                .literal("journalctl"), .literal("--no-pager"), .literal("-n"), .literal("200"),
                // No `--` here: the slot is the argument of `-u`, and
                // getopt would consume the marker as that argument.
                .literal("-u"), .slot(.init(name: "unit", kind: .systemdUnit, isOptionArgument: true)),
            ],
            risk: .readOnly
        ),
        CommandTemplate(
            id: "disk.usage",
            segments: [
                .literal("df"), .literal("-hP"),
                .literal("--"), .slot(.init(name: "path", kind: .absolutePath)),
            ],
            risk: .readOnly
        ),
    ]

    private static let byId: [String: CommandTemplate] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Exact lookup. An unknown id is `nil` — never a fallback to a raw
    /// command or to the old string classifier.
    public static func template(id: String) -> CommandTemplate? {
        byId[id]
    }
}
