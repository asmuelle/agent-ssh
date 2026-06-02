import Foundation
import UIKit
import UserNotifications

final class MobileMonitoringAlertNotificationCenter: NSObject {
    static let shared = MobileMonitoringAlertNotificationCenter()

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

    func deliver(_ payloads: [MonitoringAlertDeliveryPayload]) {
        guard !payloads.isEmpty else { return }

        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.schedule(payloads)
            case .notDetermined:
                self.requestAuthorization { granted in
                    if granted {
                        self.schedule(payloads)
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    private func schedule(_ payloads: [MonitoringAlertDeliveryPayload]) {
        for payload in payloads {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default
            content.categoryIdentifier = Self.monitoringFailureCategoryIdentifier
            content.threadIdentifier = payload.notificationThreadIdentifier
            content.userInfo = payload.userInfo

            let request = UNNotificationRequest(
                identifier: payload.id,
                content: content,
                trigger: nil
            )
            notificationCenter.add(request)
        }
    }

    private static let monitoringFailureCategoryIdentifier = "monitoring-failure"
}

extension MobileMonitoringAlertNotificationCenter: UNUserNotificationCenterDelegate {
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
            UIApplication.shared.open(openURL)
        }
    }
}
