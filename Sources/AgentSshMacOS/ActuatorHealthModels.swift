import Foundation

public enum ActuatorAuthenticationKind: String, Codable, CaseIterable, Sendable {
    case none
    case basic
    case bearer
}

public struct ActuatorAuthenticationConfiguration: Codable, Equatable, Sendable {
    public var kind: ActuatorAuthenticationKind
    public var username: String
    public var credentialReference: String

    public init(
        kind: ActuatorAuthenticationKind = .none,
        username: String = "",
        credentialReference: String = "actuator.shared"
    ) {
        self.kind = kind
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialReference = reference.isEmpty ? "actuator.shared" : reference
    }
}

public enum ActuatorScheme: String, Codable, CaseIterable, Sendable {
    case http
    case https
}

public struct ActuatorServiceConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var profileId: String
    public var name: String
    public var managementHost: String
    public var managementPort: UInt16
    public var scheme: ActuatorScheme
    public var basePath: String
    public var enabledMetrics: [String]

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        name: String,
        managementHost: String = "127.0.0.1",
        managementPort: UInt16,
        scheme: ActuatorScheme = .http,
        basePath: String = "/actuator",
        enabledMetrics: [String] = Self.defaultMetrics
    ) {
        self.id = id
        self.profileId = profileId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = managementHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.managementHost = host.isEmpty ? "127.0.0.1" : host
        self.managementPort = managementPort
        self.scheme = scheme
        self.basePath = Self.normalizeBasePath(basePath)
        self.enabledMetrics = Array(Set(enabledMetrics)).sorted()
    }

    public static let defaultMetrics = [
        "application.ready.time",
        "application.started.time",
        "hikaricp.connections.active",
        "hikaricp.connections.idle",
        "http.server.requests",
        "jvm.gc.pause",
        "jvm.memory.max",
        "jvm.memory.used",
        "jvm.threads.live",
        "process.cpu.usage",
        "process.uptime",
    ]

    public var validationError: String? {
        if profileId.isEmpty { return "Choose an SSH host." }
        if name.isEmpty { return "Service name is required." }
        if managementHost.isEmpty { return "Management host is required." }
        if managementPort == 0 { return "Management port must be between 1 and 65535." }
        return nil
    }

    public func endpointPath(_ suffix: String) -> String {
        let normalizedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalizedSuffix.isEmpty ? basePath : "\(basePath)/\(normalizedSuffix)"
    }

    private static func normalizeBasePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/actuator" : "/\(trimmed)"
    }
}

public struct ActuatorTunnelSpecification: Equatable, Sendable {
    public var forwardId: String
    public var profileId: String
    public var bindHost: String
    public var bindPort: UInt16
    public var destinationHost: String
    public var destinationPort: UInt16

    public init(service: ActuatorServiceConfiguration) {
        self.forwardId = "actuator-\(service.id)"
        self.profileId = service.profileId
        self.bindHost = "127.0.0.1"
        self.bindPort = 0
        self.destinationHost = service.managementHost
        self.destinationPort = service.managementPort
    }
}

public struct ActuatorFleetConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var authentication: ActuatorAuthenticationConfiguration
    public var services: [ActuatorServiceConfiguration]

    public init(
        schemaVersion: Int = 1,
        authentication: ActuatorAuthenticationConfiguration = .init(),
        services: [ActuatorServiceConfiguration] = []
    ) {
        self.schemaVersion = schemaVersion
        self.authentication = authentication
        self.services = services
    }

    public static let empty = ActuatorFleetConfiguration()
}

public enum ActuatorAuthorizationHeader {
    public static func make(
        configuration: ActuatorAuthenticationConfiguration,
        secret: String?
    ) -> String? {
        switch configuration.kind {
        case .none:
            return nil
        case .basic:
            guard let secret, !secret.isEmpty, !configuration.username.isEmpty else { return nil }
            let data = Data("\(configuration.username):\(secret)".utf8)
            return "Basic \(data.base64EncodedString())"
        case .bearer:
            guard let secret, !secret.isEmpty else { return nil }
            return "Bearer \(secret)"
        }
    }
}

public enum ActuatorHealthStatus: String, Codable, CaseIterable, Sendable {
    case up = "UP"
    case down = "DOWN"
    case outOfService = "OUT_OF_SERVICE"
    case unknown = "UNKNOWN"

    public init(code: String?) {
        let normalized = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        self = ActuatorHealthStatus(rawValue: normalized ?? "") ?? .unknown
    }

    public var isHealthy: Bool { self == .up }
}

public struct ActuatorHealthComponent: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var status: ActuatorHealthStatus

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    public init(path: String, status: ActuatorHealthStatus) {
        self.path = path
        self.status = status
    }
}

public struct ActuatorHealthDocument: Equatable, Sendable {
    public var status: ActuatorHealthStatus
    public var components: [ActuatorHealthComponent]
}

public enum ActuatorHealthParserError: Error, LocalizedError, Equatable {
    case invalidJSON
    case missingStatus

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Actuator returned malformed JSON."
        case .missingStatus: return "Actuator health response did not contain a status."
        }
    }
}

