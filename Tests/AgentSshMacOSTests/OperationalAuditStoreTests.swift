import XCTest
@testable import AgentSshMacOS

final class OperationalAuditStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAppendPersistsRedactedRecord() throws {
        let store = OperationalAuditStore(directoryURL: directory, maxEvents: 10)
        let event = OperationalAuditRecord(
            date: Date(timeIntervalSince1970: 100),
            profileId: "prod-api",
            connectionId: "connection-1",
            actor: .user,
            action: "runbook",
            title: "Deploy",
            detail: "Authorization: Bearer top-secret",
            command: "PASSWORD=hunter2 ./deploy.sh",
            outcome: .succeeded,
            exitCode: 0
        )

        try store.append(event)

        let reloaded = OperationalAuditStore(directoryURL: directory, maxEvents: 10).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].detail, "Authorization: [redacted]")
        XCTAssertEqual(reloaded[0].command, "PASSWORD=[redacted] ./deploy.sh")
        XCTAssertEqual(reloaded[0].profileId, "prod-api")
        XCTAssertEqual(reloaded[0].exitCode, 0)
    }

    func testAppendKeepsNewestRecordsWithinRetentionLimit() throws {
        let store = OperationalAuditStore(directoryURL: directory, maxEvents: 2)

        for index in 1...3 {
            try store.append(OperationalAuditRecord(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                actor: .app,
                action: "monitor",
                title: "Event \(index)",
                detail: "detail",
                outcome: .observed
            ))
        }

        XCTAssertEqual(store.load().map(\.title), ["Event 3", "Event 2"])
    }

    func testMalformedLedgerFailsClosedToEmptyHistory() throws {
        let fileURL = directory.appendingPathComponent(SharedAppStorageConfiguration.operationalAuditFileName)
        try Data("not-json".utf8).write(to: fileURL)
        let store = OperationalAuditStore(directoryURL: directory, maxEvents: 10)

        XCTAssertEqual(store.load(), [])
    }
}
