import AgentSshMacOS
import SwiftUI

struct FleetStackAuditSheet: View {
    let tabs: [TerminalTab]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileIds: Set<String> = []
    @State private var results: [String: HostStackAuditResult] = [:]
    @State private var isRunning = false

    private var selectedTabs: [TerminalTab] {
        tabs.filter { selectedProfileIds.contains($0.profile.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                targetPane
                    .frame(minWidth: 280, idealWidth: 330)
                resultPane
                    .frame(minWidth: 580, idealWidth: 760)
            }
        }
        .frame(minWidth: 920, idealWidth: 1_100, minHeight: 620, idealHeight: 740)
        .onAppear {
            if selectedProfileIds.isEmpty {
                selectedProfileIds = Set(tabs.map(\.profile.id))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Fleet Stack Audit", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Text("Fixed read-only discovery for Compose, Spring Boot, Next.js, proxies, firewalls, and PostgreSQL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Run Read-Only Audit") {
                Task { await runAudit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedTabs.isEmpty || isRunning)
            Button("Close") { dismiss() }
                .disabled(isRunning)
        }
        .padding(16)
    }

    private var targetPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Targets")
                    .font(.headline)
                Spacer()
                Button("All") { selectedProfileIds = Set(tabs.map(\.profile.id)) }
                Button("None") { selectedProfileIds.removeAll() }
            }
            .controlSize(.small)
            .padding(12)
            Divider()

            List(tabs) { tab in
                Toggle(isOn: targetBinding(tab.profile.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.profile.name)
                            .font(.caption.weight(.semibold))
                        Text(tab.profile.host)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.plain)

            Divider()
            DisclosureGroup("Exact probe script") {
                ScrollView([.vertical, .horizontal]) {
                    Text(StackDiagnosticProbe.script)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
            }
            .font(.caption)
            .padding(12)
        }
    }

    @ViewBuilder
    private var resultPane: some View {
        if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Run the audit to build a structured stack inventory.")
                    .font(.callout)
                Text("The probe never installs packages, writes files, or restarts services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(tabs.filter { results[$0.profile.id] != nil }) { tab in
                        if let result = results[tab.profile.id] {
                            hostResultCard(result)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func hostResultCard(_ result: HostStackAuditResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.hostName, systemImage: result.error == nil ? "server.rack" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(result.error == nil ? .primary : .red)
                Spacer()
                Text(result.finishedAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if result.snapshot.components.isEmpty {
                Text("No supported stack components were detected. Inspect raw evidence for permission or PATH issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                    ForEach(result.snapshot.components) { component in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: componentIcon(component.kind))
                                .foregroundStyle(componentColor(component.state))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.kind.displayName)
                                    .font(.caption.weight(.semibold))
                                Text(component.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(componentColor(component.state).opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }

            DisclosureGroup("Raw evidence") {
                Text(result.snapshot.rawOutput.isEmpty ? "(no output)" : result.snapshot.rawOutput)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func targetBinding(_ profileId: String) -> Binding<Bool> {
        Binding(
            get: { selectedProfileIds.contains(profileId) },
            set: { selected in
                if selected { selectedProfileIds.insert(profileId) }
                else { selectedProfileIds.remove(profileId) }
            }
        )
    }

    @MainActor
    private func runAudit() async {
        guard !isRunning else { return }
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        let targets = selectedTabs
        var offset = 0
        while offset < targets.count {
            let upper = min(offset + 4, targets.count)
            let chunk = Array(targets[offset..<upper])
            let chunkResults = await withTaskGroup(of: HostStackAuditResult.self) { group in
                for tab in chunk {
                    let profileId = tab.profile.id
                    let hostName = tab.profile.name
                    let connectionId = tab.connectionId
                    group.addTask {
                        do {
                            let output = try await RemoteCommandRunner.runChecked(
                                connectionId: connectionId,
                                script: StackDiagnosticProbe.script
                            )
                            return HostStackAuditResult(
                                profileId: profileId,
                                connectionId: connectionId,
                                hostName: hostName,
                                snapshot: StackDiagnosticParser.parse(output),
                                error: nil
                            )
                        } catch {
                            return HostStackAuditResult(
                                profileId: profileId,
                                connectionId: connectionId,
                                hostName: hostName,
                                snapshot: StackDiagnosticSnapshot(components: [], rawOutput: ""),
                                error: error.localizedDescription
                            )
                        }
                    }
                }
                var collected: [HostStackAuditResult] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for hostResult in chunkResults {
                results[hostResult.profileId] = hostResult
                let warnings = hostResult.snapshot.components.filter {
                    $0.state == .warning || $0.state == .critical
                }.count
                ActivityLogStore.shared.record(
                    title: "Stack audit",
                    detail: hostResult.error ?? "\(hostResult.snapshot.components.count) components; \(warnings) need attention",
                    profileId: hostResult.profileId,
                    connectionId: hostResult.connectionId,
                    icon: "square.stack.3d.up",
                    severity: hostResult.error != nil ? .critical : (warnings > 0 ? .warning : .success),
                    actor: .user,
                    action: "stack-audit",
                    command: StackDiagnosticProbe.script,
                    outcome: hostResult.error == nil ? .succeeded : .failed
                )
            }
            offset = upper
        }
    }

    private func componentColor(_ state: StackDiagnosticState) -> Color {
        switch state {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func componentIcon(_ kind: StackComponentKind) -> String {
        switch kind {
        case .dockerCompose: return "shippingbox"
        case .springBoot: return "cup.and.saucer"
        case .nextjs: return "chevron.left.forwardslash.chevron.right"
        case .reverseProxy: return "arrow.triangle.branch"
        case .firewall: return "shield"
        case .postgres: return "cylinder"
        }
    }
}

private struct HostStackAuditResult: Identifiable, Sendable {
    let profileId: String
    let connectionId: String
    let hostName: String
    let snapshot: StackDiagnosticSnapshot
    let error: String?
    let finishedAt = Date()

    var id: String { profileId }
}
