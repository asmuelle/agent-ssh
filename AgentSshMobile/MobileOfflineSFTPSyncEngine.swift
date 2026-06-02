import Foundation

struct MobileOfflineSFTPSyncSummary {
    let folderId: String
    let remotePath: String
    let itemCount: Int
    let byteCount: UInt64
}

final class MobileOfflineSFTPSyncEngine {
    static let shared = MobileOfflineSFTPSyncEngine()

    private let itemLimit = 2_000

    private init() {}

    func syncFolder(
        connectionId: String,
        folder: OfflineSFTPFolderRecord,
        operationId: String? = nil
    ) async throws -> MobileOfflineSFTPSyncSummary {
        let operationStore = BackgroundSSHOperationStore()
        let integrationStore = PlatformIntegrationStore()
        let manifestStore = OfflineSFTPCacheManifestStore()

        if let operationId {
            try? operationStore.update(id: operationId, status: .running)
        }

        do {
            let cacheRoot = try offlineCacheRootURL(folderId: folder.id)
            try updateOfflineFolder(
                folder.id,
                syncState: .syncing,
                localCachePath: cacheRoot.path,
                lastSyncedAt: folder.lastSyncedAt,
                lastError: nil,
                integrationStore: integrationStore
            )
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

            var itemCount = 0
            var byteCount: UInt64 = 0
            var records: [OfflineSFTPCacheItemRecord] = []
            try await syncContents(
                connectionId: connectionId,
                folderId: folder.id,
                rootRemotePath: folder.remotePath,
                currentRemotePath: folder.remotePath,
                cacheRoot: cacheRoot,
                records: &records,
                itemCount: &itemCount,
                byteCount: &byteCount,
                operationId: operationId
            )

            var manifest = try manifestStore.load()
            manifest.items.removeAll { $0.folderId == folder.id }
            manifest.items.append(contentsOf: records)
            manifest.generatedAt = Date()
            try manifestStore.save(manifest)

            try updateOfflineFolder(
                folder.id,
                syncState: .current,
                localCachePath: cacheRoot.path,
                lastSyncedAt: Date(),
                lastError: nil,
                integrationStore: integrationStore
            )

            if let operationId {
                try? operationStore.update(
                    id: operationId,
                    status: .running,
                    progress: BackgroundSSHOperationProgress(
                        completedUnitCount: Int64(itemCount),
                        totalUnitCount: Int64(itemCount)
                    )
                )
            }

            return MobileOfflineSFTPSyncSummary(
                folderId: folder.id,
                remotePath: folder.remotePath,
                itemCount: itemCount,
                byteCount: byteCount
            )
        } catch {
            try? updateOfflineFolder(
                folder.id,
                syncState: .failed,
                localCachePath: folder.localCachePath,
                lastSyncedAt: folder.lastSyncedAt,
                lastError: error.localizedDescription,
                integrationStore: integrationStore
            )
            throw error
        }
    }

