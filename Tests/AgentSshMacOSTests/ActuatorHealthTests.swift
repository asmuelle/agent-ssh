import Foundation
import XCTest
@testable import AgentSshMacOS

final class ActuatorHealthTests: XCTestCase {
    func testServiceConfigurationNormalizesLoopbackAndBasePath() {
        let service = ActuatorServiceConfiguration(
            profileId: " profile-1 ",
            name: " Orders API ",
            managementHost: "   ",
            managementPort: 8_081,
            basePath: "manage/"
        )

        XCTAssertEqual(service.profileId, "profile-1")
        XCTAssertEqual(service.name, "Orders API")
        XCTAssertEqual(service.managementHost, "127.0.0.1")
        XCTAssertEqual(service.basePath, "/manage")
        XCTAssertNil(service.validationError)
    }

    func testServiceConfigurationRejectsMissingIdentityAndPortZero() {
        let service = ActuatorServiceConfiguration(
            profileId: "",
            name: "",
            managementPort: 0
        )

        XCTAssertNotNil(service.validationError)
    }

    func testConfigurationStoreRoundTripsServicesAndSharedAuthentication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActuatorConfigurationStore(directoryURL: directory)
        let configuration = ActuatorFleetConfiguration(
            authentication: ActuatorAuthenticationConfiguration(
                kind: .basic,
                username: "operations",
                credentialReference: "actuator.shared"
            ),
            services: [
                ActuatorServiceConfiguration(
                    id: "orders",
                    profileId: "server-1",
                    name: "Orders",
                    managementPort: 8_081
                ),
            ]
        )

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
    }

    func testAuthorizationHeaderSupportsBasicBearerAndNone() {
        let basic = ActuatorAuthenticationConfiguration(
            kind: .basic,
            username: "ops",
            credentialReference: "shared"
        )
        let bearer = ActuatorAuthenticationConfiguration(
            kind: .bearer,
            credentialReference: "shared"
        )

        XCTAssertEqual(
            ActuatorAuthorizationHeader.make(configuration: basic, secret: "secret"),
            "Basic b3BzOnNlY3JldA=="
        )
        XCTAssertEqual(
            ActuatorAuthorizationHeader.make(configuration: bearer, secret: "token"),
            "Bearer token"
        )
        XCTAssertNil(
            ActuatorAuthorizationHeader.make(
                configuration: ActuatorAuthenticationConfiguration(kind: .none),
                secret: nil
            )
        )
        XCTAssertNil(ActuatorAuthorizationHeader.make(configuration: basic, secret: nil))
    }

    func testParserFlattensNestedHealthComponentsWithoutPersistingDetails() throws {
        let document = try ActuatorHealthParser.parse(jsonData("""
        {
          "status": "DOWN",
          "components": {
            "db": { "status": "DOWN", "details": { "database": "PostgreSQL", "password": "secret" } },
            "diskSpace": { "status": "UP" },
            "messaging": {
              "status": "DOWN",
              "components": {
                "kafka": { "status": "DOWN", "details": { "broker": "internal" } }
              }
            }
          }
        }
        """))

        XCTAssertEqual(document.status, .down)
        XCTAssertEqual(document.components.map(\.path), ["db", "diskSpace", "messaging", "messaging/kafka"])
        XCTAssertEqual(document.components.last?.status, .down)
    }

    func testDiscoveryUsesReadinessAndLivenessGroupsWhenAvailable() async {
        let requested = LockedValues<String>()
        let snapshot = await ActuatorHealthDiscovery.observe(
            serviceId: "orders",
            basePath: "/actuator",
            observedAt: Date(timeIntervalSince1970: 100)
        ) { path in
            requested.append(path)
            return ActuatorEndpointResponse(
                statusCode: 200,
                data: self.healthData(status: "UP", component: path.contains("readiness") ? "db" : "ping"),
                duration: 0.12
            )
        }

        XCTAssertEqual(snapshot.state, .healthy)
        XCTAssertEqual(snapshot.readinessStatus, .up)
        XCTAssertEqual(snapshot.livenessStatus, .up)
        XCTAssertTrue(snapshot.healthGroupsAvailable)
        XCTAssertEqual(Set(requested.values), ["/actuator/health/readiness", "/actuator/health/liveness"])
    }

    func testDiscoveryFallsBackToOverallHealthWhenGroupsAreMissing() async {
        let requested = LockedValues<String>()
        let snapshot = await ActuatorHealthDiscovery.observe(
            serviceId: "billing",
            basePath: "/manage"
        ) { path in
            requested.append(path)
            if path == "/manage/health" {
                return ActuatorEndpointResponse(
                    statusCode: 200,
                    data: self.healthData(status: "UP", component: "db"),
                    duration: 0.08
                )
            }
            return ActuatorEndpointResponse(statusCode: 404, data: Data(), duration: 0.02)
        }

        XCTAssertEqual(snapshot.state, .healthy)
        XCTAssertEqual(snapshot.overallStatus, .up)
        XCTAssertNil(snapshot.readinessStatus)
        XCTAssertNil(snapshot.livenessStatus)
        XCTAssertFalse(snapshot.healthGroupsAvailable)
        XCTAssertTrue(requested.values.contains("/manage/health"))
    }

    func testDiscoveryDistinguishesUnauthorizedUnsupportedAndUnreachable() async {
        let unauthorized = await ActuatorHealthDiscovery.observe(serviceId: "one") { _ in
            ActuatorEndpointResponse(statusCode: 401, data: Data(), duration: 0.01)
        }
        let unsupported = await ActuatorHealthDiscovery.observe(serviceId: "two") { _ in
            ActuatorEndpointResponse(statusCode: 404, data: Data(), duration: 0.01)
        }
        let unreachable = await ActuatorHealthDiscovery.observe(serviceId: "three") { _ in
            throw URLError(.cannotConnectToHost)
        }

        XCTAssertEqual(unauthorized.state, .unauthorized)
        XCTAssertEqual(unsupported.state, .unsupported)
        XCTAssertEqual(unreachable.state, .unreachable)
    }

    func testReadinessFailureOverridesHealthyLiveness() async {
        let snapshot = await ActuatorHealthDiscovery.observe(serviceId: "orders") { path in
            let status = path.contains("readiness") ? "DOWN" : "UP"
            return ActuatorEndpointResponse(
                statusCode: 200,
                data: self.healthData(status: status, component: "db"),
                duration: 0.02
            )
        }

        XCTAssertEqual(snapshot.state, .unhealthy)
        XCTAssertEqual(snapshot.readinessStatus, .down)
        XCTAssertEqual(snapshot.livenessStatus, .up)
    }

    func testSessionHistoryIsBoundedAndTransitionsIgnoreRepeatedState() {
        let store = ActuatorSessionHistoryStore(maxObservationsPerService: 3)
        store.record(snapshot(serviceId: "orders", state: .healthy, time: 1))
        store.record(snapshot(serviceId: "orders", state: .healthy, time: 2))
        store.record(snapshot(serviceId: "orders", state: .degraded, time: 3))
        store.record(snapshot(serviceId: "orders", state: .unhealthy, time: 4))

        XCTAssertEqual(store.history(for: "orders").map(\.observedAt), [
            Date(timeIntervalSince1970: 2),
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 4),
        ])
        XCTAssertEqual(store.transitions(for: "orders").map(\.state), [.healthy, .degraded, .unhealthy])
    }

    func testPollingPolicyUsesDetailIntervalAndCapsFailureBackoff() {
        let policy = ActuatorPollingPolicy()

        XCTAssertEqual(policy.interval(isSelected: false, consecutiveFailures: 0), 30)
        XCTAssertEqual(policy.interval(isSelected: true, consecutiveFailures: 0), 10)
        XCTAssertEqual(policy.interval(isSelected: false, consecutiveFailures: 1), 60)
        XCTAssertEqual(policy.interval(isSelected: false, consecutiveFailures: 8), 120)
        XCTAssertEqual(policy.verificationInterval, 5)
    }

    func testTunnelSpecificationUsesEphemeralLoopbackBinding() {
        let service = ActuatorServiceConfiguration(
            id: "orders",
            profileId: "host-1",
            name: "Orders",
            managementHost: "127.0.0.1",
            managementPort: 8_081
        )

        let tunnel = ActuatorTunnelSpecification(service: service)

        XCTAssertEqual(tunnel.forwardId, "actuator-orders")
        XCTAssertEqual(tunnel.bindHost, "127.0.0.1")
        XCTAssertEqual(tunnel.bindPort, 0)
        XCTAssertEqual(tunnel.destinationHost, "127.0.0.1")
        XCTAssertEqual(tunnel.destinationPort, 8_081)
    }

    func testSnapshotProjectionBecomesStaleWithoutChangingRecordedState() {
        let observation = snapshot(serviceId: "orders", state: .healthy, time: 10)

        XCTAssertEqual(
            observation.effectiveState(now: Date(timeIntervalSince1970: 80), staleAfter: 60),
            .stale
        )
        XCTAssertEqual(observation.state, .healthy)
    }

    func testFleetSummaryUsesWorstConfiguredServiceState() {
        let services = [
            ActuatorServiceConfiguration(
                id: "orders",
                profileId: "host-1",
                name: "Orders",
                managementPort: 8_081
            ),
            ActuatorServiceConfiguration(
                id: "billing",
                profileId: "host-1",
                name: "Billing",
                managementPort: 8_082
            ),
        ]
        let snapshots = [
            "orders": snapshot(serviceId: "orders", state: .healthy, time: 100),
            "billing": snapshot(serviceId: "billing", state: .unhealthy, time: 100),
        ]

        let summary = ActuatorFleetSummary.make(
            profileId: "host-1",
            services: services,
            snapshots: snapshots,
            now: Date(timeIntervalSince1970: 110)
        )

        XCTAssertEqual(summary?.state, .unhealthy)
        XCTAssertEqual(summary?.serviceCount, 2)
        XCTAssertEqual(summary?.problemServiceNames, ["Billing"])
    }

    func testVerifierRequiresConsecutiveHealthyObservations() async {
        let sequence = LockedQueue([
            snapshot(serviceId: "orders", state: .unhealthy, time: 1),
            snapshot(serviceId: "orders", state: .healthy, time: 2),
            snapshot(serviceId: "orders", state: .healthy, time: 3),
            snapshot(serviceId: "orders", state: .healthy, time: 4),
        ])
        let sleeps = LockedValues<TimeInterval>()

        let result = await ActuatorHealthVerifier.verify(
            requiredConsecutiveHealthy: 3,
            maxAttempts: 5,
            interval: 0.01,
            observe: { sequence.removeFirst() },
            sleep: { sleeps.append($0) }
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.attempts, 4)
        XCTAssertEqual(sleeps.values.count, 3)
    }

    func testVerifierFailsAfterAttemptBudget() async {
        let result = await ActuatorHealthVerifier.verify(
            requiredConsecutiveHealthy: 2,
            maxAttempts: 3,
            interval: 0,
            observe: { self.snapshot(serviceId: "orders", state: .degraded, time: 1) },
            sleep: { _ in }
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(result.lastSnapshot?.state, .degraded)
    }

    private func healthData(status: String, component: String) -> Data {
        jsonData("""
        {
          "status": "\(status)",
          "components": { "\(component)": { "status": "\(status)" } }
        }
        """)
    }

    private func snapshot(
        serviceId: String,
        state: ActuatorServiceState,
        time: TimeInterval
    ) -> ActuatorHealthSnapshot {
        ActuatorHealthSnapshot(
            serviceId: serviceId,
            state: state,
            observedAt: Date(timeIntervalSince1970: time)
        )
    }

    private func jsonData(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("actuator-tests-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedQueue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value]

    init(_ values: [Value]) {
        storage = values
    }

    func removeFirst() -> Value {
        lock.withLock { storage.removeFirst() }
    }
}
