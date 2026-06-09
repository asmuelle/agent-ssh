import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

enum DrillDownMode: String, CaseIterable {
    case overview = "Overview"
    case hotspots = "Hotspots"
    case details = "Details"
    case raw = "Raw"

    func title(for drillDown: MonitorDrillDown) -> String {
        switch (drillDown, self) {
        case (.ufw, .details):
            return "Rules"
        default:
            return rawValue
        }
    }
}

enum MonitorDiagnosticSnapshot {
    case cpu(CPUDiagnostic)
    case memory(MemoryDiagnostic)
    case disk(DiskDiagnostic)
    case systemd(SystemdDiagnostic)
    case ufw(UFWDiagnostic)
}

struct ProcessDiagnosticRow: Identifiable {
    let pid: Int
    let ppid: Int
    let user: String
    let state: String
    let command: String
    let cpuPercent: Double
    let memoryPercent: Double
    let rssKB: UInt64
    let vszKB: UInt64
    let elapsed: String
    let arguments: String

    var id: Int { pid }
}

struct ThreadDiagnosticRow: Identifiable {
    let pid: Int
    let threadId: String
    let cpuPercent: Double
    let memoryPercent: Double
    let command: String

    var id: String { "\(pid):\(threadId)" }
    var threadSortKey: Int { Int(threadId) ?? 0 }
}

struct CPUDiagnostic {
    var load = ""
    var cores = ""
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var threads: [ThreadDiagnosticRow] = []
    var warnings: [String] = []
}

struct MemoryDiagnostic {
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var events: [String] = []
    var warnings: [String] = []
}

struct DiskDiagnostic {
    var mount = ""
    var usage = ""
    var files: [DiskFileDiagnosticRow] = []
    var warnings: [String] = []
}

struct DiskFileDiagnosticRow: Identifiable {
    let size: UInt64
    let modifiedEpoch: Double
    let modified: String
    let owner: String
    let directory: String
    let path: String

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? path
            : URL(fileURLWithPath: path).lastPathComponent
    }
}

struct SystemdDiagnostic {
    var properties: [(String, String)] = []
    var files: [SystemdFileDiagnostic] = []
    var journalLines: [String] = []
    var warnings: [String] = []
    var serviceFamily = LinuxServiceFamily.generic
    var serviceGroups: [ServiceDiagnosticGroup] = []

    var journalIssueCounts: JournalIssueCounts {
        JournalIssueClassifier.counts(in: journalLines)
    }

    func value(for key: String) -> String? {
        properties.first { $0.0 == key }?.1
    }

    mutating func appendServiceRow(section: String, label: String, value: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].rows.append((label, value))
    }

    mutating func appendServiceLine(section: String, line: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].lines.append(line)
    }

    private mutating func serviceGroupIndex(for section: String) -> Int {
        let title = section.isEmpty ? "Service" : section
        if let index = serviceGroups.firstIndex(where: { $0.title == title }) {
            return index
        }
        serviceGroups.append(ServiceDiagnosticGroup(title: title))
        return serviceGroups.count - 1
    }
}

struct SystemdFileDiagnostic: Identifiable {
    let kind: String
    let path: String
    var lines: [String]

    var id: String { "\(kind):\(path)" }
    var content: String { lines.joined(separator: "\n") }
}

struct ServiceDiagnosticGroup: Identifiable {
    let title: String
    var rows: [(String, String)] = []
    var lines: [String] = []

    var id: String { title }
}

enum LinuxServiceFamily: String {
    case generic
    case web
    case apparmor
    case fail2ban
    case apt
    case certbot
    case chrony
    case clamav
    case container
    case mail
    case syslog
    case snap
    case ssh

    var title: String {
        switch self {
        case .generic:  return "Generic Service"
        case .web:      return "Web Server"
        case .apparmor: return "AppArmor"
        case .fail2ban: return "Fail2ban"
        case .apt:      return "APT Automation"
        case .certbot:  return "Certificate Renewal"
        case .chrony:   return "Time Sync"
        case .clamav:   return "Malware Scanning"
        case .container:return "Container Runtime"
        case .mail:     return "Mail Service"
        case .syslog:   return "System Logging"
        case .snap:     return "Snap Packages"
        case .ssh:      return "SSH Access"
        }
    }

    var description: String {
        switch self {
        case .generic:  return ""
        case .web:      return "listeners, vhosts, TLS, config test"
        case .apparmor: return "profiles and denials"
        case .fail2ban: return "jails, bans, offenders"
        case .apt:      return "timers and package activity"
        case .certbot:  return "certificates and renewals"
        case .chrony:   return "offset, sources, sync health"
        case .clamav:   return "definitions and scan health"
        case .container:return "namespaces, containers, disk hints"
        case .mail:     return "queues, listeners, auth/mail logs"
        case .syslog:   return "pipeline validation and log targets"
        case .snap:     return "refreshes, snaps, services"
        case .ssh:      return "listeners, sessions, auth signals"
        }
    }

