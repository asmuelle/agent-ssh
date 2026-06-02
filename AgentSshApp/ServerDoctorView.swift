import SwiftUI
import AgentSshMacOS

struct ServerDoctorTarget: Identifiable, Equatable {
    let id: String
    let hostLabel: String
    let connectionId: String
    /// Stable connection-profile id used to key persisted summaries.
    let profileId: String

    init(tab: TerminalTab) {
        self.id = tab.connectionId
        self.hostLabel = tab.profile.name
        self.connectionId = tab.connectionId
        self.profileId = tab.profile.id
    }
}

struct ServerDoctorView: View {
    @StateObject private var store: ServerDoctorStore
    @Environment(\.dismiss) private var dismiss

    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explanationError: String?

    init(target: ServerDoctorTarget) {
        let request = ServerDoctorCollectionRequest(
            connectionId: target.connectionId,
            hostLabel: target.hostLabel,
            privacyPreset: ServerDoctorPreferences.privacyPreset()
        )
        let provider = ServerDoctorProviderFactory.makeProvider()
        _store = StateObject(wrappedValue: ServerDoctorStore(
            request: request,
            provider: provider,
            profileId: target.profileId
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 640, idealHeight: 760)
        .task { await store.loadPreview() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Server Doctor")
                    .font(.headline)
                Text(store.request.hostLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isCollecting || store.isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            errorPane(error)
        } else if let report = store.report {
            reportPane(report)
        } else {
            previewPane
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read-only collection preview")
                .font(.title3.weight(.semibold))
            Text("Doctor will run only fixed read-only collectors. No files are edited, no services are restarted, and no interactive sudo prompt is used.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if store.providerMetadata != .localHeuristics {
                Label(
                    "LLM: \(store.providerMetadata.providerName) / \(store.providerMetadata.modelName)",
                    systemImage: "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let preview = store.preview {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Collector profiles", systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        ForEach(store.request.profiles, id: \.self) { profile in
                            Text(profile.displayName)
                                .font(.callout)
                        }
                    }
                    .frame(width: 180, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Commands", systemImage: "terminal")
                            .font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(preview.plannedCommands) { command in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(command.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(command.command)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if !preview.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.notes, id: \.self) { note in
                            Label(note, systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if store.isLoadingPreview {
                ProgressView("Preparing preview...")
                    .controlSize(.small)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await store.startDiagnosis() }
                } label: {
                    Label("Start Diagnosis", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.preview == nil || store.isCollecting)
            }
        }
        .padding(20)
    }

    private func reportPane(_ report: ServerDoctorReport) -> some View {
        VStack(spacing: 0) {
            reportSummary(report)
            Divider()
            HSplitView {
                findingsList(report)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                findingDetail
                    .frame(minWidth: 360, idealWidth: 460)
                evidenceDetail
                    .frame(minWidth: 320, idealWidth: 380)
            }
            Divider()
            commandsRun
                .frame(height: 150)
        }
    }

    private func reportSummary(_ report: ServerDoctorReport) -> some View {
        HStack(spacing: 14) {
            severitySymbol(report.overallSeverity)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.reportTitle)
                    .font(.headline)
                Text(report.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            summaryBadge(report.overallSeverity.rawValue.capitalized)
            summaryBadge(report.overallConfidence.rawValue.capitalized)
            summaryBadge(report.provider.providerName)
            if report.provider.modelName != ServerDoctorProviderMetadata.localHeuristics.modelName {
                summaryBadge(report.provider.modelName)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func findingsList(_ report: ServerDoctorReport) -> some View {
        List(selection: $store.selectedFindingId) {
            ForEach(report.findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        severitySymbol(finding.severity)
                        Text(finding.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                    }
                    Text(finding.affectedSubsystem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(finding.confidence.rawValue.capitalized) confidence")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .tag(finding.id)
            }
        }
    }

    private var findingDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let finding = store.selectedFinding {
                    Text(finding.title)
                        .font(.title3.weight(.semibold))
                    Text(finding.summary)
                        .font(.callout)
                    if !finding.explanation.isEmpty {
                        section("Why this matters") {
                            Text(finding.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    explainSimplySection(finding)
                    section("Evidence") {
                        ForEach(finding.evidenceIds, id: \.self) { evidenceId in
                            Button {
                                store.selectedEvidenceId = evidenceId
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    Text(store.evidence(id: evidenceId)?.title ?? evidenceId)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !finding.safeNextSteps.isEmpty {
                        section("Safe next steps") {
                            ForEach(finding.safeNextSteps) { action in
                                Label(action.title, systemImage: "arrow.right.circle")
                                    .font(.callout)
                            }
                        }
                    }
                    if !finding.unsafeActionsToAvoid.isEmpty {
                        section("Avoid for now") {
                            ForEach(finding.unsafeActionsToAvoid, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } else {
                    Text("No finding selected.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.selectedFindingId) { _ in
            explanation = nil
            explanationError = nil
            isExplaining = false
        }
    }

    @ViewBuilder
    private func explainSimplySection(_ finding: ServerDoctorFinding) -> some View {
        if ServerDoctorExplanationService.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await explain(finding) }
                } label: {
                    Label(isExplaining ? "Explaining…" : "Explain simply", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(isExplaining)

                if let explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Label("Generated on-device by Apple Intelligence", systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let explanationError {
                    Text(explanationError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @MainActor
    private func explain(_ finding: ServerDoctorFinding) async {
        isExplaining = true
        explanationError = nil
        defer { isExplaining = false }
        do {
            explanation = try await ServerDoctorExplanationService.explain(
                finding: finding,
                evidence: store.redactedBundle?.evidence ?? []
            )
        } catch {
            explanationError = error.localizedDescription
        }
    }

    private var evidenceDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let evidence = store.selectedEvidence {
                    Text(evidence.title)
                        .font(.headline)
                    Text(evidence.source)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        summaryBadge(evidence.kind.rawValue)
                        if let exit = evidence.exitStatus {
                            summaryBadge("exit \(exit)")
                        }
                        if evidence.truncated {
                            summaryBadge("truncated")
                        }
                        if evidence.permissionLimited {
                            summaryBadge("permission-limited")
                        }
                    }
                    Text(evidence.redactedExcerpt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("No evidence selected.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }

    private var commandsRun: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Commands Run")
                    .font(.headline)
                ForEach(store.redactedBundle?.commandAudits ?? []) { audit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(audit.displayName)
                            .font(.caption.weight(.medium))
                            .frame(width: 150, alignment: .leading)
                        Text(audit.command)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(audit.exitStatus.map { "exit \($0)" } ?? "no exit")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(audit.durationMs) ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func errorPane(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Back to Preview") {
                store.resetToPreview()
                Task { await store.loadPreview() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func summaryBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func severitySymbol(_ severity: ServerDoctorSeverity) -> some View {
        let name: String
        let color: Color
        switch severity {
        case .critical:
            name = "xmark.octagon.fill"
            color = .red
        case .high:
            name = "exclamationmark.triangle.fill"
            color = .orange
        case .warning:
            name = "exclamationmark.circle.fill"
            color = .yellow
        case .info:
            name = "checkmark.circle.fill"
            color = .green
        case .unknown:
            name = "questionmark.circle.fill"
            color = .secondary
        }
        return Image(systemName: name).foregroundStyle(color)
    }
}
