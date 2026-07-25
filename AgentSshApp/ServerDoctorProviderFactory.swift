import Foundation
import Security
import AgentSshMacOS

/// Resolves the user's configured Server Doctor engine into a concrete provider,
/// degrading gracefully when the preferred engine is unavailable.
///
/// Fallback chain:
///   Apple Intelligence (if enabled + ready) → configured local LLM → heuristics.
///
/// `DisabledServerDoctorLLMProvider` is the heuristics sentinel: it returns no
/// model report, so `ServerDoctorReportGenerator` uses the deterministic
/// heuristic report. That path always works, even with no AI at all.
enum ServerDoctorProviderFactory {
    static func makeProvider(
        preferred: ServerDoctorProviderKind = ServerDoctorPreferences.providerKind(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ServerDoctorLLMProviding {
        switch preferred {
        case .appleIntelligence:
            if let appleProvider = appleIntelligenceProvider() {
                return appleProvider
            }
            // Prefer a configured local model over bare heuristics when Apple
            // Intelligence is unavailable, so the user still gets AI analysis.
            return localLLMProvider(environment: environment)
                ?? DisabledServerDoctorLLMProvider()

        case .localLLM:
            return localLLMProvider(environment: environment)
                ?? DisabledServerDoctorLLMProvider()

        case .heuristics:
            return DisabledServerDoctorLLMProvider()
        }
    }

    /// Environment variables, when set, override the GUI configuration
    /// entirely — including when the env values are invalid, which degrades
    /// to heuristics exactly as the env-only path always did, rather than
    /// silently substituting different GUI values.
    private static func localLLMProvider(
        environment: [String: String]
    ) -> LocalOpenAICompatibleServerDoctorProvider? {
        if ServerDoctorLocalLLMConfig.isEnvironmentOverrideActive(environment) {
            return LocalOpenAICompatibleServerDoctorProvider.fromEnvironment(environment)
        }
        return ServerDoctorLocalLLMConfig.provider()
    }

    private static func appleIntelligenceProvider() -> ServerDoctorLLMProviding? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *),
              AppleFoundationModelsDoctorAvailability.current().isReady else {
            return nil
        }
        return AppleFoundationModelsDoctorProvider()
        #else
        return nil
        #endif
    }
}

/// GUI-persisted local LLM configuration for Server Doctor.
///
/// Endpoint and model live in `UserDefaults` alongside the other Server
/// Doctor preferences; the API token lives in the Keychain (never
/// `UserDefaults`). The `MIDNIGHT_SSH_DOCTOR_LLM_*` environment variables
/// remain a power-user escape hatch that overrides all of these.
enum ServerDoctorLocalLLMConfig {
    static let endpointDefaultsKey = "serverDoctor.localLLM.endpoint"
    static let modelDefaultsKey = "serverDoctor.localLLM.model"

    private static let tokenService = "com.mc-ssh.server-doctor-llm-token"
    private static let tokenAccount = "local-llm"

    /// True when any `MIDNIGHT_SSH_DOCTOR_LLM_*` variable is set. Override is
    /// all-or-nothing: mixing env and GUI values would make the effective
    /// endpoint/model pairing unpredictable.
    static func isEnvironmentOverrideActive(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let keys = [
            LocalOpenAICompatibleServerDoctorProvider.endpointEnvironmentKey,
            LocalOpenAICompatibleServerDoctorProvider.modelEnvironmentKey,
            LocalOpenAICompatibleServerDoctorProvider.apiKeyEnvironmentKey,
            LocalOpenAICompatibleServerDoctorProvider.timeoutEnvironmentKey
        ]
        return keys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Builds a provider from the GUI values via `makeValidated`, so the GUI
    /// path enforces the exact same http(s) + loopback invariant as the
    /// environment path. Returns nil when no model is configured or the
    /// stored endpoint fails validation.
    static func provider(
        from defaults: UserDefaults = .standard
    ) -> LocalOpenAICompatibleServerDoctorProvider? {
        guard let model = nonEmptyValue(forKey: modelDefaultsKey, in: defaults) else {
            return nil
        }
        let endpointValue = nonEmptyValue(forKey: endpointDefaultsKey, in: defaults)
            ?? LocalOpenAICompatibleServerDoctorProvider.defaultEndpoint
        return try? LocalOpenAICompatibleServerDoctorProvider.makeValidated(
            endpointValue: endpointValue,
            model: model,
            apiKey: loadToken()
        )
    }

    private static func nonEmptyValue(forKey key: String, in defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Keychain-backed API token

    static func loadToken() -> String? {
        var query = tokenQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saving an empty token deletes the entry. Returns false when the
    /// Keychain rejected the write so the UI can surface it.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteToken() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(tokenQuery as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var attributes = tokenQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteToken() -> Bool {
        let status = SecItemDelete(tokenQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var tokenQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount
        ]
    }
}
