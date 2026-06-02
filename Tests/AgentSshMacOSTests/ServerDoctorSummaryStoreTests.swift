import XCTest
@testable import AgentSshMacOS

final class ServerDoctorSummaryStoreTests: XCTestCase {
    private func makeStore() -> (ServerDoctorSummaryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-doctor-summary-tests")
            .appendingPathComponent(UUID().uuidString)
        let store = ServerDoctorSummaryStore(directoryURL: directory)
        return (store, directory)
    }

    // Whole-second, recent timestamp: the store serializes dates as ISO8601
    // (second resolution), so a sub-second `Date()` would not survive a round
    // trip; and it must be fresh for the staleness filter to return it.
    private static let recentDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func makeSummary(
        profileId: String = "profile-1",
        severity: ServerDoctorSeverity = .high,
        headline: String = "Disk almost full on /var",
        generatedAt: Date = ServerDoctorSummaryStoreTests.recentDate
    ) -> ServerDoctorHostSummary {
        ServerDoctorHostSummary(
            profileId: profileId,
            hostLabel: "web-01",
            headline: headline,
            overallSeverity: severity,
            topFindingTitle: "Disk pressure on /var",
            findingCount: 2,
            generatedAt: generatedAt,
            narratedOnDevice: true
        )
    }

    func testUpsertRoundTripsViaExplicitDirectory() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let summary = makeSummary()
        try store.upsert(summary)

        let loaded = try store.load()
        XCTAssertEqual(loaded, [summary])
        XCTAssertEqual(store.summary(profileId: "profile-1"), summary)
    }

    func testUpsertReplacesExistingSummaryForSameProfile() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsert(makeSummary(headline: "old"))
        try store.upsert(makeSummary(headline: "new"))

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.headline, "new")
    }

    func testStaleSummaryIsNotReturned() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Date().addingTimeInterval(-(ServerDoctorSummaryStore.staleAfter + 60))
        try store.upsert(makeSummary(generatedAt: old))

        XCTAssertNil(store.summary(profileId: "profile-1"))
        // The record is still persisted, just filtered by freshness.
        XCTAssertEqual(try store.load().count, 1)
    }

    func testRemoveDeletesSummary() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.upsert(makeSummary(profileId: "a"))
        try store.upsert(makeSummary(profileId: "b"))
        try store.remove(profileId: "a")

        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.profileId), ["b"])
    }

    func testProviderKindDefaultsToAppleIntelligence() {
        let defaults = UserDefaults(suiteName: "doctor-prefs-\(UUID().uuidString)")!
        XCTAssertEqual(ServerDoctorPreferences.providerKind(from: defaults), .appleIntelligence)

        defaults.set(ServerDoctorProviderKind.heuristics.rawValue, forKey: ServerDoctorPreferences.providerKindKey)
        XCTAssertEqual(ServerDoctorPreferences.providerKind(from: defaults), .heuristics)
    }
}
