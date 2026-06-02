import AppKit
import SwiftUI
import AgentSshMacOS

@main
struct AgentSshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var layoutManager = LayoutManager()
    @StateObject private var tabsStore = TerminalTabsStore()
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var entitlementsStore = EntitlementsStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Midnight SSH", id: "main") {
            ContentView()
                .environmentObject(layoutManager)
                .environmentObject(tabsStore)
                .environmentObject(entitlementsStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // Single network-tools window — git deploy-state, multi-perspective DNS,
        // listening ports, and live tcpdump captures. Reuses the connected
        // SSH tabs from the main window via `tabsStore`.
        Window("Network Tools", id: "network-tools") {
            NetworkToolsWindow()
                .environmentObject(tabsStore)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    layoutManager.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Toggle Inspector") {
                    layoutManager.toggleInspector()
                }
                .keyboardShortcut("m", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Command Palette…") {
                    AgentSshEventBus.shared.events.send(.showCommandPalette)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Reconnect Active Connection") {
                    Task { await tabsStore.reconnectActive() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(tabsStore.activeTab == nil)

                Button("Show Dashboard") {
                    AgentSshEventBus.shared.events.send(.showDashboard)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(tabsStore.connectedSSHTabs.count < 2)

                Divider()

                Button("Zen Mode") {
                    layoutManager.applyPreset(.zen)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button("Reset Layout") {
                    layoutManager.applyPreset(.default)
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Divider()

                Button("Close Tab") {
                    tabsStore.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabsStore.activeTab == nil)

                Button("Next Tab") {
                    tabsStore.selectAdjacentTab(forward: true)
                }
                .keyboardShortcut(.tab, modifiers: .command)
                .disabled(tabsStore.tabs.count < 2)

                Button("Previous Tab") {
                    tabsStore.selectAdjacentTab(forward: false)
                }
                .keyboardShortcut(.tab, modifiers: [.command, .shift])
                .disabled(tabsStore.tabs.count < 2)
            }

            CommandMenu("Tools") {
                Button("Network Tools…") {
                    openWindow(id: "network-tools")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            }

            CommandMenu("Find") {
                Button("Find") {
                    Self.dispatchFind(.showFindPanel)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    Self.dispatchFind(.next)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    Self.dispatchFind(.previous)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Use Selection for Find") {
                    Self.dispatchFind(.setFindString)
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandMenu("Help") {
                Button("Check for Updates…") {
                    updateManager.checkForUpdates()
                }

                Button("Export Diagnostics…") {
                    DiagnosticsBundleExporter.export(
                        connectionStore: ConnectionStoreManager.shared,
                        tabsStore: tabsStore,
                        layoutManager: layoutManager
                    )
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(updateManager)
                .environmentObject(entitlementsStore)
        }
        .windowResizability(.contentMinSize)
    }

    /// Send a standard `performFindPanelAction:` to the responder chain so
    /// the focused `SwiftTerm.TerminalView` (which overrides that selector)
    /// gets it. SwiftTerm runs its own find bar + SearchService — we don't
    /// implement the actual search; the menu is the only thing missing in
    /// our shell.
    ///
    /// `performFindPanelAction:` lives on the `NSStandardKeyBindingResponding`
    /// informal protocol, not as a typed `NSResponder` method, so we build
    /// the selector by name rather than via `#selector`.
    private static func dispatchFind(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(
            #selector(FindPanelActionSelector.performFindPanelAction(_:)),
            to: nil,
            from: item
        )
    }

}

@objc protocol FindPanelActionSelector {
    func performFindPanelAction(_ sender: Any?)
}
