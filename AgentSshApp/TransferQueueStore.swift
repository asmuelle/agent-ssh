import AppKit
import Combine
import Foundation
import AgentSshMacOS
import OSLog

/// Owns the list of in-flight and completed SFTP transfers. The
/// `FileBrowserView` enqueues from download / upload actions.
///
/// Architecture: each enqueue spawns a `Task.detached` that calls the
/// FFI synchronously (the Rust side blocks on its Tokio runtime). The
/// FFI emits `TransferProgress` events on every chunk; we observe them
/// via `AgentSshEventBus` and update the matching `Transfer` by
/// `(connectionId, remotePath)` — the same tuple Rust stamps onto each
/// event. The Task awaits completion, then sets the transfer's final
/// state.
///
/// **Concurrency cap:** transfers are run sequentially per connection
/// (the SFTP subsystem on a single SSH session can't multiplex). Cross-
/// connection transfers run concurrently. Tracking lives in
/// `runningPerConnection`.
@MainActor
final class TransferQueueStore: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []

    private let logger = Logger(subsystem: "com.mc-ssh", category: "transfers")
    private var cancellables = Set<AnyCancellable>()
    /// Per-connection serial pump. Each connection has its own `Task`
    /// chain so transfers to host A don't block transfers to host B.
    private var runningPerConnection: [String: Task<Void, Never>] = [:]

    /// Buffer of recently-completed download URLs awaiting a single
    /// Finder reveal. Coalesces N rapid completions (e.g. a multi-row
    /// download batch) into one `activateFileViewerSelecting` call so
    /// Finder is fronted once with all files selected, instead of
    /// thrashing once per transfer.
    private var pendingReveals: [URL] = []
    private var revealTask: Task<Void, Never>?
    private static let revealDebounce: UInt64 = 500_000_000  // 500 ms

    /// Live Activity persistence is a full read-modify-write of an App
    /// Group JSON file (plus a Watch-status file). Doing that on the main
    /// actor for every SFTP progress event — dozens per second during a
    /// transfer — is the primary cause of UI stalls. We funnel all writes
    /// through a serial actor (off-main, no concurrent file races) and
    /// coalesce the high-frequency progress writes to ~4 Hz. Terminal and
    /// enqueue states still write immediately (but still off-main).
    private let liveActivityWriter = LiveActivityWriter()
    private var pendingProgressSnapshots: [String: LiveActivitySnapshot] = [:]
    private var liveActivityFlushScheduled = false
    private static let liveActivityThrottle: UInt64 = 250_000_000  // 250 ms → 4 Hz

    init() {
        AgentSshEventBus.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case .transferProgress(let connectionId, let payload) = event else { return }
                self?.handleProgress(connectionId: connectionId, payload: payload)
            }
            .store(in: &cancellables)
    }

    // MARK: - Enqueue

    func enqueueDownload(
        connectionId: String,
        remotePath: String,
        localPath: String,
        expectedSize: UInt64,
        revealsInFinder: Bool = true,
        onCompleted: ((Bool) -> Void)? = nil
    ) {
        let transfer = Transfer(
            id: UUID(),
            connectionId: connectionId,
            kind: .download,
            remotePath: remotePath,
            localPath: localPath,
            totalBytes: expectedSize,
            bytesTransferred: 0,
            status: .queued,
            revealsInFinder: revealsInFinder,
            onCompleted: onCompleted
        )
        transfers.append(transfer)
        publishLiveActivity(for: transfer)
        scheduleRun(for: connectionId)
    }

    func enqueueUpload(
        connectionId: String,
        localPath: String,
        remotePath: String,
        onCompleted: ((Bool) -> Void)? = nil
    ) {
        // Stat client-side so the queue UI can show a total even before
        // the first progress event arrives. Falls back to 0 (indeterminate
        // progress bar) if the file's gone or unreadable — the FFI will
        // surface the real error on the actual upload attempt.
        let totalBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.uint64Value
        }()

        let transfer = Transfer(
            id: UUID(),
            connectionId: connectionId,
            kind: .upload,
            remotePath: remotePath,
            localPath: localPath,
            totalBytes: totalBytes,
            bytesTransferred: 0,
            status: .queued,
            onCompleted: onCompleted
        )
        transfers.append(transfer)
        publishLiveActivity(for: transfer)
        scheduleRun(for: connectionId)
    }

    func clearCompleted() {
        transfers.removeAll {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
    }

    /// Cancel a transfer. For `.queued` items the FFI hasn't been
    /// called yet — we just remove the row. For `.inProgress` items
    /// the bridge signals the running transfer; the running Task observes
    /// `SftpError::Cancelled` and marks the row.
    func cancel(transferId: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        switch transfers[idx].status {
        case .queued:
            removeLiveActivity(for: transfers[idx])
            let removed = transfers.remove(at: idx)
            removed.onCompleted?(false)
        case .inProgress:
            // Fire-and-forget: the running transfer's Task observes
            // `SftpError::Cancelled` and flips status to `.cancelled`.
            Task { await BridgeManager.shared.sftpCancel(transferId: transferId) }
        case .completed, .failed, .cancelled:
            break
        }
    }

    // MARK: - Per-connection run loop

    /// Ensure a single Task drains the queue for this connection. Runs
    /// each pending transfer sequentially via the bridge; on completion or
    /// failure, picks up the next pending one for the same connection.
    private func scheduleRun(for connectionId: String) {
        // If a runner is already in flight for this connection, the
        // existing loop will pick up the newly-appended transfer on its
        // next iteration. No new task needed.
        if runningPerConnection[connectionId] != nil { return }

        let task = Task { @MainActor [weak self] in
            while let self {
                guard let nextIdx = self.transfers.firstIndex(where: {
                    $0.connectionId == connectionId && $0.status == .queued
                }) else { break }

                self.transfers[nextIdx].status = .inProgress
                let snapshot = self.transfers[nextIdx]
                self.publishLiveActivity(for: snapshot)
                await self.runTransfer(snapshot)
            }
            self?.runningPerConnection[connectionId] = nil
        }
        runningPerConnection[connectionId] = task
    }

    private func runTransfer(_ transfer: Transfer) async {
        do {
            let bytes: UInt64
            switch transfer.kind {
            case .download:
                bytes = try await BridgeManager.shared.sftpDownload(
                    transferId: transfer.id,
                    connectionId: transfer.connectionId,
                    remotePath: transfer.remotePath,
                    localPath: transfer.localPath,
                    expectedSize: transfer.totalBytes
                )
            case .upload:
                bytes = try await BridgeManager.shared.sftpUpload(
                    transferId: transfer.id,
                    connectionId: transfer.connectionId,
                    localPath: transfer.localPath,
                    remotePath: transfer.remotePath
                )
            }

            guard let idx = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
            transfers[idx].bytesTransferred = bytes
            transfers[idx].status = .completed
            publishLiveActivity(for: transfers[idx])
            logger.info("Transfer completed: \(transfer.remotePath, privacy: .public) (\(bytes) bytes)")

            // Reveal the downloaded file in Finder. Coalesce — if more
            // downloads finish within the debounce window they get
            // batched into a single Finder activation with all files
            // selected, instead of fronting Finder once per file.
            // Relay legs of a server→server copy land in a temp dir
            // the user never asked to see, so they opt out.
            if transfer.kind == .download && transfer.revealsInFinder {
                scheduleReveal(URL(fileURLWithPath: transfer.localPath))
            }
            transfers[idx].onCompleted?(true)
        } catch let error as SftpError {
            guard let idx = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
            switch error {
            case .Cancelled:
                transfers[idx].status = .cancelled
                publishLiveActivity(for: transfers[idx])
                logger.info("Transfer cancelled: \(transfer.remotePath, privacy: .public)")
            default:
                transfers[idx].status = .failed
                transfers[idx].error = error.localizedDescription
                publishLiveActivity(for: transfers[idx])
                logger.error("Transfer failed for \(transfer.remotePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            transfers[idx].onCompleted?(false)
        } catch {
            guard let idx = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
            transfers[idx].status = .failed
            transfers[idx].error = error.localizedDescription
            publishLiveActivity(for: transfers[idx])
            logger.error("Transfer failed for \(transfer.remotePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            transfers[idx].onCompleted?(false)
        }
    }

    // MARK: - Coalesced reveal

    private func scheduleReveal(_ url: URL) {
        pendingReveals.append(url)
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.revealDebounce)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let urls = self.pendingReveals
                self.pendingReveals.removeAll()
                self.revealTask = nil
                guard !urls.isEmpty else { return }
                // `activateFileViewerSelecting` takes an array — when
                // every URL shares a parent, Finder opens that parent
                // and selects all of them. Mixed-parent batches open
                // a "All My Files"-style selection, which is rare in
                // practice (single-batch UI flows download into one
                // destination directory).
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    // MARK: - Progress

    private func handleProgress(connectionId: String, payload: String) {
        // Rust sends `{"path": ..., "bytesTransferred": ..., "totalBytes": ...}`
        struct Wire: Decodable {
            let path: String
            let bytesTransferred: UInt64
            let totalBytes: UInt64
        }
        guard let data = payload.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }

        // Only update transfers in flight — completed / failed shouldn't
        // appear to make backwards progress if a stale event arrives.
        guard let idx = transfers.firstIndex(where: {
            $0.connectionId == connectionId
                && $0.remotePath == wire.path
                && $0.status == .inProgress
        }) else { return }

        transfers[idx].bytesTransferred = wire.bytesTransferred
        if wire.totalBytes > 0 && transfers[idx].totalBytes == 0 {
            transfers[idx].totalBytes = wire.totalBytes
        }
        throttledPublishLiveActivity(for: transfers[idx])
    }

    // MARK: - Live Activity persistence (off-main, coalesced)

    /// Immediate, durable write for low-frequency state changes (enqueue,
    /// completed / failed / cancelled). Still hops off the main actor.
    private func publishLiveActivity(for transfer: Transfer) {
        let snapshot = transfer.liveActivitySnapshot
        // A definitive state supersedes any throttled progress write queued
        // for the same id, so drop the pending one to avoid a stale overwrite.
        pendingProgressSnapshots[snapshot.id] = nil
        Task { await liveActivityWriter.upsert(snapshot) }
    }

    /// High-frequency progress path: keep only the latest snapshot per id
    /// and flush the batch in a single file write at most every 250 ms.
    private func throttledPublishLiveActivity(for transfer: Transfer) {
        let snapshot = transfer.liveActivitySnapshot
        pendingProgressSnapshots[snapshot.id] = snapshot
        guard !liveActivityFlushScheduled else { return }
        liveActivityFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveActivityThrottle)
            guard let self else { return }
            self.liveActivityFlushScheduled = false
            let batch = Array(self.pendingProgressSnapshots.values)
            self.pendingProgressSnapshots.removeAll()
            guard !batch.isEmpty else { return }
            await self.liveActivityWriter.upsertBatch(batch)
        }
    }

    private func removeLiveActivity(for transfer: Transfer) {
        let id = transfer.liveActivitySnapshot.id
        pendingProgressSnapshots[id] = nil
        Task { await liveActivityWriter.remove(id: id) }
    }
}

