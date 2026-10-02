import Foundation

public enum SyncedConnectionAuthMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case password
    case publicKey

    public init(_ authMethod: AuthMethod) {
        switch authMethod {
        case .password: self = .password
        case .publicKey: self = .publicKey
        }
    }

    public var connectionAuthMethod: AuthMethod {
        switch self {
        case .password: return .password
        case .publicKey: return .publicKey
        }
    }
}

public enum SyncedConnectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ssh
    case sftp

    public init(_ kind: ConnectionKind) {
        switch kind {
        case .ssh: self = .ssh
        case .sftp: self = .sftp
        }
    }

    public var connectionKind: ConnectionKind {
        switch self {
        case .ssh: return .ssh
        case .sftp: return .sftp
        }
    }
}

public struct ConnectionCSVRow: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: SyncedConnectionAuthMethod
    public var kind: SyncedConnectionKind
    public var folderPath: String?
    public var tags: [String]
    public var favorite: Bool
    public var color: String?
    public var notes: String?

    public init(
        id: String? = nil,
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: SyncedConnectionAuthMethod = .password,
        kind: SyncedConnectionKind = .ssh,
        folderPath: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        color: String? = nil,
        notes: String? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authMethod = authMethod
        self.kind = kind
        self.folderPath = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tags = tags
        self.favorite = favorite
        self.color = color?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.notes = notes
    }

    public init(profile: ConnectionProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authMethod: SyncedConnectionAuthMethod(profile.authMethod),
            kind: SyncedConnectionKind(profile.kind),
            folderPath: profile.folderPath,
            tags: profile.tags,
            favorite: profile.favorite,
            color: profile.color,
            notes: profile.notes
        )
    }

    public var stableId: String {
        id ?? "csv-\(Self.stableHash([name, host, "\(port)", username].joined(separator: "|")))"
    }

    public func connectionProfile(preserving existing: ConnectionProfile? = nil) -> ConnectionProfile {
        ConnectionProfile(
            id: stableId,
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.connectionAuthMethod,
            kind: kind.connectionKind,
            folderPath: folderPath,
            sshKeyReference: existing?.sshKeyReference,
            createdAt: existing?.createdAt ?? Date(),
            lastConnected: existing?.lastConnected,
            favorite: favorite,
            tags: tags,
            color: color,
            notes: notes,
            monitoredSystemdServices: existing?.monitoredSystemdServices ?? []
        )
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public enum ConnectionCSVError: LocalizedError, Equatable {
    case missingHeader
    case missingRequiredColumn(String)
    case malformedRow(Int)
    case invalidPort(row: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .missingHeader:
            return "CSV import requires a header row."
        case .missingRequiredColumn(let column):
            return "CSV import is missing the required \(column) column."
        case .malformedRow(let row):
            return "CSV row \(row) is malformed."
        case .invalidPort(let row, let value):
            return "CSV row \(row) has an invalid port: \(value)."
        }
    }
}

public enum ConnectionCSVCodec {
    public static let header = [
        "id", "name", "host", "port", "username", "authMethod", "kind",
        "folder", "tags", "favorite", "color", "notes"
    ]

