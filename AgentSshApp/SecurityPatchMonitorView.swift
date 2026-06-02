import AppKit
import SwiftUI
import AgentSshMacOS

struct SecurityPatchMonitorView: View {
    @StateObject private var store: SecurityPatchMonitorStore

    init(connectionId: String, profileId: String? = nil, connectionLabel: String) {
        let request = SecurityPatchScanRequest(
            connectionId: connectionId,
            profileId: profileId,
            hostLabel: connectionLabel
        )
        _store = StateObject(wrappedValue: SecurityPatchMonitorStore(request: request))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await store.loadPreview() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Security")
                    .font(.headline)
                Text(store.request.hostLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoadingPreview || store.isScanning || store.isRefreshingAdvisories {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await store.runScan() }
            } label: {
                Label(store.result == nil ? "Run Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.preview == nil || store.isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            errorPane(error)
        } else if let result = store.result {
            resultPane(result)
        } else {
            previewPane
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-only security scan")
                .font(.title3.weight(.semibold))
            Text("The scan checks package update status, reboot signals, and sshd hardening using fixed commands. It does not upgrade packages, restart services, or reboot the host.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = store.preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.plannedCommands) { command in
                            commandRow(command)
                            Divider()
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !preview.notes.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(preview.notes, id: \.self) { note in
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if store.isLoadingPreview {
                ProgressView("Preparing scan preview...")
                    .controlSize(.small)
            }
        }
        .padding(16)
    }

    private func resultPane(_ result: SecurityPatchScanResult) -> some View {
        VStack(spacing: 0) {
            summaryStrip(result)
            Divider()
            HSplitView {
                findingsList(result)
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
                findingDetail
                    .frame(minWidth: 320, idealWidth: 430)
                evidenceDetail
                    .frame(minWidth: 300, idealWidth: 380)
            }
            Divider()
            commandsRun(result)
                .frame(height: 120)
        }
    }

    private func summaryStrip(_ result: SecurityPatchScanResult) -> some View {
        HStack(spacing: 12) {
            severitySymbol(result.overallSeverity)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.summaryLabel)
                    .font(.headline)
                    .lineLimit(1)
                Text(summarySubtitle(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isShowingCachedResult {
                summaryBadge(
                    store.isResultStale ? "Stale cache" : "Cached",
                    foreground: store.isResultStale ? .orange : .secondary,
                    background: (store.isResultStale ? Color.orange : Color.secondary).opacity(0.12)
                )
            }
            summaryBadge(result.packageSummary.packageManager.displayName)
            if let count = result.packageSummary.securityUpdateCount {
                summaryBadge("\(count) security")
            }
            if let count = result.packageSummary.totalUpdateCount {
                summaryBadge("\(count) updates")
            }
            if !result.advisoryMatches.isEmpty {
                summaryBadge(
                    "\(result.advisoryMatches.count) KEV",
                    foreground: .red,
                    background: Color.red.opacity(0.12)
                )
            }
            summaryBadge(result.rebootStatus == .required ? "Reboot needed" : "No reboot")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func findingsList(_ result: SecurityPatchScanResult) -> some View {
        List(selection: $store.selectedFindingId) {
            ForEach(result.findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        severitySymbol(finding.severity)
                        Text(finding.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                    }
                    Text(finding.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
                .tag(finding.id)
            }
        }
    }

    private var findingDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let finding = store.selectedFinding {
                    HStack(spacing: 8) {
                        severitySymbol(finding.severity)
                        Text(finding.title)
                            .font(.title3.weight(.semibold))
                    }
                    Text(finding.summary)
                        .font(.callout)
                    if !finding.recommendation.isEmpty {
                        section("Recommendation") {
                            Text(finding.recommendation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let advisoryMatches = store.advisoryMatches(for: finding)
                    if !advisoryMatches.isEmpty {
                        section("CISA KEV") {
                            ForEach(advisoryMatches) { match in
                                advisoryRow(match)
                            }
                        }
                    }
                    if !finding.evidenceIds.isEmpty {
                        section("Evidence") {
                            ForEach(finding.evidenceIds, id: \.self) { evidenceId in
                                Button {
                                    store.selectedEvidenceId = evidenceId
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.text.magnifyingglass")
                                        Text(store.evidence(id: evidenceId)?.title ?? evidenceId)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text("Select a finding.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var evidenceDetail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedEvidence?.title ?? "Evidence")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let evidence = store.selectedEvidence {
                    Button {
                        copy(evidence.rawOutput)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy evidence")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(store.selectedEvidence?.rawOutput ?? "Select evidence from a finding.")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func advisoryRow(_ match: SecurityPatchAdvisoryMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(match.cveId)
                    .font(.caption.weight(.semibold).monospaced())
                Text(match.source.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
                Spacer()
            }
            Text(match.title)
                .font(.caption)
                .lineLimit(2)
            Text("\(match.vendorProject) · \(match.product)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let dueDate = match.dueDate {
                Text("CISA due date: \(dueDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(match.requiredAction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func commandsRun(_ result: SecurityPatchScanResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("Commands Run", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if let status = store.advisoryStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(result.commandAudits.count) commands")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(result.commandAudits) { audit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(audit.displayName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(audit.exitStatus.map { "exit \($0)" } ?? "no exit")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(audit.permissionLimited ? .orange : .secondary)
                            }
                            Text(audit.command)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .frame(width: 280, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .contextMenu {
                            Button("Copy Command") { copy(audit.command) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func commandRow(_ command: SecurityPatchPlannedCommand) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(command.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(command.profile.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(command.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func errorPane(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.orange)
            Text("Security scan failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry Preview") {
                Task { await store.loadPreview() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func severitySymbol(_ severity: SecurityPatchSeverity) -> some View {
        Image(systemName: severity.systemImage)
            .foregroundStyle(severity.color)
            .symbolRenderingMode(.hierarchical)
            .frame(width: 16, height: 16)
    }

    private func summaryBadge(
        _ text: String,
        foreground: Color = .primary,
        background: Color = Color.secondary.opacity(0.12)
    ) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }

    private func summarySubtitle(_ result: SecurityPatchScanResult) -> String {
        let os = result.osInfo.prettyName ?? result.osInfo.id ?? "Unknown OS"
        let scanKind = store.isShowingCachedResult ? "cached scan" : "scan"
        let timestamp = result.scannedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(os) · \(scanKind) \(timestamp)"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension SecurityPatchSeverity {
    var color: Color {
        switch self {
        case .critical: return .red
        case .high: return .orange
        case .warning: return .yellow
        case .info: return .green
        case .unknown: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}
