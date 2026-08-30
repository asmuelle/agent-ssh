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

    /// The unit's journal lines the classifier flags as errors or
    /// warnings — what the Logs tab shows while issue focus is on.
    var issueOnlyUnitJournalLines: [String] {
        filteredUnitJournalLines.filter { JournalIssueClassifier.classify($0) != nil }
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

    // MARK: - Journal display model

    /// One rendered journal row. Consecutive lines from the same
    /// process whose messages share a fingerprint template — the same
    /// log statement fired with different parameters (connection ids,
    /// counters, timestamps) — are coalesced into a single entry with a
    /// repeat count. 42 near-identical sshd failures read as one fact,
    /// not a wall; the varying parameters live in `occurrences`.
    struct JournalDisplayEntry: Identifiable {
        struct Occurrence {
            let timestamp: String
            let captures: [String]
            /// The line's own `name[pid]`. A forked daemon groups across
            /// PIDs, so the expanded list names the one each line came from.
            let process: String
        }

        /// Stable across filtering: derived from the group's own content,
        /// not its position. A positional id meant that typing in the
        /// search box left an unrelated row expanded.
        let id: String
        let firstTimestamp: String
        var lastTimestamp: String
        let host: String
        let process: String
        /// `sshd[1234]` reduced to `sshd`. journald tags each line with
        /// the emitting PID, and a daemon that forks per connection emits
        /// every line under a different one — grouping on the raw field
        /// would give a wall of one-line "groups" for exactly the
        /// repetitive logs this collapsing exists to tame.
        let processGroupKey: String
        let message: String
        let severity: JournalSeverity
        let rawLine: String
        let template: String
        var occurrences: [Occurrence]

        var repeatCount: Int { occurrences.count }

        /// Names the process without claiming a PID the group does not
        /// share. Several PIDs collapsed together → show the bare name.
        var displayProcess: String {
            Set(occurrences.map(\.process)).count > 1 ? processGroupKey : process
        }

        /// Capture-slot indices whose values differ across the run —
        /// what the expanded occurrence list shows per line.
        var variedCaptureIndices: [Int] {
            guard let first = occurrences.first else { return [] }
            return first.captures.indices.filter { index in
                occurrences.contains {
                    $0.captures.indices.contains(index) && $0.captures[index] != first.captures[index]
                }
            }
        }

        var day: String {
            String(firstTimestamp.prefix(10))
        }

        /// "19:43:45" — the date lives in the day divider and the
        /// tooltip, not on every row.
        var timeOfDay: String {
            guard let tIndex = firstTimestamp.firstIndex(of: "T") else {
                return firstTimestamp
            }
            return String(firstTimestamp[firstTimestamp.index(after: tIndex)...].prefix(8))
        }
    }

    enum JournalDisplayItem: Identifiable {
        case day(String)
        case entry(JournalDisplayEntry)

        var id: String {
            switch self {
            case .day(let day): return "day:\(day)"
            case .entry(let entry): return "entry:\(entry.id)"
            }
        }
    }

    func journalDisplayItems(lines: [String]) -> [JournalDisplayItem] {
        var items: [JournalDisplayItem] = []
        var pending: JournalDisplayEntry?
        var lastDay = ""

        func flush() {
            if let entry = pending {
                items.append(.entry(entry))
                pending = nil
            }
        }

        var usedIds: Set<String> = []

        for line in lines {
            let parts = splitJournalLine(line)
            let severity = journalSeverity(line)
            let fingerprint = JournalMessageFingerprinting.fingerprint(parts.message)
            let groupKey = journalProcessGroupKey(parts.process)
            if var entry = pending,
               !parts.message.isEmpty,
               entry.processGroupKey == groupKey,
               entry.severity == severity,
               entry.template == fingerprint.template {
                entry.lastTimestamp = parts.timestamp
                entry.occurrences.append(
                    .init(
                        timestamp: parts.timestamp,
                        captures: fingerprint.captures,
                        process: parts.process
                    )
                )
                pending = entry
                continue
            }
            flush()
            if parts.timestamp.count >= 10 {
                let day = String(parts.timestamp.prefix(10))
                if day != lastDay {
                    items.append(.day(day))
                    lastDay = day
                }
            }
            // Content-derived so the id survives a filter change. A
            // collision needs an identical group at the same second under
            // the same process — the ordinal only breaks that tie.
            var id = "\(parts.timestamp)|\(groupKey)|\(fingerprint.template)"
            if usedIds.contains(id) {
                var ordinal = 2
                while usedIds.contains("\(id)#\(ordinal)") { ordinal += 1 }
                id = "\(id)#\(ordinal)"
            }
            usedIds.insert(id)

            pending = JournalDisplayEntry(
                id: id,
                firstTimestamp: parts.timestamp,
                lastTimestamp: parts.timestamp,
                host: parts.host,
                process: parts.process,
                processGroupKey: groupKey,
                message: parts.message,
                severity: severity,
                rawLine: line,
                template: fingerprint.template,
                occurrences: [.init(
                    timestamp: parts.timestamp,
                    captures: fingerprint.captures,
                    process: parts.process
                )]
            )
        }
        flush()
        return items
    }

    // MARK: - Journal rendering

    func journalEntriesList(lines: [String], autoScroll: Bool) -> some View {
        let items = journalDisplayItems(lines: lines)
        let host = items.compactMap { item -> String? in
            if case .entry(let entry) = item, !entry.host.isEmpty { return entry.host }
            return nil
        }.first
        let entryCount = items.reduce(0) { count, item in
            if case .entry = item { return count + 1 }
            return count
        }
        let coalescedGroups = items.reduce(0) { count, item in
            if case .entry(let entry) = item, entry.repeatCount > 1 { return count + 1 }
            return count
        }

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(journalScrollAxes) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        journalColumnHeader(host: host)
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .day(let day):
                                journalDayDivider(day)
                            case .entry(let entry):
                                journalEntryRow(entry, striped: index.isMultiple(of: 2))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(
                        minWidth: wrapJournalLines ? 0 : 1180,
                        maxWidth: wrapJournalLines ? .infinity : nil,
                        alignment: .leading
                    )
                }
                .onChange(of: lines.count) { _ in
                    if autoScroll, let last = items.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            journalFooter(
                entryCount: entryCount,
                coalescedGroups: coalescedGroups,
                lineCount: lines.count
            )
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var journalScrollAxes: Axis.Set {
        wrapJournalLines ? .vertical : [.vertical, .horizontal]
    }

    func journalColumnHeader(host: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear
                .frame(width: 3)
            Text("Time")
                .frame(width: 64, alignment: .leading)
            Text("Process")
                .frame(width: 142, alignment: .leading)
            Text("Message")
                .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
            // The host never varies within one server's journal —
            // shown once here instead of 74pt on every row.
            if let host {
                Spacer(minLength: 8)
                Text(host)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    func journalDayDivider(_ day: String) -> some View {
        HStack(spacing: 8) {
            Text(day)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    func journalEntryRow(_ entry: JournalDisplayEntry, striped: Bool) -> some View {
        let isExpandable = wrapJournalLines
            && entry.message.count > Self.journalMessageExpandThreshold
        let isExpanded = expandedJournalEntryIds.contains(entry.id)
        let isGroupExpanded = expandedJournalGroupIds.contains(entry.id)

        return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(entry.severity.accentColor)
                .frame(width: 3)
            Text(entry.timeOfDay)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
                .help(journalTimestampHelp(entry))
            Text(entry.displayProcess)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 142, alignment: .leading)
                .help(entry.displayProcess)
            HStack(alignment: .top, spacing: 6) {
                if entry.repeatCount > 1 {
                    Button {
                        if isGroupExpanded {
                            expandedJournalGroupIds.remove(entry.id)
                        } else {
                            expandedJournalGroupIds.insert(entry.id)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("×\(entry.repeatCount)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                            Image(systemName: isGroupExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        .foregroundStyle(entry.severity.foreground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (entry.severity.accentColor == .clear
                                ? Color.secondary
                                : entry.severity.accentColor).opacity(0.15),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .help(journalTimestampHelp(entry) + " — click to list each occurrence")
                }
                Text(JournalSyntaxHighlighting.highlighted(message: entry.message))
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.severity.foreground)
                    .textSelection(.enabled)
                    .lineLimit(
                        isExpanded ? nil : (wrapJournalLines ? Self.journalMessageLineCap : 1)
                    )
                    .truncationMode(.tail)
                    .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
                    .fixedSize(horizontal: !wrapJournalLines, vertical: wrapJournalLines)
                if isExpandable {
                    Button {
                        if isExpanded {
                            expandedJournalEntryIds.remove(entry.id)
                        } else {
                            expandedJournalEntryIds.insert(entry.id)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "ellipsis")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse entry" : "Show full entry")
                }
            }
            .frame(maxWidth: wrapJournalLines ? .infinity : nil, alignment: .leading)
        }
        if entry.repeatCount > 1, isGroupExpanded {
            journalOccurrenceList(entry)
        }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        // Alternating stripes carry the row rhythm; severity lives in
        // the accent bar and text color, not a full-row wash — 42 red
        // rows in a block were unreadable.
        .background(
            striped
                ? Color.clear
                : Color(NSColor.controlBackgroundColor).opacity(0.45)
        )
        .contextMenu {
            Button("Copy Message") { copyJournalText(entry.message) }
            Button("Copy Entry") { copyJournalText(entry.rawLine) }
        }
    }

    /// The expanded view of a coalesced run: one compact line per
    /// occurrence, showing its time and only the parameter values that
    /// vary across the run — the message itself is already on the
    /// parent row.
    func journalOccurrenceList(_ entry: JournalDisplayEntry) -> some View {
        let variedIndices = entry.variedCaptureIndices
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entry.occurrences.enumerated()), id: \.offset) { _, occurrence in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(timeOfDay(occurrence.timestamp))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 64, alignment: .leading)
                        .help(occurrence.timestamp)
                    let varied = variedIndices.compactMap { index in
                        occurrence.captures.indices.contains(index) ? occurrence.captures[index] : nil
                    }
                    Text(varied.isEmpty ? "identical" : varied.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(varied.isEmpty ? .tertiary : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 73)
        .padding(.top, 3)
        .padding(.bottom, 1)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)
                .padding(.leading, 67)
        }
    }

    func timeOfDay(_ timestamp: String) -> String {
        guard let tIndex = timestamp.firstIndex(of: "T") else { return timestamp }
        return String(timestamp[timestamp.index(after: tIndex)...].prefix(8))
    }

    func journalTimestampHelp(_ entry: JournalDisplayEntry) -> String {
        entry.repeatCount > 1
            ? "Repeated \(entry.repeatCount)× · \(entry.firstTimestamp) – \(entry.lastTimestamp)"
            : entry.firstTimestamp
    }

    func journalFooter(entryCount: Int, coalescedGroups: Int, lineCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
            if coalescedGroups > 0 {
                Text("· \(entryCount) shown · \(coalescedGroups) repeated group\(coalescedGroups == 1 ? "" : "s") coalesced")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(NSColor.controlBackgroundColor))
    }

    func copyJournalText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        // Structured entries carry an explicit level — trust it for the
        // payload (substring heuristics misfire on payload contents), but
        // still scan the text outside the payload: a wrapper like
        // "Failed to deliver: {level:info,…}" is an error.
        let assessment = JournalSyntaxHighlighting.assess(message: line)
        let keyword = keywordJournalSeverity(assessment.residualText)
        guard let level = assessment.level else { return keyword }
        let structured: JournalSeverity
        switch level {
        case .critical: structured = .critical
        case .error: structured = .error
        case .warning: structured = .warning
        case .notice: structured = .notice
        case .trace, .debug, .info: structured = .info
        }
        return structured.rank >= keyword.rank ? structured : keyword
    }

    func keywordJournalSeverity(_ text: String) -> JournalSeverity {
        let upper = text.uppercased()
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

        /// Ordering for combining structured-level and keyword severity.
        var rank: Int {
            switch self {
            case .info: return 0
            case .notice: return 1
            case .warning: return 2
            case .error: return 3
            case .critical: return 4
            }
        }

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
