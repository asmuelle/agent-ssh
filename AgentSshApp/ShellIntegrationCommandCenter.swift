import Foundation
import AgentSshMacOS
import OSLog
@preconcurrency import UserNotifications

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class ShellIntegrationCommandCenter {
    static let shared = ShellIntegrationCommandCenter()

    private let logger = Logger(subsystem: "com.mc-ssh", category: "shell-integration")
    private let notificationCenter = UNUserNotificationCenter.current()
    private let liveActivityStore = LiveActivitySnapshotStore()

    private init() {}

    func handle(_ command: ShellIntegrationCommand, connectionId: String) {
        switch command.kind {
        case .notify:
            deliverNotification(command, connectionId: connectionId)
        case .widget:
            WidgetMonitoringSnapshotCenter.shared.upsert(widgetSnapshot(command, connectionId: connectionId))
            reloadWidgets()
        case .liveActivity:
            do {
                try liveActivityStore.upsert(.shellIntegration(command, connectionId: connectionId))
            } catch {
                logger.warning("Failed to save shell Live Activity command: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deliverNotification(_ command: ShellIntegrationCommand, connectionId: String) {
        let title = command.title ?? "Midnight SSH"
        let body = command.body ?? "Remote command notification"

        ActivityLogStore.shared.record(
            title: title,
            detail: body,
            connectionId: connectionId,
            icon: symbol(for: command),
            severity: severity(for: command)
        )

        notificationCenter.getNotificationSettings { [notificationCenter, logger] settings in
            let schedule = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.threadIdentifier = "shell-integration-\(connectionId)"
                if let openURL = command.openURL {
                    content.userInfo = ["openURL": openURL]
                }

                let request = UNNotificationRequest(
                    identifier: "shell-\(command.stableIdentifier)",
                    content: content,
                    trigger: nil
                )
                notificationCenter.add(request) { error in
                    if let error {
                        logger.warning("Failed to deliver shell notification: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                schedule()
            case .notDetermined:
                notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        logger.warning("Failed to request shell notification authorization: \(error.localizedDescription, privacy: .public)")
                    }
                    if granted {
                        schedule()
                    }
                }
            case .denied:
                logger.info("Shell integration notification skipped because notifications are disabled")
            @unknown default:
                logger.info("Shell integration notification skipped due to unknown authorization state")
            }
        }
    }

    private func widgetSnapshot(
        _ command: ShellIntegrationCommand,
        connectionId: String
    ) -> WidgetMonitorSnapshot {
        let state = command.state
            .flatMap { WidgetMonitorState(rawValue: $0.lowercased()) }
            ?? .unknown
        let kind = command.metadata["kind"]
            .flatMap { WidgetMonitorKind(rawValue: $0.lowercased()) }
            ?? .custom
        let title = command.title ?? "Remote status"
        return WidgetMonitorSnapshot(
            id: "shell:\(command.stableIdentifier)",
            displayName: title,
            kind: kind,
            state: state,
            lastCheckedAt: Date(),
            lastChangedAt: Date(),
            summary: command.body ?? LiveActivityPresenter.stateLabel(for: LiveActivityOperationState(rawValue: command.state ?? "") ?? .running),
            detail: command.metadata["detail"],
            openURL: command.openURL ?? "agent-ssh://terminal/\(connectionId)"
        )
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.widgetKind)
        #endif
    }

    private func severity(for command: ShellIntegrationCommand) -> ActivitySeverity {
        switch command.metadata["severity"]?.lowercased() {
        case "success", "ok":
            return .success
        case "warning", "warn":
            return .warning
        case "error", "critical", "failed":
            return .critical
        default:
            return .info
        }
    }

    private func symbol(for command: ShellIntegrationCommand) -> String {
        switch command.metadata["severity"]?.lowercased() {
        case "success", "ok":
            return "checkmark.circle.fill"
        case "warning", "warn":
            return "exclamationmark.triangle.fill"
        case "error", "critical", "failed":
            return "xmark.octagon.fill"
        default:
            return "bell.badge"
        }
    }
}
