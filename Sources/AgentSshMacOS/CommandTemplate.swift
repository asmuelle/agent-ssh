import Foundation

/// How much damage running a template could do. A property of the vetted
/// catalog entry, never of the data bound into it: two renders of the
/// same template must never land on opposite sides of the gate, which is
/// what a classifier over a finished string cannot promise.
public enum CommandRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// Reads state. Safe to run without asking.
    case readOnly
    /// Starts, stops or reloads a running service.
    case modifiesService
    /// Edits a configuration file on disk.
    case modifiesConfig
    /// Installs, removes or upgrades software.
    case modifiesPackages

    public static func < (lhs: CommandRisk, rhs: CommandRisk) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .readOnly: return 0
        case .modifiesService: return 1
        case .modifiesConfig: return 2
        case .modifiesPackages: return 3
        }
    }
}

/// A vetted command shape with typed holes.
///
/// The segment list is the whole point. A template is not a format string
/// with `\(…)` holes, because in a format string the literal text is
/// itself assembled at runtime and becomes a second, unvalidated slot —
/// the shape `"systemctl \(verb) \(quote(unit))"` looks parameterized but
/// lets `verb` carry anything. Here a literal is a `StaticString`, which
/// no ordinary code path can produce from a runtime value — only a
/// deliberate reach for underscored stdlib builtins — so in practice
/// every literal is author-written and a slot cannot syntactically hide
/// inside one.
public struct CommandTemplate: Sendable {
    public struct Slot: Sendable, Equatable {
        public let name: String
        public let kind: CommandSlotKind
        /// True when the slot supplies the argument of a preceding option
        /// (`journalctl -u <unit>`) rather than standing as a positional
        /// operand.
        ///
        /// The distinction decides whether `--` belongs in front of it,
        /// and getopt makes it a real one: an option that requires an
        /// argument consumes the very next word whatever it is, so
        /// `-u -- nginx.service` sets the unit to `--`. An option
        /// argument is never option-parsed, so it needs no marker; a
        /// positional does.
        public let isOptionArgument: Bool

        public init(name: String, kind: CommandSlotKind, isOptionArgument: Bool = false) {
            self.name = name
            self.kind = kind
            self.isOptionArgument = isOptionArgument
        }
    }

    public enum Segment: Sendable {
        case literal(StaticString)
        case slot(Slot)
    }

    public let id: String
    public let segments: [Segment]
    public let risk: CommandRisk
    /// Whether the runner must prepend `sudo -n`. A catalog field rather
    /// than something a template writes itself, so privilege is visible
    /// to the gate instead of buried in command text.
    public let requiresPrivilege: Bool
    /// Set only for commands that genuinely cannot take `--` (GNU `find`
    /// is the usual one). Carrying the reason means the exemption is
    /// argued in the catalog rather than assumed by the test.
    public let endOfOptionsUnsupportedReason: String?

    /// Deliberately not `public`: a template is a vetted artefact, and
    /// app code minting its own would make the catalog a habit rather
    /// than the allowlist. Only this module — i.e. the catalog — builds
    /// templates.
    init(
        id: String,
        segments: [Segment],
        risk: CommandRisk,
        requiresPrivilege: Bool = false,
        endOfOptionsUnsupportedReason: String? = nil
    ) {
        self.id = id
        self.segments = segments
        self.risk = risk
        self.requiresPrivilege = requiresPrivilege
        self.endOfOptionsUnsupportedReason = endOfOptionsUnsupportedReason
    }

    public var slots: [Slot] {
        segments.compactMap { if case .slot(let slot) = $0 { return slot } else { return nil } }
    }
}

/// Why a render was refused. Refusal is a first-class outcome — "no
/// guided fix is available for this" is an acceptable, visible answer,
/// and far better than a command nobody vetted.
public struct CommandTemplateError: Error, Equatable {
    public enum Reason: Equatable, Sendable {
        case unknownTemplate(String)
        case unknownSlot(String)
        case missingValue(String)
        case rejectedValue(slot: String, kind: CommandSlotKind)
    }

    public let reason: Reason

