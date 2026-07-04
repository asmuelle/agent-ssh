import Foundation

/// A connected server's evaluated health at a point in time. Combines a
/// resource sample, firewall state, and failed-service list into ranked issues.
struct MobileServerHealthSnapshot: Identifiable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let sample: MobileServerResourceSample?
    let firewall: MobileServerFirewallState
    let failedServices: [String]
    let issues: [MobileServerHealthIssue]
    let probeError: String?
    let updatedAt: Date

    var id: String { profileId }

    var severity: MobileServerSeverity {
        MobileServerHealthEvaluator.overallSeverity(issues)
    }
}

/// Polls connected servers for resource/firewall/service health and publishes
/// per-server snapshots that drive the fleet dashboard's "needs attention"
/// overview. Only connected profiles are probed; disconnected ones are pruned.
@MainActor
final class MobileServerHealthStore: ObservableObject {
    @Published private(set) var snapshots: [String: MobileServerHealthSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?

    func snapshot(for profileId: String) -> MobileServerHealthSnapshot? {
        snapshots[profileId]
    }

    /// Number of connected servers currently flagged as needing attention.
    var attentionCount: Int {
        snapshots.values.filter { $0.severity.needsAttention }.count
    }

    /// Probe every connected profile concurrently and refresh its snapshot.
    /// Snapshots for profiles that are no longer connected are dropped.
    func refresh(profiles: [MobileConnectionProfile], sessionStore: MobileSessionStore) async {
        let connected: [(profile: MobileConnectionProfile, connectionId: String)] = profiles.compactMap { profile in
            guard case .connected(let connectionId) = sessionStore.status(for: profile) else { return nil }
            return (profile, connectionId)
        }

        let connectedIds = Set(connected.map(\.profile.id))
        snapshots = snapshots.filter { connectedIds.contains($0.key) }

        guard !connected.isEmpty else {
            isRefreshing = false
            lastRefreshed = Date()
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = Date()
        }

        await withTaskGroup(of: MobileServerHealthSnapshot.self) { group in
            for entry in connected {
                group.addTask { @MainActor in
                    await Self.probe(profile: entry.profile, connectionId: entry.connectionId)
                }
            }
            for await snapshot in group {
                snapshots[snapshot.profileId] = snapshot
            }
        }
    }

    // MARK: - Probing

    private static func probe(
        profile: MobileConnectionProfile,
        connectionId: String
    ) async -> MobileServerHealthSnapshot {
        async let sampleResult = fetchSample(connectionId: connectionId)
        async let firewallResult = fetchFirewall(connectionId: connectionId, sshPort: profile.port)
        async let servicesResult = fetchFailedServices(connectionId: connectionId)

        let (sample, sampleError) = await sampleResult
        let firewall = await firewallResult
        let failedServices = await servicesResult

        let issues = MobileServerHealthEvaluator.evaluate(
            sample: sample,
            firewall: firewall,
            failedServices: failedServices
        )

        return MobileServerHealthSnapshot(
            profileId: profile.id,
            profileName: profile.name,
            sample: sample,
            firewall: firewall,
            failedServices: failedServices,
            issues: issues,
            probeError: sampleError,
            updatedAt: Date()
        )
    }

    private static func fetchSample(
        connectionId: String
    ) async -> (MobileServerResourceSample?, String?) {
        do {
            let stats = try await MobileMonitorBridge.shared.getSystemStats(connectionId: connectionId)
            return (sample(from: stats), nil)
        } catch {
            return (nil, describe(error))
        }
    }

    private static func fetchFirewall(
        connectionId: String,
        sshPort: UInt16
    ) async -> MobileServerFirewallState {
        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: firewallScript
            )
            return MobileFirewallStatusParser.parse(output: output, sshPort: sshPort)
        } catch {
            return .unknown
        }
    }

    private static func fetchFailedServices(connectionId: String) async -> [String] {
        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: failedServicesScript
            )
            return parseFailedServices(output)
        } catch {
            return []
        }
    }

    // MARK: - Parsing helpers

    private static func sample(from stats: FfiSystemStats) -> MobileServerResourceSample {
        MobileServerResourceSample(
            cpuPercent: stats.cpuPercent,
            loadAverage1m: stats.loadAverage1m,
            memoryUsed: stats.memoryUsed,
            memoryTotal: stats.memoryTotal,
            swapUsed: stats.swapUsed,
            swapTotal: stats.swapTotal,
            disks: stats.disks.map {
                MobileServerResourceSample.Disk(mount: $0.mount, used: $0.used, total: $0.total)
            },
            uptimeSeconds: stats.uptimeSeconds
        )
    }

    private static func parseFailedServices(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                var tokens = line
                    .trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                if tokens.first == "●" { tokens.removeFirst() }
                return tokens.first
            }
            .filter { !$0.isEmpty }
    }

    private static func describe(_ error: Error) -> String {
        if let monitorError = error as? MonitorError {
            switch monitorError {
            case .NotConnected:
                return "Not connected."
            case .ParseError(let detail):
                return detail
            case .Unsupported(let os):
                return "Unsupported host OS: \(os)."
            case .Other(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }

    private static let firewallScript = """
    if command -v ufw >/dev/null 2>&1; then
      sudo -n ufw status numbered 2>&1
    else
      echo \(mobileUFWUnavailableMarker)
    fi
    """

    private static let failedServicesScript = """
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}'
    fi
    """
}
