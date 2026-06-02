import Foundation
import AgentSshMacOS

@MainActor
final class SecurityPatchMonitorStore: ObservableObject {
    @Published private(set) var preview: SecurityPatchScanPreview?
    @Published private(set) var bundle: SecurityPatchScanBundle?
    @Published private(set) var result: SecurityPatchScanResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRefreshingAdvisories = false
    @Published private(set) var advisoryStatusMessage: String?
    @Published private(set) var isShowingCachedResult = false
    @Published var selectedFindingId: String?
    @Published var selectedEvidenceId: String?

    let request: SecurityPatchScanRequest

    init(request: SecurityPatchScanRequest) {
        self.request = request
        if let cached = SecurityPatchMonitorResultStore.shared.result(
            profileId: request.profileId,
            connectionId: request.connectionId
        ) {
            apply(cached, cached: true)
        }
    }

    var selectedFinding: SecurityPatchFinding? {
        guard let selectedFindingId else { return result?.findings.first }
        return result?.findings.first { $0.id == selectedFindingId }
    }

    var selectedEvidence: SecurityPatchEvidence? {
        guard let selectedEvidenceId else {
            guard let firstEvidenceId = selectedFinding?.evidenceIds.first else {
                return result?.evidence.first
            }
            return evidence(id: firstEvidenceId)
        }
        return evidence(id: selectedEvidenceId)
    }

    func evidence(id: String) -> SecurityPatchEvidence? {
        result?.evidence.first { $0.id == id }
    }

    func advisoryMatches(for finding: SecurityPatchFinding) -> [SecurityPatchAdvisoryMatch] {
        guard let result else { return [] }
        if finding.kind == .knownExploitedVulnerability {
            return result.advisoryMatches
        }
        let evidenceIds = Set(finding.evidenceIds)
        return result.advisoryMatches.filter { match in
            !evidenceIds.isDisjoint(with: match.evidenceIds)
        }
    }

    var isResultStale: Bool {
        guard let result else { return false }
        return SecurityPatchMonitorCache.isStale(scannedAt: result.scannedAt)
    }

    func loadPreview() async {
        guard preview == nil, !isLoadingPreview else { return }
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }

        do {
            preview = try await BridgeManager.shared.securityPatchPreview(request: request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runScan() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        do {
            let collected = try await BridgeManager.shared.securityPatchScan(request: request)
            let scored = await correlateAdvisories(
                SecurityPatchMonitorScoring.buildResult(bundle: collected)
            )
            bundle = collected
            apply(scored, cached: false)
            SecurityPatchMonitorSummaryStore.shared.record(scored.hostSummary)
            SecurityPatchMonitorResultStore.shared.record(scored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        bundle = nil
        result = nil
        selectedFindingId = nil
        selectedEvidenceId = nil
        errorMessage = nil
        isShowingCachedResult = false
    }

    private func correlateAdvisories(_ result: SecurityPatchScanResult) async -> SecurityPatchScanResult {
        let cveIds = SecurityPatchMonitorAdvisoryCorrelation.extractCveIds(evidence: result.evidence)
        guard !cveIds.isEmpty else {
            advisoryStatusMessage = "No CVE IDs found in scan evidence for CISA KEV correlation."
            return result
        }

        isRefreshingAdvisories = true
        defer { isRefreshingAdvisories = false }

        let correlated = await SecurityPatchAdvisoryStore.shared.correlate(result)
        if !correlated.advisoryMatches.isEmpty {
            advisoryStatusMessage = "\(correlated.advisoryMatches.count) CISA KEV match\(correlated.advisoryMatches.count == 1 ? "" : "es") found."
        } else if let error = SecurityPatchAdvisoryStore.shared.lastError {
            advisoryStatusMessage = "CISA KEV catalog unavailable: \(error)"
        } else {
            advisoryStatusMessage = "No CISA KEV matches for \(cveIds.count) CVE ID\(cveIds.count == 1 ? "" : "s") in scan evidence."
        }
        return correlated
    }

    private func apply(_ result: SecurityPatchScanResult, cached: Bool) {
        self.result = result
        selectedFindingId = result.findings.first?.id
        selectedEvidenceId = result.findings.first?.evidenceIds.first
        isShowingCachedResult = cached
    }
}
