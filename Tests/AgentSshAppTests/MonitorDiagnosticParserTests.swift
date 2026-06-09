import Foundation
import Testing
@testable import AgentSshApp

/// Tests for `MonitorDiagnosticParser`, extracted from the former monolithic
/// `SystemMonitorView.swift`. It turns the tab-separated, tagged output of the
/// remote diagnostic scripts into typed `*Diagnostic` models. The parser is
/// pure, so these exercise the record routing, field extraction, and sorting.
struct MonitorDiagnosticParserTests {
    // Tab-joined record builder — the scripts emit `TAG\tfield\tfield…`.
    private func rec(_ fields: String...) -> String { fields.joined(separator: "\t") }

    private func cpu(_ s: MonitorDiagnosticSnapshot) -> CPUDiagnostic? {
        if case .cpu(let d) = s { return d } else { return nil }
    }
    private func memory(_ s: MonitorDiagnosticSnapshot) -> MemoryDiagnostic? {
        if case .memory(let d) = s { return d } else { return nil }
    }
    private func disk(_ s: MonitorDiagnosticSnapshot) -> DiskDiagnostic? {
        if case .disk(let d) = s { return d } else { return nil }
    }
    private func ufw(_ s: MonitorDiagnosticSnapshot) -> UFWDiagnostic? {
        if case .ufw(let d) = s { return d } else { return nil }
    }

    // MARK: - CPU

    @Test("Parses CPU load, cores, summary, processes (CPU-sorted), threads, warnings")
    func parsesCPU() throws {
        let output = [
            rec("INFO", "Load", "0.50 0.40 0.30"),
            rec("INFO", "Cores", "8"),
            rec("SUMMARY", "CPU is busy"),
            rec("PROC", "100", "1", "root", "R", "nginx", "12.5", "3.2", "10240", "20480", "01:00", "/usr/sbin/nginx -g"),
            rec("PROC", "200", "1", "www", "S", "postgres", "45.0", "8.1", "51200", "102400", "02:00", "postgres: writer"),
            rec("THREAD", "100", "100", "5.0", "1.0", "nginx-worker"),
            rec("WARN", "high load"),
        ].joined(separator: "\n")

        let d = try #require(cpu(MonitorDiagnosticParser.parse(output, kind: .cpu)))
        #expect(d.load == "0.50 0.40 0.30")
        #expect(d.cores == "8")
        #expect(d.summary == ["CPU is busy"])
        #expect(d.warnings == ["high load"])
        #expect(d.threads.count == 1)
        #expect(d.threads.first?.command == "nginx-worker")
        // Sorted by CPU descending: postgres (45.0) before nginx (12.5).
        #expect(d.processes.map(\.pid) == [200, 100])
        let top = try #require(d.processes.first)
        #expect(top.command == "postgres")
        #expect(top.cpuPercent == 45.0)
        #expect(top.rssKB == 51200)
        #expect(top.arguments == "postgres: writer")
    }

    @Test("Drops PROC records with too few fields")
    func dropsMalformedProcess() throws {
        let output = [
            rec("PROC", "100", "1", "root", "R", "nginx"),  // only 6 fields, needs 12
            rec("PROC", "200", "1", "www", "S", "redis", "5.0", "1.0", "1024", "2048", "00:30", "redis-server"),
        ].joined(separator: "\n")

        let d = try #require(cpu(MonitorDiagnosticParser.parse(output, kind: .cpu)))
        #expect(d.processes.map(\.pid) == [200])
    }

    // MARK: - Memory

    @Test("Parses memory summary, events, warnings, and RSS-sorted processes")
    func parsesMemory() throws {
        let output = [
            rec("SUMMARY", "MemTotal 16G"),
            rec("PROC", "100", "1", "root", "R", "chrome", "2.0", "10.0", "20480", "40960", "10:00", "chrome"),
            rec("PROC", "200", "1", "root", "S", "java", "1.0", "30.0", "81920", "163840", "20:00", "java -jar app"),
            rec("EVENT", "oom-kill invoked"),
            rec("WARN", "swap pressure"),
        ].joined(separator: "\n")

        let d = try #require(memory(MonitorDiagnosticParser.parse(output, kind: .memory)))
        #expect(d.summary == ["MemTotal 16G"])
        #expect(d.events == ["oom-kill invoked"])
        #expect(d.warnings == ["swap pressure"])
        // Sorted by RSS descending: java (81920) before chrome (20480).
        #expect(d.processes.map(\.pid) == [200, 100])
        #expect(d.processes.first?.rssKB == 81920)
    }

    // MARK: - Disk

    @Test("Parses mount usage and size-sorted files with explicit directory column")
    func parsesDisk() throws {
        let mount = FfiDiskMount(source: "/dev/disk1", mount: "/", fsType: "apfs", total: 100, used: 80)
        let output = [
            rec("MOUNT", "/", "80% of 100G"),
            rec("FILE", "1048576", "1700000000", "2023-11-14", "root", "/var/log", "/var/log/big.log"),
            rec("FILE", "2097152", "1700000500", "2023-11-15", "www", "/tmp", "/tmp/huge.bin"),
            rec("WARN", "disk filling"),
        ].joined(separator: "\n")

        let d = try #require(disk(MonitorDiagnosticParser.parse(output, kind: .disk(mount))))
        #expect(d.mount == "/")
        #expect(d.usage == "80% of 100G")
        #expect(d.warnings == ["disk filling"])
        // Sorted by size descending: huge.bin (2 MiB) before big.log (1 MiB).
        #expect(d.files.map(\.path) == ["/tmp/huge.bin", "/var/log/big.log"])
        let largest = try #require(d.files.first)
        #expect(largest.size == 2_097_152)
        #expect(largest.directory == "/tmp")
        #expect(largest.owner == "www")
    }

    // MARK: - UFW

    @Test("Parses UFW info, status, number-sorted rules, blocked sources, warnings")
    func parsesUFW() throws {
        let output = [
            rec("INFO", "Version", "0.36"),
            rec("STATUS", "Status: active"),
            rec("RULE", "[ 2] 22/tcp  ALLOW IN  Anywhere"),
            rec("RULE", "[ 1] 80/tcp  ALLOW IN  Anywhere"),
            rec("LOG", "[UFW BLOCK] SRC=203.0.113.9 DST=10.0.0.1 PROTO=TCP"),
            rec("WARN", "telnet port open"),
        ].joined(separator: "\n")

        let d = try #require(ufw(MonitorDiagnosticParser.parse(output, kind: .ufw)))
        #expect(d.info.first?.0 == "Version")
        #expect(d.info.first?.1 == "0.36")
        #expect(d.statusLines == ["Status: active"])
        #expect(d.warnings == ["telnet port open"])
        // Sorted by rule number ascending.
        #expect(d.rules.map(\.number) == [1, 2])
        let firstRule = try #require(d.rules.first)
        #expect(firstRule.target == "80/tcp")
        #expect(firstRule.action == "ALLOW IN")
        #expect(firstRule.source == "Anywhere")
        // Blocked sources are extracted from `SRC=` in log lines.
        #expect(d.blockedSources == ["203.0.113.9"])
    }

    @Test("Returns an empty diagnostic for empty output")
    func handlesEmptyOutput() throws {
        let d = try #require(cpu(MonitorDiagnosticParser.parse("", kind: .cpu)))
        #expect(d.processes.isEmpty)
        #expect(d.summary.isEmpty)
        #expect(d.load.isEmpty)
    }
}
