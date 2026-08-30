import Foundation
import Testing
@testable import AgentSshMacOS

/// Quoting is the last line of defence between a value a remote host
/// chose and a shell that will execute it, so these tests are written as
/// attacks rather than as examples.
struct ShellQuotingTests {
    @Test("A value containing a quote and a combining mark cannot break out")
    func combiningMarkAfterQuoteCannotBreakOut() {
        // The regression that motivated this type. `'` followed by a
        // combining acute is ONE grapheme cluster, so a grapheme-aligned
        // replace never sees the quote and passes it through unescaped,
        // closing the string and leaving the rest as shell code.
        let payload = "a\u{0027}\u{0301}; id #"
        let quoted = ShellQuoting.singleQuoted(payload)
        #expect(quoted == "'a'\\''\u{0301}; id #'")
    }

    @Test("Every apostrophe is escaped, however many and wherever placed", arguments: [
        "'", "''", "a'b", "'leading", "trailing'", "a'b'c'd",
        "\u{0027}\u{0301}", "x\u{0027}\u{0301}\u{0301}y",
    ])
    func everyApostropheEscaped(payload: String) {
        let quoted = ShellQuoting.singleQuoted(payload)
        // Compared on unicode scalars throughout: a grapheme-based
        // comparison is exactly the bug under test.
        #expect(quoted.unicodeScalars.first == "'" && quoted.unicodeScalars.last == "'")
        let inner = quoted.unicodeScalars.dropFirst().dropLast()
        // Each apostrophe in the input becomes `'\\''` — three apostrophes.
        let originals = payload.unicodeScalars.filter { $0 == "'" }.count
        let escaped = inner.filter { $0 == "'" }.count
        #expect(escaped == originals * 3)
    }

    @Test("Shell metacharacters survive as literal data")
    func metacharactersAreInert() {
        for payload in ["; id", "$(id)", "`id`", "a && id", "a | id", "$IFS", "*", "~", "\n id", "\\"] {
            let quoted = ShellQuoting.singleQuoted(payload)
            #expect(quoted == "'\(payload)'", "metacharacters need no escape inside single quotes")
        }
    }

    @Test("Empty and whitespace values still produce one shell word")
    func emptyValueIsStillOneWord() {
        #expect(ShellQuoting.singleQuoted("") == "''")
        #expect(ShellQuoting.singleQuoted(" ") == "' '")
    }

    @Test("Non-ASCII text is preserved byte for byte")
    func unicodePreserved() {
        #expect(ShellQuoting.singleQuoted("/mnt/Sicherungslaufwerk") == "'/mnt/Sicherungslaufwerk'")
        #expect(ShellQuoting.singleQuoted("日本語") == "'日本語'")
    }
}