    public static func encode(profiles: [ConnectionProfile]) -> String {
        var rows = [header]
        rows += profiles.map { profile in
            let row = ConnectionCSVRow(profile: profile)
            return [
                row.id ?? "",
                row.name,
                row.host,
                "\(row.port)",
                row.username,
                row.authMethod.rawValue,
                row.kind.rawValue,
                row.folderPath ?? "",
                row.tags.joined(separator: ";"),
                row.favorite ? "true" : "false",
                row.color ?? "",
                row.notes ?? "",
            ]
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    public static func decode(_ csv: String) throws -> [ConnectionCSVRow] {
        let table = parse(csv)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let headerRow = table.first else { throw ConnectionCSVError.missingHeader }
        let headerMap = Dictionary(uniqueKeysWithValues: headerRow.enumerated().map { index, name in
            (name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), index)
        })
        for required in ["name", "host", "username"] where headerMap[required] == nil {
            throw ConnectionCSVError.missingRequiredColumn(required)
        }

        return try table.dropFirst().enumerated().map { offset, fields in
            let rowNumber = offset + 2
            func field(_ name: String) -> String {
                guard let index = headerMap[name.lowercased()], index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rawPort = field("port")
            let port = rawPort.isEmpty ? 22 : UInt16(rawPort)
            guard let port else { throw ConnectionCSVError.invalidPort(row: rowNumber, value: rawPort) }

            return ConnectionCSVRow(
                id: field("id"),
                name: field("name"),
                host: field("host"),
                port: port,
                username: field("username"),
                authMethod: SyncedConnectionAuthMethod(rawValue: field("authMethod")) ?? .password,
                kind: SyncedConnectionKind(rawValue: field("kind")) ?? .ssh,
                folderPath: field("folder"),
                tags: field("tags").split(separator: ";").map(String.init),
                favorite: ["true", "yes", "1"].contains(field("favorite").lowercased()),
                color: field("color"),
                notes: field("notes")
            )
        }
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                row.append(field)
                                field = ""
                            } else if next == "\n" {
                                row.append(field)
                                rows.append(row)
                                row = []
                                field = ""
                            } else if next != "\r" {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    continue
                default:
                    field.append(char)
                }
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

public enum ConnectionCSVImportAction: String, Codable, Equatable, Sendable {
    case add
    case update
    case skip
    case invalid
}

public struct ConnectionCSVImportItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var action: ConnectionCSVImportAction
    public var row: ConnectionCSVRow
    public var message: String?

    public init(action: ConnectionCSVImportAction, row: ConnectionCSVRow, message: String? = nil) {
        self.id = row.stableId
        self.action = action
        self.row = row
        self.message = message
    }
}

public struct ConnectionCSVImportPlan: Codable, Equatable, Sendable {
    public var items: [ConnectionCSVImportItem]

    public init(items: [ConnectionCSVImportItem]) {
        self.items = items
    }

    public var addCount: Int { items.filter { $0.action == .add }.count }
    public var updateCount: Int { items.filter { $0.action == .update }.count }
    public var skipCount: Int { items.filter { $0.action == .skip }.count }
    public var invalidCount: Int { items.filter { $0.action == .invalid }.count }

    public var isApplicable: Bool {
        invalidCount == 0 && items.contains { $0.action == .add || $0.action == .update }
    }

    public var summary: String {
        "\(addCount) add, \(updateCount) update, \(skipCount) unchanged, \(invalidCount) invalid"
    }
}

public enum ConnectionCSVImportPlanner {
    public static func plan(existing: [ConnectionProfile], csv: String) throws -> ConnectionCSVImportPlan {
        try plan(existing: existing, rows: ConnectionCSVCodec.decode(csv))
    }

    public static func plan(existing: [ConnectionProfile], rows: [ConnectionCSVRow]) -> ConnectionCSVImportPlan {
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var seenIds = Set<String>()
        let items = rows.map { row -> ConnectionCSVImportItem in
            guard !row.name.isEmpty, !row.host.isEmpty, !row.username.isEmpty else {
                return ConnectionCSVImportItem(action: .invalid, row: row, message: "Name, host, and username are required.")
            }

            let stableId = row.stableId
            guard seenIds.insert(stableId).inserted else {
                return ConnectionCSVImportItem(action: .invalid, row: row, message: "Duplicate stable ID \(stableId).")
            }

            if let existing = existingById[stableId] {
                return row.connectionProfile(preserving: existing) == existing
                    ? ConnectionCSVImportItem(action: .skip, row: row)
                    : ConnectionCSVImportItem(action: .update, row: row)
            }
            return ConnectionCSVImportItem(action: .add, row: row)
        }
        return ConnectionCSVImportPlan(items: items)
    }

    public static func apply(_ plan: ConnectionCSVImportPlan, to existing: [ConnectionProfile]) -> [ConnectionProfile] {
        var output = existing
        for item in plan.items {
            switch item.action {
            case .add:
                output.append(item.row.connectionProfile())
            case .update:
                guard let index = output.firstIndex(where: { $0.id == item.id }) else { continue }
                output[index] = item.row.connectionProfile(preserving: output[index])
            case .skip, .invalid:
                continue
            }
        }
        return output
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
