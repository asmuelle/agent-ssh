import Foundation
import AgentSshMacOS

struct ServerDoctorPromptPayload: Codable, Sendable {
    var bundle: ServerDoctorCollectionBundle
    var privacyPreset: ServerDoctorPrivacyPreset
}

struct ServerDoctorLLMRawResponse: Codable, Sendable {
    var report: ServerDoctorReport?
}

enum ServerDoctorLocalLLMError: Error, LocalizedError {
    case invalidEndpoint(String)
    case nonLocalEndpoint(String)
    case invalidPrompt
    case httpStatus(Int, String)
    case emptyResponse
    case invalidModelJSON
    case responseFormat(String)
    case serverMessage(String)
    case preflight(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid Server Doctor LLM endpoint: \(value)"
        case .nonLocalEndpoint(let value):
            return "Server Doctor local LLM endpoint must use localhost, 127.0.0.1, or ::1: \(value)"
        case .invalidPrompt:
            return "Server Doctor could not build the local LLM prompt."
        case .httpStatus(let status, let body):
            return "Local LLM request failed with HTTP \(status): \(body)"
        case .emptyResponse:
            return "Local LLM returned an empty response."
        case .invalidModelJSON:
            return "Local LLM did not return a usable Server Doctor JSON report."
        case .responseFormat(let snippet):
            return "Local LLM response was not OpenAI-compatible or Ollama chat JSON: \(snippet)"
        case .serverMessage(let message):
            return "Local LLM returned an error: \(message)"
        case .preflight(let message):
            return "Local LLM preflight failed: \(message)"
        }
    }
}

protocol ServerDoctorLLMProviding: Sendable {
    var metadata: ServerDoctorProviderMetadata { get }

    func preflight() async throws

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse
}

extension ServerDoctorLLMProviding {
    func preflight() async throws {}
}

struct DisabledServerDoctorLLMProvider: ServerDoctorLLMProviding {
    let metadata = ServerDoctorProviderMetadata.localHeuristics

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse {
        ServerDoctorLLMRawResponse(report: nil)
    }
}

struct MockServerDoctorLLMProvider: ServerDoctorLLMProviding {
    let metadata = ServerDoctorProviderMetadata(
        providerName: "Mock Server Doctor",
        modelName: "mock",
        externalCall: false
    )

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse {
        let redaction = ServerDoctorRedactionSummary(preset: prompt.privacyPreset)
        return ServerDoctorLLMRawResponse(
            report: ServerDoctorHeuristics.generateReport(
                bundle: prompt.bundle,
                redaction: redaction
            )
        )
    }
}

struct LocalOpenAICompatibleServerDoctorProvider: ServerDoctorLLMProviding {
    static let endpointEnvironmentKey = "MIDNIGHT_SSH_DOCTOR_LLM_ENDPOINT"
    static let modelEnvironmentKey = "MIDNIGHT_SSH_DOCTOR_LLM_MODEL"
    static let apiKeyEnvironmentKey = "MIDNIGHT_SSH_DOCTOR_LLM_API_KEY"
    static let timeoutEnvironmentKey = "MIDNIGHT_SSH_DOCTOR_LLM_TIMEOUT_SECONDS"
    static let defaultEndpoint = "http://127.0.0.1:11434/v1/chat/completions"

    let endpoint: URL
    let model: String
    private let apiKey: String?
    private let timeout: TimeInterval
    private var endpointKind: ServerDoctorLocalLLMEndpointKind {
        ServerDoctorLocalLLMEndpointKind(endpoint: endpoint)
    }

    var metadata: ServerDoctorProviderMetadata {
        ServerDoctorProviderMetadata(
            providerName: "Local LLM",
            modelName: model,
            externalCall: false
        )
    }

    init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        timeout: TimeInterval = 120
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOpenAICompatibleServerDoctorProvider? {
        guard let model = environment[modelEnvironmentKey]?.serverDoctorNonEmpty else {
            return nil
        }

        let endpointValue = environment[endpointEnvironmentKey]?.serverDoctorNonEmpty ?? defaultEndpoint
        guard let endpoint = URL(string: endpointValue), endpoint.scheme?.hasPrefix("http") == true else {
            return nil
        }
        guard endpoint.isServerDoctorLoopback else {
            return nil
        }

        let timeout = environment[timeoutEnvironmentKey]
            .flatMap { TimeInterval($0) }
            .map { max(10, min($0, 300)) }
            ?? 120

        return LocalOpenAICompatibleServerDoctorProvider(
            endpoint: endpoint,
            model: model,
            apiKey: environment[apiKeyEnvironmentKey]?.serverDoctorNonEmpty,
            timeout: timeout
        )
    }

