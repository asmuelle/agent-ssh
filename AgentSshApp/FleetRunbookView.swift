import AgentSshMacOS
import SwiftUI

/// Review-first fleet command execution. The first selected hosts are canaries;
/// rollout never starts unless command and verification both pass there.
struct FleetRunbookSheet: View {
    let tabs: [TerminalTab]

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var command = ""
    @State private var verificationCommand = ""
    @State private var rollbackCommand = ""
    @State private var selectedProfileIds: Set<String> = []
    @State private var canaryCount = 1
    @State private var maxConcurrency = 3
    @State private var showingConfirmation = false
    @State private var isRunning = false
    @State private var result: FleetRunbookResult?

    private var selectedTabs: [TerminalTab] {
        tabs.filter { selectedProfileIds.contains($0.profile.id) }
    }

    private var canRun: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedTabs.isEmpty
            && !isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        commandForm
                        rolloutPolicy
                        targetPicker
                    }
                    .padding(16)
                }
                .frame(minWidth: 420, idealWidth: 520)

                resultPane
                    .frame(minWidth: 360, idealWidth: 460)
            }

            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1_050, minHeight: 620, idealHeight: 720)
        .onAppear {
            if selectedProfileIds.isEmpty {
                selectedProfileIds = Set(tabs.map(\.profile.id))
            }
            clampPolicyValues()
        }
        .onChange(of: selectedProfileIds) { _ in clampPolicyValues() }
        .confirmationDialog(
            "Run on \(selectedTabs.count) hosts?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Canary, Then Rollout", role: .destructive) {
                Task { await execute() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationSummary)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Fleet Runbook", systemImage: "server.rack")
                    .font(.headline)
                Text("Canary-first execution with bounded concurrency, verification, and rollback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
                .disabled(isRunning)
        }
        .padding(16)
    }

    private var commandForm: some View {
        GroupBox("Commands") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Runbook name", text: $title)
                    .textFieldStyle(.roundedBorder)
                commandEditor("Command", text: $command, required: true)
                commandEditor("Verification command", text: $verificationCommand, required: false)
                commandEditor("Rollback command", text: $rollbackCommand, required: false)
                Text("Rollback runs only when the main command succeeded and verification failed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func commandEditor(
        _ label: String,
        text: Binding<String>,
        required: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(required ? "\(label) · required" : label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 62)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var rolloutPolicy: some View {
        GroupBox("Rollout Policy") {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(
                    "Canaries: \(canaryCount)",
                    value: $canaryCount,
                    in: 1...max(selectedTabs.count, 1)
                )
                Stepper(
                    "Maximum concurrent rollout hosts: \(maxConcurrency)",
                    value: $maxConcurrency,
                    in: 1...max(selectedTabs.count, 1)
                )
                Text("Canaries run one at a time. Remaining hosts run in batches of at most \(maxConcurrency).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var targetPicker: some View {
        GroupBox("Connected Targets") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Select All") { selectedProfileIds = Set(tabs.map(\.profile.id)) }
                    Button("Clear") { selectedProfileIds.removeAll() }
                    Spacer()
                    Text("\(selectedTabs.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)

                ForEach(tabs) { tab in
                    Toggle(isOn: targetBinding(tab.profile.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.profile.name)
                                .font(.caption.weight(.semibold))
                            Text("\(tab.profile.username)@\(tab.profile.host):\(tab.profile.port)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var resultPane: some View {
        if let result {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(
                        result.abortedAfterCanary ? "Rollout Aborted" : "Run Complete",
                        systemImage: result.abortedAfterCanary ? "hand.raised.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(result.abortedAfterCanary ? .orange : resultColor(result))
                    .font(.headline)
                    Spacer()
                    Text(result.finishedAt.timeIntervalSince(result.startedAt), format: .number.precision(.fractionLength(1)))
                        .font(.caption.monospacedDigit())
                    Text("s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()

                List(result.results) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: stateIcon(item.state))
                                .foregroundStyle(stateColor(item.state))
                            Text(item.target.displayName)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(item.state.rawValue.replacingOccurrences(of: "Failed", with: " failed").capitalized)
                                .font(.caption2)
                                .foregroundStyle(stateColor(item.state))
                        }
                        HStack(spacing: 8) {
                            if let code = item.commandExitCode { Text("command \(code)") }
                            if let code = item.verificationExitCode { Text("verify \(code)") }
                            if let code = item.rollbackExitCode { Text("rollback \(code)") }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if !item.output.isEmpty {
                            Text(item.output)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("Execution Preview", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(confirmationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Label("Every target result is written to the durable operational audit.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Review and Run") { showingConfirmation = true }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
        }
        .padding(14)
    }

    private var confirmationSummary: String {
        let names = selectedTabs.map(\.profile.name).joined(separator: ", ")
        var lines = [
            "Canary hosts: \(min(canaryCount, selectedTabs.count))",
            "Maximum rollout concurrency: \(maxConcurrency)",
            "Targets: \(names.isEmpty ? "none" : names)",
            "",
            "$ \(command.trimmingCharacters(in: .whitespacesAndNewlines))",
        ]
        if !verificationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("VERIFY: \(verificationCommand.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !rollbackCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("ROLLBACK: \(rollbackCommand.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n")
    }

    private func targetBinding(_ profileId: String) -> Binding<Bool> {
        Binding(
            get: { selectedProfileIds.contains(profileId) },
            set: { selected in
                if selected {
                    selectedProfileIds.insert(profileId)
                } else {
                    selectedProfileIds.remove(profileId)
                }
            }
        )
    }

    private func clampPolicyValues() {
        let upper = max(selectedTabs.count, 1)
        canaryCount = min(max(canaryCount, 1), upper)
        maxConcurrency = min(max(maxConcurrency, 1), upper)
    }

    @MainActor
    private func execute() async {
        guard canRun else { return }
        isRunning = true
        result = nil
        defer { isRunning = false }

        let plan = FleetRunbookPlan(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            verificationCommand: verificationCommand,
            rollbackCommand: rollbackCommand,
            targets: selectedTabs.map {
                FleetRunTarget(
                    profileId: $0.profile.id,
                    connectionId: $0.connectionId,
                    displayName: $0.profile.name
                )
            },
            canaryCount: canaryCount,
            maxConcurrency: maxConcurrency
        )

        let completed = await FleetRunbookExecutor.execute(plan: plan) { target, remoteCommand in
            do {
                let remote = try await RemoteCommandRunner.runShell(
                    connectionId: target.connectionId,
                    script: remoteCommand
                )
                return FleetCommandExecution(exitCode: remote.exitCode, output: remote.output)
            } catch {
                return FleetCommandExecution(exitCode: 255, output: error.localizedDescription)
            }
        }
        result = completed

        for item in completed.results {
            ActivityLogStore.shared.record(
                title: "Fleet runbook: \(completed.title)",
                detail: "\(item.target.displayName): \(item.state.rawValue)",
                profileId: item.target.profileId,
                connectionId: item.target.connectionId,
                icon: "server.rack",
                severity: auditSeverity(item.state),
                actor: .user,
                action: "fleet-runbook",
                command: plan.command,
                outcome: auditOutcome(item.state),
                exitCode: item.commandExitCode
            )
        }
    }

    private func stateColor(_ state: FleetTargetRunState) -> Color {
        switch state {
        case .succeeded: return .green
        case .skipped: return .secondary
        case .rolledBack: return .orange
        case .failed, .verificationFailed, .rollbackFailed: return .red
        }
    }

    private func stateIcon(_ state: FleetTargetRunState) -> String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .skipped: return "forward.end.circle"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        case .failed, .verificationFailed, .rollbackFailed: return "xmark.octagon.fill"
        }
    }

    private func resultColor(_ result: FleetRunbookResult) -> Color {
        result.results.allSatisfy { $0.state == .succeeded } ? .green : .orange
    }

    private func auditSeverity(_ state: FleetTargetRunState) -> ActivitySeverity {
        switch state {
        case .succeeded: return .success
        case .skipped, .rolledBack: return .warning
        case .failed, .verificationFailed, .rollbackFailed: return .critical
        }
    }

    private func auditOutcome(_ state: FleetTargetRunState) -> OperationalAuditOutcome {
        switch state {
        case .succeeded: return .succeeded
        case .skipped: return .denied
        case .rolledBack: return .failed
        case .failed, .verificationFailed, .rollbackFailed: return .failed
        }
    }
}
