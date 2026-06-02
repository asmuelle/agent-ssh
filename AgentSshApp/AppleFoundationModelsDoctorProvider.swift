import Foundation
import AgentSshMacOS

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Guided-generation schema
//
// These mirror `ServerDoctorReport` / `ServerDoctorFinding`, but as `@Generable`
// types so the on-device model is constrained to the schema at decode time. That
// removes the brittle JSON-repair the OpenAI-compatible path needs (fence
// stripping, brace scanning, partial-decode fallbacks): the framework hands us a
// typed value or throws.

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct DoctorReportGen {
    @Guide(description: "Short report title, roughly ten words or fewer.")
    var reportTitle: String

    @Guide(description: "One or two sentence plain-language operational summary.")
    var summary: String

    @Guide(description: "Overall severity. One of: critical, high, warning, info, unknown.")
    var overallSeverity: String

    @Guide(description: "Overall confidence. One of: high, medium, low.")
    var overallConfidence: String

    @Guide(description: "Findings. Each must cite evidence ids from the allowed list. Empty when nothing notable was found.")
    var findings: [DoctorFindingGen]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct DoctorFindingGen {
    @Guide(description: "Stable short identifier in kebab-case, e.g. nginx-missing-cert.")
    var id: String

    @Guide(description: "Short finding title.")
    var title: String

    @Guide(description: "What appears wrong, in plain language.")
    var summary: String

    @Guide(description: "Severity. One of: critical, high, warning, info, unknown.")
    var severity: String

    @Guide(description: "Confidence. One of: high, medium, low.")
    var confidence: String

    @Guide(description: "Affected subsystem, e.g. Web, Disk, Services, Memory, Network.")
    var affectedSubsystem: String

    @Guide(description: "Affected service name if known, otherwise an empty string.")
    var affectedService: String

    @Guide(description: "Evidence ids supporting this finding. Must come from the allowed evidence id list.")
    var evidenceIds: [String]

    @Guide(description: "Read-only inspection steps only. Never restarts, reloads, writes, installs, chmod, chown, kill, or other changes.")
    var safeNextSteps: [String]

    @Guide(description: "Mutating actions the user should avoid until the cause is confirmed.")
    var unsafeActionsToAvoid: [String]

    @Guide(description: "Why the cited evidence supports this finding.")
    var explanation: String
}

// MARK: - Read-only evidence tool
//
// Lets the model pull the full redacted text of a specific evidence item on
// demand. The prompt only carries truncated excerpts (budgeted), so without this
// the model is blind past the first few KB of any log. The tool is safe by
// construction: it reads already-collected, already-redacted local data and runs
// no commands — it cannot widen collection or reach the host.

@available(macOS 26.0, iOS 26.0, *)
struct ServerDoctorEvidenceTool: Tool {
    let name = "fetch_evidence_detail"
    let description = "Return the full redacted text of a specific collected evidence item by its id, when the truncated excerpt is not enough to judge a finding."

    let evidence: [ServerDoctorEvidence]

    @Generable
    struct Arguments {
        @Guide(description: "The evidence id to expand, taken from the allowed evidence id list.")
        var evidenceId: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let item = evidence.first(where: { $0.id == arguments.evidenceId }) else {
            return "No evidence found with id \(arguments.evidenceId)."
        }
        let source = item.redactedExcerpt.isEmpty ? item.excerpt : item.redactedExcerpt
        let bounded = String(source.prefix(6_000))
        return """
        Evidence \(item.id) — \(item.title)
        source: \(item.source)
        exit: \(item.exitStatus.map(String.init) ?? "n/a")
        ---
        \(bounded)
        """
    }
}

// MARK: - Provider

@available(macOS 26.0, iOS 26.0, *)
struct AppleFoundationModelsDoctorProvider: ServerDoctorLLMProviding {
    var metadata: ServerDoctorProviderMetadata {
        ServerDoctorProviderMetadata(
            providerName: "Apple Intelligence",
            modelName: "On-device",
            externalCall: false
        )
    }

    func preflight() async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw ServerDoctorLocalLLMError.preflight(Self.describe(reason))
        @unknown default:
            throw ServerDoctorLocalLLMError.preflight("Apple Intelligence is unavailable on this device.")
        }
    }

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse {
        guard case .available = SystemLanguageModel.default.availability else {
            try await preflight()
            return ServerDoctorLLMRawResponse(report: nil)
        }

        let userMessage = try ServerDoctorLocalOpenAIPromptBuilder.userMessage(for: prompt)
        let tool = ServerDoctorEvidenceTool(evidence: prompt.bundle.evidence)
        let session = LanguageModelSession(tools: [tool]) {
            ServerDoctorLocalOpenAIPromptBuilder.systemMessage
        }

        let response = try await session.respond(
            to: userMessage,
            generating: DoctorReportGen.self,
            options: GenerationOptions(temperature: 0.2)
        )

        let report = Self.makeReport(from: response.content, prompt: prompt)
        return ServerDoctorLLMRawResponse(report: report)
    }

    // MARK: Availability

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled. Turn it on in System Settings to use on-device diagnosis."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. Try again shortly."
        @unknown default:
            return "Apple Intelligence is currently unavailable."
        }
    }

    // MARK: Mapping

    private static func makeReport(
        from gen: DoctorReportGen,
        prompt: ServerDoctorPromptPayload
    ) -> ServerDoctorReport {
        let known = Set(prompt.bundle.evidence.map(\.id))
        let findings = gen.findings.compactMap { makeFinding(from: $0, known: known) }
        let severity = parseSeverity(gen.overallSeverity)
            ?? findings.map(\.severity).max()
            ?? .info
        let confidence = parseConfidence(gen.overallConfidence)
            ?? findings.map(\.confidence).first
            ?? .medium

        return ServerDoctorReport(
            hostLabel: prompt.bundle.hostLabel,
            reportTitle: clean(gen.reportTitle, max: 120) ?? "Server Doctor report",
            summary: clean(gen.summary, max: 700)
                ?? "No high-confidence issue was identified from the supplied read-only evidence.",
            overallSeverity: severity,
            overallConfidence: confidence,
            collectedAt: prompt.bundle.collectedAt,
            findings: findings,
            redaction: ServerDoctorRedactionSummary(preset: prompt.privacyPreset)
        )
    }

    private static func makeFinding(
        from gen: DoctorFindingGen,
        known: Set<String>
    ) -> ServerDoctorFinding? {
        let evidenceIds = uniqueNonEmpty(gen.evidenceIds).filter { known.contains($0) }
        guard !evidenceIds.isEmpty,
              let title = clean(gen.title, max: 160),
              let summary = clean(gen.summary, max: 700) else {
            return nil
        }

        let safeNextSteps = gen.safeNextSteps.compactMap { raw -> ServerDoctorSuggestedAction? in
            guard let text = clean(raw, max: 220),
                  !ServerDoctorReportValidator.isMutating(text) else {
                return nil
            }
            return ServerDoctorSuggestedAction(kind: .inspectEvidence, title: text)
        }

        return ServerDoctorFinding(
            id: clean(gen.id, max: 80) ?? UUID().uuidString,
            title: title,
            summary: summary,
            severity: parseSeverity(gen.severity) ?? .warning,
            confidence: parseConfidence(gen.confidence) ?? .medium,
            affectedSubsystem: clean(gen.affectedSubsystem, max: 120) ?? "Host",
            affectedService: clean(gen.affectedService, max: 120),
            evidenceIds: evidenceIds,
            safeNextSteps: safeNextSteps,
            unsafeActionsToAvoid: gen.unsafeActionsToAvoid.compactMap { clean($0, max: 180) },
            explanation: clean(gen.explanation, max: 1_200) ?? ""
        )
    }

    private static func clean(_ value: String, max: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max))
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func parseSeverity(_ value: String) -> ServerDoctorSeverity? {
        ServerDoctorSeverity(rawValue: value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseConfidence(_ value: String) -> ServerDoctorConfidence? {
        ServerDoctorConfidence(rawValue: value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif

// MARK: - SDK-independent availability probe
//
// Callable from non-`@available` code (the provider factory, settings UI). When
// the framework or OS is missing it reports the reason instead of crashing.
enum AppleFoundationModelsDoctorAvailability {
    enum Status: Equatable {
        case ready
        case unsupportedOS
        case frameworkUnavailable
        case unavailable(String)

        var isReady: Bool { self == .ready }

        var userMessage: String {
            switch self {
            case .ready:
                return "On-device model ready."
            case .unsupportedOS:
                return "Requires macOS 26 or iOS 26 or later."
            case .frameworkUnavailable:
                return "This build was not compiled with the Foundation Models framework."
            case .unavailable(let reason):
                return reason
            }
        }
    }

    static func current() -> Status {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .unavailable(AppleFoundationModelsDoctorProvider.describe(reason))
        @unknown default:
            return .unavailable("Apple Intelligence is currently unavailable.")
        }
        #else
        return .frameworkUnavailable
        #endif
    }
}
