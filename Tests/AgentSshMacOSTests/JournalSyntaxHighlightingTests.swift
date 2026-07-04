import XCTest
import SwiftUI
@testable import AgentSshMacOS

final class JournalSyntaxHighlightingTests: XCTestCase {
    // Real tracing_subscriber line as produced by a tower_http service.
    private let tracingLine = #"{"timestamp":"2026-07-04T10:50:26.168773Z","level":"DEBUG","fields":{"message":"started processing request"},"target":"tower_http::trace::on_request","span":{"method":"GET","request_id":"kems-000000000000008c","uri":"/auth/login?return_to=%2f/site/wp-includes/wlwmanifest.xml","name":"http_request"},"spans":[{"method":"GET","request_id":"kems-000000000000008c","uri":"/auth/login?return_to=%2f/site/wp-includes/wlwmanifest.xml","name":"http_request"}]}"#

    // MARK: - JSON payload detection

    func testDetectsWholeLineJSONPayload() {
        let range = JournalSyntaxHighlighting.jsonPayloadRange(in: tracingLine)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, tracingLine.startIndex)
        XCTAssertEqual(range?.upperBound, tracingLine.endIndex)
    }

    func testDetectsPrefixedJSONPayload() {
        let line = #"myapp[4242]: {"level":"INFO","fields":{"message":"listening"}}"#

        let range = JournalSyntaxHighlighting.jsonPayloadRange(in: line)

        XCTAssertNotNil(range)
        XCTAssertEqual(range.map { String(line[$0]) }, #"{"level":"INFO","fields":{"message":"listening"}}"#)
    }

    func testDetectsJSONArrayPayload() {
        let line = #"batch result: [1, 2, 3]"#

        let range = JournalSyntaxHighlighting.jsonPayloadRange(in: line)

        XCTAssertEqual(range.map { String(line[$0]) }, "[1, 2, 3]")
    }

    func testRejectsMalformedJSON() {
        XCTAssertNil(JournalSyntaxHighlighting.jsonPayloadRange(in: #"broken {"level":"INFO", oops"#))
        XCTAssertNil(JournalSyntaxHighlighting.jsonPayloadRange(in: "no braces at all"))
        XCTAssertNil(JournalSyntaxHighlighting.jsonPayloadRange(in: #"unbalanced {"a": 1"#))
    }

    func testRejectsJSONWithTrailingGarbage() {
        XCTAssertNil(JournalSyntaxHighlighting.jsonPayloadRange(in: #"{"a": 1} and then more text"#))
    }

    func testDetectsArrayPayloadAfterBracketPrefix() {
        // The pid bracket must not mask the array payload.
        let line = #"sshd[1234]: ["10.0.0.1", "10.0.0.2"]"#

        let range = JournalSyntaxHighlighting.jsonPayloadRange(in: line)

        XCTAssertEqual(range.map { String(line[$0]) }, #"["10.0.0.1", "10.0.0.2"]"#)
        XCTAssertNotNil(JournalSyntaxHighlighting.prettyPrintedJSON(in: "sshd[1]: [1, 2, 3]"))
    }

    func testDetectsObjectPayloadAfterBraceNoiseInPrefix() {
        // Braces in the human-readable prefix must not mask the payload.
        let line = #"handler {main} rejected: {"level":"ERROR","message":"denied"}"#

        let range = JournalSyntaxHighlighting.jsonPayloadRange(in: line)

        XCTAssertEqual(range.map { String(line[$0]) }, #"{"level":"ERROR","message":"denied"}"#)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: line), .error)
    }

    func testDetectsPayloadWithTrailingWhitespace() {
        let line = "{\"a\": 1}   \t"

        XCTAssertEqual(
            JournalSyntaxHighlighting.jsonPayloadRange(in: line).map { String(line[$0]) },
            #"{"a": 1}"#
        )
    }

    // MARK: - Level extraction

    func testExtractsDebugLevelFromTracingLine() {
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: tracingLine), .debug)
    }

    func testExtractsLevelVariants() {
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"level":"WARN"}"#), .warning)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"level":"error"}"#), .error)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"severity":"CRITICAL"}"#), .critical)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"lvl":"trace"}"#), .trace)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{ "level" : "NOTICE" }"#), .notice)
    }

    func testNoLevelInPlainTextLine() {
        XCTAssertNil(JournalSyntaxHighlighting.jsonSeverity(in: "error: connection refused"))
        XCTAssertNil(JournalSyntaxHighlighting.jsonSeverity(in: #"{"message":"no level here"}"#))
    }

    func testLevelParsingCoversSyslogNames() {
        XCTAssertEqual(JournalJSONLevel.parse("EMERG"), .critical)
        XCTAssertEqual(JournalJSONLevel.parse("panic"), .critical)
        XCTAssertEqual(JournalJSONLevel.parse("Err"), .error)
        XCTAssertEqual(JournalJSONLevel.parse("informational"), .info)
        XCTAssertNil(JournalJSONLevel.parse("verbose"))
    }

    func testTopLevelLevelWinsOverNested() {
        // Only the entry's own top-level level counts, not one nested in a
        // sub-object — regardless of key order on the wire.
        let line = #"{"fields":{"level":"ERROR"},"level":"DEBUG"}"#

        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: line), .debug)
    }

    func testBunyanNumericLevels() {
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"level":50,"msg":"boom"}"#), .error)
        XCTAssertEqual(JournalSyntaxHighlighting.jsonSeverity(in: #"{"level":30,"msg":"ok"}"#), .info)
    }

    func testAssessSeparatesWrapperTextFromPayload() {
        // A plain-text wrapper around an embedded payload keeps its own text
        // available for keyword scanning — the payload's benign level must
        // not swallow "Failed".
        let line = #"Failed to deliver webhook: {"level":"info","event":"user.created"}"#

        let assessment = JournalSyntaxHighlighting.assess(message: line)

        XCTAssertEqual(assessment.level, .info)
        XCTAssertTrue(assessment.residualText.contains("Failed to deliver webhook"))
        XCTAssertFalse(assessment.residualText.contains("user.created"))
    }

    func testAssessKeepsWholeMessageWithoutExplicitLevel() {
        let line = #"{"message":"connection failed"}"#

        let assessment = JournalSyntaxHighlighting.assess(message: line)

        XCTAssertNil(assessment.level)
        XCTAssertEqual(assessment.residualText, line)
    }

    // MARK: - Pretty printing

    func testPrettyPrintedJSONExpandsPayload() throws {
        let pretty = try XCTUnwrap(JournalSyntaxHighlighting.prettyPrintedJSON(in: tracingLine))

        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertTrue(pretty.contains(#""level" : "DEBUG""#) || pretty.contains(#""level": "DEBUG""#))
        XCTAssertTrue(pretty.contains("/auth/login?return_to="))
    }

    func testPrettyPrintedJSONNilForPlainText() {
        XCTAssertNil(JournalSyntaxHighlighting.prettyPrintedJSON(in: "plain old log line"))
    }

    // MARK: - JSON highlighting

    func testJSONKeysAndValuesGetDistinctColors() throws {
        let attributed = JournalSyntaxHighlighting.highlighted(message: tracingLine)

        let keyColor = try XCTUnwrap(color(of: #""level""#, in: attributed))
        let stringColor = try XCTUnwrap(color(of: #""DEBUG""#, in: attributed))
        XCTAssertNotEqual(keyColor, stringColor)
        XCTAssertEqual(color(of: #""timestamp""#, in: attributed), keyColor)
        XCTAssertEqual(color(of: #""tower_http::trace::on_request""#, in: attributed), stringColor)
    }

    func testJSONMessageValueIsEmphasizedNotColored() throws {
        let attributed = JournalSyntaxHighlighting.highlighted(message: tracingLine)

        let style = try XCTUnwrap(styles(of: #""started processing request""#, in: attributed))
        XCTAssertNil(style.color)
        XCTAssertTrue(style.emphasized)
    }

    func testJSONNumbersAndKeywordsAreColored() throws {
        let line = #"{"count": 42, "ratio": -3.5e2, "ok": true, "extra": null}"#

        let attributed = JournalSyntaxHighlighting.highlighted(message: line)

        let numberColor = try XCTUnwrap(color(of: "42", in: attributed))
        XCTAssertEqual(color(of: "-3.5e2", in: attributed), numberColor)
        let keywordColor = try XCTUnwrap(color(of: "true", in: attributed))
        XCTAssertEqual(color(of: "null", in: attributed), keywordColor)
        XCTAssertNotEqual(numberColor, keywordColor)
    }

    func testJSONWithEscapedQuotesKeepsTokenBoundaries() throws {
        let line = #"{"message":"user said \"hi\" today","level":"INFO"}"#

        let attributed = JournalSyntaxHighlighting.highlighted(message: line)

        let style = try XCTUnwrap(styles(of: #""user said \"hi\" today""#, in: attributed))
        XCTAssertTrue(style.emphasized)
        XCTAssertNotNil(color(of: #""INFO""#, in: attributed))
    }

    func testHighlightingPreservesOriginalText() {
        for line in [tracingLine, #"level=info msg="ready" port=8080"#, "plain text"] {
            let attributed = JournalSyntaxHighlighting.highlighted(message: line)
            XCTAssertEqual(String(attributed.characters), line)
        }
    }

    func testPrefixBeforeJSONStaysUncolored() throws {
        let line = #"myapp[7]: {"level":"INFO"}"#

        let attributed = JournalSyntaxHighlighting.highlighted(message: line)

        let style = try XCTUnwrap(styles(of: "myapp[7]: ", in: attributed))
        XCTAssertNil(style.color)
    }

    // MARK: - Plain-text highlighting

    func testLogfmtKeysQuotedStringsAndNumbersAreColored() throws {
        let line = #"level=info msg="server ready" addr=0.0.0.0:8080 took=12ms"#

        let attributed = JournalSyntaxHighlighting.highlighted(message: line)

        XCTAssertNotNil(color(of: "level", in: attributed))
        XCTAssertNotNil(color(of: #""server ready""#, in: attributed))
        XCTAssertNotNil(color(of: "0.0.0.0:8080", in: attributed))
        XCTAssertNotNil(color(of: "12ms", in: attributed))
        XCTAssertNotEqual(color(of: "level", in: attributed), color(of: #""server ready""#, in: attributed))
    }

    func testPlainSentenceKeepsWordsUncolored() throws {
        let line = "Started Session 12 of user root."

        let attributed = JournalSyntaxHighlighting.highlighted(message: line)

        let style = try XCTUnwrap(styles(of: "Started Session ", in: attributed))
        XCTAssertNil(style.color)
        XCTAssertNotNil(color(of: "12", in: attributed))
    }

    func testPercentUnitIsColoredAsOneToken() {
        let attributed = JournalSyntaxHighlighting.highlighted(message: "cpu 95% load 12ms wait")

        XCTAssertNotNil(color(of: "95%", in: attributed))
        XCTAssertNotNil(color(of: "12ms", in: attributed))
    }

    func testUnicodeRoundTripsThroughBothPasses() throws {
        let jsonLine = #"{"level":"INFO","fields":{"message":"déployé 🚀 完了"}}"#
        let plainLine = #"level=info msg="🚀 déployé" size=5MiB"#

        for line in [jsonLine, plainLine] {
            let attributed = JournalSyntaxHighlighting.highlighted(message: line)
            XCTAssertEqual(String(attributed.characters), line)
        }
        let style = try XCTUnwrap(
            styles(of: #""déployé 🚀 完了""#, in: JournalSyntaxHighlighting.highlighted(message: jsonLine))
        )
        XCTAssertTrue(style.emphasized)
        XCTAssertNotNil(color(of: "5MiB", in: JournalSyntaxHighlighting.highlighted(message: plainLine)))
    }

    // MARK: - Helpers

    /// The uniform styling of `substring` inside `attributed`, or nil when
    /// the substring is absent or split across runs with differing
    /// attributes.
    private func styles(
        of substring: String, in attributed: AttributedString
    ) -> (color: Color?, emphasized: Bool)? {
        guard let range = attributed.range(of: substring) else { return nil }
        var colors: [Color?] = []
        var intents: [InlinePresentationIntent?] = []
        for run in attributed[range].runs {
            colors.append(run.foregroundColor)
            intents.append(run.inlinePresentationIntent)
        }
        guard let firstColor = colors.first, colors.allSatisfy({ $0 == firstColor }),
              let firstIntent = intents.first, intents.allSatisfy({ $0 == firstIntent })
        else { return nil }
        return (firstColor, firstIntent == .stronglyEmphasized)
    }

    private func color(of substring: String, in attributed: AttributedString) -> Color? {
        styles(of: substring, in: attributed)?.color
    }
}
