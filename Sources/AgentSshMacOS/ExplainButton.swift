import SwiftUI

/// The app-wide "Explain" affordance: a sparkles button that opens a
/// popover with an on-device, plain-language explanation of the given
/// content. Renders nothing at all when no on-device model is available —
/// the feature is invisible rather than disappointing.
///
/// Usage (next to an existing Copy button in a sheet toolbar):
///
///     ExplainButton(context: "systemctl status output", text: output)
public struct ExplainButton: View {
    private let context: String
    private let textProvider: () -> String
    private let preset: ServerDoctorPrivacyPreset

    @State private var showingExplanation = false

    public init(
        context: String,
        text: @autoclosure @escaping () -> String,
        preset: ServerDoctorPrivacyPreset = .balanced
    ) {
        self.context = context
        self.textProvider = text
        self.preset = preset
    }

    public var body: some View {
        if ExplainService.isAvailable {
            Button {
                showingExplanation = true
            } label: {
                Label("Explain", systemImage: "sparkles")
            }
            .help("Explain this content in plain language, on device")
            .popover(isPresented: $showingExplanation) {
                ExplanationView(context: context, text: textProvider(), preset: preset)
            }
        }
    }
}

/// Runs the explanation when it appears and renders progress, the result
/// card with provenance, or an inline error. Reusable outside
/// `ExplainButton` (e.g. presented as a sheet from an alert action).
public struct ExplanationView: View {
    let context: String
    let text: String
    var preset: ServerDoctorPrivacyPreset = .balanced

    @State private var explanation: Explanation?
    @State private var errorMessage: String?

    public init(context: String, text: String, preset: ServerDoctorPrivacyPreset = .balanced) {
        self.context = context
        self.text = text
        self.preset = preset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Explanation")
                    .font(.headline)
                Spacer()
            }

            if let explanation {
                ScrollView {
                    Text(explanation.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)

                VStack(alignment: .leading, spacing: 3) {
                    Label("Generated on-device by Apple Intelligence", systemImage: "lock.shield")
                    if explanation.redactionCount > 0 {
                        Label(
                            "\(explanation.redactionCount) secret\(explanation.redactionCount == 1 ? "" : "s") redacted before the model saw this",
                            systemImage: "eye.slash"
                        )
                    }
                    if explanation.inputWasTruncated {
                        Label("Content was truncated to fit the model", systemImage: "scissors")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading \(context)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
        }
        .padding(14)
        .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
        .task {
            guard explanation == nil else { return }
            do {
                explanation = try await ExplainService.explain(
                    text: text,
                    context: context,
                    preset: preset
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Drop-in replacement for the repeated `err != nil` alert idiom that adds
/// an "Explain" action when on-device AI is available. The alert keeps its
/// exact former behavior otherwise.
public struct ExplainableErrorAlert: ViewModifier {
    let title: String
    let context: String
    @Binding var message: String?

    @State private var explaining: String?

    public func body(content: Content) -> some View {
        content
            .alert(
                title,
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                if ExplainService.isAvailable {
                    Button("Explain…") {
                        explaining = message
                        message = nil
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(
                isPresented: Binding(
                    get: { explaining != nil },
                    set: { if !$0 { explaining = nil } }
                )
            ) {
                ExplanationView(context: context, text: explaining ?? "")
                    .presentationDetents([.medium])
            }
    }
}

public extension View {
    /// `.explainableErrorAlert("Credential Error", context: "a Keychain error message", message: $error)`
    func explainableErrorAlert(
        _ title: String,
        context: String,
        message: Binding<String?>
    ) -> some View {
        modifier(ExplainableErrorAlert(title: title, context: context, message: message))
    }
}
