import Foundation
import AgentSshMacOS

@MainActor
final class SecurityPatchAdvisoryStore: ObservableObject {
    static let shared = SecurityPatchAdvisoryStore()

    @Published private(set) var catalog: SecurityPatchKevCatalog?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let session: URLSession
    private let catalogURL: URL

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        catalogURL: URL = URL(string: "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json")!
    ) {
        self.fileManager = fileManager
        self.session = session
        self.catalogURL = catalogURL
        load()
    }

    func correlate(_ result: SecurityPatchScanResult) async -> SecurityPatchScanResult {
        guard !SecurityPatchMonitorAdvisoryCorrelation.extractCveIds(evidence: result.evidence).isEmpty else {
            return result
        }
        guard let catalog = await catalogForCorrelation() else {
            return result
        }
        return SecurityPatchMonitorAdvisoryCorrelation.correlate(result: result, kevCatalog: catalog)
    }

    func refresh(force: Bool = false) async {
        _ = await catalogForCorrelation(force: force)
    }

    private func catalogForCorrelation(force: Bool = false) async -> SecurityPatchKevCatalog? {
        if !force, let catalog, let fetchedAt, !isStale(fetchedAt) {
            return catalog
        }

        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: catalogURL, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("MidnightSSH SecurityPatchMonitor", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SecurityPatchAdvisoryError.badStatus
            }

            let decoded = try JSONDecoder().decode(SecurityPatchKevCatalog.self, from: data)
            catalog = decoded
            fetchedAt = Date()
            save()
            return decoded
        } catch {
            lastError = error.localizedDescription
            return catalog
        }
    }

    private func isStale(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) > 24 * 60 * 60
    }

    private func load() {
        guard let url = try? fileURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? SecurityPatchMonitorCache.decoder.decode(SecurityPatchKevCacheFile.self, from: data) else {
            return
        }
        catalog = cache.catalog
        fetchedAt = cache.fetchedAt
    }

    private func save() {
        guard let catalog, let fetchedAt else { return }
        do {
            let url = try fileURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try SecurityPatchMonitorCache.encoder.encode(SecurityPatchKevCacheFile(
                fetchedAt: fetchedAt,
                catalog: catalog
            ))
            try data.write(to: url, options: [.atomic])
        } catch {
            // Advisory data is an enrichment cache. Scans should still render without it.
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
            .appendingPathComponent("security-patch-cisa-kev.json")
    }
}

private struct SecurityPatchKevCacheFile: Codable {
    var fetchedAt: Date
    var catalog: SecurityPatchKevCatalog
}

private enum SecurityPatchAdvisoryError: LocalizedError {
    case badStatus

    var errorDescription: String? {
        switch self {
        case .badStatus:
            return "CISA KEV catalog request returned an unsuccessful status."
        }
    }
}
