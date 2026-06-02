import Foundation
import AgentSshMacOS

@MainActor
final class SecurityPatchMonitorResultStore: ObservableObject {
    static let shared = SecurityPatchMonitorResultStore()

    @Published private(set) var results: [String: SecurityPatchScanResult] = [:]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    func result(profileId: String?, connectionId: String) -> SecurityPatchScanResult? {
        if let profileId, let result = results[profileId] {
            return result
        }
        return results[connectionId]
    }

    func record(_ result: SecurityPatchScanResult) {
        let key = result.profileId ?? result.connectionId
        results[key] = result
        save()
    }

    private func load() {
        guard let url = try? fileURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? SecurityPatchMonitorCache.decoder.decode(SecurityPatchResultFile.self, from: data) else {
            return
        }
        results = Dictionary(uniqueKeysWithValues: file.results.map { result in
            (result.profileId ?? result.connectionId, result)
        })
    }

    private func save() {
        do {
            let url = try fileURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = SecurityPatchResultFile(results: Array(results.values))
            let data = try SecurityPatchMonitorCache.encoder.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Full scan results are a cache; fresh scans should still render if persistence fails.
        }
    }

    private func fileURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("agent-ssh", isDirectory: true)
            .appendingPathComponent("security-patch-results.json")
    }
}

private struct SecurityPatchResultFile: Codable {
    var results: [SecurityPatchScanResult]
}