public enum ActuatorHealthParser {
    public static func parse(_ data: Data) throws -> ActuatorHealthDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActuatorHealthParserError.invalidJSON
        }
        guard let statusCode = root["status"] as? String else {
            throw ActuatorHealthParserError.missingStatus
        }
        var components: [ActuatorHealthComponent] = []
        flatten(root["components"] as? [String: Any], parentPath: nil, into: &components)
        return ActuatorHealthDocument(
            status: ActuatorHealthStatus(code: statusCode),
            components: components.sorted { $0.path < $1.path }
        )
    }

    private static func flatten(
        _ values: [String: Any]?,
        parentPath: String?,
        into result: inout [ActuatorHealthComponent]
    ) {
        guard let values else { return }
        for name in values.keys.sorted() {
            guard let component = values[name] as? [String: Any] else { continue }
            let path = parentPath.map { "\($0)/\(name)" } ?? name
            result.append(ActuatorHealthComponent(
                path: path,
                status: ActuatorHealthStatus(code: component["status"] as? String)
            ))
            flatten(component["components"] as? [String: Any], parentPath: path, into: &result)
        }
    }
}

public enum ActuatorServiceState: String, Codable, CaseIterable, Sendable {
    case discovering
    case healthy
    case degraded
    case unhealthy
    case unreachable
    case unauthorized
    case unsupported
    case stale

    public var isSuccessfulObservation: Bool {
        self == .healthy || self == .degraded || self == .unhealthy
    }
}

public struct ActuatorHealthSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var serviceId: String
    public var state: ActuatorServiceState
    public var overallStatus: ActuatorHealthStatus?
    public var readinessStatus: ActuatorHealthStatus?
    public var livenessStatus: ActuatorHealthStatus?
    public var components: [ActuatorHealthComponent]
    public var responseTime: TimeInterval?
    public var observedAt: Date
    public var message: String?
    public var healthGroupsAvailable: Bool

    public var id: String { serviceId }

    public init(
        serviceId: String,
        state: ActuatorServiceState,
        overallStatus: ActuatorHealthStatus? = nil,
        readinessStatus: ActuatorHealthStatus? = nil,
        livenessStatus: ActuatorHealthStatus? = nil,
        components: [ActuatorHealthComponent] = [],
        responseTime: TimeInterval? = nil,
        observedAt: Date = Date(),
        message: String? = nil,
        healthGroupsAvailable: Bool = false
    ) {
        self.serviceId = serviceId
        self.state = state
        self.overallStatus = overallStatus
        self.readinessStatus = readinessStatus
        self.livenessStatus = livenessStatus
        self.components = components
        self.responseTime = responseTime
        self.observedAt = observedAt
        self.message = message
        self.healthGroupsAvailable = healthGroupsAvailable
    }

    public func effectiveState(
        now: Date = Date(),
        staleAfter: TimeInterval = 60
    ) -> ActuatorServiceState {
        now.timeIntervalSince(observedAt) > staleAfter ? .stale : state
    }
}

public struct ActuatorFleetSummary: Equatable, Sendable {
    public var profileId: String
    public var state: ActuatorServiceState
    public var serviceCount: Int
    public var problemServiceNames: [String]

    public static func make(
        profileId: String,
        services: [ActuatorServiceConfiguration],
        snapshots: [String: ActuatorHealthSnapshot],
        now: Date = Date(),
        staleAfter: TimeInterval = 60
    ) -> ActuatorFleetSummary? {
        let matching = services.filter { $0.profileId == profileId }
        guard !matching.isEmpty else { return nil }

        let ranked: [(ActuatorServiceConfiguration, ActuatorServiceState)] = matching.map { service in
            let state = snapshots[service.id]?.effectiveState(now: now, staleAfter: staleAfter) ?? .discovering
            return (service, state)
        }
        let state = ranked.map(\.1).max(by: { severity($0) < severity($1) }) ?? .discovering
        let problems = ranked
            .filter { severity($0.1) >= severity(.degraded) }
            .map { $0.0.name }
            .sorted()

        return ActuatorFleetSummary(
            profileId: profileId,
            state: state,
            serviceCount: matching.count,
            problemServiceNames: problems
        )
    }

    private static func severity(_ state: ActuatorServiceState) -> Int {
        switch state {
        case .healthy: return 0
        case .discovering: return 1
        case .stale: return 2
        case .degraded: return 3
        case .unsupported: return 4
        case .unauthorized: return 5
        case .unreachable: return 6
        case .unhealthy: return 7
        }
    }
}

public struct ActuatorEndpointResponse: Equatable, Sendable {
    public var statusCode: Int
    public var data: Data
    public var duration: TimeInterval

    public init(statusCode: Int, data: Data, duration: TimeInterval) {
        self.statusCode = statusCode
        self.data = data
        self.duration = duration
    }
}

public struct ActuatorPollingPolicy: Equatable, Sendable {
    public var fleetInterval: TimeInterval
    public var detailInterval: TimeInterval
    public var verificationInterval: TimeInterval
    public var maximumFailureBackoff: TimeInterval

