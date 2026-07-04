import XCTest

// `MobileServerHealth.swift` is compiled directly into this logic-test target
// (see project.yml), so these tests exercise the exact heuristics the app ships
// without a `@testable import` of the full iOS app or the Rust FFI bridge.

final class ServerHealthEvaluatorTests: XCTestCase {
    private func sample(
        cpu: Double = 5,
        load: Double = 0.2,
        memUsed: UInt64 = 1,
        memTotal: UInt64 = 10,
        disks: [MobileServerResourceSample.Disk] = []
    ) -> MobileServerResourceSample {
        MobileServerResourceSample(
            cpuPercent: cpu,
            loadAverage1m: load,
            memoryUsed: memUsed,
            memoryTotal: memTotal,
            swapUsed: 0,
            swapTotal: 0,
            disks: disks,
            uptimeSeconds: 3_600
        )
    }

    private func disk(_ mount: String, usedPercent: Double) -> MobileServerResourceSample.Disk {
        // total 100 so used == percentage
        MobileServerResourceSample.Disk(mount: mount, used: UInt64(usedPercent), total: 100)
    }

    // MARK: - Resource thresholds

    func testHealthySampleHasNoIssues() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: sample(cpu: 20, memUsed: 3, memTotal: 10, disks: [disk("/", usedPercent: 40)]),
            firewall: .protected,
            failedServices: []
        )
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(MobileServerHealthEvaluator.overallSeverity(issues), .ok)
    }

    func testCPUWarningAndCriticalThresholds() {
        let warning = MobileServerHealthEvaluator.evaluate(
            sample: sample(cpu: 88), firewall: .protected, failedServices: []
        )
        XCTAssertEqual(warning.first(where: { $0.id == "cpu" })?.severity, .warning)

        let critical = MobileServerHealthEvaluator.evaluate(
            sample: sample(cpu: 96), firewall: .protected, failedServices: []
        )
        XCTAssertEqual(critical.first(where: { $0.id == "cpu" })?.severity, .critical)
    }

    func testMemoryCriticalThreshold() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: sample(memUsed: 96, memTotal: 100),
            firewall: .protected,
            failedServices: []
        )
        XCTAssertEqual(issues.first(where: { $0.id == "memory" })?.severity, .critical)
    }

    func testDiskIssuesAreCappedAtTwoFullest() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: sample(disks: [
                disk("/", usedPercent: 90),
                disk("/data", usedPercent: 99),
                disk("/backup", usedPercent: 86),
            ]),
            firewall: .protected,
            failedServices: []
        )
        let diskIssues = issues.filter { $0.id.hasPrefix("disk:") }
        XCTAssertEqual(diskIssues.count, 2)
        // The fullest (critical) must be present; the least-full over-threshold dropped.
        XCTAssertTrue(diskIssues.contains { $0.id == "disk:/data" && $0.severity == .critical })
        XCTAssertFalse(diskIssues.contains { $0.id == "disk:/backup" })
    }

    func testNoSampleProducesNoResourceIssues() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: nil, firewall: .protected, failedServices: []
        )
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Firewall

    func testFirewallSignals() {
        XCTAssertTrue(MobileServerHealthEvaluator.evaluate(sample: nil, firewall: .protected, failedServices: []).isEmpty)
        XCTAssertTrue(MobileServerHealthEvaluator.evaluate(sample: nil, firewall: .unavailable, failedServices: []).isEmpty)
        XCTAssertTrue(MobileServerHealthEvaluator.evaluate(sample: nil, firewall: .unknown, failedServices: []).isEmpty)

        let inactive = MobileServerHealthEvaluator.evaluate(sample: nil, firewall: .inactive, failedServices: [])
        XCTAssertEqual(inactive.first?.id, "firewall")
        XCTAssertEqual(inactive.first?.severity, .warning)

        let open = MobileServerHealthEvaluator.evaluate(sample: nil, firewall: .open(["8080"]), failedServices: [])
        XCTAssertEqual(open.first?.id, "firewall")
        XCTAssertEqual(open.first?.severity, .warning)
    }

    // MARK: - Failed services

    func testFailedServicesIssue() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: nil, firewall: .protected, failedServices: ["nginx.service", "redis.service"]
        )
        let issue = issues.first { $0.id == "services" }
        XCTAssertNotNil(issue)
        XCTAssertEqual(issue?.severity, .warning)
        XCTAssertTrue(issue?.title.contains("2 failed services") ?? false)
    }

    func testFailedServicesIgnoresBlankEntries() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: nil, firewall: .protected, failedServices: ["   "]
        )
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Severity rollup ordering

    func testOverallSeverityIsWorstAndIssuesSortCriticalFirst() {
        let issues = MobileServerHealthEvaluator.evaluate(
            sample: sample(cpu: 96, disks: [disk("/", usedPercent: 88)]),
            firewall: .inactive,
            failedServices: []
        )
        XCTAssertEqual(MobileServerHealthEvaluator.overallSeverity(issues), .critical)
        XCTAssertEqual(issues.first?.severity, .critical)
    }
}

final class FirewallStatusParserTests: XCTestCase {
    func testInactive() {
        XCTAssertEqual(MobileFirewallStatusParser.parse(output: "Status: inactive", sshPort: 22), .inactive)
    }

    func testUnavailableMarker() {
        XCTAssertEqual(
            MobileFirewallStatusParser.parse(output: mobileUFWUnavailableMarker, sshPort: 22),
            .unavailable
        )
    }

    func testActiveWithOnlyAllowedPortsIsProtected() {
        let output = """
        Status: active

             To                         Action      From
             --                         ------      ----
        [ 1] 22/tcp                     ALLOW IN    Anywhere
        [ 2] 80/tcp                     ALLOW IN    Anywhere
        [ 3] 443/tcp                    ALLOW IN    Anywhere
        """
        XCTAssertEqual(MobileFirewallStatusParser.parse(output: output, sshPort: 22), .protected)
    }

    func testActiveWithUnexpectedPublicPortIsOpen() {
        let output = """
        Status: active

             To                         Action      From
             --                         ------      ----
        [ 1] 22/tcp                     ALLOW IN    Anywhere
        [ 2] 8080/tcp                   ALLOW IN    Anywhere
        """
        guard case .open(let ports) = MobileFirewallStatusParser.parse(output: output, sshPort: 22) else {
            return XCTFail("Expected .open")
        }
        XCTAssertTrue(ports.contains { $0.hasPrefix("8080") })
    }

    func testActivePortRestrictedToPrivateSourceIsNotFlagged() {
        let output = """
        Status: active

             To                         Action      From
             --                         ------      ----
        [ 1] 8080/tcp                   ALLOW IN    10.0.0.0/8
        """
        XCTAssertEqual(MobileFirewallStatusParser.parse(output: output, sshPort: 22), .protected)
    }

    func testCustomSSHPortIsAllowed() {
        let output = """
        Status: active
        [ 1] 2222/tcp                   ALLOW IN    Anywhere
        """
        XCTAssertEqual(MobileFirewallStatusParser.parse(output: output, sshPort: 2222), .protected)
    }

    func testUnreadableStatusIsUnknown() {
        XCTAssertEqual(
            MobileFirewallStatusParser.parse(output: "ERROR: permission denied", sshPort: 22),
            .unknown
        )
    }
}
