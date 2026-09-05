import SwiftUI

@main
struct MidnightSSHMobileApp: App {
    @StateObject private var bridgeManager = MobileBridgeManager.shared
    @StateObject private var keychainManager = MobileKeychainManager.shared
    @StateObject private var connectionStore = MobileConnectionStore()
    @StateObject private var sessionStore = MobileSessionStore()
    @StateObject private var healthStore = MobileServerHealthStore()
    @StateObject private var terminalPreferences = MobileTerminalPreferences.shared
    @StateObject private var entitlementsStore = MobileEntitlementsStore.shared

    var body: some Scene {
        WindowGroup {
            MobilePrivacyGateView {
                MobileContentView()
            }
                .alert(
                    item: Binding(
                        get: { sessionStore.pendingHostKeyConfirmation },
                        // Dismissal without a button press (e.g. scene teardown)
                        // must not leave an unverified session live.
                        set: { if $0 == nil { sessionStore.rejectPendingHostKey() } }
                    )
                ) { pending in
                    Alert(
                        title: Text("Verify host key for \(pending.host)"),
                        message: Text(
                            "First connection to \(pending.host):\(pending.port). Compare this fingerprint with the one published by the server's administrator before continuing.\n\n\(pending.fingerprint)"
                        ),
                        primaryButton: .cancel(Text("Disconnect")) {
                            sessionStore.rejectPendingHostKey()
                        },
                        secondaryButton: .default(Text("Trust and Continue")) {
                            sessionStore.confirmPendingHostKey()
                        }
                    )
                }
                .environmentObject(bridgeManager)
                .environmentObject(keychainManager)
                .environmentObject(connectionStore)
                .environmentObject(sessionStore)
                .environmentObject(healthStore)
                .environmentObject(terminalPreferences)
                .environmentObject(entitlementsStore)
                .task {
                    bridgeManager.initialize()
                    MobileMonitoringAlertNotificationCenter.shared.start()
                    MobileLiveActivityCenter.shared.start()
                    connectionStore.load()
                    entitlementsStore.start()
                }
        }
        .commands {
            SidebarCommands()
            CommandMenu("Server") {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .mobileShowCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .mobileReconnectCurrent, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Tail Logs") {
                    NotificationCenter.default.post(name: .mobileTailLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let mobileShowCommandPalette = Notification.Name("mobileShowCommandPalette")
    static let mobileReconnectCurrent = Notification.Name("mobileReconnectCurrent")
    static let mobileTailLogs = Notification.Name("mobileTailLogs")
}
