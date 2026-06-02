import Foundation
import OSLog

/// Forwards events from the Rust event bus to the Swift app.
///
/// Conforms to the uniffi-generated `FfiEventCallback` protocol. A single
/// instance is registered with the Rust core during `BridgeManager.initialize()`.
/// Rust calls `onEvent(event:)` from a background Tokio task; we post
/// typed events to `AgentSshEventBus.shared.events` so individual views
/// can observe without every consumer needing to know about the FFI layer.
final class AgentSshEventCallback: FfiEventCallback {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "ffi-events")

    func onEvent(event: FfiEvent) {
        Task { @MainActor in
            switch event.ty {
            case "pty_output":
                // Hot path: ~hundreds of events/sec under heavy output.
                TerminalSessionManager.shared.dispatch(
                    connectionId: event.connectionId,
                    type: event.ty,
                    payload: event.payload
                )

            case "connection_status":
                self.logger.log("connection_status \(event.connectionId, privacy: .public): \(event.payload, privacy: .public)")
                AgentSshEventBus.shared.events.send(
                    .connectionStatus(connectionId: event.connectionId, payload: event.payload)
                )

            case "transfer_progress":
                AgentSshEventBus.shared.events.send(
                    .transferProgress(connectionId: event.connectionId, payload: event.payload)
                )

            case "tcpdump_line":
                // Payload shape: {"captureId": Number, "line": String, "isStderr": Bool}
                if let data = event.payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = (json["captureId"] as? NSNumber)?.uint64Value,
                   let line = json["line"] as? String {
                    let isStderr = (json["isStderr"] as? Bool) ?? false
                    AgentSshEventBus.shared.events.send(
                        .tcpdumpLine(captureId: id, line: line, isStderr: isStderr)
                    )
                }

            default:
                self.logger.warning("Unknown event type: \(event.ty, privacy: .public)")
            }
        }
    }
}