    static func makeValidated(
        endpointValue: String,
        model: String,
        apiKey: String? = nil,
        timeout: TimeInterval = 120
    ) throws -> LocalOpenAICompatibleServerDoctorProvider {
        guard let endpoint = URL(string: endpointValue), endpoint.scheme?.hasPrefix("http") == true else {
            throw ServerDoctorLocalLLMError.invalidEndpoint(endpointValue)
        }
        guard endpoint.isServerDoctorLoopback else {
            throw ServerDoctorLocalLLMError.nonLocalEndpoint(endpointValue)
        }
        return LocalOpenAICompatibleServerDoctorProvider(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            timeout: timeout
        )
    }

    func generateReport(
        prompt: ServerDoctorPromptPayload
    ) async throws -> ServerDoctorLLMRawResponse {
        let userMessage = try ServerDoctorLocalOpenAIPromptBuilder.userMessage(for: prompt)
        let messages = [
            ServerDoctorLLMChatMessage(role: "system", content: ServerDoctorLocalOpenAIPromptBuilder.systemMessage),
            ServerDoctorLLMChatMessage(role: "user", content: userMessage)
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try requestBody(messages: messages)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerDoctorLocalLLMError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?
                .serverDoctorTrimmed(maxLength: 500)
                ?? ""
            throw ServerDoctorLocalLLMError.httpStatus(httpResponse.statusCode, snippet)
        }

        let content = try ServerDoctorLocalLLMResponseDecoder.decodeContent(from: data)

        let report = try ServerDoctorLocalOpenAIReportDecoder.decodeReport(
            from: content,
            prompt: prompt
        )
        return ServerDoctorLLMRawResponse(report: report)
    }

    func preflight() async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: min(timeout, 20))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let probe = "Return exactly this JSON and nothing else: {\"reportTitle\":\"preflight\",\"summary\":\"ok\",\"findings\":[]}"
        let messages = [
            ServerDoctorLLMChatMessage(
                role: "system",
                content: "You are a JSON-only test endpoint. Return only the requested JSON."
            ),
            ServerDoctorLLMChatMessage(role: "user", content: probe)
        ]
        request.httpBody = try requestBody(messages: messages, prompt: probe)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerDoctorLocalLLMError.preflight("No HTTP response from \(endpoint.absoluteString).")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?
                .serverDoctorTrimmed(maxLength: 700)
                ?? "<non-UTF8 response>"
            throw ServerDoctorLocalLLMError.preflight(
                "HTTP \(httpResponse.statusCode) from \(endpoint.absoluteString) for model '\(model)': \(snippet)"
            )
        }

        do {
            let content = try ServerDoctorLocalLLMResponseDecoder.decodeContent(from: data)
            guard content.contains("preflight") || content.contains("ok") || content.contains("{") else {
                throw ServerDoctorLocalLLMError.preflight(
                    "Endpoint responded, but the model did not return JSON-like content. Response: \(content.serverDoctorTrimmed(maxLength: 700))"
                )
            }
        } catch let error as ServerDoctorLocalLLMError {
            throw ServerDoctorLocalLLMError.preflight(error.localizedDescription)
        } catch {
            throw ServerDoctorLocalLLMError.preflight(error.localizedDescription)
        }
    }

    private func requestBody(messages: [ServerDoctorLLMChatMessage]) throws -> Data {
        try requestBody(
            messages: messages,
            prompt: messages.map(\.content).joined(separator: "\n\n")
        )
    }

    private func requestBody(messages: [ServerDoctorLLMChatMessage], prompt: String) throws -> Data {
        switch endpointKind {
        case .ollamaChat:
            return try JSONEncoder.serverDoctorLLM.encode(
                ServerDoctorOllamaChatRequest(
                    model: model,
                    messages: messages,
                    stream: false,
                    options: .init(temperature: 0.1)
                )
            )
        case .ollamaGenerate:
            return try JSONEncoder.serverDoctorLLM.encode(
                ServerDoctorOllamaGenerateRequest(
                    model: model,
                    prompt: prompt,
                    stream: false,
                    options: .init(temperature: 0.1)
                )
            )
        case .openAI:
            return try JSONEncoder.serverDoctorLLM.encode(
                ServerDoctorOpenAIChatRequest(
                    model: model,
                    messages: messages,
                    temperature: 0.1,
                    stream: false
                )
            )
        }
    }
}

