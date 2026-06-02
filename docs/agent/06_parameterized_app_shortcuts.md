# 06. Parameterized App Shortcuts with Apple Intelligence

## Overview

Modern server management requires quick, integrated notification workflows. An alert is only useful if it reaches the right channels instantly. With **Parameterized App Shortcuts**, `agent-ssh` exposes deep, parameter-rich programmatic triggers directly to Apple's native **Shortcuts** app and the Apple Intelligence orchestrator. 

Developers can construct complex multi-app automations (e.g., *"If a server diagnostic returns Critical, format the LLM summary, post it to Slack, and log a ticket in Jira"*). Apple Intelligence parses the semantic parameters natively, enabling flexible, conversational, and automated infrastructure pipelines.

---

## Technical Architecture

We construct this using **App Intents with dynamic parameter resolution**. By defining dynamic options providers, the Shortcuts app can load the list of available server connections directly from our local Swift models at execution time.

### AppIntent with Parameter & Dynamic Query Integration

```swift
import AppIntents
import Foundation

/// Exposes a highly detailed, parameterized diagnostic intent to the system
@available(iOS 18.0, macOS 15.0, *)
struct DiagnoseServerParameterIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Diagnostic on Specific Server"
    
    // Conforming to assistant schemas lets Apple Intelligence understand the parameters semantically
    static var assistantSchemas: [AssistantSchema] {
        [.diagnostics]
    }
    
    // Dynamic parameter linking our indexed AppEntity
    @Parameter(title: "Target Server", description: "Select the server to scan.")
    var server: ServerEntity
    
    @Parameter(title: "Detail Level", default: .balanced, description: "Choose the diagnostic depth.")
    var detailLevel: DiagnosticScope
    
    enum DiagnosticScope: String, AppEnum {
        case minimal
        case balanced
        case comprehensive
        
        static var typeDisplayRepresentation: TypeDisplayRepresentation = "Diagnostic Depth"
        static var caseDisplayRepresentations: [DiagnosticScope: LocalizedStringResource] {
            [
                .minimal: "Fast check (Service status and Load only)",
                .balanced: "Standard (Checks memory, CPU, failed units, active logs)",
                .comprehensive: "Deep (Logs, configs, database lock states, package history)"
            ]
        }
    }
    
    // Returns a custom structured status type that the Shortcuts App can pass to other actions
    func perform() async throws -> some IntentResult & ReturnsValue<DiagnosticReportResult> {
        // 1. Establish secure FFI bridge and execute the designated collector profile
        let scope = matchFFIScope(detailLevel)
        let rawReport = try await BridgeManager.shared.diagnoseServer(id: server.id, scope: scope)
        
        // 2. Synthesize with local on-device LLM
        let localSynthesizer = try await LocalDiagnosticsSynthesizer()
        let report = try await localSynthesizer.synthesizeReport(
            hostContext: "Host: \(server.name), Scope: \(scope)",
            redactedEvidenceJson: rawReport.evidenceJson
        )
        
        // 3. Construct structured output
        let result = DiagnosticReportResult(
            serverName: server.name,
            overallStatus: report.overallSeverity == .critical ? "Unhealthy" : "Nominal",
            findingsCount: report.findings.count,
            plainTextSummary: report.summaryBriefing,
            safeNextStep: report.findings.first?.safeNextStepDescription ?? "No action required."
        )
        
        return .result(value: result)
    }
    
    private func matchFFIScope(_ scope: DiagnosticScope) -> String {
        switch scope {
        case .minimal: return "fast"
        case .comprehensive: return "deep"
        default: return "standard"
        }
    }
}

/// A structured result model that can be easily parsed by downstream Shortcut actions
@available(iOS 18.0, macOS 15.0, *)
struct DiagnosticReportResult: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Server Diagnostic Result"
    
    let id: UUID = UUID()
    let serverName: String
    let overallStatus: String
    let findingsCount: Int
    let plainTextSummary: String
    let safeNextStep: String
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "[\(serverName)] Diagnostic Result: \(overallStatus)",
            subtitle: "\(findingsCount) findings. \(plainTextSummary)"
        )
    }
    
    static var defaultQuery = ResultQuery()
}

@available(iOS 18.0, macOS 15.0, *)
struct ResultQuery: EntityQuery {
    func entities(for ids: [UUID]) async throws -> [DiagnosticReportResult] { [] }
}
```

### Flow Diagram

```mermaid
graph LR
    A[Shortcuts Trigger / Apple Intelligence event] --> B[Invoke DiagnoseServerParameterIntent]
    B --> C[Fetch selected ServerEntity from HostStore]
    C --> D[Run FFI Collector & Local LLM Synthesis]
    D --> E[Package DiagnosticReportResult Entity]
    E --> F[Pass output directly to Apple Shortcuts pipeline]
    F --> G[Downstream: Format Text -> Send to Slack / iMessage]
```

---

## Native User Experience

1. **Shortcuts App Integration**: The custom intent appears as a modular block inside the native macOS/iOS Shortcuts canvas. Users can drag and drop it, easily configuring the target server via a native dropdown and selecting variables from previous actions.
2. **Apple Intelligence Orchestration**: Because the parameter relies on system-wide assistant schemas, users don't even need to construct a visual shortcut block. They can ask Apple Intelligence in plain English: *"Run a comprehensive Midnight SSH diagnostic on my backup node and text the summary to Sarah."* The system-wide AI parses the parameters, invokes `DiagnoseServerParameterIntent` with the backup server entity, receives the text output, and routes it directly to the Messages app.

---

## Data Privacy & Guardrails

* **Explicit User Execution**: Dynamic parameters are fully visible. The user explicitly controls what server is selected and where the resulting data is sent.
* **Strict Sandboxing**: The data returned to Shortcuts is scoped strictly to the text summary and health results. Credentials, SSH keys, and unredacted configs are never exposed to the Shortcuts output buffer.

---

## Marketing & Positioning Strategy

### The Headline / Elevator Pitch
> *"Your server diagnostics, fully automated. Connect Server Doctor to Slack, Messages, and Jira in Apple Shortcuts."*

### Feature Showcase Scenario (App Store Video Storyboard)
* **Visual**: A developer opening the native Apple Shortcuts app on macOS.
* **Action**: They drag the **agent-ssh** `Run Diagnostic on Specific Server` action into a workflow.
* **Configuration**: They select `pg-primary-01` as the target, set depth to `Comprehensive`, and link the output to a **Slack** webhook action.
* **Outcome**: They save it as a desktop shortcut named *"Triage DB node"*. They trigger it, and in a second, a beautifully formatted Slack message appears in their team channel with a clean summary.
* **Voiceover**: *"Unleash automated triage. Create custom workflows that diagnose host health and route plain-English summaries to your team instantly, with no scripting required."*

### Developer Buzzwords & Messaging
* **Decoupled DevOps Pipelines**: Connect server status to consumer services.
* **Dynamic Entity Resolution**: Load servers directly inside the OS engine.
* **Natural Orchestration**: Trigger automation chains with Apple Intelligence.

### Competitive Edge (Why Competitors Can't Compete)
* **Termius**: Lacks rich, parameterized shortcuts that return structured custom entities. They only support opening direct terminal connections.
* **Our Edge**: By exposing fully structured, returnable `AppEntities` from our local on-device diagnostics pipeline, `agent-ssh` makes it possible to build complex, rich server-to-app automation pipelines without writing a single line of Python or Bash script.
