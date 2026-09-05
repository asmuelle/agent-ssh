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
}