private enum ServerDoctorLocalLLMEndpointKind {
    case openAI
    case ollamaChat
    case ollamaGenerate

    init(endpoint: URL) {
        if endpoint.path.hasSuffix("/api/chat") {
            self = .ollamaChat
        } else if endpoint.path.hasSuffix("/api/generate") {
            self = .ollamaGenerate
        } else {
            self = .openAI
        }
    }
}

private struct ServerDoctorLLMChatMessage: Codable {
    var role: String
    var content: String
}

private struct ServerDoctorOpenAIChatRequest: Encodable {
    var model: String
    var messages: [ServerDoctorLLMChatMessage]
    var temperature: Double
    var stream: Bool
}

private struct ServerDoctorOllamaChatRequest: Encodable {
    struct Options: Encodable {
        var temperature: Double
    }

    var model: String
    var messages: [ServerDoctorLLMChatMessage]
    var stream: Bool
    var options: Options
}

private struct ServerDoctorOllamaGenerateRequest: Encodable {
    struct Options: Encodable {
        var temperature: Double
    }

    var model: String
    var prompt: String
    var stream: Bool
    var options: Options
}

private struct ServerDoctorOpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message
    }

    var choices: [Choice]
}

private struct ServerDoctorOllamaChatResponse: Decodable {
    struct Message: Decodable {
        var content: String?
    }

    var message: Message?
    var response: String?
    var done: Bool?
}

private struct ServerDoctorLocalLLMErrorEnvelope: Decodable {
    struct ErrorObject: Decodable {
        var message: String?
    }

    var message: String?

    enum CodingKeys: String, CodingKey {
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try? container.decode(String.self, forKey: .error) {
            self.message = message
        } else if let object = try? container.decode(ErrorObject.self, forKey: .error) {
            message = object.message
        } else {
            message = nil
        }
    }
}

enum ServerDoctorLocalLLMResponseDecoder {
    static func decodeContent(from data: Data) throws -> String {
        if let error = try? JSONDecoder.serverDoctorLLM.decode(ServerDoctorLocalLLMErrorEnvelope.self, from: data),
           let message = error.message?.serverDoctorNonEmpty {
            throw ServerDoctorLocalLLMError.serverMessage(message)
        }

        if let response = try? JSONDecoder.serverDoctorLLM.decode(ServerDoctorOpenAIChatResponse.self, from: data),
           let content = response.choices.first?.message.content?.serverDoctorNonEmpty {
            return content
        }

        if let response = try? JSONDecoder.serverDoctorLLM.decode(ServerDoctorOllamaChatResponse.self, from: data),
           let content = (response.message?.content ?? response.response).serverDoctorNonEmpty {
            return content
        }

        if let streamedContent = decodeOllamaStream(from: data)?.serverDoctorNonEmpty {
            return streamedContent
        }

        let snippet = String(data: data, encoding: .utf8)?
            .serverDoctorTrimmed(maxLength: 500)
            ?? "<non-UTF8 response>"
        throw ServerDoctorLocalLLMError.responseFormat(snippet)
    }

    private static func decodeOllamaStream(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let chunks = text.split(whereSeparator: \.isNewline)
        guard !chunks.isEmpty else { return nil }

        var content = ""
        var decodedAnyChunk = false
        for chunk in chunks {
            guard let chunkData = String(chunk).data(using: .utf8),
                  let response = try? JSONDecoder.serverDoctorLLM.decode(
                    ServerDoctorOllamaChatResponse.self,
                    from: chunkData
                  ) else {
                continue
            }
            decodedAnyChunk = true
            content += response.message?.content ?? response.response ?? ""
        }

        return decodedAnyChunk ? content : nil
    }
}

