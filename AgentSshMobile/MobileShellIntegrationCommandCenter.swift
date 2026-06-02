import Foundation
@preconcurrency import UserNotifications
import WidgetKit

@MainActor
final class MobileShellIntegrationCommandCenter {
    static let shared = MobileShellIntegrationCommandCenter()

    private let notificationCenter = UNUserNotificationCenter.current()

    private init() {}

    func handle(_ command: ShellIntegrationCommand, connectionId: String) {
        switch command.kind {
        case .notify:
            deliverNotification(command, connectionId: connectionId)
        case .widget:
            upsertWidgetSnapshot(command, connectionId: connectionId)
        case .liveActivity:
            MobileLiveActivityCenter.shared.publish(.shellIntegration(command, connectionId: connectionId))
        }
    }

    private func deliverNotification(_ command: ShellIntegrationCommand, connectionId: String) {
        let title = command.title ?? "Midnight SSH"
        let body = command.body ?? "Remote command notification"

        MobileActivityLogStore.shared.record(
            title: title,
            detail: body,
            connectionId: connectionId,
            systemImage: symbol(for: command),
            severity: severity(for: command)
        )

        notificationCenter.getNotificationSettings { [notificationCenter] settings in
            let schedule = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.threadIdentifier = "shell-integration-\(connectionId)"
                if let openURL = command.openURL {
                    content.userInfo = ["openURL": openURL]
                }
                notificationCenter.add(
                    UNNotificationRequest(
                        identifier: "shell-\(command.stableIdentifier)",
                        content: content,
                        trigger: nil
                    )
                )
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                schedule()
            case .notDetermined:
                notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        schedule()
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func upsertWidgetSnapshot(_ command: ShellIntegrationCommand, connectionId: String) {
        let state = command.state
            .flatMap { WidgetMonitorState(rawValue: $0.lowercased()) }
            ?? .unknown
        let kind = command.metadata["kind"]
            .flatMap { WidgetMonitorKind(rawValue: $0.lowercased()) }
            ?? .custom
        let snapshot = WidgetMonitorSnapshot(
            id: "shell:\(command.stableIdentifier)",
            displayName: command.title ?? "Remote status",
            kind: kind,
            state: state,
            lastCheckedAt: Date(),
            lastChangedAt: Date(),
            summary: command.body ?? state.rawValue,
            detail: command.metadata["detail"],
            openURL: command.openURL ?? "agent-ssh://terminal/\(connectionId)"
        )

        do {
            let store = WidgetSnapshotStore()
            var file = try store.loadSnapshotFile() ?? WidgetMonitorSnapshotFile(snapshots: [])
            if let index = file.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                file.snapshots[index] = snapshot
            } else {
                file.snapshots.append(snapshot)
            }
            file.generatedAt = Date()
            try store.save(file)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.iOSWidgetKind)
        } catch {
            MobileActivityLogStore.shared.record(
                title: "Widget command failed",
                detail: error.localizedDescription,
                connectionId: connectionId,
                systemImage: "rectangle.stack.badge.exclamationmark",
                severity: .warning
            )
        }
    }

    private func severity(for command: ShellIntegrationCommand) -> MobileFindingSeverity {
        switch command.metadata["severity"]?.lowercased() {
        case "success", "ok":
            return .ok
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
