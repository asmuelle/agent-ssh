import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension DockerMonitorView {
    // MARK: - Disk usage

    var dockerDiskPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Disk Usage")
                        .font(.headline)
                    if let refreshedAt = diskSnapshot.refreshedAt {
                        Text("Updated \(DateFormatter.localizedString(from: refreshedAt, dateStyle: .none, timeStyle: .medium))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        RemoteCommandRunner.copy(diskSnapshot.rawText)
                    } label: {
                        Label("Copy Raw", systemImage: "doc.on.doc")
                    }
                    .disabled(diskSnapshot.rawText.isEmpty)
                }

                LazyVGrid(columns: dockerDiskMetricColumns, alignment: .leading, spacing: 10) {
                    dockerDiskMetricTile(
                        title: "Total",
                        value: DockerDiskSnapshot.formatBytes(diskSnapshot.totalSizeBytes),
                        subtitle: "Reported Docker disk usage",
                        systemImage: "internaldrive",
                        color: .accentColor
                    )
                    dockerDiskSummaryTile(section: .images, systemImage: "shippingbox", color: .blue)
                    dockerDiskSummaryTile(section: .containers, systemImage: "server.rack", color: .green)
                    dockerDiskSummaryTile(section: .volumes, systemImage: "externaldrive", color: .teal)
                    dockerDiskSummaryTile(section: .buildCache, systemImage: "hammer", color: .orange)
                }

                HStack(spacing: 8) {
                    Picker("", selection: $diskQuickFilter) {
                        ForEach(DockerDiskQuickFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)

                    Spacer()

                    Menu {
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.buildCache)
                        } label: {
                            Label("Prune unused build cache", systemImage: "hammer")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.danglingImages)
                        } label: {
                            Label("Prune dangling images", systemImage: "shippingbox")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.stoppedContainers)
                        } label: {
                            Label("Remove stopped containers", systemImage: "server.rack")
                        }
                        Button {
                            pendingBatch = dockerDiskCleanupBatch(.unusedVolumes)
                        } label: {
                            Label("Remove unused volumes", systemImage: "externaldrive")
                        }
                    } label: {
                        Label("Cleanup", systemImage: "trash")
                    }
                    .disabled(diskSnapshot.rawText.isEmpty)
                }
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 12) {
                    if diskQuickFilter != .buildCache {
                        dockerDiskSectionView(
                            .images,
                            rows: diskSnapshot.images,
                            sortOrder: $diskImageSortOrder
                        )
                        dockerDiskSectionView(
                            .containers,
                            rows: diskSnapshot.containers,
                            sortOrder: $diskContainerSortOrder
                        )
                        dockerDiskSectionView(
                            .volumes,
                            rows: diskSnapshot.volumes,
                            sortOrder: $diskVolumeSortOrder
                        )
                    }
                    dockerDiskSectionView(
                        .buildCache,
                        rows: diskSnapshot.buildCache,
                        sortOrder: $diskBuildCacheSortOrder
                    )
                }

                DisclosureGroup("Raw output", isExpanded: $showsRawDiskUsage) {
                    HighlightedRawOutputText(value: diskSnapshot.rawText.isEmpty ? "-" : diskSnapshot.rawText)
                        .background(
                            Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .font(.caption.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    var dockerDiskMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)]
    }

    func dockerDiskSummaryTile(
        section: DockerDiskSection,
        systemImage: String,
        color: Color
    ) -> some View {
        let summary = diskSnapshot.summary(for: section)
        let rows = diskSnapshot.rows(for: section)
        let subtitle: String
        if let summary {
            subtitle = "\(summary.activityText) | \(diskSnapshot.reclaimableText(for: section))"
        } else {
            subtitle = rows.isEmpty ? "No rows reported" : "\(rows.count) row\(rows.count == 1 ? "" : "s") parsed"
        }
        return dockerDiskMetricTile(
            title: section.title,
            value: diskSnapshot.sizeText(for: section),
            subtitle: subtitle,
            systemImage: systemImage,
            color: color
        )
    }

    func dockerDiskMetricTile(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value.isEmpty ? "-" : value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    func dockerDiskSectionView(
        _ section: DockerDiskSection,
        rows: [DockerDiskRow],
        sortOrder: Binding<[KeyPathComparator<DockerDiskRow>]>
    ) -> some View {
        let filteredRows = filteredDiskRows(rows)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(filteredRows.count) of \(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(diskSnapshot.reclaimableText(for: section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredRows.isEmpty {
                dockerDiskEmptyState(section)
            } else {
                dockerDiskTable(filteredRows, section: section, sortOrder: sortOrder)
                    .frame(height: dockerDiskTableHeight(rowCount: filteredRows.count))
            }
        }
    }

    func filteredDiskRows(_ rows: [DockerDiskRow]) -> [DockerDiskRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            let matchesSearch = needle.isEmpty || row.searchText.contains(needle)
            guard matchesSearch else { return false }
            switch diskQuickFilter {
            case .all:
                return true
            case .large:
                return row.isLarge
            case .stale:
                return row.isOlderThanWeek
            case .buildCache:
                return row.section == .buildCache
            }
        }
    }

    func dockerDiskEmptyState(_ section: DockerDiskSection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.emptyTitle)
                    .font(.caption.weight(.semibold))
                Text(section.emptyMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    func dockerDiskTable(
        _ rows: [DockerDiskRow],
        section: DockerDiskSection,
        sortOrder: Binding<[KeyPathComparator<DockerDiskRow>]>
    ) -> some View {
        switch section {
        case .images:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Repository", value: \.repository) { row in
                    monoCell(row.repository)
                }
                .width(min: 150, ideal: 220)
                TableColumn("Tag", value: \.tag) { row in
                    monoCell(row.tag, color: .secondary)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Image ID", value: \.imageId) { row in
                    monoCell(row.imageId, color: .secondary)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 95, ideal: 115)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Shared", value: \.sharedSize) { row in
                    monoCell(row.sharedSize, color: .secondary)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Unique", value: \.uniqueSize) { row in
                    monoCell(row.uniqueSize)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Containers", value: \.containers) { row in
                    monoCell(row.containers)
                }
                .width(min: 78, ideal: 90)
            }
        case .containers:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Container ID", value: \.containerId) { row in
                    monoCell(row.containerId)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Image", value: \.image) { row in
                    monoCell(row.image)
                }
                .width(min: 140, ideal: 190)
                TableColumn("Command", value: \.command) { row in
                    monoCell(row.command, color: .secondary)
                }
                .width(min: 140, ideal: 180)
                TableColumn("Volumes", value: \.localVolumes) { row in
                    monoCell(row.localVolumes)
                }
                .width(min: 70, ideal: 80)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 95, ideal: 115)
                TableColumn("Status", value: \.status) { row in
                    monoCell(row.status, color: statusColor(row.status))
                }
                .width(min: 95, ideal: 120)
                TableColumn("Name", value: \.name) { row in
                    monoCell(row.name)
                }
                .width(min: 120, ideal: 160)
            }
        case .volumes:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Volume", value: \.volumeName) { row in
                    monoCell(row.volumeName)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Links", value: \.links) { row in
                    monoCell(row.links)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
            }
        case .buildCache:
            Table(rows.sorted(using: sortOrder.wrappedValue), sortOrder: sortOrder) {
                TableColumn("Cache ID", value: \.cacheId) { row in
                    monoCell(row.cacheId)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Type", value: \.cacheType) { row in
                    monoCell(row.cacheType, color: .secondary)
                }
                .width(min: 80, ideal: 95)
                TableColumn("Size", value: \.sizeBytes) { row in
                    monoCell(row.size)
                }
                .width(min: 75, ideal: 90)
                TableColumn("Created", value: \.created) { row in
                    monoCell(row.created)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Last Used", value: \.lastUsed) { row in
                    monoCell(row.lastUsed)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Usage", value: \.usage) { row in
                    monoCell(row.usage)
                }
                .width(min: 65, ideal: 75)
                TableColumn("Shared", value: \.shared) { row in
                    monoCell(row.shared)
                }
                .width(min: 70, ideal: 85)
            }
        }
    }

    func dockerDiskTableHeight(rowCount: Int) -> CGFloat {
        min(max(CGFloat(rowCount) * 24 + 34, 110), 340)
    }

    func dockerDiskCleanupBatch(_ cleanup: DockerDiskCleanup) -> DockerBatch {
        switch cleanup {
        case .buildCache:
            return DockerBatch(
                title: "docker builder prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove unused Docker build cache.",
                    section: .buildCache,
                    rows: diskSnapshot.buildCache
                ),
                command: "docker builder prune -f",
                destructive: true,
                scope: .disk
            )
        case .danglingImages:
            let dangling = diskSnapshot.images.filter {
                $0.repository == "<none>" || $0.tag == "<none>"
            }
            return DockerBatch(
                title: "docker image prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove dangling images.",
                    section: .images,
                    rows: dangling
                ),
                command: "docker image prune -f",
                destructive: true,
                scope: .disk
            )
        case .stoppedContainers:
            let stopped = diskSnapshot.containers.filter {
                let status = $0.status.lowercased()
                return status.contains("exited") || status.contains("created") || status.contains("dead")
            }
            return DockerBatch(
                title: "docker container prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove stopped containers.",
                    section: .containers,
                    rows: stopped
                ),
                command: "docker container prune -f",
                destructive: true,
                scope: .disk
            )
        case .unusedVolumes:
            let unused = diskSnapshot.volumes.filter { $0.links == "0" }
            return DockerBatch(
                title: "docker volume prune",
                summary: dockerDiskCleanupSummary(
                    lead: "Remove unused local volumes.",
                    section: .volumes,
                    rows: unused
                ),
                command: "docker volume prune -f",
                destructive: true,
                scope: .disk
            )
        }
    }

    func dockerDiskCleanupSummary(
        lead: String,
        section: DockerDiskSection,
        rows: [DockerDiskRow]
    ) -> String {
        let reclaimable = diskSnapshot.summary(for: section)?.reclaimable ?? "unknown"
        let preview: String
        if rows.isEmpty {
            preview = "No detailed rows are currently reported for this cleanup scope."
        } else {
            let listed = rows
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(6)
                .map { row in
                    let name = row.previewName.isEmpty ? row.id : row.previewName
                    let size = row.size.isEmpty ? "" : " (\(row.size))"
                    return "- \(name)\(size)"
                }
                .joined(separator: "\n")
            let remaining = rows.count > 6 ? "\n- and \(rows.count - 6) more" : ""
            preview = "\(listed)\(remaining)"
        }
        return "\(lead)\nExpected reclaimable: \(reclaimable).\n\nPreview:\n\(preview)"
    }

}
