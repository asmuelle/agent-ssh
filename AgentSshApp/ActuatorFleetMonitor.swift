import AgentSshMacOS
import Combine
import Foundation
@preconcurrency import UserNotifications

private enum ActuatorMonitorError: Error, LocalizedError {
    case invalidLocalPort
    case invalidLocalURL
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLocalPort: return "The SSH tunnel did not allocate a local port."
        case .invalidLocalURL: return "Could not construct the local Actuator URL."
        case .responseTooLarge: return "Actuator response exceeded the 1 MB safety limit."
        }
    }
}

private final class ActuatorLocalHTTPClient: @unchecked Sendable {
    private let baseURL: URL
    private let authorizationHeader: String?
    private let session: URLSession
    private let maximumResponseBytes = 1_048_576

    init(baseURL: URL, authorizationHeader: String?) {
        self.baseURL = baseURL
        self.authorizationHeader = authorizationHeader
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func get(path: String) async throws -> ActuatorEndpointResponse {
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appendingPathComponent(relativePath)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else {
            throw ActuatorMonitorError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ActuatorEndpointResponse(
            statusCode: http.statusCode,
            data: data,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}

@MainActor
private final class ActuatorTunnelManager {
    private struct ActiveTunnel {
        var specification: ActuatorTunnelSpecification
        var connectionId: String
        var runtime: PortForwardRuntimeRecord
    }

    private var tunnels: [String: ActiveTunnel] = [:]

    func baseURL(
        for service: ActuatorServiceConfiguration,
        connectionId: String
    ) async throws -> URL {
        let specification = ActuatorTunnelSpecification(service: service)
        if let active = tunnels[service.id],
           active.connectionId == connectionId,
           active.specification == specification,
           active.runtime.state == .running,
           let boundPort = active.runtime.boundPort,
           boundPort > 0 {
            return try localURL(scheme: service.scheme, port: boundPort)
        }

        await stop(serviceId: service.id)
        let profile = PortForwardProfileRecord(
            id: specification.forwardId,
            profileId: specification.profileId,
            name: "Actuator · \(service.name)",
            kind: .local,
            bindHost: specification.bindHost,
            bindPort: specification.bindPort,
            destinationHost: specification.destinationHost,
            destinationPort: specification.destinationPort,
            autoStart: false
        )
        let runtime = try await BridgeManager.shared.portForwardStart(
            profile: profile,
            connectionId: connectionId
        )
        guard let boundPort = runtime.boundPort, boundPort > 0 else {
            try? await BridgeManager.shared.portForwardStop(id: specification.forwardId)
            throw ActuatorMonitorError.invalidLocalPort
        }
        tunnels[service.id] = ActiveTunnel(
            specification: specification,
            connectionId: connectionId,
            runtime: runtime
        )
        return try localURL(scheme: service.scheme, port: boundPort)
    }

    func stop(serviceId: String) async {
        guard let active = tunnels.removeValue(forKey: serviceId) else { return }
        try? await BridgeManager.shared.portForwardStop(id: active.specification.forwardId)
    }

    func stopAll() async {
        let serviceIds = Array(tunnels.keys)
        for serviceId in serviceIds {
            await stop(serviceId: serviceId)
        }
    }

    private func localURL(scheme: ActuatorScheme, port: UInt16) throws -> URL {
        guard let url = URL(string: "\(scheme.rawValue)://127.0.0.1:\(port)") else {
            throw ActuatorMonitorError.invalidLocalURL
        }
        return url
    }
}

@MainActor
final class ActuatorFleetMonitor: ObservableObject {
    static let shared = ActuatorFleetMonitor()

    @Published private(set) var configuration: ActuatorFleetConfiguration = .empty
    @Published private(set) var snapshots: [String: ActuatorHealthSnapshot] = [:]
    @Published private(set) var isPolling = false
    @Published var selectedServiceId: String?
    @Published var lastError: String?

    private let configurationStore = ActuatorConfigurationStore()
    private let credentialStore = ActuatorCredentialStore()
    private let historyStore = ActuatorSessionHistoryStore(maxObservationsPerService: 240)
    private let confirmationTracker = ActuatorStateConfirmationTracker(requiredMatches: 2)
    private let pollingPolicy = ActuatorPollingPolicy()
    private let tunnelManager = ActuatorTunnelManager()
    private weak var tabsStore: TerminalTabsStore?
    private var pollingTask: Task<Void, Never>?
    private var nextPollAt: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]
    private var inFlightServiceIds: Set<String> = []

    private init() {
        reloadConfiguration()
    }

    var services: [ActuatorServiceConfiguration] {
        configuration.services.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func services(profileId: String) -> [ActuatorServiceConfiguration] {
        services.filter { $0.profileId == profileId }
    }

    func history(for serviceId: String) -> [ActuatorHealthSnapshot] {
        historyStore.history(for: serviceId)
    }

    func transitions(for serviceId: String) -> [ActuatorHealthSnapshot] {
        historyStore.transitions(for: serviceId)
    }

    func summary(profileId: String, now: Date = Date()) -> ActuatorFleetSummary? {
        ActuatorFleetSummary.make(
            profileId: profileId,
            services: configuration.services,
            snapshots: snapshots,
            now: now
        )
    }

    func start(tabsStore: TerminalTabsStore) {
        self.tabsStore = tabsStore
        guard pollingTask == nil else { return }
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollDueServices()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    func stop() async {
        cancelPolling()
        await tunnelManager.stopAll()
        historyStore.clear()
        confirmationTracker.reset()
        snapshots.removeAll()
        nextPollAt.removeAll()
        failureCounts.removeAll()
        inFlightServiceIds.removeAll()
    }

    func reloadConfiguration() {
        do {
            configuration = try configurationStore.load()
            lastError = nil
        } catch {
            configuration = .empty
            lastError = "Could not load Actuator configuration: \(error.localizedDescription)"
        }
    }

    func saveAuthentication(
        kind: ActuatorAuthenticationKind,
        username: String,
        secret: String
    ) {
        do {
            let reference = configuration.authentication.credentialReference
            if kind == .none {
                try credentialStore.delete(reference: reference)
            } else if !secret.isEmpty {
                try credentialStore.save(secret: secret, reference: reference)
            }
            configuration.authentication = ActuatorAuthenticationConfiguration(
                kind: kind,
                username: username,
                credentialReference: reference
            )
            try persistConfiguration()
            nextPollAt.removeAll()
        } catch {
            lastError = "Could not save Actuator authentication: \(error.localizedDescription)"
        }
    }

    func upsert(_ service: ActuatorServiceConfiguration) {
        guard let validationError = service.validationError else {
            do {
                if let index = configuration.services.firstIndex(where: { $0.id == service.id }) {
                    configuration.services[index] = service
                } else {
                    configuration.services.append(service)
                }
                try persistConfiguration()
                nextPollAt[service.id] = .distantPast
            } catch {
                lastError = "Could not save Actuator service: \(error.localizedDescription)"
            }
            return
        }
        lastError = validationError
    }

    func delete(_ service: ActuatorServiceConfiguration) async {
        configuration.services.removeAll { $0.id == service.id }
        do {
            try persistConfiguration()
        } catch {
            lastError = "Could not delete Actuator service: \(error.localizedDescription)"
            return
        }
        snapshots.removeValue(forKey: service.id)
        historyStore.remove(serviceId: service.id)
        confirmationTracker.remove(serviceId: service.id)
        nextPollAt.removeValue(forKey: service.id)
        failureCounts.removeValue(forKey: service.id)
        await tunnelManager.stop(serviceId: service.id)
    }

    func refreshNow(serviceId: String? = nil) async {
        if let serviceId {
            nextPollAt[serviceId] = .distantPast
        } else {
            nextPollAt.removeAll()
        }
        await pollDueServices(force: true, onlyServiceId: serviceId)
    }

    func verify(profileId: String) async -> FleetCommandExecution {
        guard let tab = tabsStore?.connectedSSHTabs.first(where: { $0.profile.id == profileId }) else {
            return FleetCommandExecution(exitCode: 1, output: "SSH host is not connected.")
        }
        let configuredServices = services(profileId: profileId)
        guard !configuredServices.isEmpty else {
            return FleetCommandExecution(exitCode: 78, output: "No Actuator service is configured for this host.")
        }

        for service in configuredServices {
            let result = await ActuatorHealthVerifier.verify(
                requiredConsecutiveHealthy: 3,
                maxAttempts: 12,
                interval: pollingPolicy.verificationInterval,
                observe: { [weak self] in
                    guard let self else {
                        return ActuatorHealthSnapshot(
                            serviceId: service.id,
                            state: .unreachable,
                            message: "Actuator monitor stopped."
                        )
                    }
                    let snapshot = await self.observe(service: service, connectionId: tab.connectionId)
                    await self.publish(snapshot, for: service)
                    return snapshot
                },
                sleep: { interval in
                    try? await Task.sleep(for: .seconds(interval))
                }
            )
            guard result.succeeded else {
                let state = result.lastSnapshot?.state.rawValue ?? "unknown"
                return FleetCommandExecution(
                    exitCode: 1,
                    output: "\(service.name) Actuator readiness did not stabilize: \(state)."
                )
            }
        }
        return FleetCommandExecution(
            exitCode: 0,
            output: "Actuator readiness was healthy for three consecutive checks."
        )
    }

    private func persistConfiguration() throws {
        configuration.services.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try configurationStore.save(configuration)
        lastError = nil
    }

    private func pollDueServices(
        force: Bool = false,
        onlyServiceId: String? = nil
    ) async {
        guard let tabsStore else { return }
        let now = Date()
        let connected = Dictionary(
            tabsStore.connectedSSHTabs.map { ($0.profile.id, $0.connectionId) },
            uniquingKeysWith: { firstConnection, _ in firstConnection }
        )
        let dueServices = services.filter { service in
            if let onlyServiceId, service.id != onlyServiceId { return false }
            if inFlightServiceIds.contains(service.id) { return false }
            return force || nextPollAt[service.id, default: .distantPast] <= now
        }

        var offset = 0
        while offset < dueServices.count {
            let upper = min(offset + 4, dueServices.count)
            let chunk = Array(dueServices[offset..<upper])
            for service in chunk { inFlightServiceIds.insert(service.id) }
            let results = await withTaskGroup(
                of: (ActuatorServiceConfiguration, ActuatorHealthSnapshot).self
            ) { group in
                for service in chunk {
                    let connectionId = connected[service.profileId]
                    group.addTask { [weak self] in
                        guard let self else {
                            return (service, ActuatorHealthSnapshot(serviceId: service.id, state: .unreachable))
                        }
                        guard let connectionId else {
                            return (
                                service,
                                ActuatorHealthSnapshot(
                                    serviceId: service.id,
                                    state: .unreachable,
                                    message: "SSH host is disconnected."
                                )
                            )
                        }
                        return (service, await self.observe(service: service, connectionId: connectionId))
                    }
                }
                var values: [(ActuatorServiceConfiguration, ActuatorHealthSnapshot)] = []
                for await result in group { values.append(result) }
                return values
            }
            for (service, snapshot) in results {
                inFlightServiceIds.remove(service.id)
                publish(snapshot, for: service)
            }
            offset = upper
        }
    }

    private func observe(
        service: ActuatorServiceConfiguration,
        connectionId: String
    ) async -> ActuatorHealthSnapshot {
        let authentication = configuration.authentication
        let secret: String?
        do {
            secret = try credentialStore.load(reference: authentication.credentialReference)
        } catch {
            return ActuatorHealthSnapshot(
                serviceId: service.id,
                state: .unauthorized,
                message: "Could not load the shared Actuator credential: \(error.localizedDescription)"
            )
        }
        let authorization = ActuatorAuthorizationHeader.make(
            configuration: authentication,
            secret: secret
        )
        if authentication.kind != .none && authorization == nil {
            return ActuatorHealthSnapshot(
                serviceId: service.id,
                state: .unauthorized,
                message: "The shared Actuator credential is not configured."
            )
        }

        do {
            let baseURL = try await tunnelManager.baseURL(for: service, connectionId: connectionId)
            let client = ActuatorLocalHTTPClient(
                baseURL: baseURL,
                authorizationHeader: authorization
            )
            return await ActuatorHealthDiscovery.observe(
                serviceId: service.id,
                basePath: service.basePath
            ) { path in
                try await client.get(path: path)
            }
        } catch {
            return ActuatorHealthSnapshot(
                serviceId: service.id,
                state: .unreachable,
                message: error.localizedDescription
            )
        }
    }

    private func publish(
        _ snapshot: ActuatorHealthSnapshot,
        for service: ActuatorServiceConfiguration
    ) {
        historyStore.record(snapshot)
        let previous = snapshots[service.id]
        let changed = previous?.state != snapshot.state
        let shouldPublish = confirmationTracker.shouldPublish(
            serviceId: service.id,
            state: snapshot.state
        )

        if shouldPublish {
            snapshots[service.id] = snapshot
            if changed, previous != nil {
                recordTransition(service: service, snapshot: snapshot)
            }
        }

        let isFailure = !snapshot.state.isSuccessfulObservation
        failureCounts[service.id] = isFailure ? failureCounts[service.id, default: 0] + 1 : 0
        let changedCandidate = previous != nil && previous?.state != snapshot.state
        let interval = changedCandidate ? 10 : pollingPolicy.interval(
            isSelected: selectedServiceId == service.id,
            consecutiveFailures: failureCounts[service.id, default: 0]
        )
        nextPollAt[service.id] = Date().addingTimeInterval(interval)
    }

    private func recordTransition(
        service: ActuatorServiceConfiguration,
        snapshot: ActuatorHealthSnapshot
    ) {
        let isHealthy = snapshot.state == .healthy
        ActivityLogStore.shared.record(
            title: "Actuator · \(service.name)",
            detail: snapshot.message ?? "State changed to \(snapshot.state.rawValue).",
            profileId: service.profileId,
            icon: isHealthy ? "checkmark.heart.fill" : "heart.slash.fill",
            severity: isHealthy ? .success : .warning,
            actor: .app,
            action: "actuator-health-transition",
            outcome: isHealthy ? .succeeded : .failed
        )
        deliverNotification(service: service, snapshot: snapshot)
    }

    private func deliverNotification(
        service: ActuatorServiceConfiguration,
        snapshot: ActuatorHealthSnapshot
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "\(service.name) · \(snapshot.state.rawValue.capitalized)"
            content.body = snapshot.message ?? "Actuator health changed."
            content.sound = snapshot.state == .healthy ? nil : .default
            content.threadIdentifier = "actuator-health"
            // Stable per-service identifier: a new transition *replaces* the
            // service's previous banner instead of stacking. A flapping
            // service would otherwise fill Notification Center with one
            // banner per poll cycle; the user only ever needs the latest.
            let request = UNNotificationRequest(
                identifier: "actuator-health-\(service.id)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
