import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

struct DockerContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: String
    let cpu: String
    let memory: String
    let netIO: String
    let health: String
    let restarts: String
    let composeProject: String
}

struct DockerAsset: Identifiable, Hashable {
    let id: String
    let columns: [String]

    var imageName: String { column(0) }
    var imageId: String { column(1) }
    var imageSizeText: String { column(2) }
    var imageSizeBytes: Int64 { Self.parseByteSize(imageSizeText) }
    var imageCreated: String { column(3) }

    func column(_ index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        return columns[index]
    }

    static func parseByteSize(_ value: String) -> Int64 {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return 0 }

        var numberPart = ""
        var unitPart = ""
        for character in token {
            if character.isNumber || character == "." {
                numberPart.append(character)
            } else if !numberPart.isEmpty {
                unitPart.append(character)
            }
        }

        guard let value = Double(numberPart) else { return 0 }
        let unit = unitPart.lowercased()
        let multiplier: Double
        if unit.hasPrefix("t") {
            multiplier = 1_000_000_000_000
        } else if unit.hasPrefix("g") {
            multiplier = 1_000_000_000
        } else if unit.hasPrefix("m") {
            multiplier = 1_000_000
        } else if unit.hasPrefix("k") {
            multiplier = 1_000
        } else {
            multiplier = 1
        }
        return Int64(value * multiplier)
    }
}

struct DockerEvent: Identifiable, Hashable {
    let id: String
    let timestampRaw: String
    let kind: String
    let action: String
    let actorId: String
    let name: String
    let image: String
    let container: String
    let raw: String

    var date: Date? {
        if let seconds = TimeInterval(timestampRaw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: timestampRaw)
    }

    var displayTime: String {
        guard let date else { return timestampRaw.isEmpty ? "-" : timestampRaw }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    var fullTimestamp: String {
        guard let date else { return timestampRaw.isEmpty ? "-" : timestampRaw }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }

    var objectLabel: String {
        for value in [name, image, container, actorId] {
            let normalized = Self.normalized(value)
            if !normalized.isEmpty {
                return Self.compactIdentifier(normalized)
            }
        }
        return "-"
    }

    var rawText: String {
        [
            "time: \(fullTimestamp)",
            "type: \(kind.isEmpty ? "-" : kind)",
            "action: \(action.isEmpty ? "-" : action)",
            "object: \(objectLabel)",
            "actor_id: \(actorId.isEmpty ? "-" : actorId)",
            "name: \(name.isEmpty ? "-" : name)",
            "image: \(image.isEmpty ? "-" : image)",
            "container: \(container.isEmpty ? "-" : container)",
            "raw: \(raw)"
        ].joined(separator: "\n")
    }

    var searchText: String {
        [timestampRaw, fullTimestamp, kind, action, actorId, name, image, container, raw]
            .joined(separator: " ")
    }

    static func parse(_ line: String, index: Int) -> DockerEvent {
        let fields = splitFields(line)
        func field(_ offset: Int) -> String {
            guard fields.indices.contains(offset) else { return "" }
            return normalized(fields[offset])
        }
        return DockerEvent(
            id: "\(index):\(line)",
            timestampRaw: field(0),
            kind: field(1),
            action: field(2),
            actorId: field(3),
            name: field(4),
            image: field(5),
            container: field(6),
            raw: line
        )
    }

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "<no value>" ? "" : trimmed
    }

    static func compactIdentifier(_ value: String) -> String {
        guard value.count > 28 else { return value }
        let prefixCount = value.hasPrefix("sha256:") ? 19 : 16
        return "\(value.prefix(prefixCount))...\(value.suffix(8))"
    }
}

struct DockerEventQuery {
    var terms: [String] = []
    var kind: String?
    var action: String?
    var resource: String?
    var identifier: String?
    var since: TimeInterval?
}

enum DockerDiskSection: String, Hashable {
    case images
    case containers
    case volumes
    case buildCache

    var title: String {
        switch self {
        case .images: return "Images"
        case .containers: return "Containers"
        case .volumes: return "Volumes"
        case .buildCache: return "Build Cache"
        }
    }

    var emptyTitle: String {
        switch self {
        case .images: return "No image disk usage found"
        case .containers: return "No container disk usage found"
        case .volumes: return "No local volumes using space"
        case .buildCache: return "No build cache entries found"
        }
    }