    var icon: String {
        switch self {
        case .generic:  return "switch.2"
        case .web:      return "network"
        case .apparmor: return "shield.lefthalf.filled"
        case .fail2ban: return "hand.raised"
        case .apt:      return "shippingbox"
        case .certbot:  return "lock.doc"
        case .chrony:   return "clock"
        case .clamav:   return "cross.case"
        case .container:return "cube.box"
        case .mail:     return "envelope"
        case .syslog:   return "doc.text.magnifyingglass"
        case .snap:     return "sparkles"
        case .ssh:      return "terminal"
        }
    }
}

struct UFWDiagnostic {
    var info: [(String, String)] = []
    var statusLines: [String] = []
    var rules: [UFWDiagnosticRule] = []
    var logs: [String] = []
    var configLines: [String] = []
    var rawTables: [String] = []
    var warnings: [String] = []

    var blockedSources: [String] {
        let values = logs.compactMap { line -> String? in
            guard let range = line.range(of: "SRC=") else { return nil }
            let suffix = line[range.upperBound...]
            return suffix.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return Array(Set(values)).sorted()
    }
}

struct UFWDiagnosticRule: Identifiable {
    let id: Int
    let number: Int
    let target: String
    let action: String
    let source: String
    let raw: String
}

struct UFWBlockedSourceRow: Identifiable {
    let source: String
    let count: Int

    var id: String { source }
}

enum UFWRuleRisk {
    case sshExposed
    case databaseExposed
    case publicMail
    case publicWeb
    case publicRule
    case restricted
    case blocked
    case neutral

    var title: String {
        switch self {
        case .sshExposed: return "SSH exposed"
        case .databaseExposed: return "DB exposed"
        case .publicMail: return "Public mail"
        case .publicWeb: return "Public web"
        case .publicRule: return "Public"
        case .restricted: return "Restricted"
        case .blocked: return "Blocked"
        case .neutral: return "Neutral"
        }
    }

    var color: Color {
        switch self {
        case .sshExposed, .databaseExposed:
            return .red
        case .publicMail, .publicRule:
            return .orange
        case .publicWeb:
            return .blue
        case .restricted, .blocked:
            return .green
        case .neutral:
            return .secondary
        }
    }

    var rank: Int {
        switch self {
        case .sshExposed: return 0
        case .databaseExposed: return 1
        case .publicMail: return 2
        case .publicRule: return 3
        case .publicWeb: return 4
        case .restricted: return 5
        case .blocked: return 6
        case .neutral: return 7
        }
    }
}

enum MonitorDiagnosticParser {
    static func parse(_ output: String, kind: MonitorDrillDown) -> MonitorDiagnosticSnapshot {
        switch kind {
        case .cpu:
            return .cpu(parseCPU(output))
        case .memory:
            return .memory(parseMemory(output))
        case .disk:
            return .disk(parseDisk(output))
        case .systemdService:
            return .systemd(parseSystemd(output))
        case .ufw:
            return .ufw(parseUFW(output))
        }
    }

    private static func parseCPU(_ output: String) -> CPUDiagnostic {
        var diagnostic = CPUDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                if fields[1] == "Load" {
                    diagnostic.load = joined(fields, from: 2)
                } else if fields[1] == "Cores" {
                    diagnostic.cores = joined(fields, from: 2)
                }
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "THREAD":
                if fields.count >= 6 {
                    diagnostic.threads.append(ThreadDiagnosticRow(
                        pid: int(fields[1]),
                        threadId: fields[2],
                        cpuPercent: double(fields[3]),
                        memoryPercent: double(fields[4]),
                        command: joined(fields, from: 5)
                    ))
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.cpuPercent > $1.cpuPercent }
        diagnostic.threads.sort { $0.cpuPercent > $1.cpuPercent }
        return diagnostic
    }

    private static func parseMemory(_ output: String) -> MemoryDiagnostic {
        var diagnostic = MemoryDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "EVENT":
                diagnostic.events.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.rssKB > $1.rssKB }
        return diagnostic
    }

