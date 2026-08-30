import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

enum MonitorJournalSeverity: String, CaseIterable, Hashable, Identifiable {
    case error
    case warn
    case info
    case debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .error: return "Errors"
        case .warn:  return "Warnings"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .info:  return "circle.fill"
        case .debug: return "ladybug.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        case .debug: return .secondary
        }
    }

    /// Ordering for combining structured-level and keyword-derived severity.
    var rank: Int {
        switch self {
        case .error: return 3
        case .warn:  return 2
        case .debug: return 1
        case .info:  return 0
        }
    }
}

struct MonitorJournalLine: Identifiable {
    let id: Int
    let timestamp: String?
    let prefix: String
    let message: String
    let severity: MonitorJournalSeverity
    let raw: String

    /// `prefix` with the emitting PID removed (`web-1 sshd[1234]` →
    /// `web-1 sshd`). journald stamps every forked worker with its own
    /// PID, so grouping on the raw prefix leaves repeated failed logins
    /// as a wall of one-line groups.
    var groupKey: String { journalProcessGroupKey(prefix) }

    static func parseAll(_ rawLines: [String]) -> [MonitorJournalLine] {
        rawLines.enumerated().map { idx, raw in parse(raw: raw, id: idx) }
    }

    private static func parse(raw: String, id: Int) -> MonitorJournalLine {
        let chars = Array(raw)
        let isShortIso = chars.count >= 19
            && chars[4] == "-" && chars[7] == "-" && chars[10] == "T"
            && chars[13] == ":" && chars[16] == ":"

        var timestamp: String? = nil
        var prefix = ""
        var message = raw

        if isShortIso, let firstSpace = raw.firstIndex(of: " ") {
            let isoPart = raw[..<firstSpace]
            timestamp = formatTimestamp(String(isoPart))
            let rest = String(raw[raw.index(after: firstSpace)...])
            if let colonRange = rest.range(of: ": ") {
                prefix = String(rest[..<colonRange.lowerBound])
                message = String(rest[colonRange.upperBound...])
            } else {
                message = rest
            }
        }

        return MonitorJournalLine(
            id: id,
            timestamp: timestamp,
            prefix: prefix,
            message: message,
            severity: severity(for: message),
            raw: raw
        )
    }

    private static func formatTimestamp(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let timePart = iso[iso.index(after: tIndex)...]
        let stopIdx = timePart.firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "." }
        if let stopIdx { return String(timePart[..<stopIdx]) }
        return String(timePart)
    }

    private static let errorRegex = try? NSRegularExpression(
        pattern: #"\b(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)\b"#,
        options: [.caseInsensitive]
    )
    private static let warnRegex = try? NSRegularExpression(
        pattern: #"\b(warn|warning|deprecated|timeout|timed\s*out|retry|retrying|deferred|refused|rejected)\b"#,
        options: [.caseInsensitive]
    )
    private static let debugRegex = try? NSRegularExpression(
        pattern: #"\b(debug|trace)\b"#,
        options: [.caseInsensitive]
    )

    private static func severity(for message: String) -> MonitorJournalSeverity {
        // Structured entries carry an explicit level — trust it for the
        // payload (keyword heuristics misfire on scary words inside URIs),
        // but still scan the text outside the payload: a wrapper like
        // "Failed to deliver: {level:info,…}" is an error.
        let assessment = JournalSyntaxHighlighting.assess(message: message)
        let keyword = keywordSeverity(for: assessment.residualText)
        guard let level = assessment.level else { return keyword }
        let structured: MonitorJournalSeverity
        switch level {
        case .trace, .debug: structured = .debug
        case .info, .notice: structured = .info
        case .warning: structured = .warn
        case .error, .critical: structured = .error
        }
        return structured.rank >= keyword.rank ? structured : keyword
    }

    private static func keywordSeverity(for text: String) -> MonitorJournalSeverity {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if errorRegex?.firstMatch(in: text, range: range) != nil { return .error }
        if warnRegex?.firstMatch(in: text, range: range) != nil { return .warn }
        if debugRegex?.firstMatch(in: text, range: range) != nil { return .debug }
        return .info
    }

    private static let ipv4Regex = try? NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    )

    var extractedIPv4: String? {
        guard let regex = MonitorJournalLine.ipv4Regex else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let r = Range(match.range, in: message) else { return nil }
        return String(message[r])
    }
}

/// A run of consecutive journal lines that are the same log statement
/// fired with different parameters — same severity, prefix, and
/// fingerprint template. Rendered as one row with a repeat badge; the
/// varying parameters (connection ids, timestamps, …) live in an
/// expandable occurrence list instead of repeating the full message.
struct MonitorJournalGroup: Identifiable {
    let lines: [MonitorJournalLine]

