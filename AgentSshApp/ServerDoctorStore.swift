import Foundation
import AgentSshMacOS

@MainActor
final class ServerDoctorStore: ObservableObject {
    @Published private(set) var preview: ServerDoctorCollectionPreview?
    @Published private(set) var rawBundle: ServerDoctorCollectionBundle?
    @Published private(set) var redactedBundle: ServerDoctorCollectionBundle?
    @Published private(set) var report: ServerDoctorReport?
    @Published private(set) var validation: ServerDoctorReportValidationResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isCollecting = false
    @Published var selectedFindingId: String?
    @Published var selectedEvidenceId: String?

    let request: ServerDoctorCollectionRequest
    private let provider: ServerDoctorLLMProviding
    private let profileId: String?

    init(
        request: ServerDoctorCollectionRequest,
        provider: ServerDoctorLLMProviding = DisabledServerDoctorLLMProvider(),
        profileId: String? = nil
    ) {
        self.request = request
        self.provider = provider
        self.profileId = profileId
    }

    var selectedFinding: ServerDoctorFinding? {
        guard let selectedFindingId else { return report?.findings.first }
        return report?.findings.first { $0.id == selectedFindingId }
    }

    var selectedEvidence: ServerDoctorEvidence? {
        guard let selectedEvidenceId else {
            guard let firstEvidenceId = selectedFinding?.evidenceIds.first else { return redactedBundle?.evidence.first }
            return evidence(id: firstEvidenceId)
        }
        return evidence(id: selectedEvidenceId)
    }

    var providerMetadata: ServerDoctorProviderMetadata {
        provider.metadata
    }

    func evidence(id: String) -> ServerDoctorEvidence? {
        redactedBundle?.evidence.first { $0.id == id }
    }

    func loadPreview() async {
        guard preview == nil, !isLoadingPreview else { return }
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }

        do {
            preview = try await BridgeManager.shared.serverDoctorPreview(request: request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDiagnosis() async {
        isCollecting = true
        errorMessage = nil
        defer { isCollecting = false }

        do {
            if provider.metadata != .localHeuristics {
                do {
                    try await provider.preflight()
                } catch {
                    errorMessage = """
                    Local LLM check failed before Server Doctor collected host data.
                    \(error.localizedDescription)
                    """
                    return
                }
            }

            let bundle = try await BridgeManager.shared.serverDoctorCollect(request: request)
            let generated = await ServerDoctorReportGenerator.generate(
                bundle: bundle,
                privacyPreset: request.privacyPreset,
                provider: provider
            )
            rawBundle = generated.bundle
            redactedBundle = generated.redactedBundle
            report = generated.report
            validation = generated.validation
            selectedFindingId = generated.report.findings.first?.id
            selectedEvidenceId = generated.report.findings.first?.evidenceIds.first
            await persistSummary(for: generated.report)
        } catch {
            errorMessage = """
            Server Doctor collection failed before model analysis.
            \(error.localizedDescription)
            """
        }
    }

    /// Publish a compact summary of the latest report so proactive surfaces
    /// (sidebar badge, widgets, Shortcuts, monitor notifications) can show
    /// "what's wrong" without re-running a live diagnosis.
    private func persistSummary(for report: ServerDoctorReport) async {
        guard let profileId else { return }
        let narration = await HostHealthNarrator.narrate(report: report)
        let summary = ServerDoctorHostSummary(
            profileId: profileId,
            hostLabel: request.hostLabel,
            headline: narration.headline,
            overallSeverity: report.overallSeverity,
            topFindingTitle: report.findings.first?.title,
            findingCount: report.findings.count,
            narratedOnDevice: narration.onDevice
        )
        try? ServerDoctorSummaryStore().upsert(summary)
    }

    func resetToPreview() {
        rawBundle = nil
        redactedBundle = nil
        report = nil
        validation = nil
        selectedFindingId = nil
        selectedEvidenceId = nil
    }
}
