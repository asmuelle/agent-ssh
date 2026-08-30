import Foundation
import AgentSshMacOS

@MainActor
final class SecurityPatchMonitorSummaryStore: ObservableObject {
    static let shared = SecurityPatchMonitorSummaryStore()

    @Published private(set) var summaries: [String: SecurityPatchHostSummary] = [:]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    func summary(profileId: String, connectionId: String?) -> SecurityPatchHostSummary? {
        if let summary = summaries[profileId] {
            return summary
        }
        if let connectionId {
            return summaries[connectionId]
        }
        return nil
    }

    func record(_ summary: SecurityPatchHostSummary) {
        let key = summary.profileId ?? summary.connectionId
        summaries[key] = summary
        save()
        // A completed scan is news — reconcile the attention inbox now
        // rather than waiting for the next throttled sweep.
        AttentionInboxIngest.shared.syncScanSummaries()
    }

    /// Forget a deleted profile's summary so proactive surfaces (sidebar
    /// badge, attention inbox reconciles) cannot keep re-asserting it.
    func remove(profileId: String) {
        let before = summaries.count
        summaries = summaries.filter { key, summary in
            key != profileId && summary.profileId != profileId
        }
        if summaries.count != before {
            save()
        }
    }

    private func load() {
        guard let url = try? fileURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? SecurityPatchMonitorCache.decoder.decode(SecurityPatchSummaryFile.self, from: data) else {
            return
        }
        summaries = Dictionary(uniqueKeysWithValues: file.summaries.map { summary in
            (summary.profileId ?? summary.connectionId, summary)
        })
    }

    private func save() {
        do {
            let url = try fileURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = SecurityPatchSummaryFile(summaries: Array(summaries.values))
            let data = try SecurityPatchMonitorCache.encoder.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Security badges are a cache; scan results should still render if persistence fails.
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
            .appendingPathComponent("security-patch-summaries.json")
    }

}

private struct SecurityPatchSummaryFile: Codable {
    var summaries: [SecurityPatchHostSummary]
}
