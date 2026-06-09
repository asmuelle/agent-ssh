import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension MonitorDrillDownSheet {
    // MARK: - Process views

    func processHotspotPane(
        processes: [ProcessDiagnosticRow],
        threads: [ThreadDiagnosticRow]
    ) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                hotspotHeader(processes: processes, threads: threads)
                Divider()
                if processes.isEmpty {
                    placeholderPane("No processes reported.")
                        .frame(minHeight: 320, maxHeight: .infinity)
                } else {
                    processTable(processes)
                        .frame(minHeight: 320, maxHeight: .infinity)
                }
                if !threads.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .foregroundStyle(.secondary)
                            Text("Thread Hotspots")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(threads.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        threadTable(threads)
                            .frame(height: 150)
                    }
                    .padding(10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )
            .padding(12)
            .frame(minWidth: 560)

            selectedProcessDetail(processes)
                .padding(16)
                .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    func hotspotHeader(
        processes: [ProcessDiagnosticRow],
        threads: [ThreadDiagnosticRow]
    ) -> some View {
        let top = processes.sorted(using: processSortOrder).first
        let header = hotspotHeaderDescriptor

        return HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: header.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.title)
                        .font(.subheadline.weight(.semibold))
                    Text(header.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 180, alignment: .leading)
            Spacer()
            if let top {
                topHotspotBadge(top)
                compactHotspotMetric(
                    "Top RSS",
                    formatKilobytes(top.rssKB),
                    color: processRSSColor(top.rssKB)
                )
                compactHotspotMetric(
                    "Top CPU",
                    String(format: "%.1f%%", top.cpuPercent),
                    color: processCPUColor(top.cpuPercent)
                )
            }
            compactHotspotMetric("Rows", "\(processes.count)", color: .secondary)
            if !threads.isEmpty {
                compactHotspotMetric("Threads", "\(threads.count)", color: .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    var hotspotHeaderDescriptor: (title: String, subtitle: String, icon: String) {
        switch drillDown {
        case .memory:
            return ("Memory Hotspots", "Sorted by resident memory", "memorychip")
        case .cpu:
            return ("CPU Hotspots", "Sorted by processor load", "cpu")
        case .disk, .systemdService, .ufw:
            return ("Process Hotspots", "Highest-impact processes first", "flame")
        }
    }

    func topHotspotBadge(_ process: ProcessDiagnosticRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: processIcon(for: process.command))
                .font(.system(size: 10, weight: .semibold))
            Text(process.command.isEmpty ? "Process \(process.pid)" : process.command)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(processAccentColor(for: process))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 120)
        .background(processAccentColor(for: process).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    func compactHotspotMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(minWidth: 52, alignment: .trailing)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }

    func processTable(_ processes: [ProcessDiagnosticRow]) -> some View {
        let rows = processes.sorted(using: processSortOrder)

        return Table(rows, selection: Binding(
            get: { selectedProcessId },
            set: {
                selectedProcessId = $0
                focusedTitle = nil
                focusedOutput = ""
            }
        ), sortOrder: $processSortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)

            TableColumn("Process", value: \.command) { row in
                processSummaryCell(row)
            }
            .width(min: 180, ideal: 230)

            TableColumn("%CPU", value: \.cpuPercent) { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processCPUColor(row.cpuPercent))
            }
            .width(min: 55, ideal: 65)

            TableColumn("%MEM", value: \.memoryPercent) { row in
                Text(String(format: "%.1f", row.memoryPercent))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processMemoryColor(row.memoryPercent))
            }
            .width(min: 55, ideal: 65)

            TableColumn("RSS", value: \.rssKB) { row in
                Text(row.rssKB == 0 ? "-" : formatKilobytes(row.rssKB))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(processRSSColor(row.rssKB))
            }
            .width(min: 70, ideal: 90)
        }
    }

    func processSummaryCell(_ row: ProcessDiagnosticRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: processIcon(for: row.command))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(processAccentColor(for: row))
                .frame(width: 22, height: 22)
                .background(processAccentColor(for: row).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.command.isEmpty ? "-" : row.command)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(row.user) - \(row.state)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    func threadTable(_ threads: [ThreadDiagnosticRow]) -> some View {
        let rows = threads.sorted(using: threadSortOrder)

        return Table(rows, selection: Binding(
            get: { selectedThreadId },
            set: { selectedThreadId = $0 }
        ), sortOrder: $threadSortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)
            TableColumn("TID", value: \.threadSortKey) { row in
                Text(row.threadId)
                    .font(.caption.monospacedDigit())
            }
            .width(min: 70, ideal: 90)
            TableColumn("%CPU", value: \.cpuPercent) { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 60, ideal: 70)
            TableColumn("Command", value: \.command) { row in
                Text(row.command)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    static func defaultProcessSortOrder(
        for drillDown: MonitorDrillDown
    ) -> [KeyPathComparator<ProcessDiagnosticRow>] {
        switch drillDown {
        case .memory:
            return [KeyPathComparator(\.rssKB, order: .reverse)]
        case .cpu:
            return [KeyPathComparator(\.cpuPercent, order: .reverse)]
        case .disk, .systemdService, .ufw:
            return [KeyPathComparator(\.pid)]
        }
    }

    func selectedProcessDetail(_ processes: [ProcessDiagnosticRow]) -> some View {
        let process = selectedProcessId.flatMap { id in processes.first { $0.pid == id } }
        return VStack(alignment: .leading, spacing: 12) {
            if let process {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: processIcon(for: process.command))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(processAccentColor(for: process))
                        .frame(width: 42, height: 42)
                        .background(processAccentColor(for: process).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.command.isEmpty ? "Process \(process.pid)" : process.command)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(process.user) - PID \(process.pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Process \(process.pid)",
                                script: Self.processInspectionScript(pid: process.pid)
                            )
                        }
                    } label: {
                        Label("Inspect", systemImage: "magnifyingglass")
                    }
                    .disabled(focusedLoading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                    processMetricChip("CPU", String(format: "%.1f%%", process.cpuPercent), color: processCPUColor(process.cpuPercent))
                    processMetricChip("Memory", String(format: "%.1f%%", process.memoryPercent), color: processMemoryColor(process.memoryPercent))
                    processMetricChip("RSS", formatKilobytes(process.rssKB), color: processRSSColor(process.rssKB))
                    processMetricChip("VSZ", formatKilobytes(process.vszKB), color: .secondary)
                }
                processIdentityCard(process)
                sectionBox("Command Line") {
                    rawText(process.arguments.isEmpty ? process.command : process.arguments)
                        .frame(minHeight: 88, maxHeight: 160)
                }
                focusedInspectionPane
            } else {
                placeholderPane("Select a process.")
            }
        }
    }

    func processIdentityCard(_ process: ProcessDiagnosticRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                processIdentityRow("PID", "\(process.pid)")
                processIdentityDivider
                processIdentityRow("Parent", "\(process.ppid)")
                processIdentityDivider
                processIdentityRow("State", process.state)
                processIdentityDivider
                processIdentityRow("Elapsed", process.elapsed)
                processIdentityDivider
                processIdentityRow("User", process.user)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        )
    }

    func processIdentityRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    var processIdentityDivider: some View {
        Divider()
            .padding(.leading, 90)
    }

    func processMetricChip(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func processIcon(for command: String) -> String {
        let normalized = command.lowercased()
        if normalized.contains("postgres") || normalized.contains("mysql") {
            return "cylinder.split.1x2"
        }
        if normalized.contains("docker") || normalized.contains("containerd") {
            return "cube.box"
        }
        if normalized.contains("nginx") || normalized.contains("apache") || normalized.contains("http") {
            return "network"
        }
        if normalized.contains("ssh") || normalized.contains("shell") || normalized.contains("bash") {
            return "terminal"
        }
        if normalized.contains("clam") {
            return "cross.case"
        }
        if normalized.contains("java") || normalized.contains("keycloak") {
            return "server.rack"
        }
        return "gearshape.2"
    }

    func processAccentColor(for process: ProcessDiagnosticRow) -> Color {
        if process.cpuPercent >= 40 {
            return processCPUColor(process.cpuPercent)
        }
        if process.memoryPercent >= 5 {
            return processMemoryColor(process.memoryPercent)
        }
        if process.rssKB >= 524_288 {
            return processRSSColor(process.rssKB)
        }
        return Color.accentColor
    }

    func processCPUColor(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 40 { return .orange }
        if value >= 10 { return .blue }
        return .secondary
    }

    func processMemoryColor(_ value: Double) -> Color {
        if value >= 20 { return .red }
        if value >= 5 { return .orange }
        if value >= 1 { return .blue }
        return .secondary
    }

    func processRSSColor(_ kilobytes: UInt64) -> Color {
        if kilobytes >= 1_048_576 { return .orange }
        if kilobytes >= 524_288 { return .blue }
        return .secondary
    }

}
