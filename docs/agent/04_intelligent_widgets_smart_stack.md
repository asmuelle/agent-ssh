# 04. Intelligent Widgets & Siri Smart Stack Alerts

## Overview

Monitored server lists often suffer from warning fatigue. A simple dashboard with 50 indicators requires constant manual evaluation. With **Intelligent Widgets and Smart Stack Alerts**, `agent-ssh` translates system metrics into a high-level visual summary directly on the user’s home screen, desktop, or Apple Watch Smart Stack. 

Using Apple Intelligence to synthesize raw diagnostic values in a shared local app container, the widget changes its appearance to show a bold, readable header explaining *which* server needs attention and *what* safe next step is recommended, complete with dynamic progress metrics.

---

## Technical Architecture

The architecture uses a local database stored in an **App Group shared container** (to share data between the main App target and the Widget Extension target) and native **WidgetKit** timelines.

### WidgetKit & TimelineProvider Implementation

```swift
import WidgetKit
import SwiftUI
import Foundation

/// Defines the data model shared with the Widget extension.
struct ServerHealthWidgetEntry: TimelineEntry {
    let date: Date
    let totalMonitoredCount: Int
    let attentionRequiredCount: Int
    let topPriorityIncidentSummary: String // Synthesized on-device by the LLM
    let topPriorityServerName: String
    let severity: String // "critical", "warning", "nominal"
}

/// The timeline provider that handles updating the widget data.
struct ServerHealthTimelineProvider: TimelineProvider {
    typealias Entry = ServerHealthWidgetEntry

    func placeholder(in context: Context) -> ServerHealthWidgetEntry {
        ServerHealthWidgetEntry(
            date: Date(),
            totalMonitoredCount: 5,
            attentionRequiredCount: 0,
            topPriorityIncidentSummary: "All systems running smoothly.",
            topPriorityServerName: "N/A",
            severity: "nominal"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ServerHealthWidgetEntry) -> ()) {
        let entry = fetchLatestHealthEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServerHealthWidgetEntry>) -> ()) {
        let entry = fetchLatestHealthEntry()
        
        // Refresh every 15 minutes or when push alerts trigger an immediate reload
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func fetchLatestHealthEntry() -> ServerHealthWidgetEntry {
        // Reads from the shared AppGroup container (e.g. "group.com.mc-ssh.agent-ssh")
        guard let sharedDefaults = UserDefaults(suiteName: "group.com.mc-ssh.agent-ssh"),
              let rawSeverity = sharedDefaults.string(forKey: "widget_severity") else {
            return placeholder(in: .placeholder)
        }
        
        return ServerHealthWidgetEntry(
            date: Date(),
            totalMonitoredCount: sharedDefaults.integer(forKey: "widget_total_count"),
            attentionRequiredCount: sharedDefaults.integer(forKey: "widget_attention_count"),
            topPriorityIncidentSummary: sharedDefaults.string(forKey: "widget_top_summary") ?? "No details.",
            topPriorityServerName: sharedDefaults.string(forKey: "widget_top_server") ?? "",
            severity: rawSeverity
        )
    }
}
```

### SwiftUI Widget View Implementation

```swift
struct ServerHealthWidgetView: View {
    var entry: ServerHealthTimelineProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header showing count and alert level
            HStack {
                Image(systemName: "server.rack.status.badge.warning")
                    .foregroundColor(severityColor)
                    .font(.title2)
                Spacer()
                Text("\(entry.attentionRequiredCount)/\(entry.totalMonitoredCount) Warn")
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(severityBgColor)
                    .cornerRadius(8)
            }
            
            if entry.attentionRequiredCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.topPriorityServerName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    // The on-device LLM-synthesized summary
                    Text(entry.topPriorityIncidentSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemSmall ? 2 : 4)
                }
            } else {
                Text("All Systems Clean")
                    .font(.headline)
                Text("Your server infrastructure is performing within normal bounds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(UIColor.systemBackground)
        }
    }
    
    private var severityColor: Color {
        switch entry.severity.lowercased() {
        case "critical": return .red
        case "warning": return .orange
        default: return .green
        }
    }
    
    private var severityBgColor: Color {
        severityColor.opacity(0.15)
    }
}
```

---

## Native User Experience

1. **Intelligent Widget Families**:
   * **Small (Home Screen)**: Focuses strictly on the highest-priority server warning and its brief LLM description.
   * **Medium/Large (Desktop & iPad)**: Displays a split list—unhealthy servers on the left with dynamic graphs, and the on-device diagnosis summary plus safe next step deep-links on the right.
2. **Siri Smart Stack Support**: If a severe alert triggers (e.g., database connection spike), the widget actively pushes a high-priority timeline update. The system-level **Siri Smart Stack** on Apple Watch and iOS home screens automatically rotates the `agent-ssh` widget to the top of the stack, alerting the user immediately.

---

## Data Privacy & Guardrails

* **AppGroup Shared Sandbox**: The WidgetExtension relies strictly on reading pre-parsed, pre-redacted text models stored in the `group.com.mc-ssh.agent-ssh` defaults file. The widget process itself runs in an isolated sandbox and never makes network connections.
* **Redaction at Rest**: Diagnostic text stored in the shared folder is already redacted. If the widget is displayed on a locked iPad or iPhone, it displays a generalized summary to prevent exposing sensitive internal usernames or directory structures.

---

## Marketing & Positioning Strategy

### The Headline / Elevator Pitch
> *"Server monitoring at a glance. Smart widgets powered by Apple Intelligence, built directly for your home screen."*

### Feature Showcase Scenario (App Store Video Storyboard)
* **Visual**: A beautiful iOS 18 home screen with customized dark icons. A medium Midnight SSH widget sits at the top.
* **Action**: Suddenly, a red alert glows on the widget. The text changes dynamically: `[k8s-master-01] Docker is out of memory. 4 pods evicted. Tap to triage.`
* **Action**: The user long-presses the widget, showing that it’s part of their Apple Watch Smart Stack too. They tap it, opening the app straight into a read-only diagnostics checklist.
* **Voiceover**: *"Stay on top of server health without opening the app. Smart widgets translate raw technical errors into clear, actionable summaries on your home screen."*

### Developer Buzzwords & Messaging
* **Smart Stack Outage Alerts**: Dynamic widget visibility.
* **WidgetKit Infrastructure Tracking**: Beautiful glanceable states.
* **ANE-Generated Snippets**: Summarized content that fits compact screens beautifully.

### Competitive Edge (Why Competitors Can't Compete)
* **Termius**: Lacks native, dynamic widgets that leverage LLM summarization. Their widgets show basic static connections or simple connection buttons.
* **Our Edge**: By making the widget *alive* with Apple Intelligence summaries, `agent-ssh` turns standard iOS widgets into proactive infrastructure triage screens.
