import Foundation

/// Which engine turns redacted read-only evidence into a Server Doctor report.
///
/// The values are deliberately ordered most-capable → most-available. The app
/// resolves the actual provider with a fallback chain: if the preferred engine
/// is unavailable (e.g. Apple Intelligence not enabled, or no local LLM
/// configured) it degrades to the next usable option and ultimately to the
/// deterministic heuristics, which always work.
public enum ServerDoctorProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// On-device Apple Foundation Models (Apple Intelligence). Private by
    /// construction — no evidence leaves the device.
    case appleIntelligence
    /// A user-configured OpenAI-compatible / Ollama endpoint on loopback.
    case localLLM
    /// Deterministic local heuristics only. No model involved.
    case heuristics

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .localLLM: return "Local LLM endpoint"
        case .heuristics: return "Built-in heuristics"
        }
    }

    public var detail: String {
        switch self {
        case .appleIntelligence:
            return "Runs entirely on this device. Redacted evidence is never sent off-device."
        case .localLLM:
            return "Sends redacted evidence to a loopback model endpoint you configure."
        case .heuristics:
            return "Pattern-matches collected evidence locally. Always available, no model."
        }
    }

    public static let `default`: ServerDoctorProviderKind = .appleIntelligence
}

/// App-local Server Doctor preferences. Stored in `UserDefaults` (not the app
/// group — these are per-install UI choices, not shared state).
public enum ServerDoctorPreferences {
    public static let providerKindKey = "serverDoctor.providerKind"
    public static let privacyPresetKey = "serverDoctor.privacyPreset"

    public static func providerKind(
        from defaults: UserDefaults = .standard
    ) -> ServerDoctorProviderKind {
        guard let raw = defaults.string(forKey: providerKindKey),
              let kind = ServerDoctorProviderKind(rawValue: raw) else {
            return .default
        }
        return kind
    }

    public static func privacyPreset(
        from defaults: UserDefaults = .standard
    ) -> ServerDoctorPrivacyPreset {
        guard let raw = defaults.string(forKey: privacyPresetKey),
              let preset = ServerDoctorPrivacyPreset(rawValue: raw) else {
            return .balanced
        }
        return preset
    }
}
