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

    func testJSONLevelBeatsScaryWordsInPayload() {
        // A DEBUG-level tracing line whose URI contains "denied" must not
        // count as an error — the explicit level wins over keyword regexes.
        let line = #"2026-07-04T10:50:26 host app[1]: {"timestamp":"2026-07-04T10:50:26Z","level":"DEBUG","fields":{"message":"started processing request"},"span":{"uri":"/auth/login?error=denied","name":"http_request"}}"#

        XCTAssertNil(JournalIssueClassifier.classify(line))
    }

    func testJSONErrorLevelCountsWithoutKeywordMatch() {
        // ERROR level with an innocuous message — only the level says error.
        let line = #"2026-07-04T10:50:26 host app[1]: {"level":"ERROR","fields":{"message":"upstream said no"}}"#

        XCTAssertEqual(JournalIssueClassifier.classify(line), .error)
    }

    func testJSONWarnLevelCountsAsWarning() {
        let line = #"{"level":"WARN","fields":{"message":"queue depth climbing"}}"#

        XCTAssertEqual(JournalIssueClassifier.classify(line), .warning)
    }

    func testWrapperTextStillCountsDespiteBenignEmbeddedLevel() {
        // The embedded payload says info, but the wrapper text is the actual
        // log statement — "Failed" must keep counting as an error.
        let line = #"2026-07-04T10:50:26 host relay[1]: Failed to deliver webhook: {"level":"info","event":"user.created"}"#

        XCTAssertEqual(JournalIssueClassifier.classify(line), .error)
    }
}