enum ServerDoctorLocalOpenAIPromptBuilder {
    static let systemMessage = """
    You are Read-only Server Doctor inside a macOS SSH client. Analyze only the supplied redacted evidence. Do not invent files, commands, services, hostnames, users, or evidence ids.

    Return JSON only, with no Markdown. Every finding must cite one or more evidenceIds from the supplied allowedEvidenceIds list. Safe next steps must be read-only inspection steps only. Never recommend restarts, reloads, writes, deletes, package installs, chmod, chown, kill, or other mutating actions.

    Required JSON shape:
    {
      "reportTitle": "short title",
      "summary": "short operational summary",
      "overallSeverity": "critical|high|warning|info|unknown",
      "overallConfidence": "high|medium|low",
      "findings": [
        {
          "id": "stable-short-id",
          "title": "finding title",
          "summary": "what appears wrong",
          "severity": "critical|high|warning|info|unknown",
          "confidence": "high|medium|low",
          "affectedSubsystem": "subsystem",
          "affectedService": "optional service name or null",
          "evidenceIds": ["evidence-id"],
          "safeNextSteps": [
            { "kind": "inspectEvidence|openLog|openConfig|runReadOnlyFollowup", "title": "read-only action", "target": "optional evidence id or command" }
          ],
          "unsafeActionsToAvoid": ["mutating action to avoid until the cause is confirmed"],
          "explanation": "why the cited evidence supports the finding"
        }
      ],
      "questionsToResolve": ["optional missing context"],
      "suggestedReadOnlyFollowups": [
        { "kind": "runReadOnlyFollowup", "title": "read-only command or inspection", "target": "optional command" }
      ]
    }
    """

    static func userMessage(for prompt: ServerDoctorPromptPayload) throws -> String {
        let document = ServerDoctorLLMPromptDocument(prompt: prompt)
        let data = try JSONEncoder.serverDoctorLLMPrompt.encode(document)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ServerDoctorLocalLLMError.invalidPrompt
        }
        return """
        Analyze this redacted read-only server collection and return the required JSON report.

        \(json)
        """
    }
}

private struct ServerDoctorLLMPromptDocument: Encodable {
    struct Command: Encodable {
        var id: String
        var profile: String
        var displayName: String
        var command: String
        var exitStatus: Int?
        var truncated: Bool
        var permissionLimited: Bool
    }

    struct Evidence: Encodable {
        var id: String
        var kind: String
        var title: String
        var source: String
        var exitStatus: Int?
        var excerpt: String
        var truncated: Bool
        var truncatedForPrompt: Bool
        var permissionLimited: Bool
        var lineCount: Int
    }

    var task = "read_only_server_diagnosis"
    var privacyPreset: String
    var hostLabel: String
    var collectedAt: String
    var allowedEvidenceIds: [String]
    var commands: [Command]
    var evidence: [Evidence]
    var warnings: [String]

    init(prompt: ServerDoctorPromptPayload) {
        let formatter = ISO8601DateFormatter()
        let evidenceBudget = ServerDoctorEvidencePromptBudget(maxTotalCharacters: 40_000)

        privacyPreset = prompt.privacyPreset.rawValue
        hostLabel = prompt.bundle.hostLabel
        collectedAt = formatter.string(from: prompt.bundle.collectedAt)
        allowedEvidenceIds = prompt.bundle.evidence.map(\.id)
        commands = prompt.bundle.commandAudits.map {
            Command(
                id: $0.id,
                profile: $0.profile.rawValue,
                displayName: $0.displayName,
                command: $0.command,
                exitStatus: $0.exitStatus,
                truncated: $0.truncated,
                permissionLimited: $0.permissionLimited
            )
        }
        evidence = evidenceBudget.trim(prompt.bundle.evidence).map {
            Evidence(
                id: $0.source.id,
                kind: $0.source.kind.rawValue,
                title: $0.source.title,
                source: $0.source.source,
                exitStatus: $0.source.exitStatus,
                excerpt: $0.excerpt,
                truncated: $0.source.truncated,
                truncatedForPrompt: $0.truncatedForPrompt,
                permissionLimited: $0.source.permissionLimited,
                lineCount: $0.source.lineCount
            )
        }
        warnings = prompt.bundle.warnings.map(\.message)
    }
}

private struct ServerDoctorEvidencePromptBudget {
    struct TrimmedEvidence {
        var source: ServerDoctorEvidence
        var excerpt: String
        var truncatedForPrompt: Bool
    }

    var maxTotalCharacters: Int
    private let maxCharactersPerEvidence = 8_000

    func trim(_ evidence: [ServerDoctorEvidence]) -> [TrimmedEvidence] {
        var remaining = maxTotalCharacters
        var trimmed: [TrimmedEvidence] = []

        for item in evidence where remaining > 0 {
            let sourceText = item.redactedExcerpt.isEmpty ? item.excerpt : item.redactedExcerpt
            let limit = min(maxCharactersPerEvidence, remaining)
            let excerpt = String(sourceText.prefix(limit))
            remaining -= excerpt.count
            trimmed.append(
                TrimmedEvidence(
                    source: item,
                    excerpt: excerpt,
                    truncatedForPrompt: sourceText.count > excerpt.count
                )
            )
        }

        return trimmed
    }
}

