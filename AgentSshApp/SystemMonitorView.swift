import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

struct HostHealthIssue: Identifiable, Equatable {
    enum Severity: Int, Equatable {
        case warning
        case critical

        var color: Color {
            switch self {
            case .warning: return MidnightMacDesign.StatusTone.warning.color
            case .critical: return MidnightMacDesign.StatusTone.critical.color
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let severity: Severity
}

/// Log health of one user-monitored systemd unit, sampled from its
/// recent journal by the hygiene probe. Uses the same server-side
/// classifier as `MonitoredSystemdServicesPane`, so the counts in a
/// triage issue match the badges inside the Services pane.
struct HygieneServiceLogHealth: Equatable {
    let unit: String
    let activeState: String
    let journalErrors: Int
    let journalWarnings: Int
}

/// Result of the slow "hygiene" probe: service, container, and journal
/// problems that the 3-second stats poll can't see.
struct HygieneSnapshot: Equatable {
    /// Names of systemd units in the failed state (capped server-side).
    let failedUnits: [String]
    /// "name (status)" for containers that are unhealthy or restarting.
    let dockerProblems: [String]
    /// Classified journal issue counts for the last 15 minutes.
    let journalErrors: Int
    let journalWarnings: Int
    /// Per-monitored-unit journal health (empty when the profile
    /// monitors no services).
    var serviceLogs: [HygieneServiceLogHealth] = []
}

struct HostHealthSnapshot: Identifiable, Equatable {
    let id: String
    let hostName: String
    let issues: [HostHealthIssue]
}

/// Polls host stats through `BridgeManager` every few seconds for the active
/// connection and renders CPU / memory / per-mount disk / uptime / load.
///
/// **Multi-OS**: the Rust side runs `uname -s` once per connection
/// (cached) and routes to the matching parser. Linux (`/proc`) and
/// macOS (`top`/`vm_stat`/`sysctl`/`df -k -P`) are supported; BSD /
/// Solaris hosts surface as `MonitorError.Unsupported` and we render
/// a friendly placeholder instead of error spam.
///
/// The polling Task is bound to the view's lifetime via `.task` —
/// switching tabs or disconnecting tears it down automatically.
struct SystemMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    var profileId: String? = nil
    var sshPort: UInt16? = nil
    var profile: ConnectionProfile? = nil
    var connectionStatus: TerminalConnectionStatus? = nil
    var isActive: Bool = true
    /// Feed `AgentTriageStore` instead of rendering: draw nothing,
    /// additionally run the hygiene probe, and publish a
    /// `HostHealthSnapshot` through `onHealthChange` after every poll.
    /// Used by `AgentTriagePollers`, which needs the data pipeline for
    /// every connected host but no UI. Without this, "hidden" monitors
    /// at `opacity(0)` still re-render their Swift Charts on every
    /// poll, which is enough main-thread layout work per host to make
    /// the whole app feel sluggish.
    var isTriageFeed = false
    /// Stable id stamped on published snapshots; defaults to the
    /// connection id.
    var snapshotId: String? = nil
    var onHealthChange: ((HostHealthSnapshot) -> Void)? = nil

    @State var stats: FfiSystemStats?
    @State var error: String?
    @State var ufwSummary = UFWProtectionSummary.loading
    /// Latest hygiene-probe result; nil until the first probe lands.
    @State var hygiene: HygieneSnapshot?
    /// Set when the host's OS isn't supported. Renders a stable
    /// placeholder so we don't spam the user with parse errors on
    /// every poll. Reset on connection change.
    @State var unsupportedOs: String?
    /// Sliding window of recent samples for the CPU / memory trend
    /// charts. Capped at `maxHistory` — older samples are dropped at
    /// each append. Reset on `connectionId` change so a switch between
    /// hosts doesn't render misleading lines that span both.
    @State var history: [StatSample] = []
    @State var lastConnectionId: String?
    @State var drillDown: MonitorDrillDown?
    @State var serviceModal: ServiceModalKind?
    @State var showingConfidence = false
    /// Distro / kernel / arch summary shown under the connection label.
    /// `nil` until the probe finishes; reset on `connectionId` change.
    @State var osInfo: String?

    let logger = Logger(subsystem: "com.mc-ssh", category: "monitor")
    static let pollInterval: UInt64 = 3_000_000_000  // 3 s
    static let ufwPollInterval: UInt64 = 30_000_000_000  // 30 s
    /// Hygiene probe (failed services / docker / journal) — slow
    /// cadence: one combined SSH command per minute per host.
    static let hygienePollInterval: UInt64 = 60_000_000_000  // 60 s
    /// Journal errors in the probe window below this stay out of
    /// triage — a lone repeated line shouldn't paint the fleet.
    static let journalErrorThreshold = 3
    /// Monitored-service log thresholds: any error surfaces a warning
    /// chip; this many escalate to critical. Warnings alone need a
    /// real pile before they surface — chatty services are common.
    static let serviceLogErrorsCritical = 25
    static let serviceLogWarningsThreshold = 50
    /// 60 × 3s = 3 minutes of trailing history per chart.
    static let maxHistory = 60

    /// One CPU/memory snapshot for the trend charts.
    struct StatSample: Identifiable {
        let id = UUID()
        let timestamp: Date
        let cpuPercent: Double
        /// Memory utilisation 0..100 — derived from used / total at
        /// sample time so the chart's Y axis aligns with the linear
        /// progress bar above it.
        let memoryPercent: Double
    }

    var body: some View {
        visibleBody
            .task(id: pollTaskKey) {
            guard isActive else { return }
            await pollLoop()
        }
        .task(id: ufwPollTaskKey) {
            guard isActive, let connectionId else {
                ufwSummary = connectionId == nil
                    ? UFWProtectionSummary(
                        level: .unavailable,
                        statusText: "No connection",
                        extraOpenRules: [],
                        error: nil
                    )
                    : .loading
                return
            }
            await ufwPollLoop(connectionId: connectionId)
        }
        .task(id: connectionId ?? "none") {
            osInfo = nil
            guard isActive, connectionId != nil else { return }
            await loadOsInfo()
        }
        .task(id: hygienePollTaskKey) {
            hygiene = nil
            guard isActive, isTriageFeed, let connectionId else { return }
            await hygienePollLoop(connectionId: connectionId)
        }
        .sheet(item: $drillDown) { item in
            MonitorDrillDownSheet(
                connectionId: connectionId,
                drillDown: item,
                sshPort: sshPort,
                hostLabel: connectionLabel
            )
        }
        .sheet(item: $serviceModal) { kind in
            ServiceModalSheet(
                kind: kind,
                connectionId: connectionId,
                profileId: profileId,
                connectionLabel: connectionLabel
            )
        }
        .sheet(isPresented: $showingConfidence) {
            if let profile {
                ConnectionConfidenceSheet(profile: profile, status: connectionStatus)
            }
        }
        .onAppear {
            publishHealthSnapshot()
        }
        .onChange(of: connectionStatus) {
            publishHealthSnapshot()
        }
    }

    /// The inspector monitor, or — as a triage feed — an empty anchor
    /// that exists only to host the polling `.task`s above. Keeping the
    /// branch *inside* the body (rather than at the caller) means the
    /// poll loops and identity keys are exactly the same in both modes.
    @ViewBuilder
    var visibleBody: some View {
        if isTriageFeed {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var pollTaskKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    var ufwPollTaskKey: String {
        "\(connectionId ?? "none"):\(sshPort.map { String($0) } ?? "default"):\(isActive)"
    }

    var hygienePollTaskKey: String {
        "\(connectionId ?? "none"):\(isActive):\(isTriageFeed)"
    }

}
