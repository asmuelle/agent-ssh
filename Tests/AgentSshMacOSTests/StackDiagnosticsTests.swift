import XCTest
@testable import AgentSshMacOS

final class StackDiagnosticsTests: XCTestCase {
    func testParserBuildsStructuredStackInventory() {
        let output = """
        __AGENT_SSH_STACK__\tdockerCompose\thealthy\tshop (3 services)
        __AGENT_SSH_STACK__\tspringBoot\twarning\tapi.service active; actuator not verified
        __AGENT_SSH_STACK__\tnextjs\thealthy\tnext-server pid 123
        __AGENT_SSH_STACK__\treverseProxy\thealthy\tnginx config valid
        __AGENT_SSH_STACK__\tfirewall\twarning\tufw inactive
        __AGENT_SSH_STACK__\tpostgres\thealthy\taccepting connections
        ignored raw output
        """

        let snapshot = StackDiagnosticParser.parse(output)

        XCTAssertEqual(snapshot.components.count, 6)
        XCTAssertEqual(snapshot.components.first?.kind, .dockerCompose)
        XCTAssertEqual(snapshot.components.first?.detail, "shop (3 services)")
        XCTAssertEqual(snapshot.components[1].state, .warning)
        XCTAssertEqual(snapshot.rawOutput, output)
    }

    func testParserRejectsUnknownAndMalformedRecords() {
        let output = """
        __AGENT_SSH_STACK__\tunknown\thealthy\tdetail
        __AGENT_SSH_STACK__\tpostgres\tinvalid-state\tdetail
        __AGENT_SSH_STACK__\tpostgres\thealthy
        """

        XCTAssertTrue(StackDiagnosticParser.parse(output).components.isEmpty)
    }

    func testProbeScriptIsReadOnlyAndCoversRequestedStack() {
        let script = StackDiagnosticProbe.script.lowercased()

        for required in ["docker compose", "spring", "next", "nginx", "caddy", "traefik", "ufw", "firewall-cmd", "nft", "pg_isready"] {
            XCTAssertTrue(script.contains(required), "Missing stack probe for \(required)")
        }
        for mutation in ["systemctl restart", "docker prune", "docker compose up", "apt install", "dnf install", "rm -"] {
            XCTAssertFalse(script.contains(mutation), "Probe must stay read-only: \(mutation)")
        }
    }
}
