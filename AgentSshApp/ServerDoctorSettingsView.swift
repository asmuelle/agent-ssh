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

    @AppStorage(ServerDoctorLocalLLMConfig.endpointDefaultsKey)
    private var localEndpoint = ""

    @AppStorage(ServerDoctorLocalLLMConfig.modelDefaultsKey)
    private var localModel = ""

    @State private var localToken = ""
    @State private var tokenSaveFailed = false

    private var providerKind: ServerDoctorProviderKind {
        ServerDoctorProviderKind(rawValue: providerKindRaw) ?? .default
    }

    private var isEnvironmentOverrideActive: Bool {
        ServerDoctorLocalLLMConfig.isEnvironmentOverrideActive()
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
                localLLMSection
            }
        }
        .formStyle(.grouped)
    }

    private var localLLMSection: some View {
        Section("Local LLM endpoint") {
            TextField(
                "Endpoint URL",
                text: $localEndpoint,
                prompt: Text(LocalOpenAICompatibleServerDoctorProvider.defaultEndpoint)
            )
            .autocorrectionDisabled()
            if let endpointValidationError {
                Label(endpointValidationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Model name", text: $localModel, prompt: Text("e.g. llama3.1"))
                .autocorrectionDisabled()
            if localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !isEnvironmentOverrideActive {
                Text("Set a model name to enable the local LLM. Until then, diagnosis uses the built-in heuristics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("API token (optional)", text: $localToken)
                .onAppear {
                    localToken = ServerDoctorLocalLLMConfig.loadToken() ?? ""
                }
                .onChange(of: localToken) { newValue in
                    tokenSaveFailed = !ServerDoctorLocalLLMConfig.saveToken(newValue)
                }
            if tokenSaveFailed {
                Label("The token could not be saved to the Keychain.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isEnvironmentOverrideActive {
                Label(
                    "MIDNIGHT_SSH_DOCTOR_LLM_* environment variables are set and override the values above.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("The endpoint must be a loopback address (localhost / 127.0.0.1 / ::1). Evidence is redacted with the policy above before it is sent. The token is stored in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Runs the field value through the same validator the provider factory
    /// uses (`makeValidated`), so the inline error can never diverge from the
    /// enforced loopback-only invariant. Empty means the default loopback
    /// endpoint is used.
    private var endpointValidationError: String? {
        let trimmed = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try LocalOpenAICompatibleServerDoctorProvider.makeValidated(
                endpointValue: trimmed,
                model: "validation-probe"
            )
            return nil
        } catch ServerDoctorLocalLLMError.nonLocalEndpoint {
            return "Endpoint must be a loopback address (localhost, 127.0.0.1, or ::1)."
        } catch {
            return "Enter a valid http(s) URL."
        }
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
