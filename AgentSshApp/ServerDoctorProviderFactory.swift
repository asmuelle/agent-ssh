import Foundation
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
            return LocalOpenAICompatibleServerDoctorProvider.fromEnvironment(environment)
                ?? DisabledServerDoctorLLMProvider()

        case .localLLM:
            return LocalOpenAICompatibleServerDoctorProvider.fromEnvironment(environment)
                ?? DisabledServerDoctorLLMProvider()

        case .heuristics:
            return DisabledServerDoctorLLMProvider()
        }
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
