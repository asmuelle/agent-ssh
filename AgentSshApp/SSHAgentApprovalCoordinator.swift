import AppKit
import Foundation
import AgentSshMacOS

@MainActor
final class SSHAgentApprovalCoordinator {
    static let shared = SSHAgentApprovalCoordinator()

    private struct Grant {
        let key: String
        let sessionId: String?
        let expiresAt: Date?

        func isValid(now: Date = Date()) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > now
        }
    }

    private var grants: [String: Grant] = [:]

    private init() {}

    func approveIfNeeded(
        profile: ConnectionProfile,
        identityName: String,
        identityHint: String?,
        sessionId: String?
    ) -> Bool {
        let key = grantKey(profile: profile, identityHint: identityHint)
        if let grant = grants[key], grant.isValid() {
            return true
        }

        let window = promptApproval(profile: profile, identityName: identityName)
        guard let window else { return false }

        switch window {
        case .once:
            return true
        case .fiveMinutes, .sixtyMinutes:
            grants[key] = Grant(
                key: key,
                sessionId: nil,
                expiresAt: window.expirationDate()
            )
            return true
        case .currentSession:
            grants[key] = Grant(
                key: key,
                sessionId: sessionId,
                expiresAt: nil
            )
            return true
        }
    }

    func revokeSession(sessionId: String) {
        grants = grants.filter { _, grant in
            grant.sessionId != sessionId
        }
    }

    private func promptApproval(
        profile: ConnectionProfile,
        identityName: String
    ) -> AgentApprovalWindow? {
        let alert = NSAlert()
        alert.messageText = "Approve SSH Agent"
        alert.informativeText = "\(profile.name) wants to use \(identityName)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: AgentApprovalWindow.once.displayName)
        alert.addButton(withTitle: AgentApprovalWindow.fiveMinutes.displayName)
        alert.addButton(withTitle: AgentApprovalWindow.sixtyMinutes.displayName)
        alert.addButton(withTitle: AgentApprovalWindow.currentSession.displayName)
        alert.addButton(withTitle: "Deny")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .once
        case .alertSecondButtonReturn:
            return .fiveMinutes
        case .alertThirdButtonReturn:
            return .sixtyMinutes
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            return .currentSession
        default:
            return nil
        }
    }

    private func grantKey(profile: ConnectionProfile, identityHint: String?) -> String {
        "\(profile.id):\(identityHint ?? "default")"
    }
}
