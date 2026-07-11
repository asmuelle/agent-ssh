import XCTest
@testable import AgentSshMacOS

final class ExplainServiceTests: XCTestCase {
    // MARK: - Input pipeline (redact → budget)

    func testRedactsSecretsBeforeBudgeting() {
        let input = "service failed: DATABASE_URL=postgres://admin:hunter2@db.internal:5432/app password=swordfish"

        let prepared = ExplainService.prepareInput(input, preset: .balanced)

        XCTAssertFalse(prepared.text.contains("hunter2"))
        XCTAssertFalse(prepared.text.contains("swordfish"))
        XCTAssertGreaterThanOrEqual(prepared.redactionCount, 2)
        XCTAssertFalse(prepared.truncated)
    }

    func testRedactsPrivateKeyBlocks() {
        let input = """
        found key file:
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmU
        -----END OPENSSH PRIVATE KEY-----
        done
        """

        let prepared = ExplainService.prepareInput(input, preset: .balanced)

        XCTAssertFalse(prepared.text.contains("b3BlbnNzaC1rZXktdjEA"))
        XCTAssertTrue(prepared.text.contains("[redacted private key]"))
    }

    func testTruncatesOversizedInputAndMarksIt() {
        let input = String(repeating: "journal line with detail\n", count: 2_000)

        let prepared = ExplainService.prepareInput(input, preset: .balanced)

        XCTAssertTrue(prepared.truncated)
        XCTAssertTrue(prepared.text.hasSuffix("[…truncated]"))
        XCTAssertLessThanOrEqual(
            prepared.text.count,
            ExplainService.inputBudget + "\n[…truncated]".count
        )
    }

    func testRedactionRunsBeforeTruncation() {
        // A private-key block straddling the budget boundary is where the
        // order of operations matters: the key regex requires BOTH the BEGIN
        // and END markers. Truncate-first would cut off the END marker, the
        // regex would no longer match, and the raw key body inside the kept
        // prefix would leak verbatim. Redact-first replaces the whole block
        // before any truncation can split it.
        let keyBody = String(repeating: "QmFzZTY0S2V5TWF0ZXJpYWxTZW50aW5lbA==\n", count: 4)
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(keyBody)-----END OPENSSH PRIVATE KEY-----"
        // Position the block so BEGIN + part of the body fit inside the
        // budget but END falls beyond it.
        let padding = String(repeating: "x", count: ExplainService.inputBudget - 80)
        let input = padding + "\n" + key

        let prepared = ExplainService.prepareInput(input, preset: .balanced)

        XCTAssertFalse(prepared.text.contains("QmFzZTY0S2V5TWF0ZXJpYWxTZW50aW5lbA"))
        XCTAssertTrue(prepared.text.contains("[redacted private key]"))
    }

    func testEmptyInputStaysEmpty() {
        let prepared = ExplainService.prepareInput("   \n  ", preset: .balanced)

        XCTAssertTrue(prepared.text.isEmpty)
    }

    func testStrictPresetAlsoRedactsAddresses() {
        let input = "connection from 203.0.113.7 for admin@example.com refused"

        let prepared = ExplainService.prepareInput(input, preset: .strict)

        XCTAssertFalse(prepared.text.contains("203.0.113.7"))
        XCTAssertFalse(prepared.text.contains("admin@example.com"))
    }

    // MARK: - Availability contract

    func testExplainThrowsRatherThanHangsWhenUnavailable() async throws {
        // On CI/dev machines without Apple Intelligence the service must
        // fail fast with a clear error, never silently succeed.
        guard !ExplainService.isAvailable else {
            throw XCTSkip("On-device model available — generation path not exercised in unit tests.")
        }
        do {
            _ = try await ExplainService.explain(text: "some output", context: "test")
            XCTFail("Expected unavailable error")
        } catch {
            XCTAssertTrue(error is ExplainServiceError)
        }
    }
}