    public init(
        fleetInterval: TimeInterval = 30,
        detailInterval: TimeInterval = 10,
        verificationInterval: TimeInterval = 5,
        maximumFailureBackoff: TimeInterval = 120
    ) {
        self.fleetInterval = fleetInterval
        self.detailInterval = detailInterval
        self.verificationInterval = verificationInterval
        self.maximumFailureBackoff = maximumFailureBackoff
    }

    public func interval(isSelected: Bool, consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else {
            return isSelected ? detailInterval : fleetInterval
        }
        let exponent = min(consecutiveFailures, 16)
        return min(fleetInterval * pow(2, Double(exponent)), maximumFailureBackoff)
    }
}

public final class ActuatorStateConfirmationTracker: @unchecked Sendable {
    private struct Candidate {
        var state: ActuatorServiceState
        var matches: Int
    }

    private let requiredMatches: Int
    private let lock = NSLock()
    private var publishedStates: [String: ActuatorServiceState] = [:]
    private var candidates: [String: Candidate] = [:]

    public init(requiredMatches: Int = 2) {
        self.requiredMatches = max(1, requiredMatches)
    }

    public func shouldPublish(serviceId: String, state: ActuatorServiceState) -> Bool {
        lock.withLock {
            guard let published = publishedStates[serviceId] else {
                publishedStates[serviceId] = state
                return true
            }
            if state == published {
                candidates.removeValue(forKey: serviceId)
                return true
            }
            if state == .unhealthy {
                publishedStates[serviceId] = state
                candidates.removeValue(forKey: serviceId)
                return true
            }

            var candidate = candidates[serviceId]
            if candidate?.state == state {
                candidate?.matches += 1
            } else {
                candidate = Candidate(state: state, matches: 1)
            }
            guard let candidate else { return false }
            if candidate.matches >= requiredMatches {
                publishedStates[serviceId] = state
                candidates.removeValue(forKey: serviceId)
                return true
            }
            candidates[serviceId] = candidate
            return false
        }
    }

    public func remove(serviceId: String) {
        lock.withLock {
            publishedStates.removeValue(forKey: serviceId)
            candidates.removeValue(forKey: serviceId)
        }
    }

    public func reset() {
        lock.withLock {
            publishedStates.removeAll()
            candidates.removeAll()
        }
    }
}

public final class ActuatorSessionHistoryStore: @unchecked Sendable {
    private let maxObservationsPerService: Int
    private let lock = NSLock()
    private var observations: [String: [ActuatorHealthSnapshot]] = [:]

    public init(maxObservationsPerService: Int = 240) {
        self.maxObservationsPerService = max(1, maxObservationsPerService)
    }

    public func record(_ snapshot: ActuatorHealthSnapshot) {
        lock.withLock {
            var history = observations[snapshot.serviceId, default: []]
            history.append(snapshot)
            if history.count > maxObservationsPerService {
                history.removeFirst(history.count - maxObservationsPerService)
            }
            observations[snapshot.serviceId] = history
        }
    }

    public func history(for serviceId: String) -> [ActuatorHealthSnapshot] {
        lock.withLock { observations[serviceId, default: []] }
    }

    public func transitions(for serviceId: String) -> [ActuatorHealthSnapshot] {
        lock.withLock {
            var previous: ActuatorServiceState?
            return observations[serviceId, default: []].filter { snapshot in
                defer { previous = snapshot.state }
                return previous != snapshot.state
            }
        }
    }

    public func remove(serviceId: String) {
        lock.withLock { _ = observations.removeValue(forKey: serviceId) }
    }

    public func clear() {
        lock.withLock { observations.removeAll() }
    }
}

public struct ActuatorVerificationResult: Equatable, Sendable {
    public var succeeded: Bool
    public var attempts: Int
    public var lastSnapshot: ActuatorHealthSnapshot?
}

public enum ActuatorHealthVerifier {
    public typealias Observer = @Sendable () async -> ActuatorHealthSnapshot
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    public static func verify(
        requiredConsecutiveHealthy: Int = 3,
        maxAttempts: Int = 12,
        interval: TimeInterval = 5,
        observe: @escaping Observer,
        sleep: @escaping Sleeper
    ) async -> ActuatorVerificationResult {
        let required = max(1, requiredConsecutiveHealthy)
        let attemptLimit = max(1, maxAttempts)
        var consecutiveHealthy = 0
        var lastSnapshot: ActuatorHealthSnapshot?

        for attempt in 1...attemptLimit {
            let snapshot = await observe()
            lastSnapshot = snapshot
            if snapshot.state == .healthy {
                consecutiveHealthy += 1
            } else {
                consecutiveHealthy = 0
            }
            if consecutiveHealthy >= required {
                return ActuatorVerificationResult(
                    succeeded: true,
                    attempts: attempt,
                    lastSnapshot: snapshot
                )
            }
            if attempt < attemptLimit {
                await sleep(interval)
            }
        }

        return ActuatorVerificationResult(
            succeeded: false,
            attempts: attemptLimit,
            lastSnapshot: lastSnapshot
        )
    }
}