enum ServerDoctorLocalOpenAIReportDecoder {
    static func decodeReport(
        from content: String,
        prompt: ServerDoctorPromptPayload
    ) throws -> ServerDoctorReport {
        let json = try extractJSONObject(from: content)
        guard let data = json.data(using: .utf8) else {
            throw ServerDoctorLocalLLMError.invalidModelJSON
        }

        let envelope = try JSONDecoder.serverDoctorLLM.decode(
            ServerDoctorLLMReportEnvelope.self,
            from: data
        )
        return makeReport(from: envelope.report, prompt: prompt)
    }

    private static func extractJSONObject(from content: String) throws -> String {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            trimmed = lines
                .dropFirst()
                .dropLast(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" ? 1 : 0)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            throw ServerDoctorLocalLLMError.invalidModelJSON
        }

        return String(trimmed[start...end])
    }

    private static func makeReport(
        from dto: ServerDoctorLLMReportDTO,
        prompt: ServerDoctorPromptPayload
    ) -> ServerDoctorReport {
        let knownEvidenceIds = Set(prompt.bundle.evidence.map(\.id))
        let findings = (dto.findings ?? []).compactMap {
            makeFinding(from: $0, knownEvidenceIds: knownEvidenceIds)
        }
        let severity = dto.overallSeverity.serverDoctorSeverity
            ?? findings.map(\.severity).max()
            ?? .info
        let confidence = dto.overallConfidence.serverDoctorConfidence
            ?? findings.map(\.confidence).first
            ?? .medium

        return ServerDoctorReport(
            hostLabel: prompt.bundle.hostLabel,
            reportTitle: dto.reportTitle.serverDoctorClean(maxLength: 120)
                ?? "Server Doctor report",
            summary: dto.summary.serverDoctorClean(maxLength: 700)
                ?? "No high-confidence issue was identified from the supplied read-only evidence.",
            overallSeverity: severity,
            overallConfidence: confidence,
            collectedAt: prompt.bundle.collectedAt,
            findings: findings,
            questionsToResolve: (dto.questionsToResolve ?? [])
                .compactMap { $0.serverDoctorClean(maxLength: 240) },
            suggestedReadOnlyFollowups: (dto.suggestedReadOnlyFollowups ?? [])
                .compactMap(makeAction),
            redaction: ServerDoctorRedactionSummary(preset: prompt.privacyPreset)
        )
    }

    private static func makeFinding(
        from dto: ServerDoctorLLMFindingDTO,
        knownEvidenceIds: Set<String>
    ) -> ServerDoctorFinding? {
        let evidenceIds = dto.evidenceIds.serverDoctorUniqueValues()
            .filter { knownEvidenceIds.contains($0) }
        guard !evidenceIds.isEmpty else { return nil }
        guard let title = dto.title.serverDoctorClean(maxLength: 160),
              let summary = dto.summary.serverDoctorClean(maxLength: 700) else {
            return nil
        }

        return ServerDoctorFinding(
            id: dto.id.serverDoctorClean(maxLength: 80) ?? UUID().uuidString,
            title: title,
            summary: summary,
            severity: dto.severity.serverDoctorSeverity ?? .warning,
            confidence: dto.confidence.serverDoctorConfidence ?? .medium,
            affectedSubsystem: dto.affectedSubsystem.serverDoctorClean(maxLength: 120) ?? "Host",
            affectedService: dto.affectedService.serverDoctorClean(maxLength: 120),
            evidenceIds: evidenceIds,
            safeNextSteps: (dto.safeNextSteps ?? []).compactMap(makeAction),
            unsafeActionsToAvoid: (dto.unsafeActionsToAvoid ?? [])
                .compactMap { $0.serverDoctorClean(maxLength: 180) },
            explanation: dto.explanation.serverDoctorClean(maxLength: 1_200) ?? ""
        )
    }

    private static func makeAction(
        from dto: ServerDoctorLLMActionDTO
    ) -> ServerDoctorSuggestedAction? {
        guard let title = dto.title.serverDoctorClean(maxLength: 220),
              !ServerDoctorReportValidator.isMutating(title) else {
            return nil
        }
        let target = dto.target.serverDoctorClean(maxLength: 240)
        if let target, ServerDoctorReportValidator.isMutating(target) {
            return nil
        }

        return ServerDoctorSuggestedAction(
            id: dto.id.serverDoctorClean(maxLength: 80) ?? UUID().uuidString,
            kind: dto.kind.serverDoctorActionKind ?? .inspectEvidence,
            title: title,
            target: target
        )
    }
}

