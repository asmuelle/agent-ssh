import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileFileBrowserView: View {
    let profileId: String
    let connectionId: String
    let profileName: String
    var initialPath: String? = nil

    @State private var path = "."
    @State private var entries: [FfiFileEntry] = []
    @State private var selectedName: String?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var editorDocument: MobileRemoteFileDocument?
    @State private var loadingEditorPath: String?
    @State private var namePrompt: MobileFileNamePrompt?
    @State private var deleteTarget: MobileRemoteFileRow?
    @State private var showingImporter = false
    @State private var exportItem: MobileFileExport?

    private var rows: [MobileRemoteFileRow] {
        entries
            .sorted { lhs, rhs in
                if lhs.kind == .directory, rhs.kind != .directory { return true }
                if lhs.kind != .directory, rhs.kind == .directory { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { entry in
                MobileRemoteFileRow(
                    remotePath: absolutePath(joining: entry.name),
                    entry: entry
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pathBar

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            fileList
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            if let initialPath, !initialPath.isEmpty {
                path = initialPath
            }
            await refresh()
            await processQueuedBackgroundOperations()
        }
        .onChange(of: initialPath) { _, newValue in
            guard let newValue, !newValue.isEmpty, newValue != path else { return }
            path = newValue
            Task { await refresh() }
        }
        .sheet(item: $editorDocument) { document in
            MobileRemoteFileEditorView(
                document: document,
                onSave: { content in
                    try await MobileSFTPBridge.shared.saveRemoteTextFile(
                        connectionId: document.connectionId,
                        remotePath: document.remotePath,
                        fileName: document.fileName,
                        content: content
                    )
                },
                onSaved: {
                    statusMessage = "Saved \(document.fileName)."
                    Task { await refresh() }
                }
            )
        }
        .sheet(item: $namePrompt) { prompt in
            MobileFileNamePromptSheet(
                prompt: prompt,
                onCancel: { namePrompt = nil },
                onCommit: { value in
                    namePrompt = nil
                    prompt.onCommit(value)
                }
            )
            .presentationDetents([.height(190)])
        }
        .sheet(item: $exportItem) { item in
            MobileShareSheet(url: item.url)
        }
        .confirmationDialog(
            "Delete item?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                self.deleteTarget = nil
                delete(row: deleteTarget)
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if deleteTarget?.entry.kind == .directory {
                Text("Directories are removed recursively. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                upload(urls: urls)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Files", systemImage: "folder")
                    .font(.headline)
                Text(profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading || isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                navigateUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(path == "." || path == "/" || isLoading)
            .accessibilityLabel("Up")

            Text(displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .accessibilityLabel("Refresh")

            Button {
                presentNewFolderPrompt()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(isWorking)
            .accessibilityLabel("New folder")

            Button {
                showingImporter = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(isWorking)
            .accessibilityLabel("Upload")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var fileList: some View {
        if rows.isEmpty, !isLoading {
            ContentUnavailableView(
                "No Files",
                systemImage: "folder",
                description: Text("This remote directory is empty.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
            .dropDestination(for: URL.self) { items, _ in
                if !items.isEmpty { upload(urls: items) }
                return true
            }
        } else {
            List(rows) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowBackground(
                        selectedName == row.entry.name
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
            }
            .listStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 420)
            .refreshable {
                await refresh()
            }
            .dropDestination(for: URL.self) { items, _ in
                if !items.isEmpty { upload(urls: items) }
                return true
            }
        }
    }

    private func rowView(_ row: MobileRemoteFileRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: row.entry.kind))
                .foregroundStyle(iconTint(for: row.entry.kind))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.entry.name)
                        .font(.body)
                        .lineLimit(1)

                    if loadingEditorPath == row.remotePath {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(rowSubtitle(row.entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if row.entry.kind == .file, isEditableFile(row.entry) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedName = row.entry.name
        }
        .onTapGesture(count: 2) {
            activate(row)
        }
        .contextMenu {
            contextMenu(for: row)
        }
    }

    @ViewBuilder
    private func contextMenu(for row: MobileRemoteFileRow) -> some View {
        if row.entry.kind == .directory {
            Button("Open") { navigate(into: row.entry.name) }
        } else if isEditableFile(row.entry) {
            Button("Open in Editor") { openEditor(row) }
        }

        if row.entry.kind == .file {
            Button("Download") { download(row) }
        }

        if row.entry.kind == .directory {
            Button("Keep Offline") { keepOffline(row) }
        }

        Button("Rename") { presentRenamePrompt(for: row) }
        Button("Delete", role: .destructive) { deleteTarget = row }
    }

    private var displayPath: String {
        path == "." ? "~" : path
    }

    private func rowSubtitle(_ entry: FfiFileEntry) -> String {
        let size = entry.kind == .directory
            ? "Directory"
            : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        let permissions = entry.permissions ?? "---"
        if let modified = entry.modified, !modified.isEmpty {
            return "\(size) - \(permissions) - \(modified)"
        }
        return "\(size) - \(permissions)"
    }

    private func iconName(for kind: FfiFileKind) -> String {
        switch kind {
        case .directory:
            return "folder.fill"
        case .symlink:
            return "link"
        case .file:
            return "doc"
        }
    }

    private func iconTint(for kind: FfiFileKind) -> Color {
        switch kind {
        case .directory:
            return .blue
        case .symlink:
            return .purple
        case .file:
            return .secondary
        }
    }

    private func activate(_ row: MobileRemoteFileRow) {
        selectedName = row.entry.name
        switch row.entry.kind {
        case .directory:
            navigate(into: row.entry.name)
        case .file:
            if isEditableFile(row.entry) {
                openEditor(row)
            } else {
                download(row)
            }
        case .symlink:
            selectedName = row.entry.name
        }
    }

    private func navigate(into name: String) {
        path = absolutePath(joining: name)
        selectedName = nil
        Task { await refresh() }
    }

    private func navigateUp() {
        guard path != "." && path != "/" else { return }

        if let lastSlash = path.lastIndex(of: "/") {
            let parent = String(path[..<lastSlash])
            path = parent.isEmpty ? "/" : parent
        } else {
            path = "."
        }

        selectedName = nil
        Task { await refresh() }
    }

    private func absolutePath(joining name: String) -> String {
        if path == "." {
            return name
        }
        return path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private func isEditableFile(_ entry: FfiFileEntry) -> Bool {
        guard entry.kind == .file else { return false }
        if entry.name.hasPrefix("."), entry.name != ".", entry.name != ".." {
            return true
        }

        switch (entry.name as NSString).pathExtension.lowercased() {
        case "yaml", "yml", "txt", "sh", "sql", "service":
            return true
        default:
            return false
        }
    }

    private func openEditor(_ row: MobileRemoteFileRow) {
        guard isEditableFile(row.entry) else { return }
        guard row.entry.size <= 1_048_576 else {
            errorMessage = MobileSFTPBridgeError
                .fileTooLarge(fileName: row.entry.name, size: row.entry.size)
                .localizedDescription
            return
        }

        selectedName = row.entry.name
        loadingEditorPath = row.remotePath
        errorMessage = nil

        Task {
            do {
                let content = try await MobileSFTPBridge.shared.readRemoteTextFile(
                    connectionId: connectionId,
                    remotePath: row.remotePath,
                    fileName: row.entry.name,
                    expectedSize: row.entry.size
                )
                await MainActor.run {
                    loadingEditorPath = nil
                    editorDocument = MobileRemoteFileDocument(
                        connectionId: connectionId,
                        remotePath: row.remotePath,
                        fileName: row.entry.name,
                        initialContent: content
                    )
                }
            } catch {
                await MainActor.run {
                    loadingEditorPath = nil
                    errorMessage = "Could not open \(row.entry.name): \(describe(error))"
                }
            }
        }
    }

    private func download(_ row: MobileRemoteFileRow) {
        guard row.entry.kind == .file else { return }
        selectedName = row.entry.name
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                let url = try await MobileSFTPBridge.shared.downloadForExport(
                    connectionId: connectionId,
                    remotePath: row.remotePath,
                    fileName: row.entry.name,
                    expectedSize: row.entry.size
                )
                await MainActor.run {
                    isWorking = false
                    exportItem = MobileFileExport(url: url)
                    statusMessage = "Downloaded \(row.entry.name)."
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "Could not download \(row.entry.name): \(describe(error))"
                }
            }
        }
    }

    private func upload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        let targetPath = path
        Task {
            var uploaded = 0
            var failures: [String] = []

            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory != true else {
                        failures.append("\(url.lastPathComponent): directory upload is not in the mobile MVP yet")
                        continue
                    }

                    let remotePath = join(path: targetPath, child: url.lastPathComponent)
                    _ = try await MobileSFTPBridge.shared.upload(
                        connectionId: connectionId,
                        localPath: url.path,
                        remotePath: remotePath
                    )
                    uploaded += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(describe(error))")
                }
            }

            await MainActor.run {
                isWorking = false
                if !failures.isEmpty {
                    errorMessage = "Upload finished with \(failures.count) failure\(failures.count == 1 ? "" : "s"): "
                        + failures.prefix(2).joined(separator: "; ")
                } else {
                    statusMessage = "Uploaded \(uploaded) file\(uploaded == 1 ? "" : "s")."
                }
                Task { await refresh() }
            }
        }
    }

    private func presentNewFolderPrompt() {
        namePrompt = MobileFileNamePrompt(
            title: "New Folder",
            prompt: "Folder name",
            initialValue: "untitled folder",
            confirmLabel: "Create"
        ) { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validateRemoteName(name) else { return }
            mutate(action: "create folder") {
                try await MobileSFTPBridge.shared.createDir(
                    connectionId: connectionId,
                    path: absolutePath(joining: name)
                )
            }
        }
    }

    private func presentRenamePrompt(for row: MobileRemoteFileRow) {
        namePrompt = MobileFileNamePrompt(
            title: "Rename",
            prompt: "New name",
            initialValue: row.entry.name,
            confirmLabel: "Rename"
        ) { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validateRemoteName(name), name != row.entry.name else { return }
            mutate(action: "rename") {
                try await MobileSFTPBridge.shared.rename(
                    connectionId: connectionId,
                    oldPath: row.remotePath,
                    newPath: absolutePath(joining: name)
                )
            }
        }
    }

    private func delete(row: MobileRemoteFileRow) {
        mutate(action: "delete") {
            switch row.entry.kind {
            case .directory:
                try await Self.deleteRecursive(connectionId: connectionId, path: row.remotePath)
            case .file, .symlink:
                try await MobileSFTPBridge.shared.deleteFile(
                    connectionId: connectionId,
                    path: row.remotePath
                )
            }
        }
    }

    private func keepOffline(_ row: MobileRemoteFileRow) {
        do {
            let integrationStore = PlatformIntegrationStore()
            var data = try integrationStore.load()
            let normalizedRemotePath = OfflineSFTPCacheItemRecord.normalizedRemotePath(row.remotePath)
            let cacheURL = try offlineCacheRootURL(folderId: existingOrNewOfflineFolderId(in: data, remotePath: normalizedRemotePath))
            let folder: OfflineSFTPFolderRecord

            if let index = data.offlineFolders.firstIndex(where: { $0.profileId == profileId && $0.remotePath == normalizedRemotePath }) {
                data.offlineFolders[index].syncState = .pending
                data.offlineFolders[index].lastError = nil
                data.offlineFolders[index].localCachePath = cacheURL.path
                folder = data.offlineFolders[index]
            } else {
                folder = OfflineSFTPFolderRecord(
                    id: cacheURL.lastPathComponent,
                    profileId: profileId,
                    remotePath: row.remotePath,
                    displayName: row.entry.name,
                    localCachePath: cacheURL.path,
                    syncState: .pending
                )
                data.offlineFolders.append(folder)
            }
            try integrationStore.save(data)

            let operation = BackgroundSSHOperationRecord(
                profileId: profileId,
                kind: .offlineFolderSync,
                requester: .app,
                status: .queued,
                title: "Sync \(row.entry.name) for offline access",
                remotePath: row.remotePath
            )
            try BackgroundSSHOperationStore().upsert(operation)
            statusMessage = "Syncing \(row.entry.name) for offline access..."
            syncOfflineFolder(folder, operationId: operation.id, syncRootRemotePath: row.remotePath)
        } catch {
            errorMessage = "Could not mark \(row.entry.name) for offline use: \(error.localizedDescription)"
        }
    }

    private func processQueuedBackgroundOperations() async {
        let store = BackgroundSSHOperationStore()
        do {
            let operations = try store.load().operations
                .filter { operation in
                    operation.profileId == profileId
                        && operation.status == .queued
                        && operation.requester != .shortcuts
                        && processableBackgroundOperationKinds.contains(operation.kind)
                }
                .sorted { $0.createdAt < $1.createdAt }
            guard !operations.isEmpty else { return }

            var completedCount = 0
            for operation in operations {
                do {
                    try store.update(id: operation.id, status: .running)
                    try await performBackgroundOperation(operation, store: store)
                    try store.update(id: operation.id, status: .completed)
                    completedCount += 1
                } catch {
                    try? store.update(
                        id: operation.id,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                }
            }

            if completedCount > 0 {
                await MainActor.run {
                    statusMessage = "Applied \(completedCount) queued file operation\(completedCount == 1 ? "" : "s")."
                    Task { await refresh() }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Could not process queued file operations: \(describe(error))"
            }
        }
    }

    private var processableBackgroundOperationKinds: Set<BackgroundSSHOperationKind> {
        [.shareUpload, .sftpUpload, .sftpCreateDirectory, .sftpRename, .sftpDelete, .fileProviderFetch]
    }

    private func performBackgroundOperation(
        _ operation: BackgroundSSHOperationRecord,
        store: BackgroundSSHOperationStore
    ) async throws {
        switch operation.kind {
        case .shareUpload, .sftpUpload:
            guard let localFilePath = operation.localFilePath, let remotePath = operation.remotePath else {
                throw MobileBackgroundOperationError.missingPath(operation.title)
            }
            let bytes = try await MobileSFTPBridge.shared.upload(
                connectionId: connectionId,
                localPath: localFilePath,
                remotePath: remotePath
            )
            try? store.update(
                id: operation.id,
                status: .running,
                progress: BackgroundSSHOperationProgress(
                    completedUnitCount: Int64(bytes),
                    totalUnitCount: Int64(bytes)
                )
            )
            if operation.metadata?["stagedUploadId"] != nil {
                try? FileManager.default.removeItem(atPath: localFilePath)
            }
        case .sftpCreateDirectory:
            guard let remotePath = operation.remotePath else {
                throw MobileBackgroundOperationError.missingPath(operation.title)
            }
            try await MobileSFTPBridge.shared.createDir(connectionId: connectionId, path: remotePath)
        case .sftpRename:
            guard let oldPath = operation.remotePath,
                  let filename = operation.metadata?["filename"],
                  !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MobileBackgroundOperationError.missingPath(operation.title)
            }
            try await MobileSFTPBridge.shared.rename(
                connectionId: connectionId,
                oldPath: oldPath,
                newPath: renamedRemotePath(oldPath: oldPath, filename: filename)
            )
        case .sftpDelete:
            guard let remotePath = operation.remotePath else {
                throw MobileBackgroundOperationError.missingPath(operation.title)
            }
            do {
                try await MobileSFTPBridge.shared.deleteFile(connectionId: connectionId, path: remotePath)
            } catch {
                try await MobileSFTPBridge.shared.deleteDir(connectionId: connectionId, path: remotePath)
            }
        case .fileProviderFetch:
            let target = try fileProviderFetchTarget(for: operation)
            try FileManager.default.createDirectory(
                at: target.localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = try await MobileSFTPBridge.shared.download(
                connectionId: connectionId,
                remotePath: target.remotePath,
                localPath: target.localURL.path,
                expectedSize: target.expectedSize
            )
            try? store.update(
                id: operation.id,
                status: .running,
                progress: BackgroundSSHOperationProgress(
                    completedUnitCount: Int64(bytes),
                    totalUnitCount: Int64(target.expectedSize)
                )
            )
            try updateFileProviderFetchManifest(
                folderId: target.folderId,
                remotePath: target.remotePath,
                localPath: target.localURL.path
            )
        case .runCommand, .sftpDownload, .offlineFolderSync, .shortcutRun, .portForward:
            break
        }
    }

    private func fileProviderFetchTarget(
        for operation: BackgroundSSHOperationRecord
    ) throws -> (folderId: String, remotePath: String, localURL: URL, expectedSize: UInt64) {
        guard let itemIdentifier = operation.itemIdentifier,
              case .item(let folderId, let itemRemotePath) = OfflineSFTPFileProviderIdentifier(rawValue: itemIdentifier) else {
            throw MobileBackgroundOperationError.missingPath(operation.title)
        }

        let integrations = try PlatformIntegrationStore().load()
        let manifest = try OfflineSFTPCacheManifestStore().load()
        guard let folder = integrations.offlineFolders.first(where: { $0.id == folderId }),
              let item = manifest.item(folderId: folderId, remotePath: itemRemotePath),
              item.fileType == .file else {
            throw MobileBackgroundOperationError.missingPath(operation.title)
        }

        let remotePath = operation.remotePath ?? item.remotePath
        let cacheRoot = try folder.localCachePath.map(URL.init(fileURLWithPath:))
            ?? offlineCacheRootURL(folderId: folderId)
        let localURL = try item.localCachePath.map(URL.init(fileURLWithPath:))
            ?? localCacheURL(
                cacheRoot: cacheRoot,
                rootRemotePath: folder.remotePath,
                remotePath: item.remotePath,
                isDirectory: false
            )

        return (folderId, remotePath, localURL, item.size)
    }

    private func updateFileProviderFetchManifest(
        folderId: String,
        remotePath: String,
        localPath: String
    ) throws {
        let store = OfflineSFTPCacheManifestStore()
        var manifest = try store.load()
        let normalized = OfflineSFTPCacheItemRecord.normalizedRemotePath(remotePath)
        guard let index = manifest.items.firstIndex(where: {
            $0.folderId == folderId && $0.remotePath == normalized
        }) else { return }
        manifest.items[index].localCachePath = localPath
        manifest.items[index].lastSyncedAt = Date()
        manifest.generatedAt = Date()
        try store.save(manifest)
    }

    private func renamedRemotePath(oldPath: String, filename: String) -> String {
        let cleanName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = oldPath.lastIndex(of: "/") else { return cleanName }
        let parent = oldPath[..<slash]
        if parent.isEmpty { return "/\(cleanName)" }
        return "\(parent)/\(cleanName)"
    }

    private func syncOfflineFolder(
        _ folder: OfflineSFTPFolderRecord,
        operationId: String,
        syncRootRemotePath: String
    ) {
        Task {
            do {
                try await syncOfflineFolderNow(
                    folder,
                    operationId: operationId,
                    syncRootRemotePath: syncRootRemotePath
                )
                await MainActor.run {
                    statusMessage = "\(folder.displayName) is available in Files."
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not sync \(folder.displayName): \(describe(error))"
                }
            }
        }
    }

    private func syncOfflineFolderNow(
        _ folder: OfflineSFTPFolderRecord,
        operationId: String,
        syncRootRemotePath: String
    ) async throws {
        let operationStore = BackgroundSSHOperationStore()
        let integrationStore = PlatformIntegrationStore()
        let manifestStore = OfflineSFTPCacheManifestStore()
        try operationStore.update(id: operationId, status: .running)

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
            var records: [OfflineSFTPCacheItemRecord] = []
            try await syncOfflineFolderContents(
                folderId: folder.id,
                rootRemotePath: syncRootRemotePath,
                currentRemotePath: syncRootRemotePath,
                cacheRoot: cacheRoot,
                records: &records,
                itemCount: &itemCount,
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
            try operationStore.update(
                id: operationId,
                status: .completed,
                progress: BackgroundSSHOperationProgress(
                    completedUnitCount: Int64(itemCount),
                    totalUnitCount: Int64(itemCount)
                )
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
            try? operationStore.update(
                id: operationId,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private func syncOfflineFolderContents(
        folderId: String,
        rootRemotePath: String,
        currentRemotePath: String,
        cacheRoot: URL,
        records: inout [OfflineSFTPCacheItemRecord],
        itemCount: inout Int,
        operationId: String
    ) async throws {
        let entries = try await MobileSFTPBridge.shared.listDir(
            connectionId: connectionId,
            path: currentRemotePath
        )

        for entry in entries {
            guard entry.name != "." && entry.name != ".." else { continue }
            itemCount += 1
            if itemCount > 2_000 {
                throw MobileOfflineFolderSyncError.tooManyItems(limit: 2_000)
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
                try await syncOfflineFolderContents(
                    folderId: folderId,
                    rootRemotePath: rootRemotePath,
                    currentRemotePath: remotePath,
                    cacheRoot: cacheRoot,
                    records: &records,
                    itemCount: &itemCount,
                    operationId: operationId
                )
            case .file:
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try await MobileSFTPBridge.shared.download(
                    connectionId: connectionId,
                    remotePath: remotePath,
                    localPath: localURL.path,
                    expectedSize: entry.size
                )
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

            try? BackgroundSSHOperationStore().update(
                id: operationId,
                status: .running,
                progress: BackgroundSSHOperationProgress(completedUnitCount: Int64(itemCount))
            )
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

    private func existingOrNewOfflineFolderId(in data: PlatformIntegrationStoreData, remotePath: String) -> String {
        let normalizedRemotePath = OfflineSFTPCacheItemRecord.normalizedRemotePath(remotePath)
        return data.offlineFolders.first(where: { $0.profileId == profileId && $0.remotePath == normalizedRemotePath })?.id
            ?? UUID().uuidString
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
            throw MobileOfflineFolderSyncError.invalidRemotePath(remote)
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

    private func mutate(action: String, work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                try await work()
                await MainActor.run {
                    isWorking = false
                    statusMessage = "\(action.capitalized) complete."
                    Task { await refresh() }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "Could not \(action): \(describe(error))"
                }
            }
        }
    }

    private static func deleteRecursive(connectionId: String, path: String) async throws {
        let entries = try await MobileSFTPBridge.shared.listDir(connectionId: connectionId, path: path)
        for entry in entries {
            let childPath = join(path: path, child: entry.name)
            switch entry.kind {
            case .directory:
                try await deleteRecursive(connectionId: connectionId, path: childPath)
            case .file, .symlink:
                try await MobileSFTPBridge.shared.deleteFile(connectionId: connectionId, path: childPath)
            }
        }
        try await MobileSFTPBridge.shared.deleteDir(connectionId: connectionId, path: path)
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        let requestedPath = path

        do {
            let result = try await MobileSFTPBridge.shared.listDir(
                connectionId: connectionId,
                path: requestedPath
            )
            guard path == requestedPath else { return }
            entries = result
            isLoading = false
        } catch {
            guard path == requestedPath else { return }
            entries = []
            isLoading = false
            errorMessage = describe(error)
        }
    }

    private func validateRemoteName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = MobileSFTPBridgeError.invalidRemoteName(name).localizedDescription
            return false
        }
        return true
    }

    private func describe(_ error: Error) -> String {
        if let sftpError = error as? SftpError {
            switch sftpError {
            case .NotConnected:
                return "Not connected to this host."
            case .Cancelled:
                return "Cancelled."
            case .Other(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }
}

private func join(path: String, child: String) -> String {
    if path == "." {
        return child
    }
    return path.hasSuffix("/") ? path + child : path + "/" + child
}

private struct MobileRemoteFileRow: Identifiable, Hashable {
    let remotePath: String
    let entry: FfiFileEntry

    var id: String {
        remotePath
    }
}

private enum MobileOfflineFolderSyncError: LocalizedError {
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

private enum MobileBackgroundOperationError: LocalizedError {
    case missingPath(String)

    var errorDescription: String? {
        switch self {
        case .missingPath(let title):
            return "\(title) is missing a local or remote path."
        }
    }
}

private struct MobileFileNamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    let initialValue: String
    let confirmLabel: String
    let onCommit: (String) -> Void
}

private struct MobileFileNamePromptSheet: View {
    let prompt: MobileFileNamePrompt
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var value: String
    @FocusState private var focused: Bool

    init(
        prompt: MobileFileNamePrompt,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.prompt = prompt
        self.onCancel = onCancel
        self.onCommit = onCommit
        _value = State(initialValue: prompt.initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(prompt.prompt) {
                    TextField("", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { commit() }
                }
            }
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.confirmLabel, action: commit)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                focused = true
            }
        }
    }

    private func commit() {
        onCommit(value)
    }
}

private struct MobileFileExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