    private func syncContents(
        connectionId: String,
        folderId: String,
        rootRemotePath: String,
        currentRemotePath: String,
        cacheRoot: URL,
        records: inout [OfflineSFTPCacheItemRecord],
        itemCount: inout Int,
        byteCount: inout UInt64,
        operationId: String?
    ) async throws {
        let entries = try await MobileSFTPBridge.shared.listDir(
            connectionId: connectionId,
            path: currentRemotePath
        )

        for entry in entries {
            guard entry.name != "." && entry.name != ".." else { continue }
            itemCount += 1
            if itemCount > itemLimit {
                throw MobileOfflineSFTPSyncError.tooManyItems(limit: itemLimit)
            }

            let remotePath = join(path: currentRemotePath, child: entry.name)
            let localURL = try localCacheURL(
                cacheRoot: cacheRoot,
                rootRemotePath: rootRemotePath,
                remotePath: remotePath,
                isDirectory: entry.kind == .directory
            )
            let fileType = fileType(for: entry.kind)

            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                records.append(
                    OfflineSFTPCacheItemRecord(
                        folderId: folderId,
                        remotePath: remotePath,
                        parentRemotePath: currentRemotePath,
                        name: entry.name,
                        fileType: fileType,
                        size: entry.size,
                        modifiedAt: modifiedDate(for: entry),
                        localCachePath: localURL.path,
                        lastSyncedAt: Date()
                    )
                )
                try await syncContents(
                    connectionId: connectionId,
                    folderId: folderId,
                    rootRemotePath: rootRemotePath,
                    currentRemotePath: remotePath,
                    cacheRoot: cacheRoot,
                    records: &records,
                    itemCount: &itemCount,
                    byteCount: &byteCount,
                    operationId: operationId
                )
            case .file:
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let bytes = try await MobileSFTPBridge.shared.download(
                    connectionId: connectionId,
                    remotePath: remotePath,
                    localPath: localURL.path,
                    expectedSize: entry.size
                )
                byteCount += bytes
                records.append(
                    OfflineSFTPCacheItemRecord(
                        folderId: folderId,
                        remotePath: remotePath,
                        parentRemotePath: currentRemotePath,
                        name: entry.name,
                        fileType: fileType,
                        size: entry.size,
                        modifiedAt: modifiedDate(for: entry),
                        localCachePath: localURL.path,
                        lastSyncedAt: Date()
                    )
                )
            case .symlink:
                records.append(
                    OfflineSFTPCacheItemRecord(
                        folderId: folderId,
                        remotePath: remotePath,
                        parentRemotePath: currentRemotePath,
                        name: entry.name,
                        fileType: fileType,
                        size: entry.size,
                        modifiedAt: modifiedDate(for: entry),
                        lastSyncedAt: Date()
                    )
                )
            }

            if let operationId {
                try? BackgroundSSHOperationStore().update(
                    id: operationId,
                    status: .running,
                    progress: BackgroundSSHOperationProgress(completedUnitCount: Int64(itemCount))
                )
            }
        }
    }

    private func updateOfflineFolder(
        _ folderId: String,
        syncState: OfflineFolderSyncState,
        localCachePath: String?,
        lastSyncedAt: Date?,
        lastError: String?,
        integrationStore: PlatformIntegrationStore
    ) throws {
        var data = try integrationStore.load()
        guard let index = data.offlineFolders.firstIndex(where: { $0.id == folderId }) else { return }
        data.offlineFolders[index].syncState = syncState
        data.offlineFolders[index].localCachePath = localCachePath
        data.offlineFolders[index].lastSyncedAt = lastSyncedAt
        data.offlineFolders[index].lastError = lastError
        try integrationStore.save(data)
    }

    private func offlineCacheRootURL(folderId: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAppStorageConfiguration.appGroupIdentifier
        ) else {
            throw SharedJSONFileStoreError.appGroupContainerUnavailable(
                SharedAppStorageConfiguration.appGroupIdentifier
            )
        }
        return container
            .appendingPathComponent(SharedAppStorageConfiguration.offlineCacheDirectoryName, isDirectory: true)
            .appendingPathComponent(folderId, isDirectory: true)
    }

    private func localCacheURL(
        cacheRoot: URL,
        rootRemotePath: String,
        remotePath: String,
        isDirectory: Bool
    ) throws -> URL {
        let root = OfflineSFTPCacheItemRecord.normalizedRemotePath(rootRemotePath)
        let remote = OfflineSFTPCacheItemRecord.normalizedRemotePath(remotePath)
        guard remote == root || remote.hasPrefix(root == "/" ? "/" : "\(root)/") else {
            throw MobileOfflineSFTPSyncError.invalidRemotePath(remote)
        }

        let relative = remote == root
            ? ""
            : String(remote.dropFirst(root == "/" ? 1 : root.count + 1))
        return relative
            .split(separator: "/")
            .reduce(cacheRoot) { partial, component in
                partial.appendingPathComponent(safeCachePathComponent(String(component)), isDirectory: isDirectory)
            }
    }

    private func safeCachePathComponent(_ component: String) -> String {
        let cleaned = component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned == "." || cleaned == ".." || cleaned.isEmpty ? "_" : cleaned
    }

    private func fileType(for kind: FfiFileKind) -> FileType {
        switch kind {
        case .directory:
            return .directory
        case .symlink:
            return .symlink
        case .file:
            return .file
        }
    }

    private func modifiedDate(for entry: FfiFileEntry) -> Date? {
        entry.modifiedUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func join(path: String, child: String) -> String {
        if path == "." {
            return child
        }
        return path.hasSuffix("/") ? path + child : path + "/" + child
    }
}

private enum MobileOfflineSFTPSyncError: LocalizedError {
    case invalidRemotePath(String)
    case tooManyItems(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRemotePath(let path):
            return "\(path) is outside the selected offline folder."
        case .tooManyItems(let limit):
            return "Offline sync stopped after \(limit) items. Choose a smaller folder."
        }
    }
}