private struct ServerDoctorLLMReportEnvelope: Decodable {
    var report: ServerDoctorLLMReportDTO

    enum CodingKeys: String, CodingKey {
        case report
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let report = try? container.decode(ServerDoctorLLMReportDTO.self, forKey: .report) {
            self.report = report
            return
        }
        report = try ServerDoctorLLMReportDTO(from: decoder)
    }
}

private struct ServerDoctorLLMReportDTO: Decodable {
    var reportTitle: String?
    var summary: String?
    var overallSeverity: String?
    var overallConfidence: String?
    var findings: [ServerDoctorLLMFindingDTO]?
    var questionsToResolve: [String]?
    var suggestedReadOnlyFollowups: [ServerDoctorLLMActionDTO]?
}

private struct ServerDoctorLLMFindingDTO: Decodable {
    var id: String?
    var title: String?
    var summary: String?
    var severity: String?
    var confidence: String?
    var affectedSubsystem: String?
    var affectedService: String?
    var evidenceIds: [String]
    var safeNextSteps: [ServerDoctorLLMActionDTO]?
    var unsafeActionsToAvoid: [String]?
    var explanation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case severity
        case confidence
        case affectedSubsystem
        case affectedService
        case evidenceIds
        case safeNextSteps
        case unsafeActionsToAvoid
        case explanation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
        affectedSubsystem = try container.decodeIfPresent(String.self, forKey: .affectedSubsystem)
        affectedService = try container.decodeIfPresent(String.self, forKey: .affectedService)
        evidenceIds = (try? container.decodeIfPresent([String].self, forKey: .evidenceIds)) ?? []
        safeNextSteps = try container.decodeIfPresent([ServerDoctorLLMActionDTO].self, forKey: .safeNextSteps)
        unsafeActionsToAvoid = try container.decodeIfPresent([String].self, forKey: .unsafeActionsToAvoid)
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
    }
}

private struct ServerDoctorLLMActionDTO: Decodable {
    var id: String?
    var kind: String?
    var title: String?
    var target: String?
}

private extension JSONEncoder {
    static var serverDoctorLLM: JSONEncoder {
        JSONEncoder()
    }

    static var serverDoctorLLMPrompt: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var serverDoctorLLM: JSONDecoder {
        JSONDecoder()
    }
}

private extension URL {
    var isServerDoctorLoopback: Bool {
        guard let host = self.host?.lowercased() else { return false }
        return host == "localhost"
            || host == "::1"
            || host == "0:0:0:0:0:0:0:1"
            || host == "127.0.0.1"
            || host.hasPrefix("127.")
    }
}

private extension Optional where Wrapped == String {
    var serverDoctorNonEmpty: String? {
        self?.serverDoctorNonEmpty
    }

    func serverDoctorClean(maxLength: Int) -> String? {
        self?.serverDoctorClean(maxLength: maxLength)
    }

    var serverDoctorSeverity: ServerDoctorSeverity? {
        self?.serverDoctorSeverity
    }

    var serverDoctorConfidence: ServerDoctorConfidence? {
        self?.serverDoctorConfidence
    }

    var serverDoctorActionKind: ServerDoctorSuggestedActionKind? {
        self?.serverDoctorActionKind
    }
}

private extension String {
    var serverDoctorNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func serverDoctorTrimmed(maxLength: Int) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength))
    }

    func serverDoctorClean(maxLength: Int) -> String? {
        serverDoctorTrimmed(maxLength: maxLength).serverDoctorNonEmpty
    }

    var serverDoctorSeverity: ServerDoctorSeverity? {
        ServerDoctorSeverity(rawValue: lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var serverDoctorConfidence: ServerDoctorConfidence? {
        ServerDoctorConfidence(rawValue: lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var serverDoctorActionKind: ServerDoctorSuggestedActionKind? {
        ServerDoctorSuggestedActionKind(rawValue: trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension Array where Element == String {
    func serverDoctorUniqueValues() -> [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for item in self {
            guard let value = item.serverDoctorNonEmpty, !seen.contains(value) else {
                continue
            }
            seen.insert(value)
            values.append(value)
        }
        return values
    }
}

