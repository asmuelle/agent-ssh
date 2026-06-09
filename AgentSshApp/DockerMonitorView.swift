import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct DockerMonitorView: View {
    let connectionId: String?
    let connectionLabel: String

    enum Mode: String, CaseIterable {
        case containers = "Containers"
        case logs = "Logs"
        case images = "Images"
        case volumes = "Volumes"
        case networks = "Networks"
        case events = "Events"
        case disk = "Disk"
    }

    @State var mode: Mode = .containers
    @State var containers: [DockerContainer] = []
    @State var selectedContainerId: String?
    @State var checkedContainerIds: Set<String> = []
    @State var images: [DockerAsset] = []
    @State var checkedImageIds: Set<String> = []
    @State var imageSortOrder: [KeyPathComparator<DockerAsset>] = [
        .init(\.imageName)
    ]
    @State var volumes: [DockerAsset] = []
    @State var checkedVolumeIds: Set<String> = []
    @State var networks: [DockerAsset] = []
    @State var checkedNetworkIds: Set<String> = []
    @State var events: [DockerEvent] = []
    @State var selectedEventId: DockerEvent.ID?
    @State var lastEventsRefresh: Date?
    @State var diskSnapshot = DockerDiskSnapshot.empty
    @State var diskQuickFilter: DockerDiskQuickFilter = .all
    @State var showsRawDiskUsage = false
    @State var diskImageSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State var diskContainerSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State var diskVolumeSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State var diskBuildCacheSortOrder: [KeyPathComparator<DockerDiskRow>] = [
        .init(\.sizeBytes, order: .reverse)
    ]
    @State var logs: String = ""
    @State var search = ""
    @State var error: String?
    @State var loading = false
    @State var liveLogs = false
    @State var liveEvents = false
    @State var pendingAction: DockerAction?
    @State var pendingBatch: DockerBatch?
    @State var dockerOperation: RemoteOperationFeedback?
    @State var dockerOperationOutput: RemoteOperationFeedback?

    static let pollInterval: UInt64 = 5_000_000_000

    struct DockerAction: Identifiable {
        let id = UUID()
        let verb: String
        let target: String
        var destructive: Bool {
            ["stop", "restart", "kill", "rm", "pause"].contains(verb)
        }
    }

    enum BatchScope {
        case containers, images, volumes, networks, disk
    }

    enum DockerDiskCleanup {
        case buildCache
        case danglingImages
        case stoppedContainers
        case unusedVolumes
    }

    struct DockerBatch: Identifiable {
        let id = UUID()
        let title: String
        let summary: String
        let command: String
        let destructive: Bool
        let scope: BatchScope
        var targets: [String] = []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let dockerOperation {
                RemoteOperationBanner(
                    operation: dockerOperation,
                    onShowOutput: { dockerOperationOutput = dockerOperation },
                    onDismiss: { dismissDockerOperation(dockerOperation.id) }
                )
                Divider()
            }
            if connectionId == nil {
                placeholderView(icon: "network.slash", title: "No connection", message: "Open an SSH workspace to inspect Docker.")
            } else if let error {
                placeholderView(icon: "exclamationmark.triangle", title: "Docker unavailable", message: error)
            } else {
                content
            }
        }
        .task(id: "\(connectionId ?? "none"):\(mode.rawValue):\(liveLogs):\(liveEvents)") {
            await refresh()
            if mode == .logs && liveLogs {
                await logsLoop()
            } else if mode == .events && liveEvents {
                await eventsLoop()
            }
        }
        .confirmationDialog(
            "Confirm Docker action",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("docker \(action.verb) \(action.target)", role: action.destructive ? .destructive : nil) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This runs on \(connectionLabel).")
        }
        .confirmationDialog(
            "Confirm batch action",
            isPresented: Binding(
                get: { pendingBatch != nil },
                set: { if !$0 { pendingBatch = nil } }
            ),
            presenting: pendingBatch
        ) { batch in
            Button(batch.title, role: batch.destructive ? .destructive : nil) {
                Task { await runBatch(batch) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { batch in
            Text("\(batch.summary)\n\nRuns on \(connectionLabel).")
        }
        .sheet(item: $dockerOperationOutput) { operation in
            RemoteOperationOutputSheet(operation: operation)
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
            if mode == .logs {
                Toggle("Live", isOn: $liveLogs)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            } else if mode == .events {
                Toggle("Live", isOn: $liveEvents)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(connectionId == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .containers:
            containerList
        case .logs:
            logsPane
        case .images:
            imageTable
        case .volumes:
            assetList(
                volumes,
                headers: ["Volume", "Driver"],
                targetColumn: 0,
                selection: $checkedVolumeIds,
                scope: .volumes
            ) {
                volumeBatchActions
            }
        case .networks:
            assetList(
                networks,
                headers: ["Network", "Driver", "Scope"],
                targetColumn: 0,
                selection: $checkedNetworkIds,
                scope: .networks
            ) {
                networkBatchActions
            }
        case .events:
            eventsPane
        case .disk:
            dockerDiskPane
        }
    }

    var filteredContainers: [DockerContainer] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return containers }
        return containers.filter {
            $0.name.lowercased().contains(needle)
                || $0.image.lowercased().contains(needle)
                || $0.composeProject.lowercased().contains(needle)
        }
    }

    var containerList: some View {
        VStack(spacing: 0) {
            batchToolbar(
                count: checkedContainerIds.count,
                clear: { checkedContainerIds.removeAll() }
            ) {
                Button("Start") { pendingBatch = containerBatch(verb: "start", destructive: false) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Stop") { pendingBatch = containerBatch(verb: "stop", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Restart") { pendingBatch = containerBatch(verb: "restart", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Pause") { pendingBatch = containerBatch(verb: "pause", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Unpause") { pendingBatch = containerBatch(verb: "unpause", destructive: false) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
                Button("Remove") { pendingBatch = containerBatch(verb: "rm", destructive: true) }
                    .disabled(checkedContainerIds.isEmpty || isDockerOperationRunning)
            }
            Divider()
            List(selection: $selectedContainerId) {
                ForEach(groupedContainers.keys.sorted(), id: \.self) { group in
                    Section(group.isEmpty ? "Standalone" : group) {
                        ForEach(groupedContainers[group] ?? []) { container in
                            HStack(spacing: 8) {
                                rowCheckbox(
                                    isOn: Binding(
                                        get: { checkedContainerIds.contains(container.id) },
                                        set: { isOn in
                                            if isOn { checkedContainerIds.insert(container.id) }
                                            else { checkedContainerIds.remove(container.id) }
                                        }
                                    )
                                )
                                Circle()
                                    .fill(statusColor(container.status + container.health))
                                    .frame(width: 8, height: 8)
                                rowOperationIndicator(isActive: dockerOperationTargets(container.id))
                                monoCell(container.name, width: 170)
                                monoCell(container.image, width: 180, color: .secondary)
                                monoCell(container.status, width: 170, color: statusColor(container.status))
                                monoCell(container.health, width: 70, color: statusColor(container.health))
                                monoCell(container.cpu, width: 70)
                                monoCell(container.memory, width: 140)
                                monoCell(container.netIO)
                            }
                            .tag(container.id)
                            .contextMenu { dockerActions(container) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    func rowCheckbox(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 18)
    }

    func batchToolbar<Actions: View>(
        count: Int,
        clear: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Text(count > 0 ? "\(count) selected" : "No selection")
                .font(.caption)
                .foregroundStyle(.secondary)
            if count > 0 {
                Button("Clear", action: clear)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Spacer()
            actions()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    func containerBatch(verb: String, destructive: Bool) -> DockerBatch? {
        let ids = Array(checkedContainerIds)
        guard !ids.isEmpty else { return nil }
        return DockerBatch(
            title: "docker \(verb) \(ids.count) container\(ids.count == 1 ? "" : "s")",
            summary: "\(verb.capitalized) \(ids.count) container\(ids.count == 1 ? "" : "s").",
            command: "docker \(verb)",
            destructive: destructive,
            scope: .containers,
            targets: ids
        )
    }

    @ViewBuilder
    var imageBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedImageIds),
                command: "docker rmi -f",
                noun: "image",
                destructive: true,
                scope: .images
            )
        }
        .disabled(checkedImageIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker image prune",
                summary: "Remove all dangling images.",
                command: "docker image prune -f",
                destructive: true,
                scope: .images
            )
        }
        .disabled(isDockerOperationRunning)
    }

    @ViewBuilder
    var volumeBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedVolumeIds),
                command: "docker volume rm",
                noun: "volume",
                destructive: true,
                scope: .volumes
            )
        }
        .disabled(checkedVolumeIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker volume prune",
                summary: "Remove all unused volumes.",
                command: "docker volume prune -f",
                destructive: true,
                scope: .volumes
            )
        }
        .disabled(isDockerOperationRunning)
    }

    @ViewBuilder
    var networkBatchActions: some View {
        Button("Remove") {
            pendingBatch = assetBatch(
                ids: Array(checkedNetworkIds),
                command: "docker network rm",
                noun: "network",
                destructive: true,
                scope: .networks
            )
        }
        .disabled(checkedNetworkIds.isEmpty || isDockerOperationRunning)
        Button("Prune Unused") {
            pendingBatch = DockerBatch(
                title: "docker network prune",
                summary: "Remove all unused networks.",
                command: "docker network prune -f",
                destructive: true,
                scope: .networks
            )
        }
        .disabled(isDockerOperationRunning)
    }

    func assetBatch(
        ids: [String],
        command: String,
        noun: String,
        destructive: Bool,
        scope: BatchScope
    ) -> DockerBatch? {
        guard !ids.isEmpty else { return nil }
        let plural = ids.count == 1 ? noun : "\(noun)s"
        return DockerBatch(
            title: "\(command) \(ids.count) \(plural)",
            summary: "Remove \(ids.count) \(plural).",
            command: command,
            destructive: destructive,
            scope: scope,
            targets: ids
        )
    }

    var sortedImages: [DockerAsset] {
        images.sorted(using: imageSortOrder)
    }

}
