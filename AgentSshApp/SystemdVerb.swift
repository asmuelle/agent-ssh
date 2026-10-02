import AgentSshMacOS
import Foundation

/// The systemctl verbs this view offers. A closed set naming its own
/// catalog template, rather than a `String` spliced into a command:
/// the old shape let the verb carry anything, so what looked like one
/// parameterized command was really two unvalidated slots.
enum SystemdVerb: String, CaseIterable {
    case start, stop, restart, reload, enable, disable

    var templateId: String {
        switch self {
        case .start: return "systemd.start"
        case .stop: return "systemd.stop"
        case .restart: return "systemd.restart"
        case .reload: return "systemd.reload"
        case .enable: return "systemd.enable"
        case .disable: return "systemd.disable"
        }
    }

    var destructive: Bool {
        switch self {
        case .stop, .restart, .disable: return true
        case .start, .reload, .enable: return false
        }
    }

    /// What actually runs for `rendered`: the vetted command, retried under
    /// `sudo -n` when the unprivileged attempt fails, so it works both as
    /// root and for sudoers. Show this string and run this string.
    static func script(for rendered: RenderedCommand) -> String {
        guard rendered.requiresPrivilege else { return rendered.command }
        return "\(rendered.command) || sudo -n \(rendered.command)"
    }

    /// One symbol per verb, the same in the Systemd tab and the detail sheet.
    var symbol: String {
        switch self {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .restart: return "arrow.clockwise.circle"
        case .reload: return "arrow.triangle.2.circlepath"
        case .enable: return "checkmark.circle"
        case .disable: return "slash.circle"
        }
    }

    /// "Restart", for titles and buttons.
    var label: String { rawValue.capitalized }

    /// The app's one confirmation for this verb. `command` must be the exact
    /// string `perform` runs.
    func confirmation(
        unit: String,
        host: String,
        command: String,
        perform: @escaping @MainActor () async -> Void
    ) -> PendingServerAction {
        PendingServerAction(
            title: "\(label) \(unit)?",
            confirmLabel: label,
            target: host,
            command: command,
            isDestructive: destructive,
            perform: perform
        )
    }
}