/// Serializes Live Activity snapshot persistence off the main actor. Every
/// `upsert`/`remove` is a full read-modify-write of an App Group JSON file;
/// funnelling them through one actor keeps that I/O off the UI thread and
/// stops concurrent writers from racing on the file.
actor LiveActivityWriter {
    private let store = LiveActivitySnapshotStore()

    func upsert(_ snapshot: LiveActivitySnapshot) {
        try? store.upsert(snapshot)
    }

    /// Applies a batch of snapshots in a single load-modify-save, so a burst
    /// of coalesced progress events costs one file write, not one per event.
    func upsertBatch(_ snapshots: [LiveActivitySnapshot]) {
        guard !snapshots.isEmpty, var file = try? store.load() else { return }
        for snapshot in snapshots {
            if let index = file.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                file.snapshots[index] = snapshot
            } else {
                file.snapshots.append(snapshot)
            }
        }
        file.generatedAt = Date()
        try? store.save(file)
    }

    func remove(id: String) {
        try? store.remove(id: id)
    }
}

// MARK: - Models

struct Transfer: Identifiable {
    enum Kind { case download, upload }
    enum Status { case queued, inProgress, completed, failed, cancelled }

    let id: UUID
    let connectionId: String
    let kind: Kind
    let remotePath: String
    let localPath: String
    var createdAt: Date = Date()
    var totalBytes: UInt64
    var bytesTransferred: UInt64
    var status: Status
    var error: String?
    /// Downloads front Finder with the result by default; relay legs
    /// of a server→server copy (temp-dir destinations) turn this off.
    var revealsInFinder: Bool = true
    /// Fired exactly once when the transfer reaches a terminal state:
    /// `true` for `.completed`, `false` for `.failed` / `.cancelled`
    /// (including queued items removed before they ever ran). Used by
    /// `RemoteCopyCoordinator` to chain the upload leg of a
    /// server→server copy onto its download leg and to clean up temp
    /// files. Runs on the main actor.
    var onCompleted: ((Bool) -> Void)?

