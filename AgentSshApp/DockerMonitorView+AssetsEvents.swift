import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension DockerMonitorView {
    // MARK: - Images, logs, events

    var imageTable: some View {
        let allTargets = Set(images.compactMap { assetTarget($0, column: 1) })
        let allSelected = !allTargets.isEmpty && allTargets.isSubset(of: checkedImageIds)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(checkedImageIds.isEmpty ? "No selection" : "\(checkedImageIds.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(allSelected ? "Clear" : "Select All") {
                    if allSelected {
                        checkedImageIds.subtract(allTargets)
                    } else {
                        checkedImageIds.formUnion(allTargets)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(allTargets.isEmpty || isDockerOperationRunning)
                if !checkedImageIds.isEmpty {
                    Button("Clear") {
                        checkedImageIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isDockerOperationRunning)
                }
                Spacer()
                imageBatchActions
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            Table(sortedImages, sortOrder: $imageSortOrder) {
                TableColumn("") { asset in
                    let target = assetTarget(asset, column: 1)
                    HStack(spacing: 4) {
                        rowCheckbox(
                            isOn: Binding(
                                get: { target.map { checkedImageIds.contains($0) } ?? false },
                                set: { isOn in
                                    guard let target else { return }
                                    if isOn { checkedImageIds.insert(target) }
                                    else { checkedImageIds.remove(target) }
                                }
                            )
                        )
                        rowOperationIndicator(isActive: target.map(dockerOperationTargets) ?? false)
                    }
                }
                .width(min: 42, ideal: 48, max: 54)

                TableColumn("Image", value: \.imageName) { asset in
                    monoCell(asset.imageName)
                }
                .width(min: 190, ideal: 260)

                TableColumn("ID", value: \.imageId) { asset in
                    monoCell(asset.imageId, color: .secondary)
                }
                .width(min: 95, ideal: 120)

                TableColumn("Size", value: \.imageSizeBytes) { asset in
                    monoCell(asset.imageSizeText)
                }
                .width(min: 80, ideal: 95)

                TableColumn("Created", value: \.imageCreated) { asset in
                    monoCell(asset.imageCreated, color: .secondary)
                }
                .width(min: 105, ideal: 140)
            }
        }
    }

    var groupedContainers: [String: [DockerContainer]] {
        Dictionary(grouping: filteredContainers) { $0.composeProject }
    }

    var logsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Container", selection: $selectedContainerId) {
                    Text("Select a container").tag(nil as String?)
                    ForEach(containers) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 260)
                Spacer()
                Button("Exec Shell Command") {
                    if let container = selectedContainer {
                        runExecShell(container)
                    }
                }
                .disabled(selectedContainer == nil)
                Button("Copy Logs") { RemoteCommandRunner.copy(logs) }
                    .disabled(logs.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            logText(logs)
        }
    }

    var selectedContainer: DockerContainer? {
        guard let selectedContainerId else { return containers.first }
        return containers.first { $0.id == selectedContainerId }
    }

    var filteredEvents: [DockerEvent] {
        let query = dockerEventQuery(search)
        return events.filter { event in
            if let kind = query.kind, !event.kind.lowercased().contains(kind) {
                return false
            }
            if let action = query.action, !event.action.lowercased().contains(action) {
                return false
            }
            if let resource = query.resource, !event.objectLabel.lowercased().contains(resource) {
                return false
            }
            if let identifier = query.identifier, !event.actorId.lowercased().contains(identifier) {
                return false
            }
            if let since = query.since {
                guard let date = event.date, Date().timeIntervalSince(date) <= since else {
                    return false
                }
            }
            let haystack = event.searchText.lowercased()
            return query.terms.allSatisfy { haystack.contains($0) }
        }
    }

    var selectedEvent: DockerEvent? {
        if let selectedEventId,
           let event = filteredEvents.first(where: { $0.id == selectedEventId }) {
            return event
        }
        return filteredEvents.first
    }

    var eventsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(filteredEvents.count) of \(events.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastEventsRefresh {
                    Text("Updated \(DateFormatter.localizedString(from: lastEventsRefresh, dateStyle: .none, timeStyle: .medium))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    RemoteCommandRunner.copy(events.map(\.rawText).joined(separator: "\n\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(events.isEmpty)
                Button {
                    events.removeAll()
                    selectedEventId = nil
                    lastEventsRefresh = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(events.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()

            if events.isEmpty {
                dockerEventEmptyState(
                    icon: "dot.radiowaves.left.and.right",
                    title: "No Docker events",
                    message: "No container, image, volume, or network events were returned for the last 30 minutes."
                )
            } else if filteredEvents.isEmpty {
                dockerEventEmptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No matching events",
                    message: "Try clearing the filter or using queries like type:image, action:delete, or since:10m."
                )
            } else {
                HSplitView {
                    dockerEventTable
                        .frame(minWidth: 560)
                    dockerEventDetails(selectedEvent)
                        .frame(minWidth: 280, idealWidth: 340)
                }
            }
        }
    }

    var dockerEventTable: some View {
        Table(filteredEvents, selection: $selectedEventId) {
            TableColumn("Time") { event in
                Text(event.displayTime)
                    .font(.caption.monospacedDigit())
                    .help(event.fullTimestamp)
            }
            .width(min: 82, ideal: 92, max: 110)

            TableColumn("Resource") { event in
                dockerEventToken(event.kind, color: .blue)
            }
            .width(min: 78, ideal: 92, max: 120)

            TableColumn("Action") { event in
                dockerEventToken(event.action, color: dockerEventActionColor(event.action))
            }
            .width(min: 84, ideal: 104, max: 130)

            TableColumn("Object") { event in
                Text(event.objectLabel)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event.actorId.isEmpty ? event.objectLabel : event.actorId)
            }

            TableColumn("Details") { event in
                Text(dockerEventDetailSummary(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)
        }
    }

    func dockerEventDetails(_ event: DockerEvent?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event Details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let event {
                    Button {
                        RemoteCommandRunner.copy(event.rawText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy event details")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()

            if let event {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        dockerEventDetailRow("Time", event.fullTimestamp)
                        dockerEventDetailRow("Resource", event.kind)
                        dockerEventDetailRow("Action", event.action)
                        dockerEventDetailRow("Object", event.objectLabel)
                        dockerEventDetailRow("Actor ID", event.actorId)
                        dockerEventDetailRow("Name", event.name)
                        dockerEventDetailRow("Image", event.image)
                        dockerEventDetailRow("Container", event.container)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Raw")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(highlightedRawOutput(event.raw))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                Text("Select an event to inspect its full Docker actor data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    func dockerEventDetailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func dockerEventEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

}