    public var slotName: String {
        switch reason {
        case .unknownTemplate: return ""
        case .unknownSlot(let name), .missingValue(let name): return name
        case .rejectedValue(let slot, _): return slot
        }
    }

    /// Plain-language, for a user who is being told their fix cannot run.
    public var explanation: String {
        switch reason {
        case .unknownTemplate(let id):
            return "There is no vetted fix called “\(id)”, so nothing was run."
        case .unknownSlot(let name):
            return "This fix was given a value called “\(name)” that its command does not have a place for."
        case .missingValue(let name):
            return "This fix needs a value for “\(name)” and none was supplied."
        case .rejectedValue(let slot, let kind):
            return "The value for “\(slot)” is not a valid \(kind.humanReadableName), so the fix was not run."
        }
    }
}

/// The only way to obtain a `RenderedCommand`.
public enum CommandTemplateRenderer {
    /// The public way to build a command: by catalog id. Membership of
    /// the allowlist is a precondition of rendering rather than a habit,
    /// so an unknown id fails closed instead of falling back to anything.
    public static func render(
        templateId: String,
        values: [String: String]
    ) throws -> RenderedCommand {
        guard let template = CommandTemplateCatalog.template(id: templateId) else {
            throw CommandTemplateError(reason: .unknownTemplate(templateId))
        }
        return try render(template, values: values)
    }

    /// Module-internal so the catalog's own invariant tests can drive a
    /// template directly. App code goes through the id-keyed entry point
    /// above, which is why that one is the public surface.
    static func render(
        _ template: CommandTemplate,
        values: [String: String]
    ) throws -> RenderedCommand {
        let slotNames = Set(template.slots.map(\.name))
        // Surplus bindings are refused rather than ignored: a value the
        // template has no place for means the caller and the catalog
        // disagree about what this fix does.
        for name in values.keys where !slotNames.contains(name) {
            throw CommandTemplateError(reason: .unknownSlot(name))
        }

        var words: [String] = []
        for segment in template.segments {
            switch segment {
            case .literal(let literal):
                words.append(literal.description)
            case .slot(let slot):
                guard let value = values[slot.name] else {
                    throw CommandTemplateError(reason: .missingValue(slot.name))
                }
                // Validate at render time, every time — never trusting a
                // value because it was checked at ingest. Remote-derived
                // names cross a persistence boundary and come back.
                guard let accepted = slot.kind.validate(value) else {
                    throw CommandTemplateError(
                        reason: .rejectedValue(slot: slot.name, kind: slot.kind)
                    )
                }
                words.append(ShellQuoting.singleQuoted(accepted))
            }
        }

        return RenderedCommand(
            templateId: template.id,
            command: words.joined(separator: " "),
            risk: template.risk,
            requiresPrivilege: template.requiresPrivilege
        )
    }
}

/// A command that a vetted template produced from validated values.
///
/// Unforgeable on purpose: the initializer is `fileprivate`, so the
/// renderer above is the only code that can make one. An executor that
/// takes this type instead of a `String` cannot be handed a command
/// nobody vetted — the guarantee is structural rather than a convention
/// a later catalog entry can quietly route around.
///
/// Deliberately not `Codable` and not `RawRepresentable`: either would
/// reopen free construction from disk.
public struct RenderedCommand: Sendable, Equatable {
    public let templateId: String
    /// Exactly what will run. Show this, execute this, audit this — no
    /// re-derivation between consent and execution.
    public let command: String
    public let risk: CommandRisk
    public let requiresPrivilege: Bool

    fileprivate init(templateId: String, command: String, risk: CommandRisk, requiresPrivilege: Bool) {
        self.templateId = templateId
        self.command = command
        self.risk = risk
        self.requiresPrivilege = requiresPrivilege
    }
}

public extension CommandSlotKind {
    /// For refusal messages shown to someone who does not know the term.
    var humanReadableName: String {
        switch self {
        case .shellWord: return "value"
        case .absolutePath: return "file path"
        case .systemdUnit: return "service name"
        case .packageName: return "package name"
        case .sshdConfigToken: return "SSH algorithm name"
        }
    }
}
