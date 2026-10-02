import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import AgentSshMacOS

struct MonitorDrillDownSheet: View {
    let connectionId: String?
    let drillDown: MonitorDrillDown
    let sshPort: UInt16?
    let hostLabel: String

    @Environment(\.dismiss) var dismiss
    @State var rawOutput = ""
    @State var snapshot: MonitorDiagnosticSnapshot?
    @State var error: String?
    @State var notice: String?
    @State var isLoading = false
    @State var pendingAction: PendingServerAction?
    @State var lastRefreshedAt: Date?
    @State var mode = DrillDownMode.overview
    @State var selectedProcessId: Int?
    @State var selectedThreadId: String?
    @State var selectedFilePath: String?
    @State var selectedSystemdFileId: String?
    @State var selectedUFWRuleId: Int?
    @State var selectedUFWSource: String?
    @State var processSortOrder: [KeyPathComparator<ProcessDiagnosticRow>]
    @State var threadSortOrder: [KeyPathComparator<ThreadDiagnosticRow>] = [
        KeyPathComparator(\.cpuPercent, order: .reverse)
    ]
    @State var focusedTitle: String?
    @State var focusedOutput = ""
    @State var focusedLoading = false

    init(connectionId: String?, drillDown: MonitorDrillDown, sshPort: UInt16?, hostLabel: String) {
        self.connectionId = connectionId
        self.drillDown = drillDown
        self.sshPort = sshPort
        self.hostLabel = hostLabel
        _processSortOrder = State(initialValue: Self.defaultProcessSortOrder(for: drillDown))
        _mode = State(initialValue: Self.defaultMode(for: drillDown))
    }

    /// Unit drill-downs open on the journal (Details) so the errors and
    /// warnings that brought the user here are visible immediately —
    /// status and actions are one segment away in Overview.
    static func defaultMode(for drillDown: MonitorDrillDown) -> DrillDownMode {
        if case .systemdService = drillDown {
            return .details
        }
        return .overview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, notice == nil ? 10 : 4)
            }
            Picker("", selection: $mode) {
                ForEach(DrillDownMode.allCases, id: \.self) { mode in
                    Text(mode.title(for: drillDown)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            Divider()
            diagnosticContent
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .serverActionConfirmation($pendingAction)
        .task(id: drillDown.id) {
            await refresh()
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: drillDown.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(drillDown.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(drillDown.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            systemdActions
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let lastRefreshedAt {
                Text("Updated \(lastRefreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(isLoading)
            .help("Refresh")

            Button {
                RemoteCommandRunner.copy(copyOutput)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled(copyOutput.isEmpty)
            .help("Copy output")

            ExplainButton(context: drillDown.title, text: copyOutput)
                .labelStyle(.iconOnly)
                .disabled(copyOutput.isEmpty)

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

    var copyOutput: String {
        if mode == .raw || focusedOutput.isEmpty {
            return rawOutput
        }
        return focusedOutput
    }

    @ViewBuilder
    var diagnosticContent: some View {
        if mode == .raw {
            rawPane(rawOutput)
        } else if let snapshot {
            switch snapshot {
            case .cpu(let diagnostic):
                cpuContent(diagnostic)
            case .memory(let diagnostic):
                memoryContent(diagnostic)
            case .disk(let diagnostic):
                diskContent(diagnostic)
            case .systemd(let diagnostic):
                systemdContent(diagnostic)
            case .ufw(let diagnostic):
                ufwContent(diagnostic)
            }
        } else if isLoading {
            ProgressView("Loading diagnostics...")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholderPane("No diagnostic data.")
        }
    }

    @ViewBuilder
    var systemdActions: some View {
        if case .systemdService(let unit) = drillDown {
            HStack(spacing: 6) {
                Button {
                    requestSystemdAction(.start, unit: unit)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        Text("Start")
                    }
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .help("Start service")

                Button {
                    requestSystemdAction(.stop, unit: unit)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                }
                .tint(.red)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Stop service")

                Button {
                    requestSystemdAction(.restart, unit: unit)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .tint(.blue)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Restart service")

                Button {
                    requestSystemdAction(.reload, unit: unit)
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .tint(.secondary)
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Reload service")
            }
            .controlSize(.small)
        }
    }

    @MainActor
    func refresh() async {
        guard let connectionId else {
            rawOutput = ""
            snapshot = nil
            error = "No SSH connection selected."
            return
        }

        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: diagnosticScript()
            )
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot = MonitorDiagnosticParser.parse(rawOutput, kind: drillDown)
            lastRefreshedAt = Date()
            applyDefaultSelections()
            ActivityLogStore.shared.record(
                title: "Deep dive opened",
                detail: drillDown.title,
                connectionId: connectionId,
                icon: drillDown.icon,
                severity: result.succeeded ? .info : .warning
            )
            if result.succeeded {
                error = nil
            } else {
                error = "Diagnostics exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
            rawOutput = ""
            snapshot = nil
        }
    }

    /// Render the action and ask for consent. The unit name came from the
    /// host, so rendering may refuse it — refusing loudly beats running
    /// something unvetted.
    @MainActor
    func requestSystemdAction(_ verb: SystemdVerb, unit: String) {
        guard connectionId != nil else {
            error = "No SSH connection selected."
            return
        }

        let rendered: RenderedCommand
        do {
            rendered = try CommandTemplateRenderer.render(
                templateId: verb.templateId,
                values: ["unit": unit]
            )
        } catch let templateError as CommandTemplateError {
            error = templateError.explanation
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        let script = SystemdVerb.script(for: rendered)
        pendingAction = verb.confirmation(unit: unit, host: hostLabel, command: script) {
            await performSystemdAction(verb, unit: unit, script: script)
        }
    }

    @MainActor
    func performSystemdAction(_ verb: SystemdVerb, unit: String, script: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }
        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded {
                let message = "\(verb.rawValue.capitalized) completed for \(unit)."
                ActivityLogStore.shared.record(
                    title: "Service \(verb)",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "switch.2",
                    severity: .success
                )
                await refresh()
                notice = message
            } else {
                ActivityLogStore.shared.record(
                    title: "Service \(verb) failed",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "exclamationmark.triangle.fill",
                    severity: .critical
                )
                error = "\(verb.rawValue.capitalized) exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func runFocusedInspection(title: String, script: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }

        focusedTitle = title
        focusedLoading = true
        focusedOutput = ""
        defer { focusedLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            focusedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.succeeded {
                error = "Inspection exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func applyDefaultSelections() {
        guard let snapshot else { return }
        switch snapshot {
        case .cpu(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
            selectedThreadId = diagnostic.threads.first?.id
        case .memory(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
        case .disk(let diagnostic):
            selectedFilePath = diagnostic.files.first?.path
        case .systemd(let diagnostic):
            selectedSystemdFileId = diagnostic.files.first?.id
        case .ufw(let diagnostic):
            selectedUFWRuleId = diagnostic.rules.first?.id
            selectedUFWSource = ufwBlockedSourceRows(diagnostic).first?.source
        }
        focusedTitle = nil
        focusedOutput = ""
    }

}
