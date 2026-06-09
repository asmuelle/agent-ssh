import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension SystemdMonitorView {
    // MARK: - Journal

    var journalPane: some View {
        VStack(spacing: 0) {
            journalToolbar
            Divider()
            if journal.isEmpty {
                placeholderView(
                    icon: "tray",
                    title: "No journal entries",
                    message: priorityFilteredEmptyMessage
                )
            } else if filteredJournalLines.isEmpty {
                placeholderView(
                    icon: "magnifyingglass",
                    title: "No matching journal entries",
                    message: "No entry matches the current filter."
                )
            } else {
                journalEntriesList
            }
        }
    }

    var journalToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Picker("", selection: $journalPriority) {
                    ForEach(JournalPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .foregroundStyle(.secondary)
                Picker("", selection: $journalTail) {
                    ForEach(Self.journalTailOptions, id: \.self) { Text("\($0) lines").tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            Text("System")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Wrap", isOn: $wrapJournalLines)
                .toggleStyle(.checkbox)
                .help("Wrap long journal messages")
            Text("\(filteredJournalLines.count) of \(rawJournalLines.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Copy") { RemoteCommandRunner.copy(filteredJournalLines.joined(separator: "\n")) }
                .disabled(filteredJournalLines.isEmpty)
                .controlSize(.small)
                .help("Copy visible journal entries")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onChange(of: journalPriority) { _ in Task { await loadJournal() } }
        .onChange(of: journalTail) { _ in Task { await loadJournal() } }
    }

    var rawJournalLines: [String] {
        journal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var filteredJournalLines: [String] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = rawJournalLines.filter { !$0.isEmpty }
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(needle) }
    }

    var rawUnitJournalLines: [String] {
        unitJournal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var filteredUnitJournalLines: [String] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = rawUnitJournalLines.filter { !$0.isEmpty }
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(needle) }
    }

    var unitJournalIssueCounts: JournalIssueCounts {
        JournalIssueClassifier.counts(in: rawUnitJournalLines)
    }

    var priorityFilteredEmptyMessage: String {
        switch journalPriority {
        case .all: return "journalctl returned nothing for this scope."
        case .info, .notice, .warning, .error, .critical:
            return "No entries at \(journalPriority.rawValue) or higher. Try lowering the priority filter."
        }
    }

    var journalEntriesList: some View {
        journalEntriesList(lines: filteredJournalLines, autoScroll: liveJournal)
    }

    func journalEntriesList(lines: [String], autoScroll: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(journalScrollAxes) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    journalColumnHeader
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        journalLineRow(line)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
                .frame(
                    minWidth: wrapJournalLines ? 0 : 1180,
                    maxWidth: wrapJournalLines ? .infinity : nil,
                    alignment: .leading
                )
            }
            .onChange(of: lines.count) { count in
                if autoScroll {
                    proxy.scrollTo(max(count - 1, 0), anchor: .bottom)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var journalScrollAxes: Axis.Set {
        wrapJournalLines ? .vertical : [.vertical, .horizontal]
    }

    var journalColumnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear
                .frame(width: 3)
            Text("Time")
                .frame(width: 188, alignment: .leading)
            Text("Host")
                .frame(width: 74, alignment: .leading)
            Text("Process")
                .frame(width: 142, alignment: .leading)
            Text("Message")
                .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    func journalLineRow(_ line: String) -> some View {
        let severityLevel = journalSeverity(line)
        let indicatorColor = severityLevel.accentColor
        let foregroundColor = severityLevel.foreground
        let backgroundColor = severityLevel.background
        let parts = splitJournalLine(line)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle()
                .fill(indicatorColor)
                .frame(width: 3)
            Text(parts.timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 188, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.timestamp)
            Text(parts.host)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 74, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.host)
            Text(parts.process)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 142, alignment: .leading)
                .textSelection(.enabled)
                .help(parts.process)
            Text(parts.message)
                .font(.caption.monospaced())
                .foregroundStyle(foregroundColor)
                .textSelection(.enabled)
                .lineLimit(wrapJournalLines ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
                .fixedSize(horizontal: !wrapJournalLines, vertical: wrapJournalLines)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(backgroundColor)
    }

    struct JournalLineParts {
        let timestamp: String
        let host: String
        let process: String
        let message: String
    }

    func splitJournalLine(_ line: String) -> JournalLineParts {
        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, isLikelyJournalTimestamp(fields[0]) else {
            return JournalLineParts(timestamp: "", host: "", process: "", message: line)
        }

        let timestamp = fields[0]
        let host = fields.indices.contains(1) ? fields[1] : ""
        guard fields.count >= 3 else {
            return JournalLineParts(timestamp: timestamp, host: host, process: "", message: "")
        }

        var process = fields[2]
        var message = fields.indices.contains(3) ? fields[3] : ""
        if process.hasSuffix(":") {
            process.removeLast()
        } else if message.isEmpty {
            message = process
            process = ""
        } else {
            message = "\(process) \(message)"
            process = ""
        }

        return JournalLineParts(timestamp: timestamp, host: host, process: process, message: message)
    }

    func isLikelyJournalTimestamp(_ value: String) -> Bool {
        (value.contains("-") || value.contains(":")) && value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    func journalSeverity(_ line: String) -> JournalSeverity {
        let upper = line.uppercased()
        if upper.contains(" CRIT") || upper.contains("CRITICAL") || upper.contains(" EMERG") || upper.contains(" ALERT") {
            return .critical
        }
        if upper.contains(" ERR") || upper.contains("ERROR") || upper.contains("FAILED") || upper.contains("FATAL") {
            return .error
        }
        if upper.contains(" WARN") || upper.contains("WARNING") {
            return .warning
        }
        if upper.contains(" NOTICE") {
            return .notice
        }
        return .info
    }

    enum JournalSeverity {
        case info, notice, warning, error, critical
        var accentColor: Color {
            switch self {
            case .info: return .clear
            case .notice: return .blue.opacity(0.6)
            case .warning: return .orange
            case .error: return .red
            case .critical: return .purple
            }
        }
        var foreground: Color {
            switch self {
            case .info, .notice: return .primary
            case .warning: return .orange
            case .error: return .red
            case .critical: return .purple
            }
        }
        var background: Color {
            switch self {
            case .info, .notice: return .clear
            case .warning: return Color.orange.opacity(0.06)
            case .error: return Color.red.opacity(0.07)
            case .critical: return Color.purple.opacity(0.1)
            }
        }
    }

    func detailBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            logText(value.isEmpty ? "-" : value)
                .frame(minHeight: title == "Journal" ? 160 : 90)
        }
    }

    func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func statusBadge(_ text: String, color: Color, emphasized: Bool = true) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.caption2.weight(emphasized ? .semibold : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(emphasized ? 0.12 : 0.04), in: Capsule())
    }

}