    var id: Int { lines[0].id }
    var first: MonitorJournalLine { lines[0] }
    var count: Int { lines.count }

    /// Capture-slot indices whose values differ across the run — the
    /// only parameters worth listing per occurrence.
    var variedCaptureIndices: [Int] {
        JournalMessageFingerprinting.variedCaptureIndices(
            of: lines.map { JournalMessageFingerprinting.fingerprint($0.message) }
        )
    }

    /// The varying parameter values of `line`, for the occurrence list.
    func variedCaptures(of line: MonitorJournalLine, at indices: [Int]) -> [String] {
        let captures = JournalMessageFingerprinting.fingerprint(line.message).captures
        return indices.compactMap { captures.indices.contains($0) ? captures[$0] : nil }
    }

    var timeRange: String? {
        guard count > 1, let firstTime = first.timestamp, let lastTime = lines[count - 1].timestamp else {
            return nil
        }
        return "\(firstTime) – \(lastTime)"
    }

    static func groupConsecutive(_ lines: [MonitorJournalLine]) -> [MonitorJournalGroup] {
        var groups: [MonitorJournalGroup] = []
        var run: [MonitorJournalLine] = []
        for line in lines {
            if let last = run.last,
               last.severity == line.severity,
               last.groupKey == line.groupKey,
               JournalMessageFingerprinting.fingerprint(last.message).template
                   == JournalMessageFingerprinting.fingerprint(line.message).template {
                run.append(line)
                continue
            }
            if !run.isEmpty { groups.append(MonitorJournalGroup(lines: run)) }
            run = [line]
        }
        if !run.isEmpty { groups.append(MonitorJournalGroup(lines: run)) }
        return groups
    }
}

