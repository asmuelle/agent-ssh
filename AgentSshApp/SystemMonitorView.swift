import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

struct DashboardHealthIssue: Identifiable, Equatable {
    enum Severity: Int, Equatable {
        case warning
        case critical

        var color: Color {
            switch self {
            case .warning: return .orange
            case .critical: return .red
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let icon: String
    let severity: Severity
}

struct DashboardHealthSnapshot: Identifiable, Equatable {
    let id: String
    let hostName: String
    let issues: [DashboardHealthIssue]
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
    var dashboardMode = false
    var dashboardIdentity: String? = nil
    var resolvedIPAddresses: [String] = []
    var onDashboardHealthChange: ((DashboardHealthSnapshot) -> Void)? = nil
    /// Render nothing — keep only the poll loops and the health
    /// snapshot publishing. Used by `AgentTriagePollers`, which needs
    /// the data pipeline for every connected host but no UI. Without
    /// this, "hidden" monitors at `opacity(0)` still re-render their
    /// Swift Charts on every poll, which is enough main-thread layout
    /// work per host to make the whole app feel sluggish.
    var headless = false

    @State var stats: FfiSystemStats?
    @State var error: String?
    @State var ufwSummary = UFWProtectionSummary.loading
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
    @State var servicesExpanded = false
    @State var activityExpanded = false
    @State var portsExpanded = false
    @State var mapExpanded = false
    /// Distro / kernel / arch summary shown under the connection label.
    /// `nil` until the probe finishes; reset on `connectionId` change.
    @State var osInfo: String?

    let logger = Logger(subsystem: "com.mc-ssh", category: "monitor")
    static let pollInterval: UInt64 = 3_000_000_000  // 3 s
    static let ufwPollInterval: UInt64 = 30_000_000_000  // 30 s
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
        .sheet(item: $drillDown) { item in
            MonitorDrillDownSheet(
                connectionId: connectionId,
                drillDown: item,
                sshPort: sshPort
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
            publishDashboardHealthSnapshot()
        }
        .onChange(of: connectionStatus) { _ in
            publishDashboardHealthSnapshot()
        }
    }

    /// The rendered monitor, or — headless — an empty anchor that
    /// exists only to host the polling `.task`s above. Keeping the
    /// branch *inside* the body (rather than at the caller) means the
    /// poll loops, health publishing, and identity keys are exactly
    /// the same in both modes.
    @ViewBuilder
    var visibleBody: some View {
        if headless {
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
            .background {
                if dashboardMode {
                    RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                        .fill(MidnightMacDesign.ColorToken.windowBackground)
                }
            }
            .overlay {
                if dashboardMode {
                    RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                        .stroke(MidnightMacDesign.ColorToken.separator.opacity(0.45), lineWidth: 1)
                }
            }
        }
    }

    var pollTaskKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    var ufwPollTaskKey: String {
        "\(connectionId ?? "none"):\(sshPort.map { String($0) } ?? "default"):\(isActive)"
    }

}
