import XCTest
@testable import AgentSshMacOS

final class FleetHealthStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-fleet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testFreshnessDistinguishesFreshAndStaleObservations() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let record = FleetHostHealthRecord(
            profileId: "api-1",
            hostName: "api-1",
            state: .healthy,
            summary: "Healthy",
            observedAt: observedAt
        )

        XCTAssertEqual(
            record.freshness(now: observedAt.addingTimeInterval(299), staleAfter: 300),
            .fresh
        )
        XCTAssertEqual(
            record.freshness(now: observedAt.addingTimeInterval(301), staleAfter: 300),
            .stale
        )
    }

    func testStorePersistsLatestSnapshotPerProfile() throws {
        let store = FleetHostHealthStore(directoryURL: directory)
        try store.record(FleetHostHealthRecord(
            profileId: "api-1",
            hostName: "api-1",
            state: .warning,
            summary: "CPU high",
            observedAt: Date(timeIntervalSince1970: 1)
        ))
        try store.record(FleetHostHealthRecord(
            profileId: "api-1",
            hostName: "api-1",
            state: .healthy,
            summary: "Recovered",
            observedAt: Date(timeIntervalSince1970: 2)
        ))

        let reloaded = FleetHostHealthStore(directoryURL: directory).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded["api-1"]?.state, .healthy)
        XCTAssertEqual(reloaded["api-1"]?.summary, "Recovered")
    }

    func testStorePrunesDeletedProfiles() throws {
        let store = FleetHostHealthStore(directoryURL: directory)
        try store.record(FleetHostHealthRecord(
            profileId: "keep",
            hostName: "keep",
            state: .healthy,
            summary: "Healthy"
        ))
        try store.record(FleetHostHealthRecord(
            profileId: "delete",
            hostName: "delete",
            state: .unknown,
            summary: "Unknown"
        ))

        try store.prune(keepingProfileIds: ["keep"])

        XCTAssertEqual(Set(store.load().keys), ["keep"])
    }
}
