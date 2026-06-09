import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

extension MonitorDrillDownSheet {
    // MARK: - Detail panes

    func diskFilePane(_ diagnostic: DiskDiagnostic) -> some View {
        HSplitView {
            Table(diagnostic.files, selection: Binding(
                get: { selectedFilePath },
                set: {
                    selectedFilePath = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) {
                TableColumn("Size") { file in
                    Text(formatBytes(file.size))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 90, ideal: 110)
                TableColumn("Modified") { file in
                    Text(file.modified)
                        .font(.caption.monospacedDigit())
                }
                .width(min: 130, ideal: 150)
                TableColumn("Owner") { file in
                    Text(file.owner)
                        .font(.caption)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Path") { file in
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(minWidth: 560)

            selectedDiskFileDetail(diagnostic.files)
                .padding(12)
                .frame(minWidth: 340)
        }
    }

    func selectedDiskFileDetail(_ files: [DiskFileDiagnosticRow]) -> some View {
        let file = selectedFilePath.flatMap { path in files.first { $0.path == path } }
        return VStack(alignment: .leading, spacing: 10) {
            if let file {
                HStack {
                    Text(file.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Directory \(file.directory)",
                                script: Self.directoryInspectionScript(path: file.directory)
                            )
                        }
                    } label: {
                        Label("Inspect Directory", systemImage: "folder.badge.gearshape")
                    }
                    .disabled(focusedLoading)
                }
                keyValuePane([
                    ("Size", formatBytes(file.size)),
                    ("Modified", file.modified),
                    ("Owner", file.owner),
                    ("Directory", file.directory),
                    ("Path", file.path),
                ])
                focusedInspectionPane
            } else {
                placeholderPane("Select a file.")
            }
        }
    }

    func systemdFilesPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            List(diagnostic.files, selection: Binding(
                get: { selectedSystemdFileId },
                set: { selectedSystemdFileId = $0 }
            )) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.kind)
                        .font(.caption.weight(.semibold))
                    Text(file.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let file = selectedSystemdFileId.flatMap({ id in diagnostic.files.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.path)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    rawPane(file.content)
                }
                .padding(12)
                .frame(minWidth: 420)
            } else {
                placeholderPane("Select a unit, drop-in, or environment file.")
            }
        }
    }

    func systemdJournalPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            keyValuePane(diagnostic.properties)
                .padding(12)
                .frame(minWidth: 340)
            MonitorJournalLogView(
                rawLines: diagnostic.journalLines,
                fallbackHints: diagnostic.warnings
            )
            .padding(12)
            .frame(minWidth: 460)
        }
    }

    @ViewBuilder
    func serviceSpecificPane(_ diagnostic: SystemdDiagnostic) -> some View {
        if diagnostic.serviceFamily != .generic || !diagnostic.serviceGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: diagnostic.serviceFamily.icon)
                        .foregroundStyle(.secondary)
                    Text(diagnostic.serviceFamily.title)
                        .font(.headline)
                    Spacer()
                    if !diagnostic.serviceFamily.description.isEmpty {
                        Text(diagnostic.serviceFamily.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !diagnostic.serviceGroups.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(diagnostic.serviceGroups) { group in
                            serviceGroupBox(group)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func serviceGroupBox(_ group: ServiceDiagnosticGroup) -> some View {
        let joinedLines = group.lines.joined(separator: "\n")
        let isShellError = joinedLines.contains("unexpected operator") || joinedLines.contains("sh: ") || joinedLines.contains("permission denied") || joinedLines.contains("not found")

        return VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !group.rows.isEmpty {
                inlineKeyValueRows(group.rows)
            }

            if !group.lines.isEmpty {
                if isShellError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Data retrieval issue")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(joinedLines)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                    )
                } else {
                    rawText(joinedLines)
                        .frame(minHeight: 80, maxHeight: 180)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func ufwBlockedSourceRows(_ diagnostic: UFWDiagnostic) -> [UFWBlockedSourceRow] {
        var counts: [String: Int] = [:]
        for line in diagnostic.logs {
            guard let range = line.range(of: "SRC=") else { continue }
            let suffix = line[range.upperBound...]
            guard let source = suffix.split(whereSeparator: \.isWhitespace).first else { continue }
            counts[String(source), default: 0] += 1
        }
        return counts
            .map { UFWBlockedSourceRow(source: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.source < $1.source
                }
                return $0.count > $1.count
            }
    }

    func ufwRulesPane(_ diagnostic: UFWDiagnostic) -> some View {
        let sortedRules = diagnostic.rules.sorted {
            let lhsRisk = ufwRisk(for: $0)
            let rhsRisk = ufwRisk(for: $1)
            if lhsRisk.rank != rhsRisk.rank {
                return lhsRisk.rank < rhsRisk.rank
            }
            return $0.number < $1.number
        }

        return HSplitView {
            Table(sortedRules, selection: Binding(
                get: { selectedUFWRuleId },
                set: {
                    selectedUFWRuleId = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) {
                TableColumn("#") { rule in
                    Text("\(rule.number)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55)

                TableColumn("Action") { rule in
                    Text(rule.action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ufwRisk(for: rule).color)
                }
                .width(min: 80, ideal: 110)

                TableColumn("Port / Service") { rule in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.target)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Text(ufwServiceName(for: rule))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 210)

                TableColumn("Source") { rule in
                    Text(rule.source)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 170, ideal: 240)

                TableColumn("IP") { rule in
                    Text(ufwRuleVersion(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 44, ideal: 54)

                TableColumn("Risk") { rule in
                    ufwRiskBadge(ufwRisk(for: rule))
                }
                .width(min: 104, ideal: 122)
            }
            .contextMenu(forSelectionType: Int.self) { selected in
                if let id = selected.first,
                   let rule = diagnostic.rules.first(where: { $0.id == id }) {
                    Button("Copy Rule") { RemoteCommandRunner.copy(rule.raw) }
                    Button("Copy Source") { RemoteCommandRunner.copy(rule.source) }
                    Button("Copy Delete Command") { RemoteCommandRunner.copy("sudo ufw delete \(rule.number)") }
                }
            }
            .padding(12)
            .frame(minWidth: 650)

            if let rule = selectedUFWRuleId.flatMap({ id in diagnostic.rules.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Rule \(rule.number)")
                            .font(.headline)
                        ufwRiskBadge(ufwRisk(for: rule))
                        Spacer()
                        Button {
                            RemoteCommandRunner.copy(rule.raw)
                        } label: {
                            Label("Copy Rule", systemImage: "doc.on.doc")
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy rule")
                    }
                    keyValuePane([
                        ("Action", rule.action),
                        ("Target", rule.target),
                        ("Service", ufwServiceName(for: rule)),
                        ("Source", rule.source),
                        ("IP Version", ufwRuleVersion(rule)),
                        ("Risk", ufwRisk(for: rule).title),
                        ("Raw", rule.raw),
                    ])
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "UFW Source \(rule.source)",
                                script: Self.ufwSourceInspectionScript(source: rule.source)
                            )
                        }
                    } label: {
                        Label("Inspect Source", systemImage: "network")
                    }
                    .disabled(focusedLoading)
                    focusedInspectionPane
                }
                .padding(12)
                .frame(minWidth: 340)
            } else {
                placeholderPane("Select a UFW rule.")
            }
        }
    }

    func ufwBlockedSourcesPane(_ diagnostic: UFWDiagnostic) -> some View {
        let rows = ufwBlockedSourceRows(diagnostic)

        return HSplitView {
            List(rows, selection: Binding(
                get: { selectedUFWSource },
                set: {
                    selectedUFWSource = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) { row in
                HStack {
                    Text(row.source)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(row.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 260, idealWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                if let source = selectedUFWSource {
                    HStack {
                        Text(source)
                            .font(.headline)
                        Spacer()
                        Button {
                            Task {
                                await runFocusedInspection(
                                    title: "Blocked Source \(source)",
                                    script: Self.ufwSourceInspectionScript(source: source)
                                )
                            }
                        } label: {
                            Label("Inspect Source", systemImage: "network")
                        }
                        .disabled(focusedLoading)
                    }
                    keyValuePane([
                        ("Blocked Lines", "\(rows.first { $0.source == source }?.count ?? 0)"),
                        ("Source", source),
                    ])
                    sectionBox("Related Logs") {
                        rawText(diagnostic.logs.filter { $0.contains(source) }.joined(separator: "\n"))
                    }
                    focusedInspectionPane
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty {
                            placeholderPane("No blocked source IPs were found in the sampled UFW logs.")
                        } else {
                            Text("Select a source to inspect related UFW log lines.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        sectionBox("Recent Blocks") {
                            rawText(diagnostic.logs.joined(separator: "\n"))
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 520)
        }
    }

    // MARK: - Shared UI

    func overviewPane(_ items: [(String, String)], warnings: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCards(items)
                if !warnings.isEmpty {
                    warningList(warnings)
                }
            }
            .padding(16)
        }
    }

    func overviewCards(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    func warningList(_ warnings: [String]) -> some View {
        sectionBox("Warnings") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    func journalIssueSummary(_ counts: JournalIssueCounts) -> some View {
        HStack(spacing: 8) {
            Text("Recent journal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            JournalIssueBadges(counts: counts)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func keyValuePane(_ rows: [(String, String)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let standardRows = rows.filter { !$0.0.contains("ExecStart") }
                let execRows = rows.filter { $0.0.contains("ExecStart") }

                if !standardRows.isEmpty {
                    inlineKeyValueRows(standardRows)
                }

                if !execRows.isEmpty {
                    Divider()
                    ForEach(execRows, id: \.0) { row in
                        CodeBlockView(label: row.0, code: row.1)
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func inlineKeyValueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(row.1.isEmpty ? "-" : row.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
    }

    func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func rawText(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "No data." : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    func rawPane(_ text: String) -> some View {
        rawText(text.isEmpty && !isLoading ? "No output." : text)
            .padding(16)
    }

    func placeholderPane(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    var focusedInspectionPane: some View {
        if focusedLoading {
            ProgressView("Inspecting...")
                .controlSize(.small)
        } else if !focusedOutput.isEmpty || focusedTitle != nil {
            sectionBox(focusedTitle ?? "Inspection") {
                rawText(focusedOutput)
            }
        }
    }

    func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func formatMemoryProperty(_ value: String?) -> String {
        guard let value, let bytes = UInt64(value), bytes > 0 else { return "-" }
        return formatBytes(bytes)
    }

    func formatKilobytes(_ kilobytes: UInt64) -> String {
        formatBytes(kilobytes.multipliedWithoutOverflow(by: 1024))
    }

    func diagnosticScript() -> String {
        switch drillDown {
        case .cpu:
            return Self.cpuScript
        case .memory:
            return Self.memoryScript
        case .disk(let disk):
            return Self.diskScript(mount: disk.mount)
        case .systemdService(let unit):
            return Self.systemdScript(unit: unit)
        case .ufw:
            return Self.ufwScript(sshPort: sshPort)
        }
    }

}