    private static func parseDisk(_ output: String) -> DiskDiagnostic {
        var diagnostic = DiskDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "MOUNT":
                diagnostic.mount = fields.count > 1 ? fields[1] : ""
                diagnostic.usage = fields.count > 2 ? joined(fields, from: 2) : ""
            case "FILE":
                if let row = parseDiskFile(fields) {
                    diagnostic.files.append(row)
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.files.sort {
            if $0.size == $1.size {
                return $0.modifiedEpoch > $1.modifiedEpoch
            }
            return $0.size > $1.size
        }
        return diagnostic
    }

    private static func parseSystemd(_ output: String) -> SystemdDiagnostic {
        var diagnostic = SystemdDiagnostic()
        var fileOrder: [String] = []
        var filesById: [String: SystemdFileDiagnostic] = [:]

        for fields in records(output) {
            switch fields.first {
            case "KV":
                guard fields.count >= 3 else { continue }
                diagnostic.properties.append((fields[1], joined(fields, from: 2)))
            case "FILE":
                guard fields.count >= 3 else { continue }
                let file = SystemdFileDiagnostic(kind: fields[1], path: fields[2], lines: [])
                if filesById[file.id] == nil {
                    fileOrder.append(file.id)
                }
                filesById[file.id] = file
            case "FILELINE":
                guard fields.count >= 5 else { continue }
                let kind = fields[1]
                let path = fields[2]
                let id = "\(kind):\(path)"
                if filesById[id] == nil {
                    fileOrder.append(id)
                    filesById[id] = SystemdFileDiagnostic(kind: kind, path: path, lines: [])
                }
                filesById[id]?.lines.append(joined(fields, from: 4))
            case "JOURNAL":
                diagnostic.journalLines.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            case "SVCFAMILY":
                if fields.count >= 2 {
                    diagnostic.serviceFamily = LinuxServiceFamily(rawValue: fields[1]) ?? .generic
                }
            case "SVC":
                guard fields.count >= 4 else { continue }
                diagnostic.appendServiceRow(
                    section: fields[1],
                    label: fields[2],
                    value: joined(fields, from: 3)
                )
            case "SVCLINE":
                guard fields.count >= 3 else { continue }
                diagnostic.appendServiceLine(
                    section: fields[1],
                    line: joined(fields, from: 2)
                )
            default:
                continue
            }
        }

        diagnostic.files = fileOrder.compactMap { filesById[$0] }
        return diagnostic
    }

    private static func parseUFW(_ output: String) -> UFWDiagnostic {
        var diagnostic = UFWDiagnostic()
        var fallbackRuleId = 10_000

        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                diagnostic.info.append((fields[1], joined(fields, from: 2)))
            case "STATUS":
                diagnostic.statusLines.append(joined(fields, from: 1))
            case "RULE":
                let raw = joined(fields, from: 1)
                if let rule = parseUFWRule(raw, fallbackId: fallbackRuleId) {
                    diagnostic.rules.append(rule)
                    fallbackRuleId += 1
                }
            case "LOG":
                diagnostic.logs.append(joined(fields, from: 1))
            case "CONFIG":
                diagnostic.configLines.append(joined(fields, from: 1))
            case "IPTABLES", "IPTABLES6":
                diagnostic.rawTables.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }

        diagnostic.rules.sort { $0.number < $1.number }
        return diagnostic
    }

    private static func parseProcess(_ fields: [String]) -> ProcessDiagnosticRow? {
        guard fields.count >= 12 else { return nil }
        return ProcessDiagnosticRow(
            pid: int(fields[1]),
            ppid: int(fields[2]),
            user: fields[3],
            state: fields[4],
            command: fields[5],
            cpuPercent: double(fields[6]),
            memoryPercent: double(fields[7]),
            rssKB: uint(fields[8]),
            vszKB: uint(fields[9]),
            elapsed: fields[10],
            arguments: joined(fields, from: 11)
        )
    }

    private static func parseDiskFile(_ fields: [String]) -> DiskFileDiagnosticRow? {
        guard fields.count >= 6 else { return nil }
        let size = uint(fields[1])
        let modifiedEpoch = double(fields[2])
        let modified = fields[3]
        let owner = fields[4]

        let directory: String
        let path: String
        if fields.count >= 7 {
            directory = fields[5]
            path = joined(fields, from: 6)
        } else {
            path = joined(fields, from: 5)
            directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return DiskFileDiagnosticRow(
            size: size,
            modifiedEpoch: modifiedEpoch,
            modified: modified,
            owner: owner.isEmpty ? "-" : owner,
            directory: directory.isEmpty ? "/" : directory,
            path: path
        )
    }

    private static func parseUFWRule(_ raw: String, fallbackId: Int) -> UFWDiagnosticRule? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return nil }

        let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|DENY(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?|REJECT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 5,
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let targetRange = Range(match.range(at: 2), in: trimmed),
              let actionRange = Range(match.range(at: 3), in: trimmed),
              let sourceRange = Range(match.range(at: 4), in: trimmed)
        else {
            return UFWDiagnosticRule(
                id: fallbackId,
                number: fallbackId,
                target: trimmed,
                action: "Unknown",
                source: "",
                raw: raw
            )
        }

        let number = int(String(trimmed[numberRange]))
        return UFWDiagnosticRule(
            id: number,
            number: number,
            target: String(trimmed[targetRange]).trimmingCharacters(in: .whitespaces),
            action: String(trimmed[actionRange]).trimmingCharacters(in: .whitespaces),
            source: String(trimmed[sourceRange]).trimmingCharacters(in: .whitespaces),
            raw: raw
        )
    }

    private static func records(_ output: String) -> [[String]] {
        output
            .split(whereSeparator: \.isNewline)
            .map { line in
                String(line).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
    }

    private static func joined(_ fields: [String], from index: Int) -> String {
        guard fields.count > index else { return "" }
        return fields[index...].joined(separator: "\t")
    }

    private static func int(_ value: String) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func uint(_ value: String) -> UInt64 {
        UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func double(_ value: String) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

