import Foundation

/// Shared MCP configuration constants used by the macOS app and its tests.
/// Keep the app-group identifier centralized so IPC does not silently fall
/// back to a less-protected temporary directory after an entitlement change.
public enum MCPConfiguration {
    public static let appGroupIdentifier = SharedAppStorageConfiguration.appGroupIdentifier
    public static let socketFileName = "agent-ssh-mcp.sock"
    public static let defaultEnabled = false

    public static func enabled(from persistedValue: Bool?) -> Bool {
        persistedValue ?? defaultEnabled
    }
}
