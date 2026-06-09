import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension DockerMonitorView {
    // MARK: - Asset lists, operations, actions, loading

    func assetList<Actions: View>(
        _ assets: [DockerAsset],
        headers: [String],
        targetColumn: Int,
        selection: Binding<Set<String>>,
        scope: BatchScope,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let allTargets = Set(assets.compactMap { assetTarget($0, column: targetColumn) })
        let allSelected = !allTargets.isEmpty && allTargets.isSubset(of: selection.wrappedValue)
        let toggleAll = Binding(
            get: { allSelected },
            set: { isOn in
                if isOn { selection.wrappedValue.formUnion(allTargets) }
                else { selection.wrappedValue.subtract(allTargets) }
            }
        )
        return VStack(spacing: 0) {
            batchToolbar(
                count: selection.wrappedValue.count,
                clear: { selection.wrappedValue.removeAll() },
                actions: actions
            )
            Divider()
            HStack(spacing: 10) {
                Toggle("", isOn: toggleAll)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                ForEach(headers, id: \.self) { header in
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            List(assets) { asset in
                HStack(spacing: 10) {
                    let target = assetTarget(asset, column: targetColumn)
                    rowCheckbox(
                        isOn: Binding(
                            get: { target.map { selection.wrappedValue.contains($0) } ?? false },
                            set: { isOn in
                                guard let target else { return }
                                if isOn { selection.wrappedValue.insert(target) }
                                else { selection.wrappedValue.remove(target) }
                            }
                        )
                    )
                    rowOperationIndicator(isActive: target.map(dockerOperationTargets) ?? false)
                    ForEach(Array(asset.columns.enumerated()), id: \.offset) { _, column in
                        monoCell(column)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    func assetTarget(_ asset: DockerAsset, column: Int) -> String? {
        guard asset.columns.indices.contains(column) else { return nil }
        let value = asset.columns[column].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    func logText(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            HighlightedRawOutputText(value: value.isEmpty ? "-" : value)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    func dockerEventToken(_ value: String, color: Color) -> some View {
        let isEmpty = value.isEmpty
        return Text(isEmpty ? "-" : value)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(isEmpty ? Color.secondary : color)
    }

    func dockerEventActionColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("delete") || lower.contains("destroy") || lower.contains("die") || lower == "kill" || lower == "remove" {
            return .red
        }
        if lower.contains("start") || lower.contains("create") || lower.contains("connect") || lower.contains("pull") {
            return .green
        }
        if lower.contains("pause") || lower.contains("stop") || lower.contains("restart") || lower.contains("untag") {
            return .orange
        }
        return .secondary
    }

    func dockerEventDetailSummary(_ event: DockerEvent) -> String {
        let parts = [event.name, event.image, event.container, event.actorId]
            .map(DockerEvent.normalized)
            .filter { !$0.isEmpty }
            .map(DockerEvent.compactIdentifier)
        return parts.isEmpty ? "-" : parts.joined(separator: "  ")
    }

    func dockerEventQuery(_ value: String) -> DockerEventQuery {
        var query = DockerEventQuery()
        for token in value.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard let separator = token.firstIndex(of: ":") else {
                query.terms.append(token.lowercased())
                continue
            }
            let key = token[..<separator].lowercased()
            let rawValue = String(token[token.index(after: separator)...])
            let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedValue.isEmpty else { continue }
            switch key {
            case "type", "resource":
                query.kind = normalizedValue
            case "action":
                query.action = normalizedValue
            case "object", "name":
                query.resource = normalizedValue
            case "id", "actor":
                query.identifier = normalizedValue
            case "since":
                query.since = dockerEventSinceInterval(normalizedValue)
            default:
                query.terms.append(token.lowercased())
            }
        }
        return query
    }

    func dockerEventSinceInterval(_ value: String) -> TimeInterval? {
        let digits = value.prefix { $0.isNumber }
        guard let amount = Double(digits), amount > 0 else { return nil }
        let unit = String(value.dropFirst(digits.count))
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return amount
        case "h", "hr", "hrs", "hour", "hours":
            return amount * 60 * 60
        case "d", "day", "days":
            return amount * 60 * 60 * 24
        default:
            return amount * 60
        }
    }

    var isDockerOperationRunning: Bool {
        dockerOperation?.isRunning == true
    }

    func dockerOperationTargets(_ target: String) -> Bool {
        guard let dockerOperation, dockerOperation.isRunning else { return false }
        return dockerOperation.targetIds.contains(target)
    }

    func startDockerOperation(
        title: String,
        detail: String,
        targets: [String] = []
    ) -> UUID {
        let operation = RemoteOperationFeedback(
            title: title,
            detail: detail,
            targetIds: Set(targets),
            totalCount: targets.isEmpty ? nil : targets.count
        )
        dockerOperation = operation
        return operation.id
    }

    func updateDockerOperation(
        _ id: UUID,
        detail: String,
        completedCount: Int? = nil
    ) {
        guard var operation = dockerOperation, operation.id == id else { return }
        operation.detail = detail
        if let completedCount {
            operation.completedCount = completedCount
        }
        dockerOperation = operation
    }

    func finishDockerOperation(
        _ id: UUID,
        state: RemoteOperationState,
        detail: String,
        output: String,
        completedCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        guard var operation = dockerOperation, operation.id == id else { return }
        operation.state = state
        operation.detail = detail
        operation.output = output
        operation.errorMessage = errorMessage
        operation.completedCount = completedCount ?? operation.completedCount
        operation.endedAt = Date()
        dockerOperation = operation
    }

    func dismissDockerOperation(_ id: UUID) {
        guard dockerOperation?.id == id, dockerOperation?.isRunning == false else { return }
        dockerOperation = nil
    }

    @ViewBuilder
    func dockerActions(_ container: DockerContainer) -> some View {
        Button("Start") { pendingAction = DockerAction(verb: "start", target: container.id) }
        Button("Stop", role: .destructive) { pendingAction = DockerAction(verb: "stop", target: container.id) }
        Button("Restart", role: .destructive) { pendingAction = DockerAction(verb: "restart", target: container.id) }
        Button("Pause", role: .destructive) { pendingAction = DockerAction(verb: "pause", target: container.id) }
        Button("Unpause") { pendingAction = DockerAction(verb: "unpause", target: container.id) }
        Button("Kill", role: .destructive) { pendingAction = DockerAction(verb: "kill", target: container.id) }
        Button("Remove", role: .destructive) { pendingAction = DockerAction(verb: "rm", target: container.id) }
        Divider()
        Button("Show Logs") {
            selectedContainerId = container.id
            mode = .logs
            Task { await loadLogs() }
        }
        Button("Run Exec Shell in Terminal") {
            runExecShell(container)
        }
        Button("Copy Exec Shell Command") {
            RemoteCommandRunner.copy(execShellCommand(container))
        }
    }

    func refresh() async {
        switch mode {
        case .containers, .logs:
            await loadContainers()
            if mode == .logs { await loadLogs() }
        case .images:
            await loadImages()
        case .volumes:
            await loadVolumes()
        case .networks:
            await loadNetworks()
        case .events:
            await loadEvents()
        case .disk:
            await loadDiskUsage()
        }
    }

    func loadContainers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v docker >/dev/null || { echo docker not found; exit 127; }
        sep=$(printf '\\037')
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] || exit 0
        docker ps -a --format "{{.ID}}${sep}{{.Names}}${sep}{{.Image}}${sep}{{.Status}}${sep}{{.Ports}}" > /tmp/rshell_docker_ps_$$
        docker stats --no-stream --format "{{.Name}}${sep}{{.CPUPerc}}${sep}{{.MemUsage}}${sep}{{.NetIO}}" > /tmp/rshell_docker_stats_$$ 2>/dev/null || true
        while IFS="$sep" read -r id name image status ports; do
          stats=$(awk -F "$sep" -v n="$name" '$1==n {print $2 FS $3 FS $4; exit}' /tmp/rshell_docker_stats_$$)
          cpu=$(printf "%s" "$stats" | awk -F "$sep" '{print $1}')
          mem=$(printf "%s" "$stats" | awk -F "$sep" '{print $2}')
          net=$(printf "%s" "$stats" | awk -F "$sep" '{print $3}')
          inspect=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}${sep}{{.RestartCount}}${sep}{{index .Config.Labels \\"com.docker.compose.project\\"}}" "$id" 2>/dev/null || true)
          health=$(printf "%s" "$inspect" | awk -F "$sep" '{print $1}')
          restarts=$(printf "%s" "$inspect" | awk -F "$sep" '{print $2}')
          compose=$(printf "%s" "$inspect" | awk -F "$sep" '{print $3}')
          printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\\n" "$id" "$sep" "$name" "$sep" "$image" "$sep" "$status" "$sep" "$ports" "$sep" "$cpu" "$sep" "$mem" "$sep" "$net" "$sep" "$health" "$sep" "$restarts" "$sep" "$compose"
        done < /tmp/rshell_docker_ps_$$
        rm -f /tmp/rshell_docker_ps_$$ /tmp/rshell_docker_stats_$$
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            containers = output.lines().compactMap { line in
                let p = splitFields(line)
                guard p.count >= 11 else { return nil }
                return DockerContainer(id: p[0], name: p[1], image: p[2], status: p[3], ports: p[4], cpu: p[5], memory: p[6], netIO: p[7], health: p[8], restarts: p[9], composeProject: p[10])
            }
            if selectedContainerId == nil { selectedContainerId = containers.first?.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadLogs() async {
        guard let connectionId, let container = selectedContainer else { return }
        let script = "docker logs --tail 240 --timestamps \(RemoteCommandRunner.shellQuote(container.id)) 2>&1"
        do {
            logs = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadImages() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker images --format \"{{.Repository}}:{{.Tag}}${sep}{{.ID}}${sep}{{.Size}}${sep}{{.CreatedSince}}\"",
            assign: { images = $0 }
        )
    }

    func loadVolumes() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker volume ls --format \"{{.Name}}${sep}{{.Driver}}\"",
            assign: { volumes = $0 }
        )
    }

    func loadNetworks() async {
        await loadAsset(
            script: "sep=$(printf '\\037'); docker network ls --format \"{{.Name}}${sep}{{.Driver}}${sep}{{.Scope}}\"",
            assign: { networks = $0 }
        )
    }

    func loadAsset(script: String, assign: ([DockerAsset]) -> Void) async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\n\(script) 2>&1"
            )
            let assets = output.lines().enumerated().map { index, line in
                DockerAsset(id: "\(index):\(line)", columns: splitFields(line))
            }
            assign(assets)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadEvents() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v docker >/dev/null || { echo docker not found; exit 127; }
        sep=$(printf '\\037')
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        docker events --since 30m --until "$now" --format "{{.Time}}${sep}{{.Type}}${sep}{{.Action}}${sep}{{.Actor.ID}}${sep}{{.Actor.Attributes.name}}${sep}{{.Actor.Attributes.image}}${sep}{{.Actor.Attributes.container}}" 2>&1
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            events = output.lines().enumerated().map { index, line in
                DockerEvent.parse(line, index: index)
            }
            if selectedEventId == nil || !events.contains(where: { $0.id == selectedEventId }) {
                selectedEventId = events.first?.id
            }
            lastEventsRefresh = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDiskUsage() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "command -v docker >/dev/null || { echo docker not found; exit 127; }\ndocker system df -v 2>&1"
            )
            diskSnapshot = DockerDiskSnapshot.parse(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logsLoop() async {
        while !Task.isCancelled && liveLogs {
            await loadLogs()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    func eventsLoop() async {
        while !Task.isCancelled && liveEvents {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if !Task.isCancelled && liveEvents {
                await loadEvents()
            }
        }
    }

    func run(_ action: DockerAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        guard !isDockerOperationRunning else { return }
        let title = "docker \(action.verb)"
        let operationId = startDockerOperation(
            title: title,
            detail: action.target,
            targets: [action.target]
        )
        let script = "docker \(action.verb) \(RemoteCommandRunner.shellQuote(action.target)) 2>&1"
        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: script
            )
            await loadContainers()
            let detail = dockerCompletionDetail(
                fallback: "Completed \(title) for \(action.target).",
                output: output
            )
            finishDockerOperation(
                operationId,
                state: .succeeded,
                detail: detail,
                output: output,
                completedCount: 1
            )
            ActivityLogStore.shared.record(
                title: title,
                detail: detail,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .success
            )
        } catch {
            let message = error.localizedDescription
            finishDockerOperation(
                operationId,
                state: .failed,
                detail: "Failed \(title) for \(action.target).",
                output: "",
                completedCount: 0,
                errorMessage: message
            )
            ActivityLogStore.shared.record(
                title: "\(title) failed",
                detail: message,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .critical
            )
        }
    }

    func runBatch(_ batch: DockerBatch) async {
        guard let connectionId else { return }
        pendingBatch = nil
        guard !isDockerOperationRunning else { return }
        let operationId = startDockerOperation(
            title: batch.title,
            detail: batch.summary,
            targets: batch.targets
        )

        if !batch.targets.isEmpty {
            await runTargetedDockerBatch(batch, connectionId: connectionId, operationId: operationId)
            return
        }

        do {
            let output = try await RemoteCommandRunner.runChecked(
                connectionId: connectionId,
                script: "\(batch.command) 2>&1"
            )
            switch batch.scope {
            case .containers: checkedContainerIds.removeAll()
            case .images: checkedImageIds.removeAll()
            case .volumes: checkedVolumeIds.removeAll()
            case .networks: checkedNetworkIds.removeAll()
            case .disk: break
            }
            await refresh()
            let detail = dockerCompletionDetail(
                fallback: "Completed \(batch.title).",
                output: output
            )
            finishDockerOperation(
                operationId,
                state: .succeeded,
                detail: detail,
                output: output
            )
            ActivityLogStore.shared.record(
                title: batch.title,
                detail: detail,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .success
            )
        } catch {
            let message = error.localizedDescription
            finishDockerOperation(
                operationId,
                state: .failed,
                detail: "Failed \(batch.title).",
                output: "",
                errorMessage: message
            )
            ActivityLogStore.shared.record(
                title: "\(batch.title) failed",
                detail: message,
                connectionId: connectionId,
                icon: "shippingbox",
                severity: .critical
            )
        }
    }

    func runTargetedDockerBatch(
        _ batch: DockerBatch,
        connectionId: String,
        operationId: UUID
    ) async {
        var outputs: [String] = []
        var failedTargets: [(target: String, message: String)] = []
        var succeededTargets: [String] = []
        let total = batch.targets.count

        for (index, target) in batch.targets.enumerated() {
            let humanIndex = index + 1
            updateDockerOperation(
                operationId,
                detail: "\(batch.command) \(target) (\(humanIndex) of \(total))",
                completedCount: index
            )

            let script = "\(batch.command) \(RemoteCommandRunner.shellQuote(target)) 2>&1"
            do {
                let output = try await RemoteCommandRunner.runChecked(
                    connectionId: connectionId,
                    script: script
                )
                succeededTargets.append(target)
                outputs.append(dockerOutputBlock(command: script, output: output))
            } catch {
                let message = error.localizedDescription
                failedTargets.append((target, message))
                outputs.append(dockerOutputBlock(command: script, output: "FAILED: \(message)"))
            }

            updateDockerOperation(
                operationId,
                detail: "\(batch.command) \(target) (\(humanIndex) of \(total))",
                completedCount: humanIndex
            )
        }

        clearDockerSelection(scope: batch.scope, succeededTargets: Set(succeededTargets))
        await refresh()

        let failedCount = failedTargets.count
        let succeededCount = succeededTargets.count
        let state: RemoteOperationState
        let detail: String
        if failedCount == 0 {
            state = .succeeded
            detail = "Completed \(succeededCount) of \(total)."
        } else if succeededCount == 0 {
            state = .failed
            detail = "Failed all \(total) item\(total == 1 ? "" : "s")."
        } else {
            state = .warning
            detail = "Completed \(succeededCount) of \(total); \(failedCount) failed."
        }

        let failureSummary = failedTargets
            .map { "\($0.target): \($0.message)" }
            .joined(separator: "\n")
        let output = outputs.joined(separator: "\n\n")
        finishDockerOperation(
            operationId,
            state: state,
            detail: detail,
            output: output,
            completedCount: total,
            errorMessage: failureSummary.isEmpty ? nil : failureSummary
        )
        ActivityLogStore.shared.record(
            title: batch.title,
            detail: detail,
            connectionId: connectionId,
            icon: "shippingbox",
            severity: state == .succeeded ? .success : (state == .warning ? .warning : .critical)
        )
    }

    func clearDockerSelection(scope: BatchScope, succeededTargets: Set<String>) {
        switch scope {
        case .containers:
            checkedContainerIds.subtract(succeededTargets)
        case .images:
            checkedImageIds.subtract(succeededTargets)
        case .volumes:
            checkedVolumeIds.subtract(succeededTargets)
        case .networks:
            checkedNetworkIds.subtract(succeededTargets)
        case .disk:
            break
        }
    }

    func dockerCompletionDetail(fallback: String, output: String) -> String {
        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return firstLine ?? fallback
    }

    func dockerOutputBlock(command: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "$ \(command)"
        }
        return "$ \(command)\n\(trimmed)"
    }

    func execShellCommand(_ container: DockerContainer) -> String {
        "docker exec -it \(RemoteCommandRunner.shellQuote(container.name)) sh"
    }

    func runExecShell(_ container: DockerContainer) {
        guard let connectionId else { return }
        guard let data = "\(execShellCommand(container))\n".data(using: .utf8) else { return }
        TerminalSessionManager.shared.sendInput(connectionId: connectionId, data: data)
    }
}
