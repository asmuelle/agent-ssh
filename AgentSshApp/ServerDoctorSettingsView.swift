import SwiftUI
import AgentSshMacOS

/// Server Doctor engine + privacy configuration.
///
/// Replaces the previous env-var-only configuration so real users (not just
/// developers exporting `MIDNIGHT_SSH_DOCTOR_LLM_*`) can choose how diagnosis is
/// generated and how aggressively evidence is redacted before any model sees it.
struct ServerDoctorSettingsView: View {
    @AppStorage(ServerDoctorPreferences.providerKindKey)
    private var providerKindRaw = ServerDoctorProviderKind.default.rawValue

    @AppStorage(ServerDoctorPreferences.privacyPresetKey)
    private var privacyPresetRaw = ServerDoctorPrivacyPreset.balanced.rawValue

    private var providerKind: ServerDoctorProviderKind {
        ServerDoctorProviderKind(rawValue: providerKindRaw) ?? .default
    }

    private var appleStatus: AppleFoundationModelsDoctorAvailability.Status {
        AppleFoundationModelsDoctorAvailability.current()
    }

    var body: some View {
        Form {
            Section("Diagnosis engine") {
                Picker("Engine", selection: $providerKindRaw) {
                    ForEach(ServerDoctorProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Text(providerKind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Intelligence") {
                HStack(spacing: 8) {
                    Image(systemName: appleStatus.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appleStatus.isReady ? .green : .orange)
                    Text(appleStatus.userMessage)
                        .font(.callout)
                }
                if !appleStatus.isReady && providerKind == .appleIntelligence {
                    Text("Diagnosis will fall back to a configured local LLM, or the built-in heuristics, until the on-device model is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Picker("Redaction before analysis", selection: $privacyPresetRaw) {
                    ForEach(ServerDoctorPrivacyPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                Text(privacyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if providerKind == .localLLM {
                Section("Local LLM endpoint") {
                    Text("Configured via environment variables:")
                        .font(.caption)
                    Label(LocalOpenAICompatibleServerDoctorProvider.modelEnvironmentKey, systemImage: "cpu")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Label(LocalOpenAICompatibleServerDoctorProvider.endpointEnvironmentKey, systemImage: "network")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Text("The endpoint must be a loopback address (localhost / 127.0.0.1 / ::1). Evidence is redacted with the policy above before it is sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyDetail: String {
        switch ServerDoctorPrivacyPreset(rawValue: privacyPresetRaw) ?? .balanced {
        case .balanced:
            return "Redacts secrets (keys, tokens, passwords, credentialed URLs). Keeps hostnames, paths, and ports — these usually matter for diagnosis."
        case .strict:
            return "Also redacts hostnames, usernames, IPs, emails, and domains. Higher privacy, slightly lower diagnostic precision."
        case .localOnly:
            return "Strict redaction. Combine with the Apple Intelligence engine to keep all evidence on this device."
        }
    }
}
