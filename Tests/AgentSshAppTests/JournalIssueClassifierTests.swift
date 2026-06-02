import XCTest
@testable import AgentSshApp

final class JournalIssueClassifierTests: XCTestCase {
    func testCountsWarningsAndErrorsFromRecentJournalLines() {
        let counts = JournalIssueClassifier.counts(in: [
            "2026-05-21T09:00:00 host app[1]: started successfully",
            "2026-05-21T09:01:00 host app[1]: timeout while contacting upstream",
            "2026-05-21T09:02:00 host app[1]: fatal database connection failed",
            "2026-05-21T09:03:00 host app[1]: retrying request",
        ])

        XCTAssertEqual(counts.errors, 1)
        XCTAssertEqual(counts.warnings, 2)
    }

    func testErrorWinsWhenLineContainsWarningAndFailureTerms() {
        let counts = JournalIssueClassifier.counts(in: [
            "2026-05-21T09:00:00 host app[1]: warning: restart failed"
        ])

        XCTAssertEqual(counts.errors, 1)
        XCTAssertEqual(counts.warnings, 0)
    }

    func testShortIsoPrefixDoesNotCreateFalseIssueCount() {
        let counts = JournalIssueClassifier.counts(in: [
            "2026-05-21T09:00:00 warning-host error-reporter[1]: started"
        ])

        XCTAssertEqual(counts, .zero)
    }
}
