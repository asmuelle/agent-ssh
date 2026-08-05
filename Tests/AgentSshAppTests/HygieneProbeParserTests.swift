@testable import AgentSshApp
import AgentSshMacOS
import Foundation
import Testing

/// Covers parsing of the combined hygiene-probe output (failed
/// systemd units, docker container problems, journal issue counts)
/// that feeds the fleet dashboard's problem chips.
struct HygieneProbeParserTests {
    private let separator = "__AGENT_SSH_HYGIENE_SEP__"

    private func parse(_ output: String) -> HygieneSnapshot {
        SystemMonitorView.parseHygieneOutput(output, separator: separator)
    }

    @Test("Empty output yields an empty snapshot")
    func emptyOutput() {
        let snapshot = parse("\n\(separator)\n\(separator)\n")
        #expect(snapshot.failedUnits.isEmpty)
        #expect(snapshot.dockerProblems.isEmpty)
        #expect(snapshot.journalErrors == 0)
        #expect(snapshot.journalWarnings == 0)
    }

    @Test("Failed units come from the first systemctl column")
    func failedUnits() {
        let output = """
        nginx.service loaded failed failed A high performance web server
        redis-server.service loaded failed failed Advanced key-value store
        \(separator)
        \(separator)
        """
        let snapshot = parse(output)
        #expect(snapshot.failedUnits == ["nginx.service", "redis-server.service"])
    }

    @Test("Docker problems are deduplicated across the two filters")
    func dockerProblems() {
        let output = """
        \(separator)
        api|Up 2 hours (unhealthy)
        api|Restarting (1) 5 seconds ago
        worker|Restarting (137) 2 seconds ago
        \(separator)
        """
        let snapshot = parse(output)
        #expect(snapshot.dockerProblems == [
            "api (Up 2 hours (unhealthy))",
            "worker (Restarting (137) 2 seconds ago)",
        ])
    }

    @Test("Journal lines are classified into error and warning counts")
    func journalCounts() {
        let output = """
        \(separator)
        \(separator)
        Aug 04 12:00:01 host kernel: <3>oom-kill: process 1234 error out of memory
        Aug 04 12:00:02 host sshd[1]: error: kex_exchange_identification failed
        """
        let snapshot = parse(output)
        #expect(snapshot.journalErrors + snapshot.journalWarnings >= 1)
    }

    @Test("Garbage without separators degrades to no findings")
    func garbageOutput() {
        let snapshot = parse("command not found")
        // No dots in "command" / "not" / "found" tokens → no units.
        #expect(snapshot.failedUnits.isEmpty)
        #expect(snapshot.dockerProblems.isEmpty)
    }
}