    var emptyMessage: String {
        switch self {
        case .images: return "Docker did not report image rows for this host."
        case .containers: return "Docker did not report stopped or running containers using local space."
        case .volumes: return "There are no local volume rows in the disk report."
        case .buildCache: return "Build cache is empty, filtered out, or unavailable from this Docker version."
        }
    }
}

enum DockerDiskQuickFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case large = "Large"
    case stale = "7+ days"
    case buildCache = "Build cache"

    var id: String { rawValue }
}

struct DockerDiskSummaryItem: Identifiable, Hashable {
    let section: DockerDiskSection
    let total: String
    let active: String
    let size: String
    let sizeBytes: Int64
    let reclaimable: String
    let reclaimableBytes: Int64

    var id: String { section.rawValue }

    var activityText: String {
        if total.isEmpty && active.isEmpty { return "No activity counts" }
        if active.isEmpty { return "\(total) total" }
        return "\(total) total, \(active) active"
    }
}

struct DockerDiskRow: Identifiable, Hashable {
    let id: String
    let section: DockerDiskSection
    let repository: String
    let tag: String
    let imageId: String
    let created: String
    let size: String
    let sizeBytes: Int64
    let sharedSize: String
    let uniqueSize: String
    let containers: String
    let containerId: String
    let image: String
    let command: String
    let localVolumes: String
    let status: String
    let name: String
    let volumeName: String
    let links: String
    let cacheId: String
    let cacheType: String
    let lastUsed: String
    let usage: String
    let shared: String

    var searchText: String {
        [
            repository, tag, imageId, created, size, sharedSize, uniqueSize, containers,
            containerId, image, command, localVolumes, status, name, volumeName, links,
            cacheId, cacheType, lastUsed, usage, shared
        ]
        .joined(separator: " ")
        .lowercased()
    }

    var previewName: String {
        switch section {
        case .images:
            return repository.isEmpty ? imageId : "\(repository):\(tag)"
        case .containers:
            return name.isEmpty ? containerId : name
        case .volumes:
            return volumeName
        case .buildCache:
            return cacheId
        }
    }

    var isLarge: Bool {
        sizeBytes >= 100_000_000
    }

    var isOlderThanWeek: Bool {
        Self.isOlderThanWeek(created) || Self.isOlderThanWeek(lastUsed)
    }

    static func isOlderThanWeek(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("month") || lower.contains("year") { return true }
        let amount = Int(lower.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
        if lower.contains("week") { return amount >= 1 }
        if lower.contains("day") { return amount >= 7 }
        return false
    }
}

struct DockerDiskSnapshot {
    var rawText: String = ""
    var summaries: [DockerDiskSummaryItem] = []
    var images: [DockerDiskRow] = []
    var containers: [DockerDiskRow] = []
    var volumes: [DockerDiskRow] = []
    var buildCache: [DockerDiskRow] = []
    var refreshedAt: Date?

    static let empty = DockerDiskSnapshot()

