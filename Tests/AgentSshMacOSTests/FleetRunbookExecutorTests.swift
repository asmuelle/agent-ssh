import XCTest
@testable import AgentSshMacOS

final class FleetRunbookExecutorTests: XCTestCase {
    func testCanaryFailureAbortsRolloutTargets() async {
        let calls = FleetRunnerProbe()
        let plan = FleetRunbookPlan(
            title: "Restart API",
            command: "systemctl restart api",
            targets: targets(3),
            canaryCount: 1,
            maxConcurrency: 2
        )

        let result = await FleetRunbookExecutor.execute(plan: plan) { target, command in
            await calls.record(target: target, command: command)
            return FleetCommandExecution(exitCode: target.profileId == "host-1" ? 1 : 0, output: "")
        }

        XCTAssertTrue(result.abortedAfterCanary)
        let calledProfileIds = await calls.profileIds()
        XCTAssertEqual(calledProfileIds, ["host-1"])
        XCTAssertEqual(result.results.map(\.state), [.failed, .skipped, .skipped])
    }

    func testRolloutHonorsMaximumConcurrency() async {
        let probe = FleetConcurrencyProbe()
        let plan = FleetRunbookPlan(
            title: "Read health",
            command: "uptime",
            targets: targets(5),
            canaryCount: 1,
            maxConcurrency: 2
        )

        let result = await FleetRunbookExecutor.execute(plan: plan) { _, _ in
            await probe.started()
            try? await Task.sleep(for: .milliseconds(20))
            await probe.finished()
            return FleetCommandExecution(exitCode: 0, output: "ok")
        }

        XCTAssertFalse(result.abortedAfterCanary)
        let peak = await probe.peak()
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertTrue(result.results.allSatisfy { $0.state == .succeeded })
    }

    func testVerificationFailureRunsRollback() async {
        let calls = FleetRunnerProbe()
        let plan = FleetRunbookPlan(
            title: "Deploy",
            command: "deploy",
            verificationCommand: "verify",
            rollbackCommand: "rollback",
            targets: targets(1),
            canaryCount: 1,
            maxConcurrency: 1
        )

        let result = await FleetRunbookExecutor.execute(plan: plan) { target, command in
            await calls.record(target: target, command: command)
            return FleetCommandExecution(
                exitCode: command == "verify" ? 1 : 0,
                output: command
            )
        }

        let commands = await calls.commands()
        XCTAssertEqual(commands, ["deploy", "verify", "rollback"])
        XCTAssertEqual(result.results.first?.state, .rolledBack)
        XCTAssertEqual(result.results.first?.verificationExitCode, 1)
        XCTAssertEqual(result.results.first?.rollbackExitCode, 0)
    }

    private func targets(_ count: Int) -> [FleetRunTarget] {
        (1...count).map {
            FleetRunTarget(
                profileId: "host-\($0)",
                connectionId: "connection-\($0)",
                displayName: "Host \($0)"
            )
        }
    }
}

private actor FleetRunnerProbe {
    private var calls: [(String, String)] = []

    func record(target: FleetRunTarget, command: String) {
        calls.append((target.profileId, command))
    }

    func profileIds() -> [String] { calls.map(\.0) }
    func commands() -> [String] { calls.map(\.1) }
}

private actor FleetConcurrencyProbe {
    private var active = 0
    private var peakValue = 0

    func started() {
        active += 1
        peakValue = max(peakValue, active)
    }

    func finished() {
        active -= 1
    }

    func peak() -> Int { peakValue }
}
