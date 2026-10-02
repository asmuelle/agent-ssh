import Combine
import Foundation

/// Type-safe inner-app event bus. Replaces the loose `NotificationCenter`
/// userInfo dictionaries so the compiler verifies event shapes at each
/// send/receive site.
enum AgentSshEvent: Equatable {
    case connectionStatus(connectionId: String, payload: String)
    case transferProgress(connectionId: String, payload: String)
    case terminalTitleChanged(connectionId: String, title: String)
    case showCommandPalette
    case showHostSection(HostSection)
    case showFleetTool(FleetTool)
    case selectAdjacentHost(forward: Bool)
}

/// Tools that act on several connected hosts at once. They open over
/// the host screen as sheets.
enum FleetTool: String, Identifiable, Equatable {
    case runbook, stackAudit

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .runbook: return "Run on Several Hosts…"
        case .stackAudit: return "Audit Stacks…"
        }
    }
}

// `@unchecked`: `PassthroughSubject` is not annotated `Sendable`, but Combine
// subjects serialize `send` internally. Events arrive from the Rust callback
// thread and the main thread alike.
final class AgentSshEventBus: @unchecked Sendable {
    static let shared = AgentSshEventBus()
    let events = PassthroughSubject<AgentSshEvent, Never>()
    private init() {}
}