    var totalSizeBytes: Int64 {
        let summaryTotal = summaries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if summaryTotal > 0 { return summaryTotal }
        return [images, containers, volumes, buildCache]
            .flatMap { $0 }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    func rows(for section: DockerDiskSection) -> [DockerDiskRow] {
        switch section {
        case .images: return images
        case .containers: return containers
        case .volumes: return volumes
        case .buildCache: return buildCache
        }
    }

    func summary(for section: DockerDiskSection) -> DockerDiskSummaryItem? {
        summaries.first { $0.section == section }
    }

    func sizeText(for section: DockerDiskSection) -> String {
        if let summary = summary(for: section), !summary.size.isEmpty {
            return summary.size
        }
        let bytes = rows(for: section).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return bytes > 0 ? Self.formatBytes(bytes) : "0 B"
    }

    func reclaimableText(for section: DockerDiskSection) -> String {
        guard let summary = summary(for: section), !summary.reclaimable.isEmpty else {
            return "No reclaimable estimate"
        }
        return "\(summary.reclaimable) reclaimable"
    }

    static func parse(_ output: String, refreshedAt: Date = Date()) -> DockerDiskSnapshot {
        let lines = output.lines()
        var snapshot = DockerDiskSnapshot(
            rawText: output,
            summaries: parseSummary(lines),
            images: parseImages(lines),
            containers: parseContainers(lines),
            volumes: parseVolumes(lines),
            buildCache: parseBuildCache(lines),
            refreshedAt: refreshedAt
        )

        if snapshot.summary(for: .buildCache) == nil,
           let buildCacheSize = parseBuildCacheUsage(lines) {
            snapshot.summaries.append(
                DockerDiskSummaryItem(
                    section: .buildCache,
                    total: "\(snapshot.buildCache.count)",
                    active: "",
                    size: buildCacheSize,
                    sizeBytes: parseByteSize(buildCacheSize),
                    reclaimable: buildCacheSize,
                    reclaimableBytes: parseByteSize(buildCacheSize)
                )
            )
        }

        return snapshot
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func parseSummary(_ lines: [String]) -> [DockerDiskSummaryItem] {
        let summaryLines: [String]
        if let firstSection = lines.firstIndex(where: isSectionTitle) {
            summaryLines = Array(lines[..<firstSection])
        } else {
            summaryLines = lines
        }
        let rows = parseFixedWidthRows(
            summaryLines,
            labels: ["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"]
        )
        return rows.compactMap { row in
            let type = row["TYPE", default: ""].lowercased()
            let section: DockerDiskSection?
            if type.hasPrefix("image") {
                section = .images
            } else if type.hasPrefix("container") {
                section = .containers
            } else if type.hasPrefix("local volume") {
                section = .volumes
            } else if type.hasPrefix("build cache") {
                section = .buildCache
            } else {
                section = nil
            }
            guard let section else { return nil }
            let reclaimable = row["RECLAIMABLE", default: ""]
            return DockerDiskSummaryItem(
                section: section,
                total: row["TOTAL", default: ""],
                active: row["ACTIVE", default: ""],
                size: row["SIZE", default: ""],
                sizeBytes: parseByteSize(row["SIZE", default: ""]),
                reclaimable: reclaimable,
                reclaimableBytes: parseByteSize(reclaimable)
            )
        }
    }

    static func parseImages(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Images space usage:"),
            labels: ["REPOSITORY", "TAG", "IMAGE ID", "CREATED", "SIZE", "SHARED SIZE", "UNIQUE SIZE", "CONTAINERS"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "images:\(index):\(row["IMAGE ID", default: ""])",
                section: .images,
                repository: row["REPOSITORY", default: ""],
                tag: row["TAG", default: ""],
                imageId: row["IMAGE ID", default: ""],
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                sharedSize: row["SHARED SIZE", default: ""],
                uniqueSize: row["UNIQUE SIZE", default: ""],
                containers: row["CONTAINERS", default: ""]
            )
        }
    }

    static func parseContainers(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Containers space usage:"),
            labels: ["CONTAINER ID", "IMAGE", "COMMAND", "LOCAL VOLUMES", "SIZE", "CREATED", "STATUS", "NAMES"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "containers:\(index):\(row["CONTAINER ID", default: ""])",
                section: .containers,
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                containerId: row["CONTAINER ID", default: ""],
                image: row["IMAGE", default: ""],
                command: row["COMMAND", default: ""],
                localVolumes: row["LOCAL VOLUMES", default: ""],
                status: row["STATUS", default: ""],
                name: row["NAMES", default: ""]
            )
        }
    }

    static func parseVolumes(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Local Volumes space usage:"),
            labels: ["VOLUME NAME", "LINKS", "SIZE"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "volumes:\(index):\(row["VOLUME NAME", default: ""])",
                section: .volumes,
                size: row["SIZE", default: ""],
                volumeName: row["VOLUME NAME", default: ""],
                links: row["LINKS", default: ""]
            )
        }
    }

    static func parseBuildCache(_ lines: [String]) -> [DockerDiskRow] {
        parseFixedWidthRows(
            sectionLines(in: lines, titlePrefix: "Build cache usage:"),
            labels: ["CACHE ID", "CACHE TYPE", "SIZE", "CREATED", "LAST USED", "USAGE", "SHARED"]
        )
        .enumerated()
        .map { index, row in
            diskRow(
                id: "build-cache:\(index):\(row["CACHE ID", default: ""])",
                section: .buildCache,
                created: row["CREATED", default: ""],
                size: row["SIZE", default: ""],
                cacheId: row["CACHE ID", default: ""],
                cacheType: row["CACHE TYPE", default: ""],
                lastUsed: row["LAST USED", default: ""],
                usage: row["USAGE", default: ""],
                shared: row["SHARED", default: ""]
            )
        }
    }