    var progress: Double {
        totalBytes > 0 ? Double(bytesTransferred) / Double(totalBytes) : 0
    }

    var displayName: String {
        // Last path component of whichever side is the "destination
        // identity" — for downloads that's the remote name (what the
        // user picked), for uploads also the remote (where it landed).
        (remotePath as NSString).lastPathComponent
    }

    var liveActivitySnapshot: LiveActivitySnapshot {
        LiveActivitySnapshot(
            id: "transfer:\(id.uuidString)",
            connectionId: connectionId,
            kind: .transfer,
            title: "\(kind.liveActivityTitle) \(displayName)",
            subtitle: remotePath,
            state: status.liveActivityState,
            progress: totalBytes > 0 ? progress : nil,
            createdAt: createdAt,
            startedAt: status == .queued ? nil : createdAt,
            updatedAt: Date(),
            endedAt: status.liveActivityState.isActive ? nil : Date(),
            errorMessage: error,
            openURL: "agent-ssh://terminal/\(connectionId)",
            metadata: [
                "remotePath": remotePath,
                "localPath": localPath,
                "bytesTransferred": String(bytesTransferred),
                "totalBytes": String(totalBytes),
            ]
        )
    }
}

private extension Transfer.Kind {
    var liveActivityTitle: String {
        switch self {
        case .download:
            return "Download"
        case .upload:
            return "Upload"
        }
    }
}

private extension Transfer.Status {
    var liveActivityState: LiveActivityOperationState {
        switch self {
        case .queued:
            return .queued
        case .inProgress:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }
}
