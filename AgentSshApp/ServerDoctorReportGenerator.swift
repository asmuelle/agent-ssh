import Foundation
import AgentSshMacOS

struct ServerDoctorGeneratedReport {
    var bundle: ServerDoctorCollectionBundle
    var redactedBundle: ServerDoctorCollectionBundle
    var report: ServerDoctorReport
    var validation: ServerDoctorReportValidationResult
}

enum ServerDoctorReportGenerator {
    static func generate(
        bundle: ServerDoctorCollectionBundle,
        privacyPreset: ServerDoctorPrivacyPreset,
        provider: ServerDoctorLLMProviding = DisabledServerDoctorLLMProvider()
    ) async -> ServerDoctorGeneratedReport {
        let (redactedBundle, redaction) = ServerDoctorRedactor.redact(
            bundle: bundle,
            preset: privacyPreset
        )

        let prompt = ServerDoctorPromptPayload(
            bundle: redactedBundle,
            privacyPreset: privacyPreset
        )

        let modelReport: ServerDoctorReport?
        do {
            modelReport = try await provider.generateReport(prompt: prompt).report
        } catch {
            modelReport = nil
        }

        let heuristicReport = ServerDoctorHeuristics.generateReport(
            bundle: redactedBundle,
            redaction: redaction
        )
        let rawReport = modelReport ?? heuristicReport
        var report = rawReport
        report.provider = modelReport == nil ? .localHeuristics : provider.metadata
        report.redaction = redaction

        var validation = ServerDoctorReportValidator.validate(
            report: report,
            evidence: redactedBundle.evidence
        )
        if !validation.isValid {
            let filtered = ServerDoctorReportValidator.filteredReadOnlyReport(
                report,
                evidence: redactedBundle.evidence
            )
            if filtered.findings.isEmpty && !report.findings.isEmpty {
                report = heuristicReport
                report.provider = .localHeuristics
                report.redaction = redaction
            } else {
                report = filtered
            }
            validation = ServerDoctorReportValidator.validate(
                report: report,
                evidence: redactedBundle.evidence
            )
        }

        return ServerDoctorGeneratedReport(
            bundle: bundle,
            redactedBundle: redactedBundle,
            report: report,
            validation: validation
        )
    }
}
