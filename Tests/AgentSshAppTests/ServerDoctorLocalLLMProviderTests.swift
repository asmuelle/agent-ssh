import XCTest
import AgentSshMacOS
@testable import AgentSshApp

final class ServerDoctorLocalLLMProviderTests: XCTestCase {
    func testEnvironmentProviderDefaultsToOllamaEndpoint() {
        let provider = LocalOpenAICompatibleServerDoctorProvider.fromEnvironment([
            LocalOpenAICompatibleServerDoctorProvider.modelEnvironmentKey: "gemma4"
        ])

        XCTAssertEqual(provider?.endpoint.absoluteString, LocalOpenAICompatibleServerDoctorProvider.defaultEndpoint)
        XCTAssertEqual(provider?.model, "gemma4")
        XCTAssertEqual(provider?.metadata.providerName, "Local LLM")
        XCTAssertFalse(provider?.metadata.externalCall ?? true)
    }

    func testEnvironmentProviderRejectsRemoteEndpoint() {
        let provider = LocalOpenAICompatibleServerDoctorProvider.fromEnvironment([
            LocalOpenAICompatibleServerDoctorProvider.modelEnvironmentKey: "gemma4",
            LocalOpenAICompatibleServerDoctorProvider.endpointEnvironmentKey: "https://example.com/v1/chat/completions"
        ])

        XCTAssertNil(provider)
    }

    func testDecoderAcceptsFencedJSONAndFiltersUnsafeModelDetails() throws {
        let prompt = ServerDoctorPromptPayload(
            bundle: sampleBundle(),
            privacyPreset: .balanced
        )
        let response = """
        ```json
        {
          "reportTitle": "nginx certificate issue",
          "summary": "nginx cannot load a configured certificate.",
          "overallSeverity": "high",
          "overallConfidence": "high",
          "findings": [
            {
              "id": "nginx-cert",
              "title": "nginx certificate is missing",
              "summary": "The nginx config test reports that the configured certificate file is missing.",
              "severity": "high",
              "confidence": "high",
              "affectedSubsystem": "nginx",
              "affectedService": "nginx",
              "evidenceIds": ["evidence-nginx", "missing-evidence"],
              "safeNextSteps": [
                {
                  "kind": "inspectEvidence",
                  "title": "Review the nginx config test output",
                  "target": "evidence-nginx"
                },
                {
                  "kind": "runReadOnlyFollowup",
                  "title": "restart nginx"
                }
              ],
              "unsafeActionsToAvoid": ["restart nginx until the certificate path is confirmed"],
              "explanation": "The cited nginx -t evidence contains BIO_new_file() failed for the certificate path."
            }
          ],
          "questionsToResolve": [],
          "suggestedReadOnlyFollowups": []
        }
        ```
        """

        let report = try ServerDoctorLocalOpenAIReportDecoder.decodeReport(
            from: response,
            prompt: prompt
        )

        XCTAssertEqual(report.reportTitle, "nginx certificate issue")
        XCTAssertEqual(report.overallSeverity, .high)
        XCTAssertEqual(report.findings.first?.evidenceIds, ["evidence-nginx"])
        XCTAssertEqual(report.findings.first?.safeNextSteps.map(\.title), ["Review the nginx config test output"])
    }

    func testResponseDecoderAcceptsOllamaNativeChatResponse() throws {
        let payload = """
        {
          "model": "gemma4",
          "message": {
            "role": "assistant",
            "content": "{\\"reportTitle\\":\\"ok\\",\\"summary\\":\\"ok\\",\\"findings\\":[]}"
          },
          "done": true
        }
        """

        let content = try ServerDoctorLocalLLMResponseDecoder.decodeContent(from: Data(payload.utf8))

        XCTAssertTrue(content.contains(#""reportTitle":"ok""#))
    }

    func testResponseDecoderReportsUnexpectedBodySnippet() {
        let payload = "<html>not a chat completion</html>"

        XCTAssertThrowsError(
            try ServerDoctorLocalLLMResponseDecoder.decodeContent(from: Data(payload.utf8))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not OpenAI-compatible or Ollama chat JSON"))
            XCTAssertTrue(error.localizedDescription.contains("not a chat completion"))
        }
    }

    func testReportGeneratorFallsBackWhenModelOnlyCitesMissingEvidence() async {
        let generated = await ServerDoctorReportGenerator.generate(
            bundle: sampleBundle(),
            privacyPreset: .balanced,
            provider: MissingEvidenceProvider()
        )

        XCTAssertEqual(generated.report.provider, .localHeuristics)
        XCTAssertEqual(generated.report.findings.first?.title, "nginx references a missing certificate")
        XCTAssertTrue(generated.validation.isValid)
    }
}

private struct MissingEvidenceProvider: ServerDoctorLLMProviding {
    let metadata = ServerDoctorProviderMetadata(
        providerName: "Broken Local LLM",
        modelName: "broken",
        externalCall: false
    )

    func generateReport(prompt: ServerDoctorPromptPayload) async throws -> ServerDoctorLLMRawResponse {
        let report = ServerDoctorReport(
            hostLabel: prompt.bundle.hostLabel,
            reportTitle: "Bad model report",
            summary: "This model report cites evidence that is not in the bundle.",
            overallSeverity: .high,
            overallConfidence: .high,
            collectedAt: prompt.bundle.collectedAt,
            findings: [
                ServerDoctorFinding(
                    title: "Uncited issue",
                    summary: "This should not survive validation.",
                    severity: .high,
                    confidence: .high,
                    affectedSubsystem: "nginx",
                    evidenceIds: ["missing-evidence"]
                )
            ],
            redaction: ServerDoctorRedactionSummary(preset: prompt.privacyPreset)
        )
        return ServerDoctorLLMRawResponse(report: report)
    }
}

private func sampleBundle() -> ServerDoctorCollectionBundle {
    let evidence = ServerDoctorEvidence(
        id: "evidence-nginx",
        kind: .commandOutput,
        title: "nginx config test",
        source: "nginx -t 2>&1",
        collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        exitStatus: 1,
        excerpt: #"cannot load certificate "/etc/letsencrypt/live/app/fullchain.pem": BIO_new_file() failed (No such file)"#,
        rawOutput: #"cannot load certificate "/etc/letsencrypt/live/app/fullchain.pem": BIO_new_file() failed (No such file)"#,
        rawRef: "doctor://sample/evidence-nginx",
        byteCount: 112,
        lineCount: 1,
        truncated: false,
        permissionLimited: false
    )

    return ServerDoctorCollectionBundle(
        id: "bundle",
        hostLabel: "web",
        collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        profiles: [.nginx],
        commandAudits: [
            ServerDoctorCommandAudit(
                id: "audit-nginx",
                collectorId: "nginx-test",
                profile: .nginx,
                displayName: "nginx config test",
                command: "nginx -t 2>&1",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationMs: 45,
                exitStatus: 1,
                stdoutBytes: 0,
                stderrBytes: 112,
                truncated: false,
                permissionLimited: false
            )
        ],
        evidence: [evidence]
    )
}
