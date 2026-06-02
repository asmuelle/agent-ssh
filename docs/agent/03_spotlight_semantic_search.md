# 03. Spotlight Semantic Search for Server Findings

## Overview

Finding specific issues across multiple servers usually requires logging into each server individually, searching syslog, or navigating complex dashboard tabs. With **Spotlight Semantic Search**, `agent-ssh` leverages macOS and iOS's local semantic search index. By exposing server profiles and diagnostic findings as native **App Entities**, the OS indexes these records. 

A user can command Spotlight from their desktop or home screen (e.g., *"Spotlight search: database out of memory"*) and immediately see a direct reference to the affected server finding, without even opening the app first.

---

## Technical Architecture

To index our database of servers and active findings with the OS, we conform our data models to the `AppEntity` protocol under the `AppIntents` framework. This automatically makes the properties discoverable to both Spotlight and Siri.

### AppEntity Implementation

```swift
import AppIntents
import CoreSpotlight
import Foundation

/// Exposes individual server profiles as Spotlight-indexable entities.
@available(iOS 18.0, macOS 15.0, *)
struct ServerEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Monitored Server"
    
    let id: UUID
    let name: String
    let ipAddress: String
    let subsystemRole: String // e.g., "Postgres Primary", "Web Proxy"
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subsystemRole) • \(ipAddress)",
            image: DisplayRepresentation.Image(systemName: "server.rack")
        )
    }
    
    static var defaultQuery = ServerQuery()
}

/// Exposes specific active Server Doctor findings to Spotlight.
@available(iOS 18.0, macOS 15.0, *)
struct FindingEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Server Diagnostic Finding"
    
    let id: String // Finding UUID
    let title: String
    let summary: String
    let severity: String
    let affectedHostName: String
    
    var displayRepresentation: DisplayRepresentation {
        let image = matchSeverityImage(severity)
        return DisplayRepresentation(
            title: "[\(affectedHostName)] \(title)",
            subtitle: "\(summary)",
            image: DisplayRepresentation.Image(systemName: image)
        )
    }
    
    static var defaultQuery = FindingQuery()
    
    private func matchSeverityImage(_ sev: String) -> String {
        switch sev.lowercased() {
        case "critical", "high": return "exclamationmark.triangle.fill"
        case "warning": return "exclamationmark.circle"
        default: return "info.circle"
        }
    }
}

// Queries are called by the OS to resolve entities during Spotlight indexing & searches
@available(iOS 18.0, macOS 15.0, *)
struct FindingQuery: EntityQuery {
    func entities(for ids: [String]) async throws -> [FindingEntity] {
        // Fetch specific findings matching IDs from local SQLite/Store
        return try await LocalReportStore.shared.fetchFindingEntities(matchingIds: ids)
    }
    
    func suggestedEntities() async throws -> [FindingEntity] {
        // Return highly critical active findings to populate suggested results
        return try await LocalReportStore.shared.fetchActiveHighSeverityFindings()
    }
    
    /// Called when Spotlight performs a natural language search
    func entities(matching string: String) async throws -> [FindingEntity] {
        // Semantically filter findings in local DB based on string query
        return try await LocalReportStore.shared.searchFindings(query: string)
    }
}
```

### Flow Diagram

```mermaid
graph LR
    A[Host Collector detects issue] --> B[Server Doctor writes Diagnostic Report]
    B --> C[Local SQLite Database updated]
    C --> D[Update AppEntity spotlight indices]
    D --> E[CoreSpotlight indexes local entities]
    F[User opens Spotlight & types 'database error'] --> G[OS queries FindingQuery.entities matching string]
    G --> H[Spotlight surfaces [pg-prod-01] Postgres Lock Error]
    H --> I[User clicks -> App deep links directly to Finding Detail]
```

---

## Native User Experience

1. **Seamless Search Results**: Tapping `Cmd + Space` on a Mac or dragging down on iOS opens Spotlight. Typing search terms like *"nginx config"* or *"disk full"* displays a dedicated grouping for **agent-ssh** displaying the matching server and the specific file or finding.
2. **Rich Quick Look Previews**: Pressing `Space` over the search finding displays an interactive preview containing:
   * The severity level with dynamic HSL-tailored colored rings.
   * The plain-language synthesis summary.
   * A button to **"View Raw Logs"** which deep links the user directly into the terminal or log streaming panel inside the app.

---

## Data Privacy & Guardrails

* **Spotlight Sandboxing**: The `AppEntity` index is fully owned by the OS sandbox. No diagnostic text or server nicknames are transmitted to external servers.
* **Transient Index Expiry**: Set auto-expiration attributes on findings. If an issue is resolved or a diagnostic report is cleared by the user, the corresponding `FindingEntity` is immediately purged from the system Spotlight index to prevent outdated results.
* **Redacted Properties**: Properties indexed in Spotlight never contain unredacted secrets or credentials. Only titles, high-level summaries, and severities are exported to `CoreSpotlight`.

---

## Marketing & Positioning Strategy

### The Headline / Elevator Pitch
> *"Your servers, indexed by Spotlight. Triage production anomalies straight from your Mac's desktop search bar."*

### Feature Showcase Scenario (App Store Video Storyboard)
* **Visual**: A clean macOS desktop. The developer presses `Cmd + Space` to bring up the Spotlight Search prompt.
* **Action**: They type: *"certificates"*
* **Outcome**: Spotlight instantly lists a dynamic finding card from Midnight SSH: `[web-01] Let's Encrypt Expiring in 4 days`.
* **Action**: They press `Space` to inspect it, seeing the exact certificate paths and a deep link to check the renewal log.
* **Voiceover**: *"Don't hunt through terminal tabs. If there's an issue with your config, certificate, or disk space, finding it is as simple as searching your Mac."*

### Developer Buzzwords & Messaging
* **Spotlight Indexable Infrastructure**: Spotlight as a DevOps console.
* **System-Wide App Entities**: Seamless integration into the OS shell.
* **Command Bar Triage**: Rapid search-based productivity.

### Competitive Edge (Why Competitors Can't Compete)
* **Termius & Traditional SSH Clients**: Force you to open their heavy apps, choose a server, start a terminal session, and manually run search scripts to locate issues.
* **Our Edge**: By exposing findings as Spotlight-compatible `AppEntities`, `agent-ssh` lets the system handle search routing. You find out *what* server is broken and *why* in a fraction of a second, without launching a single SSH connection window manually.
