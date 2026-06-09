import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension PostgresMonitorView {
    // MARK: - Sessions, query runner, schema, explain

    var sessionsView: some View {
        List(selection: $selectedPid) {
            ForEach(filteredSessions) { session in
                HStack(spacing: 8) {
                    monoCell(session.pid, width: 70)
                    monoCell(session.user, width: 90)
                    monoCell(session.state, width: 90, color: statusColor(session.state))
                    monoCell(session.wait, width: 130)
                    monoCell(session.age, width: 90)
                    monoCell(session.query)
                }
                .tag(session.pid)
                .contextMenu {
                    Button("Cancel Query") {
                        pendingBackendAction = BackendAction(function: "pg_cancel_backend", pid: session.pid)
                    }
                    Button("Terminate Backend", role: .destructive) {
                        pendingBackendAction = BackendAction(function: "pg_terminate_backend", pid: session.pid)
                    }
                    Button("Copy Query") { RemoteCommandRunner.copy(session.query) }
                }
            }
        }
        .listStyle(.plain)
    }

    var filteredSessions: [PGSession] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.pid.contains(needle)
                || $0.user.lowercased().contains(needle)
                || $0.query.lowercased().contains(needle)
                || $0.state.lowercased().contains(needle)
        }
    }

    var queryRunner: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                queryEditorToolbar
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 210)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            queryResultsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var queryEditorToolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runQuery() }
            } label: {
                Label(queryIsRunning ? "Running" : "Run", systemImage: queryIsRunning ? "hourglass" : "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(queryIsRunning || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                queryText = ""
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(queryIsRunning || queryText.isEmpty)

            Spacer()

            queryStatusView
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var queryStatusView: some View {
        TimelineView(.periodic(from: queryStartedAt ?? Date(), by: 1)) { context in
            HStack(spacing: 6) {
                if queryIsRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(queryStatusText(now: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(queryError == nil ? Color.secondary : Color.red)
            }
        }
    }

    var queryResultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(queryResultsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !queryWarnings.isEmpty {
                    Label("\(queryWarnings.count) warning\(queryWarnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(queryWarnings.joined(separator: "\n"))
                }

                Spacer()

                TextField("Filter results", text: $queryFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(queryResult.rows.isEmpty)

                Button {
                    RemoteCommandRunner.copy(resultText(visibleQueryResult))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(visibleQueryResult.rows.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let queryError {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(queryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.06))
            }

            Divider()

            resultTable(visibleQueryResult)
        }
    }

    var schemaBrowser: some View {
        Table(filteredTables.sorted(using: schemaSortOrder), selection: $selectedTableId, sortOrder: $schemaSortOrder) {
            TableColumn("Schema", value: \.schema) { table in
                monoCell(table.schema, color: .secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Name", value: \.name) { table in
                monoCell(table.name)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Kind", value: \.kind) { table in
                monoCell(table.kind)
            }
            .width(min: 55, ideal: 70, max: 90)

            TableColumn("Size", value: \.sizeBytes) { table in
                monoCell(table.size)
            }
            .width(min: 75, ideal: 90, max: 120)

            TableColumn("Rows", value: \.estimateCount) { table in
                monoCell(table.estimate)
            }
            .width(min: 80, ideal: 100)
        }
    }

    var filteredTables: [PGTableInfo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return schemaRows }
        return schemaRows.filter {
            $0.schema.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    var explainPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                explainToolbar
                TextEditor(text: $queryText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 210)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            explainResultsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var explainToolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runExplain() }
            } label: {
                Label(explainIsRunning ? "Running" : "Explain Analyze", systemImage: explainIsRunning ? "hourglass" : "chart.bar.doc.horizontal")
            }
            .disabled(explainIsRunning || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                RemoteCommandRunner.copy(explainText)
            } label: {
                Label("Copy Plan", systemImage: "doc.on.doc")
            }
            .disabled(explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            TimelineView(.periodic(from: explainStartedAt ?? Date(), by: 1)) { context in
                HStack(spacing: 6) {
                    if explainIsRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(explainStatusText(now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(explainError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var explainResultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(explainSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !explainWarnings.isEmpty {
                    postgresWarningsLabel(explainWarnings)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let explainError {
                Divider()
                postgresInlineNotice(
                    systemImage: "xmark.octagon.fill",
                    title: "Explain failed",
                    message: explainError,
                    color: .red
                )
            }

            Divider()

            if explainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                placeholderView(icon: "chart.bar.doc.horizontal", title: "No plan", message: "Run Explain Analyze to inspect the current SQL.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    HighlightedRawOutputText(value: explainText)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

}