/// Standalone journal drill-down sheet: fetches the last hour of
/// warning-and-worse entries and renders them in the filterable log
/// view. Opened from a fleet-row journal chip or the expanded row's
/// "Open journal" action.
struct FleetJournalSheet: View {
    let connectionId: String?
    let connectionLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var rawLines: [String] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Journal · \(connectionLabel)", systemImage: "exclamationmark.bubble")
                    .font(.headline)
                Text("errors and warnings · last hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh") {
                    Task { await load() }
                }
                .disabled(isLoading || connectionId == nil)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            Group {
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    MonitorJournalLogView(rawLines: rawLines, focusOnIssues: true)
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 640)
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let connectionId else {
            loadError = "Not connected to this host."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: "journalctl -p warning --since '-1 hour' --no-pager -q -n 400 2>/dev/null"
            )
            let lines = result.output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty && !result.succeeded {
                loadError = "journalctl isn't available on this host, or reading the journal requires elevated permissions."
            } else {
                rawLines = lines
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct MonitorJournalLogView: View {
    let rawLines: [String]
    var fallbackHints: [String] = []
    /// Open pre-filtered to errors and warnings so the problem is on
    /// screen immediately — the reason a user opens a journal from a
    /// problem chip. Falls back to all severities on appear when the
    /// sample contains no issue lines, so the view never opens empty.
    var focusOnIssues = false

    @State private var searchText = ""
    @State private var enabledSeverities: Set<MonitorJournalSeverity>
    @State private var pinnedIDs: Set<Int> = []
    @State private var jumpCursor: Int?
    @State private var expandedGroupIDs: Set<Int> = []

    init(rawLines: [String], fallbackHints: [String] = [], focusOnIssues: Bool = false) {
        self.rawLines = rawLines
        self.fallbackHints = fallbackHints
        self.focusOnIssues = focusOnIssues
        _enabledSeverities = State(
            initialValue: focusOnIssues
                ? [.error, .warn]
                : Set(MonitorJournalSeverity.allCases)
        )
    }

    private var lines: [MonitorJournalLine] { MonitorJournalLine.parseAll(rawLines) }

    private var counts: [MonitorJournalSeverity: Int] {
        var c: [MonitorJournalSeverity: Int] = [:]
        for line in lines { c[line.severity, default: 0] += 1 }
        return c
    }

    private var filtered: [MonitorJournalLine] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lines.filter { line in
            guard enabledSeverities.contains(line.severity) else { return false }
            if needle.isEmpty { return true }
            return line.raw.lowercased().contains(needle)
        }
    }

    private var groups: [MonitorJournalGroup] {
        MonitorJournalGroup.groupConsecutive(filtered)
    }

    private var pinnedLines: [MonitorJournalLine] {
        lines.filter { pinnedIDs.contains($0.id) }
    }

    private var issueIDs: [Int] {
        groups
            .filter { $0.first.severity == .error || $0.first.severity == .warn }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controls
            Group {
                if filtered.isEmpty && pinnedLines.isEmpty {
                    placeholder
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !pinnedLines.isEmpty {
                                    pinnedSection
                                }
                                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                    row(group.first, isPinned: pinnedIDs.contains(group.first.id), group: group)
                                        .id(group.id)
                                    if index < groups.count - 1 {
                                        Divider().opacity(0.18)
                                    }
                                }
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: jumpCursor) { newValue in
                            guard let target = newValue else { return }
                            withAnimation(.snappy) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            // Issue focus with nothing to focus on would open an empty
            // pane — fall back to showing everything.
            if focusOnIssues,
               !lines.contains(where: { $0.severity == .error || $0.severity == .warn }) {
                enabledSeverities = Set(MonitorJournalSeverity.allCases)
            }
        }
        .onChange(of: rawLines) { _ in
            // Line ids are positions in `rawLines`, so a refetch
            // renumbers every line: a pin or an expanded group kept
            // across it would address whatever now sits at that index.
            pinnedIDs.removeAll()
            expandedGroupIDs.removeAll()
            jumpCursor = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Recent Journal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(headerCountText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            issueNavigator
            exportMenu
        }
    }

    private var headerCountText: String {
        let base = "(\(filtered.count) of \(lines.count)"
        let groupCount = groups.count
        guard groupCount < filtered.count else { return base + ")" }
        return base + " · \(groupCount) rows)"
    }

    @ViewBuilder
    private var issueNavigator: some View {
        if !issueIDs.isEmpty {
            HStack(spacing: 2) {
                Button {
                    jumpToIssue(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Previous issue (error or warning)")

                Text("\(issueIDs.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .frame(minWidth: 18)

                Button {
                    jumpToIssue(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Next issue (error or warning)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.30), lineWidth: 0.5))
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                copyFiltered()
            } label: {
                Label("Copy filtered (\(filtered.count) lines)", systemImage: "doc.on.doc")
            }
            .disabled(filtered.isEmpty)

            Button {
                copyAll()
            } label: {
                Label("Copy all (\(lines.count) lines)", systemImage: "doc.on.doc.fill")
            }
            .disabled(lines.isEmpty)

            Divider()

            Button {
                saveFiltered()
            } label: {
                Label("Save filtered as .log…", systemImage: "square.and.arrow.down")
            }
            .disabled(filtered.isEmpty)

            if !pinnedIDs.isEmpty {
                Divider()
                Button(role: .destructive) {
                    pinnedIDs.removeAll()
                } label: {
                    Label("Unpin all (\(pinnedIDs.count))", systemImage: "pin.slash")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy or export journal lines")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            severityPills
            Spacer(minLength: 8)
            searchField
        }
    }

    private var severityPills: some View {
        HStack(spacing: 6) {
            ForEach(MonitorJournalSeverity.allCases) { severity in
                let count = counts[severity] ?? 0
                let isOn = enabledSeverities.contains(severity)
                Button {
                    toggle(severity)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: severity.symbol)
                            .font(.caption2)
                            .foregroundStyle(isOn ? severity.color : .secondary)
                        Text("\(count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isOn ? severity.color : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (isOn ? severity.color.opacity(0.14) : Color.gray.opacity(0.10)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            isOn ? severity.color.opacity(0.35) : Color.clear,
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("\(severity.label): \(count) — click to toggle")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
    }

    // MARK: Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text("Pinned (\(pinnedLines.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ForEach(Array(pinnedLines.enumerated()), id: \.element.id) { index, line in
                row(line, isPinned: true)
                if index < pinnedLines.count - 1 {
                    Divider().opacity(0.18)
                }
            }
            Divider()
                .overlay(Color.yellow.opacity(0.40))
        }
        .background(Color.yellow.opacity(0.06))
    }

    // MARK: Placeholder

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: lines.isEmpty ? "tray" : "text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(placeholderText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if lines.isEmpty, !fallbackHints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(fallbackHints.enumerated()), id: \.offset) { _, hint in
                        Label(hint, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var placeholderText: String {
        if lines.isEmpty { return "No journal entries." }
        if !searchText.isEmpty { return "No matches for \"\(searchText)\"." }
        return "All severities are filtered out — re-enable one above."
    }

    // MARK: Row

    private func row(
        _ line: MonitorJournalLine, isPinned: Bool, group: MonitorJournalGroup? = nil
    ) -> some View {
        let repeatCount = group?.count ?? 1
        let isExpanded = group.map { expandedGroupIDs.contains($0.id) } ?? false

        return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 8) {
            Button {
                togglePin(line.id)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.caption2)
                    .foregroundStyle(isPinned ? Color.yellow : Color.gray.opacity(0.35))
            }
            .buttonStyle(.plain)
            .frame(width: 12, alignment: .center)
            .padding(.top, 3)
            .help(isPinned ? "Unpin" : "Pin")

            Image(systemName: line.severity.symbol)
                .font(.caption2)
                .foregroundStyle(line.severity.color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            if let timestamp = line.timestamp {
                Text(timestamp)
                    .font(.system(.caption2, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .leading)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 1) {
                if !line.prefix.isEmpty {
                    Text(line.prefix)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(alignment: .top, spacing: 6) {
                    if repeatCount > 1 {
                        Text("×\(repeatCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(line.severity.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(line.severity.color.opacity(0.14), in: Capsule())
                            .help("Repeated \(repeatCount)× with varying parameters")
                    }
                    Text(highlightedMessage(line.message))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(messageColor(for: line.severity))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            if let group, repeatCount > 1 {
                Button {
                    toggleGroupExpansion(group.id)
                } label: {
                    HStack(spacing: 4) {
                        if let range = group.timeRange {
                            Text(range)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
                .help(isExpanded ? "Hide occurrences" : "Show each occurrence")
            }
        }
        if let group, repeatCount > 1, isExpanded {
            occurrenceList(group)
        }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(jumpCursor == line.id ? Color.accentColor.opacity(0.14) : Color.clear)
        .contextMenu {
            Button(isPinned ? "Unpin line" : "Pin line") {
                togglePin(line.id)
            }
            Button("Copy line") {
                RemoteCommandRunner.copy(line.raw)
            }
            if let group, group.count > 1 {
                Button("Copy all \(group.count) occurrences") {
                    RemoteCommandRunner.copy(group.lines.map(\.raw).joined(separator: "\n"))
                }
            }
            if let pretty = JournalSyntaxHighlighting.prettyPrintedJSON(in: line.message) {
                Button("Copy as pretty JSON") {
                    RemoteCommandRunner.copy(pretty)
                }
            }
            if let ip = line.extractedIPv4 {
                Button("Copy IP \(ip)") {
                    RemoteCommandRunner.copy(ip)
                }
            }
            if let timestamp = line.timestamp {
                Button("Copy timestamp \(timestamp)") {
                    RemoteCommandRunner.copy(timestamp)
                }
            }
        }
    }

    /// The expanded view of a repeat group: one compact line per
    /// occurrence showing its timestamp and only the parameter values
    /// that actually vary — never the full message again.
    private func occurrenceList(_ group: MonitorJournalGroup) -> some View {
        let variedIndices = group.variedCaptureIndices
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(group.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.timestamp ?? "–")
                        .font(.system(.caption2, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    let varied = group.variedCaptures(of: line, at: variedIndices)
                    Text(varied.isEmpty ? "identical" : varied.joined(separator: " · "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(varied.isEmpty ? .tertiary : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 96)
        .padding(.top, 3)
        .padding(.bottom, 1)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)
                .padding(.leading, 90)
        }
    }

    private func toggleGroupExpansion(_ id: Int) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private func messageColor(for severity: MonitorJournalSeverity) -> Color {
        switch severity {
        case .error, .warn: return severity.color
        case .info:         return .primary
        case .debug:        return .secondary
        }
    }

    private func highlightedMessage(_ message: String) -> AttributedString {
        var attributed = JournalSyntaxHighlighting.highlighted(message: message)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(of: needle, options: .caseInsensitive) {
            attributed[found].backgroundColor = Color.yellow.opacity(0.45)
            attributed[found].foregroundColor = Color.black
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }

    // MARK: Actions

    private func toggle(_ severity: MonitorJournalSeverity) {
        if enabledSeverities.contains(severity) {
            if enabledSeverities.count == 1 {
                enabledSeverities = Set(MonitorJournalSeverity.allCases)
            } else {
                enabledSeverities.remove(severity)
            }
        } else {
            enabledSeverities.insert(severity)
        }
    }

    private func togglePin(_ id: Int) {
        if pinnedIDs.contains(id) {
            pinnedIDs.remove(id)
        } else {
            pinnedIDs.insert(id)
        }
    }

    private func jumpToIssue(forward: Bool) {
        guard !issueIDs.isEmpty else { return }
        if let cursor = jumpCursor, let idx = issueIDs.firstIndex(of: cursor) {
            let next = forward
                ? (idx + 1) % issueIDs.count
                : (idx - 1 + issueIDs.count) % issueIDs.count
            jumpCursor = issueIDs[next]
        } else {
            jumpCursor = forward ? issueIDs.first : issueIDs.last
        }
    }

    private func copyFiltered() {
        RemoteCommandRunner.copy(filtered.map(\.raw).joined(separator: "\n"))
    }

    private func copyAll() {
        RemoteCommandRunner.copy(lines.map(\.raw).joined(separator: "\n"))
    }

    private func saveFiltered() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "journal-\(Self.nowSlug()).log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let body = filtered.map(\.raw).joined(separator: "\n")
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func nowSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Monitor diagnostic data

