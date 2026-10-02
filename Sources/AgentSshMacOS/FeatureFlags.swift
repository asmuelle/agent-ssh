import Foundation

// MARK: - Feature flags

/// Central registry of feature flags that gate incomplete v1 features.
///
/// Before the beta, set any feature that isn't stable to `false`.
/// This hides UI elements (menu items, toolbar buttons, sidebar entries)
/// without removing the code paths.
public enum FeatureFlags: String, CaseIterable, Sendable {
    /// iCloud sync for profile metadata, snippets, and settings
    case cloudSync = "iCloud Sync"
    /// General local/remote/dynamic SSH port forwarding
    case portForwarding = "Port Forwarding"
    /// DigitalOcean / Hetzner inventory and server lifecycle
    case cloudServerManagement = "Cloud Server Management"
    /// Tailscale-aware resolution and Multipath TCP support
    case networkPolish = "Network Polish"
    /// Read-only, evidence-linked server diagnostics.
    case serverDoctor = "Server Doctor"
    /// Read-only update, reboot, and SSH hardening checks for connected hosts.
    case securityPatchMonitor = "Security Patch Monitor"

    /// Whether this feature is enabled for the current build.
    ///
    /// In Debug builds, all features are visible. In Release (beta) builds,
    /// only the stable subset is enabled.
    public var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        switch self {
        case .cloudSync: return false
        case .portForwarding: return false
        case .cloudServerManagement: return false
        case .networkPolish: return false
        case .serverDoctor: return true
        case .securityPatchMonitor: return true
        }
        #endif
    }
}
