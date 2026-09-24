import Combine
import Foundation

/// Type-safe inner-app event bus. Replaces the loose `NotificationCenter`
/// userInfo dictionaries so the compiler verifies event shapes at each
/// send/receive site.
enum AgentSshEvent: Equatable {
    case connectionStatus(connectionId: String, payload: String)
    case transferProgress(connectionId: String, payload: String)
    case terminalTitleChanged(connectionId: String, title: String)
    case tcpdumpLine(captureId: UInt64, line: String, isStderr: Bool)
    case showCommandPalette
    case showDashboard
}

// `@unchecked`: `PassthroughSubject` is not annotated `Sendable`, but Combine
// subjects serialize `send` internally. Events arrive from the Rust callback
// thread and the main thread alike.
final class AgentSshEventBus: @unchecked Sendable {
    static let shared = AgentSshEventBus()
    let events = PassthroughSubject<AgentSshEvent, Never>()
    private init() {}
}
