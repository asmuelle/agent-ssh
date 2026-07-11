import XCTest
@testable import AgentSshMacOS

final class ConfigSaveRecoveryTests: XCTestCase {
    func testSuccessfulRollbackReportsRestoredState() {
        let status = ConfigRollbackStatus.commandResult(exitCode: 0, output: "")

        XCTAssertEqual(status, .restored)
    }

    func testFailedRollbackPreservesRemoteCommandOutput() {
        let status = ConfigRollbackStatus.commandResult(
            exitCode: 1,
            output: "cp: cannot create regular file: Permission denied"
        )

        XCTAssertEqual(
            status,
            .failed(detail: "cp: cannot create regular file: Permission denied")
        )
    }

    func testFailedRollbackFallsBackToExitCodeWhenOutputIsEmpty() {
        let status = ConfigRollbackStatus.commandResult(exitCode: 23, output: "\n")

        XCTAssertEqual(status, .failed(detail: "Rollback command exited with status 23."))
    }

    func testValidationFailureOnlyClaimsRestoreWhenRollbackSucceeded() {
        let restored = ConfigValidationRecoveryFailure(
            validator: "nginx validation",
            validationOutput: "nginx: configuration test failed",
            backupPath: "/etc/nginx/nginx.conf.agent-ssh.bak",
            rollbackStatus: .restored
        )
        let failed = ConfigValidationRecoveryFailure(
            validator: "nginx validation",
            validationOutput: "nginx: configuration test failed",
            backupPath: "/etc/nginx/nginx.conf.agent-ssh.bak",
            rollbackStatus: .failed(detail: "Permission denied")
        )
        let unknown = ConfigValidationRecoveryFailure(
            validator: "nginx validation",
            validationOutput: "nginx: configuration test failed",
            backupPath: "/etc/nginx/nginx.conf.agent-ssh.bak",
            rollbackStatus: .unknown(detail: "SSH connection closed")
        )

        XCTAssertTrue(restored.localizedDescription.contains("was restored"))
        XCTAssertFalse(failed.localizedDescription.contains("was restored"))
        XCTAssertTrue(failed.localizedDescription.contains("ROLLBACK FAILED"))
        XCTAssertFalse(unknown.localizedDescription.contains("was restored"))
        XCTAssertTrue(unknown.localizedDescription.contains("ROLLBACK STATUS UNKNOWN"))
    }
}
