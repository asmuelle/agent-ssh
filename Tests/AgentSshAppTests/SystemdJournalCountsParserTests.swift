@testable import AgentSshApp
import AgentSshMacOS
import Foundation
import Testing

/// Covers parsing of the per-unit journal error/warning counts the
/// systemd modal's units script emits ("unit \t errors \t warnings").
struct SystemdJournalCountsParserTests {
    @Test("Tab-separated count lines parse into a per-unit dictionary")
    func parsesCounts() {
        let output = """
        nginx.service\t0\t54
        kms.service\t15\t101
        """
        let counts = parseSystemdJournalCounts(output)
        #expect(counts["kms.service"] == JournalIssueCounts(errors: 15, warnings: 101))
        #expect(counts["nginx.service"] == JournalIssueCounts(errors: 0, warnings: 54))
        #expect(counts.count == 2)
    }

    @Test("Malformed lines and empty output degrade to no counts")
    func toleratesGarbage() {
        #expect(parseSystemdJournalCounts("").isEmpty)
        #expect(parseSystemdJournalCounts("no tabs here").isEmpty)
        #expect(parseSystemdJournalCounts("unit.service\tNaN\t3").isEmpty)
    }
}
