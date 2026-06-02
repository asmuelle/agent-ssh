import AppKit
import Foundation
import OSLog
import AgentSshMacOS
import UserNotifications

final class MonitoringAlertNotificationCenter: NSObject {
    static let shared = MonitoringAlertNotificationCenter()

    private let logger = Logger(subsystem: "com.mc-ssh", category: "monitoring-alerts")
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
    }

    func start() {
        notificationCenter.delegate = self

        let openAction = UNNotificationAction(
            identifier: "open-monitoring",
            title: "Open Midnight SSH",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.monitoringFailureCategoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([category])
    }

    func deliver(
        _ decisions: [WidgetMonitorAlertDecision],
        didSchedule: @escaping @Sendable (WidgetMonitorAlertDecision) -> Void
    ) {
        guard !decisions.isEmpty else { return }

        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.schedule(decisions, didSchedule: didSchedule)
            case .notDetermined:
                self.requestAuthorization { granted in
                    guard granted else {
                        self.logger.info("Monitoring alert notifications were not authorized")
                        return
                    }
                    self.schedule(decisions, didSchedule: didSchedule)
                }
            case .denied:
                self.logger.info("Monitoring alert notifications are disabled by the user")
            @unknown default:
                self.logger.info("Monitoring alert notifications have an unknown authorization state")
            }
        }
    }

    private func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                self?.logger.warning("Failed to request monitoring alert authorization: \(error.localizedDescription, privacy: .public)")
            }
            completion(granted)
        }
    }

    private func schedule(
        _ decisions: [WidgetMonitorAlertDecision],
        didSchedule: @escaping @Sendable (WidgetMonitorAlertDecision) -> Void
    ) {
        for decision in decisions {
            let payload = decision.deliveryPayload(source: .macOSApp)
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = Self.enrichedBody(payload.body, openURL: decision.openURL)
            content.sound = .default
            content.categoryIdentifier = Self.monitoringFailureCategoryIdentifier
            content.threadIdentifier = payload.notificationThreadIdentifier
            content.userInfo = payload.userInfo

            let request = UNNotificationRequest(
                identifier: payload.id,
                content: content,
                trigger: nil
            )

            notificationCenter.add(request) { [weak self] error in
                if let error {
                    self?.logger.warning("Failed to schedule monitoring alert: \(error.localizedDescription, privacy: .public)")
                    return
                }
                didSchedule(decision)
            }
        }
    }

    private static let monitoringFailureCategoryIdentifier = "monitoring-failure"

    /// Append the most recent Server Doctor headline for the affected host, so a
    /// "CPU high" alert also carries the likely cause the user already diagnosed.
    /// This is a synchronous read of the precomputed summary — no model runs on
    /// the delivery path.
    private static func enrichedBody(_ body: String, openURL: String?) -> String {
        guard let openURL,
              let profileId = URL(string: openURL)?.lastPathComponent,
              !profileId.isEmpty,
              let doctor = ServerDoctorSummaryStore().summary(profileId: profileId),
              doctor.overallSeverity >= .warning else {
            return body
        }
        return "\(body)\n\nServer Doctor: \(doctor.headline)"
    }
}

extension MonitoringAlertNotificationCenter: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard let payload = MonitoringAlertDeliveryPayload(userInfo: userInfo),
              let openURLString = payload.openURL,
              let openURL = URL(string: openURLString)
        else { return }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(openURL)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
