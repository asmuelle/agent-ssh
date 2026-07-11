import XCTest
@testable import AgentSshMacOS

final class MCPConfigurationTests: XCTestCase {
    func testMCPIsDisabledByDefault() {
        XCTAssertFalse(MCPConfiguration.defaultEnabled)
        XCTAssertFalse(MCPConfiguration.enabled(from: nil))
    }

    func testMCPUsesTheEntitledAppGroup() {
        XCTAssertEqual(
            MCPConfiguration.appGroupIdentifier,
            "group.com.agent-ssh.agent-ssh"
        )
        XCTAssertEqual(
            MCPConfiguration.appGroupIdentifier,
            SharedAppStorageConfiguration.appGroupIdentifier
        )
    }
}
