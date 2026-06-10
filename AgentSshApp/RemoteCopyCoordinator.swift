import Foundation
import OSLog

/// Orchestrates server→server file copies by relaying through the Mac:
/// download the source file into a private temp directory, then upload
/// it to the destination host, then delete the temp copy.
///
/// Why relay instead of a direct host-to-host transfer (scp/rsync from
/// A to B)? A direct transfer requires host A to authenticate against
/// host B — credentials the app holds locally would have to be
/// forwarded or temporarily installed on A. The relay needs nothing the
/// two existing SFTP sessions don't already have, works when the hosts
/// can't reach each other (different VPNs, firewalled DMZs), and keeps
/// every byte inside the connections the user already trusts. The cost
/// is 2× transfer time and local disk for one file at a time.
///
/// Both legs run through `TransferQueueStore`, so they show up in the
/// transfer overlay with progress and per-leg cancellation, and they
/// respect the per-connection serial queue (a single SSH session can't
/// multiplex SFTP transfers).
@MainActor
enum RemoteCopyCoordinator {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "remote-copy")

    /// Kick off a copy of `drag` (a file or directory on its source
    /// host) into `destDir` on `destConnectionId`. Directory copies
    /// walk the source tree and relay each file; `onError` surfaces
    /// walk failures (listing a source dir, creating a destination
    /// dir) — per-file transfer failures already surface as failed
    /// rows in the transfer overlay.
    static func copy(
        drag: RemoteFileDrag,
        toConnection destConnectionId: String,
        destDir: String,
        transfers: TransferQueueStore,
        onError: @escaping (String) -> Void
    ) {
        guard drag.connectionId != destConnectionId else { return }
        let destPath = joinRemotePath(destDir, drag.name)

        switch drag.kind {
        case .file, .symlink:
            relayFile(
                sourceConnectionId: drag.connectionId,
                sourcePath: drag.remotePath,
                name: drag.name,
                size: drag.size,
                destConnectionId: destConnectionId,
                destPath: destPath,
                transfers: transfers
            )
        case .directory:
            Task {
                await relayDirectory(
                    sourceConnectionId: drag.connectionId,
                    sourceRoot: drag.remotePath,
                    destConnectionId: destConnectionId,
                    destRoot: destPath,
                    transfers: transfers,
                    onError: onError
                )
            }
        }
    }

    // MARK: - Single file relay

    /// Download → upload chain for one file. The upload leg is enqueued
    /// from the download leg's completion callback so it never runs
    /// against a half-written temp file. The temp copy is deleted as
    /// soon as the chain reaches any terminal state.
    private static func relayFile(
        sourceConnectionId: String,
        sourcePath: String,
        name: String,
        size: UInt64,
        destConnectionId: String,
        destPath: String,
        transfers: TransferQueueStore
    ) {
        let tempURL = temporaryRelayURL(for: name)
        do {
            try FileManager.default.createDirectory(
                at: tempURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Could not create relay temp dir: \(error.localizedDescription, privacy: .public)")
            return
        }

        transfers.enqueueDownload(
            connectionId: sourceConnectionId,
            remotePath: sourcePath,
            localPath: tempURL.path,
            expectedSize: size,
            revealsInFinder: false,
            onCompleted: { downloadSucceeded in
                guard downloadSucceeded else {
                    cleanUpRelayFile(tempURL)
                    return
                }
                transfers.enqueueUpload(
                    connectionId: destConnectionId,
                    localPath: tempURL.path,
                    remotePath: destPath,
                    onCompleted: { _ in
                        cleanUpRelayFile(tempURL)
                    }
                )
            }
        )
    }

    // MARK: - Directory relay

    /// Mirror a remote directory tree from one host onto another:
    /// mkdir on the destination, list the source, recurse into
    /// subdirectories, relay every file. Directory creation is awaited
    /// step by step (children rely on parents existing); file relays
    /// are fire-and-forget through the transfer queue.
    private static func relayDirectory(
        sourceConnectionId: String,
        sourceRoot: String,
        destConnectionId: String,
        destRoot: String,
        transfers: TransferQueueStore,
        onError: @escaping (String) -> Void
    ) async {
        do {
            try await createDestinationDirectory(connectionId: destConnectionId, path: destRoot)
        } catch {
            onError("Could not create \(destRoot): \(error.localizedDescription)")
            return
        }

        let entries: [FfiFileEntry]
        do {
            entries = try await BridgeManager.shared.sftpListDir(
                connectionId: sourceConnectionId,
                path: sourceRoot
            )
        } catch {
            onError("Could not list \(sourceRoot): \(error.localizedDescription)")
            return
        }

        for entry in entries {
            let sourceChild = joinRemotePath(sourceRoot, entry.name)
            let destChild = joinRemotePath(destRoot, entry.name)

            switch entry.kind {
            case .directory:
                await relayDirectory(
                    sourceConnectionId: sourceConnectionId,
                    sourceRoot: sourceChild,
                    destConnectionId: destConnectionId,
                    destRoot: destChild,
                    transfers: transfers,
                    onError: onError
                )
            case .file, .symlink:
                relayFile(
                    sourceConnectionId: sourceConnectionId,
                    sourcePath: sourceChild,
                    name: entry.name,
                    size: entry.size,
                    destConnectionId: destConnectionId,
                    destPath: destChild,
                    transfers: transfers
                )
            }
        }
    }

    /// mkdir on the destination host, tolerating "already exists" —
    /// dropping a directory onto a host that already has one of the
    /// same name merges contents, mirroring how Finder drops into the
    /// remote pane behave.
    private static func createDestinationDirectory(
        connectionId: String,
        path: String
    ) async throws {
        do {
            try await BridgeManager.shared.sftpCreateDir(connectionId: connectionId, path: path)
        } catch let err as SftpError {
            if case let .Other(detail) = err,
               detail.lowercased().contains("exist")
            {
                return
            }
            throw err
        }
    }

    // MARK: - Size estimation

    /// Total byte size of a remote directory tree, walked breadth-first
    /// via SFTP listings, bailing out as soon as `threshold` is reached
    /// — the caller only needs to know "big or small", so a 200 GB tree
    /// shouldn't cost a full walk. Listing errors skip that branch
    /// (under-counting degrades to the relay path, which surfaces its
    /// own errors).
    static func estimatedSize(
        connectionId: String,
        rootPath: String,
        atLeast threshold: UInt64
    ) async -> UInt64 {
        var total: UInt64 = 0
        var pending = [rootPath]

        while !pending.isEmpty {
            let dir = pending.removeFirst()
            guard let entries = try? await BridgeManager.shared.sftpListDir(
                connectionId: connectionId,
                path: dir
            ) else { continue }

            for entry in entries {
                switch entry.kind {
                case .directory:
                    pending.append(joinRemotePath(dir, entry.name))
                case .file, .symlink:
                    total += entry.size
                }
                if total >= threshold {
                    return total
                }
            }
        }
        return total
    }

    // MARK: - Paths

    /// Join a remote directory and a child name. `"."` and `""` mean
    /// the SFTP session root, where a bare name resolves correctly.
    static func joinRemotePath(_ dir: String, _ name: String) -> String {
        if dir == "." || dir.isEmpty {
            return name
        }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// Per-relay unique temp location preserving the original filename
    /// (helps debugging and keeps the upload leg's overlay row legible).
    static func temporaryRelayURL(for name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-relay", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func cleanUpRelayFile(_ url: URL) {
        // Remove the per-relay UUID directory, not just the file, so
        // /tmp doesn't accumulate empty wrappers.
        let wrapper = url.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: wrapper)
        } catch {
            logger.debug("Relay temp cleanup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }
}
