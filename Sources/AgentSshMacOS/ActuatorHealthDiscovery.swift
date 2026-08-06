import Foundation

public enum ActuatorHealthDiscovery {
    public typealias Fetcher = @Sendable (String) async throws -> ActuatorEndpointResponse

    public static func observe(
        serviceId: String,
        basePath: String = "/actuator",
        observedAt: Date = Date(),
        fetch: @escaping Fetcher
    ) async -> ActuatorHealthSnapshot {
        let base = normalizedBasePath(basePath)
        let readiness = await attempt(path: "\(base)/health/readiness", fetch: fetch)
        let liveness = await attempt(path: "\(base)/health/liveness", fetch: fetch)

        if readiness.isUnauthorized || liveness.isUnauthorized {
            return failure(serviceId, state: .unauthorized, message: "Actuator authentication was rejected.", at: observedAt)
        }
        if readiness.isFailure || liveness.isFailure {
            return failure(serviceId, state: .unreachable, message: readiness.message ?? liveness.message, at: observedAt)
        }

        if let readinessDocument = readiness.document,
           let livenessDocument = liveness.document {
            return snapshot(
                serviceId: serviceId,
                overall: nil,
                readiness: readinessDocument,
                liveness: livenessDocument,
                responseTime: max(readiness.duration, liveness.duration),
                observedAt: observedAt,
                groupsAvailable: true
            )
        }

        let overall = await attempt(path: "\(base)/health", fetch: fetch)
        if overall.isUnauthorized {
            return failure(serviceId, state: .unauthorized, message: "Actuator authentication was rejected.", at: observedAt)
        }
        if overall.isNotFound {
            return failure(serviceId, state: .unsupported, message: "No Actuator health endpoint was found.", at: observedAt)
        }
        if overall.isFailure {
            return failure(serviceId, state: .unreachable, message: overall.message, at: observedAt)
        }
        guard let overallDocument = overall.document else {
            return failure(serviceId, state: .unsupported, message: overall.message ?? "Actuator health response was invalid.", at: observedAt)
        }

        return snapshot(
            serviceId: serviceId,
            overall: overallDocument,
            readiness: readiness.document,
            liveness: liveness.document,
            responseTime: max(overall.duration, readiness.duration, liveness.duration),
            observedAt: observedAt,
            groupsAvailable: false
        )
    }

    private static func snapshot(
        serviceId: String,
        overall: ActuatorHealthDocument?,
        readiness: ActuatorHealthDocument?,
        liveness: ActuatorHealthDocument?,
        responseTime: TimeInterval,
        observedAt: Date,
        groupsAvailable: Bool
    ) -> ActuatorHealthSnapshot {
        let statuses = [overall?.status, readiness?.status, liveness?.status].compactMap { $0 }
        let state: ActuatorServiceState
        if statuses.contains(.down) || statuses.contains(.outOfService) {
            state = .unhealthy
        } else if statuses.contains(.unknown) {
            state = .degraded
        } else if !statuses.isEmpty && statuses.allSatisfy(\.isHealthy) {
            state = .healthy
        } else {
            state = .degraded
        }

        var componentsByPath: [String: ActuatorHealthComponent] = [:]
        for component in (overall?.components ?? []) + (readiness?.components ?? []) + (liveness?.components ?? []) {
            if componentsByPath[component.path] == nil || component.status != .up {
                componentsByPath[component.path] = component
            }
        }

        return ActuatorHealthSnapshot(
            serviceId: serviceId,
            state: state,
            overallStatus: overall?.status,
            readinessStatus: readiness?.status,
            livenessStatus: liveness?.status,
            components: componentsByPath.values.sorted { $0.path < $1.path },
            responseTime: responseTime,
            observedAt: observedAt,
            healthGroupsAvailable: groupsAvailable
        )
    }

    private static func failure(
        _ serviceId: String,
        state: ActuatorServiceState,
        message: String?,
        at observedAt: Date
    ) -> ActuatorHealthSnapshot {
        ActuatorHealthSnapshot(
            serviceId: serviceId,
            state: state,
            observedAt: observedAt,
            message: message
        )
    }

    private static func normalizedBasePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/actuator" : "/\(trimmed)"
    }

    private static func attempt(path: String, fetch: @escaping Fetcher) async -> EndpointAttempt {
        do {
            let response = try await fetch(path)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .unauthorized(response.duration)
            }
            if response.statusCode == 404 {
                return .notFound(response.duration)
            }
            guard !response.data.isEmpty else {
                return .failure("Actuator returned HTTP \(response.statusCode) with no health payload.", response.duration)
            }
            do {
                return .success(try ActuatorHealthParser.parse(response.data), response.duration)
            } catch {
                return .failure(error.localizedDescription, response.duration)
            }
        } catch {
            return .failure(error.localizedDescription, 0)
        }
    }
}

private enum EndpointAttempt {
    case success(ActuatorHealthDocument, TimeInterval)
    case unauthorized(TimeInterval)
    case notFound(TimeInterval)
    case failure(String, TimeInterval)

    var document: ActuatorHealthDocument? {
        if case .success(let document, _) = self { return document }
        return nil
    }

    var duration: TimeInterval {
        switch self {
        case .success(_, let duration), .unauthorized(let duration), .notFound(let duration), .failure(_, let duration):
            return duration
        }
    }

    var message: String? {
        if case .failure(let message, _) = self { return message }
        return nil
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