    static func diskRow(
        id: String,
        section: DockerDiskSection,
        repository: String = "",
        tag: String = "",
        imageId: String = "",
        created: String = "",
        size: String = "",
        sharedSize: String = "",
        uniqueSize: String = "",
        containers: String = "",
        containerId: String = "",
        image: String = "",
        command: String = "",
        localVolumes: String = "",
        status: String = "",
        name: String = "",
        volumeName: String = "",
        links: String = "",
        cacheId: String = "",
        cacheType: String = "",
        lastUsed: String = "",
        usage: String = "",
        shared: String = ""
    ) -> DockerDiskRow {
        DockerDiskRow(
            id: id,
            section: section,
            repository: repository,
            tag: tag,
            imageId: imageId,
            created: created,
            size: size,
            sizeBytes: parseByteSize(size),
            sharedSize: sharedSize,
            uniqueSize: uniqueSize,
            containers: containers,
            containerId: containerId,
            image: image,
            command: command,
            localVolumes: localVolumes,
            status: status,
            name: name,
            volumeName: volumeName,
            links: links,
            cacheId: cacheId,
            cacheType: cacheType,
            lastUsed: lastUsed,
            usage: usage,
            shared: shared
        )
    }

    static func parseFixedWidthRows(_ lines: [String], labels: [String]) -> [[String: String]] {
        guard let headerIndex = lines.firstIndex(where: { line in
            labels.allSatisfy { line.contains($0) }
        }) else {
            return []
        }
        let header = lines[headerIndex]
        guard let starts = columnStarts(in: header, labels: labels) else { return [] }
        return lines.dropFirst(headerIndex + 1).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isSectionTitle(line) else { return nil }
            var row: [String: String] = [:]
            for (index, label) in labels.enumerated() {
                row[label] = slice(line, start: starts[index], end: starts[safe: index + 1])
            }
            let hasValue = labels.contains { !(row[$0] ?? "").isEmpty }
            return hasValue ? row : nil
        }
    }

    static func columnStarts(in header: String, labels: [String]) -> [Int]? {
        var starts: [Int] = []
        var searchStart = header.startIndex
        for label in labels {
            guard let range = header.range(of: label, range: searchStart..<header.endIndex) else {
                return nil
            }
            starts.append(header.distance(from: header.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
        }
        return starts
    }

    static func slice(_ line: String, start: Int, end: Int?) -> String {
        guard start < line.count else { return "" }
        let lower = line.index(line.startIndex, offsetBy: start)
        let upperOffset = min(end ?? line.count, line.count)
        let upper = line.index(line.startIndex, offsetBy: upperOffset)
        return String(line[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sectionLines(in lines: [String], titlePrefix: String) -> [String] {
        guard let start = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix(titlePrefix.lowercased())
        }) else {
            return []
        }
        let afterStart = lines.index(after: start)
        let end = lines[afterStart...].firstIndex(where: isSectionTitle) ?? lines.endIndex
        return Array(lines[afterStart..<end])
    }

    static func isSectionTitle(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("images space usage:")
            || lower.hasPrefix("containers space usage:")
            || lower.hasPrefix("local volumes space usage:")
            || lower.hasPrefix("build cache usage:")
    }

    static func parseBuildCacheUsage(_ lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("build cache usage:") else { continue }
            return trimmed
                .dropFirst("Build cache usage:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func parseByteSize(_ value: String) -> Int64 {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return 0 }

        var numberPart = ""
        var unitPart = ""
        for character in token {
            if character.isNumber || character == "." {
                numberPart.append(character)
            } else if !numberPart.isEmpty {
                unitPart.append(character)
            }
        }
        guard let value = Double(numberPart) else { return 0 }
        let unit = unitPart.lowercased()
        let multiplier: Double
        if unit.hasPrefix("t") {
            multiplier = 1_000_000_000_000
        } else if unit.hasPrefix("g") {
            multiplier = 1_000_000_000
        } else if unit.hasPrefix("m") {
            multiplier = 1_000_000
        } else if unit.hasPrefix("k") {
            multiplier = 1_000
        } else {
            multiplier = 1
        }
        return Int64(value * multiplier)
    }
}
