import AgentSshMacOS
import SwiftUI
import UniformTypeIdentifiers

/// Multi-host file workspace: one `FileBrowserView` pane per connected
/// host, arranged in a grid on the main panel. Replaces the per-tab
/// workspace the same way the Dashboard does, toggled from the tab
/// strip.
///
/// Cross-server copy: every browser row is already draggable as a
/// `RemoteFileDrag` (the payload the dual-pane layout uses for
/// remote→local copies). Each pane here is additionally a drop target
/// for those payloads — dropping a row from host A onto host B's pane
/// relays the file (or directory tree) through the Mac via
/// `RemoteCopyCoordinator` into whatever directory B's pane is
/// currently showing. Drops from the same host are ignored rather
/// than degenerating into a same-connection copy.
struct FilesPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @EnvironmentObject var transfers: TransferQueueStore

    /// Current remote cwd per pane (keyed by tab id), fed by each
    /// browser's `onPathChange`. Read when a cross-server drop lands
    /// so the copy goes where the user is looking, not the SFTP root.
    @State private var panePaths: [UUID: String] = [:]
    /// Pane (tab id) a cross-server drag is currently hovering over.
    @State private var dropTargetPane: UUID?
    @State private var copyError: String?

    /// In-flight / finished direct server→server copies (status cards).
    @StateObject private var directCopies = DirectCopyStore()
    /// A drop big enough to offer the direct path, parked while the
    /// user picks relay vs. direct in the confirmation dialog.
    @State private var pendingLargeCopy: PendingLargeCopy?

    /// Payloads at or above this size get the "copy directly?" offer —
    /// below it the relay's 2× cost is cheaper than a dialog.
    static let directCopyOfferThreshold: UInt64 = 500 * 1024 * 1024

    struct PendingLargeCopy: Identifiable {
        let id = UUID()
        let drag: RemoteFileDrag
        let destConnectionId: String
        let destProfile: ConnectionProfile
        let destDir: String
        let estimatedBytes: UInt64
        /// Direct copy drives `ssh-keygen` / `sftp` on the source via
        /// its shell — SFTP-only source tabs can't, so they only get
        /// the relay button.
        let sourceLabel: String
        let canCopyDirectly: Bool
    }

    /// Every connected tab — SSH and SFTP-only kinds both carry an
    /// SFTP subsystem we can browse.
    private var fileTabs: [TerminalTab] {
        tabsStore.tabs
            .filter { $0.status == .connected }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        Group {
            if fileTabs.isEmpty {
                emptyState
            } else {
                paneGrid
            }
        }
        .overlay {
            TransferProgressOverlay()
                .environmentObject(transfers)
        }
        .overlay(alignment: .bottomTrailing) {
            DirectCopyStatusList(store: directCopies)
        }
        .confirmationDialog(
            "Large copy",
            isPresented: Binding(
                get: { pendingLargeCopy != nil },
                set: { if !$0 { pendingLargeCopy = nil } }
            ),
            presenting: pendingLargeCopy
        ) { pending in
            if pending.canCopyDirectly {
                Button("Copy Directly (Server → Server)") {
                    DirectServerCopyCoordinator.copy(
                        drag: pending.drag,
                        sourceLabel: pending.sourceLabel,
                        destProfile: pending.destProfile,
                        destConnectionId: pending.destConnectionId,
                        destDir: pending.destDir,
                        store: directCopies
                    )
                }
            }
            Button("Copy via This Mac") {
                RemoteCopyCoordinator.copy(
                    drag: pending.drag,
                    toConnection: pending.destConnectionId,
                    destDir: pending.destDir,
                    transfers: transfers,
                    onError: { message in copyError = message }
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(min(pending.estimatedBytes, UInt64(Int64.max))),
                countStyle: .file
            )
            if pending.canCopyDirectly {
                Text("""
                \(pending.drag.name) is \(size)\(pending.drag.isDirectory ? " or more" : ""). \
                Direct copy pushes it straight from \(pending.sourceLabel) to \(pending.destProfile.name) \
                using a temporary SFTP-only key that is removed afterwards — \
                it requires \(pending.sourceLabel) to reach \(pending.destProfile.name) directly. \
                Copying via this Mac always works but transfers the data twice.
                """)
            } else {
                Text("""
                \(pending.drag.name) is \(size)\(pending.drag.isDirectory ? " or more" : "") \
                and will be relayed through this Mac (the source host has no shell access \
                for a direct server→server push).
                """)
            }
        }
        .alert(
            "Copy failed",
            isPresented: Binding(
                get: { copyError != nil },
                set: { if !$0 { copyError = nil } }
            )
        ) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "")
        }
    }

    // MARK: - Grid

    /// Fixed row/column layout (no scroll view: `Table` needs real
    /// height, and operators want every host on screen at once — same
    /// rationale as the dashboard). Panes split the panel evenly.
    private var paneGrid: some View {
        let tabs = fileTabs
        let columns = Self.columnCount(forPaneCount: tabs.count)
        let rows = stride(from: 0, to: tabs.count, by: columns).map {
            Array(tabs[$0 ..< min($0 + columns, tabs.count)])
        }

        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { tab in
                        pane(for: tab)
                    }
                    // Keep a short last row's panes the same width as
                    // the full rows above it.
                    ForEach(0 ..< (columns - row.count), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// 1 host fills the panel; 2 sit side by side; 3–4 form a 2×2;
    /// beyond that, three columns and as many rows as needed.
    static func columnCount(forPaneCount count: Int) -> Int {
        switch count {
        case ..<2: return 1
        case 2: return 2
        case 3, 4: return 2
        default: return 3
        }
    }

    @ViewBuilder
    private func pane(for tab: TerminalTab) -> some View {
        let isDropTarget = dropTargetPane == tab.id

        FileBrowserView(
            connectionId: tab.connectionId,
            connectionLabel: tab.profile.name,
            canEditPermissions: tab.effectiveKind.supportsTerminal,
            canRunRemoteCommands: tab.effectiveKind.supportsTerminal,
            onPathChange: { panePaths[tab.id] = $0 }
        )
        .background(MidnightMacDesign.ColorToken.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                .strokeBorder(
                    isDropTarget ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        // Cross-server drop target. `RemoteFileDrag` travels as tagged
        // plain text (see its doc comment for why not a custom UTType),
        // so accept text drops and decode; non-payload text is ignored.
        // Folder rows inside the pane keep their own URL drop targets
        // for Finder uploads — different payload type, no conflict.
        .onDrop(
            of: [UTType.plainText],
            isTargeted: Binding(
                get: { dropTargetPane == tab.id },
                set: { hovering in
                    dropTargetPane = hovering ? tab.id : (dropTargetPane == tab.id ? nil : dropTargetPane)
                }
            )
        ) { providers in
            acceptCrossServerDrop(providers, onto: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No connected hosts to browse.")
                .font(MidnightMacDesign.FontToken.subheadline)
                .foregroundStyle(.secondary)
            Text("Connect to a host from the sidebar and its files appear here.")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Cross-server drop

    private func acceptCrossServerDrop(_ providers: [NSItemProvider], onto tab: TerminalTab) -> Bool {
        let destConnectionId = tab.connectionId

        let textProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        guard !textProviders.isEmpty else { return false }

        let destDir = panePaths[tab.id] ?? "."

        for provider in textProviders {
            provider.loadItem(
                forTypeIdentifier: UTType.plainText.identifier,
                options: nil
            ) { item, _ in
                let raw: String?
                if let string = item as? String {
                    raw = string
                } else if let string = item as? NSString {
                    raw = string as String
                } else if let data = item as? Data {
                    raw = String(data: data, encoding: .utf8)
                } else {
                    raw = nil
                }

                guard let raw,
                      let drag = RemoteFileDrag.decodePasteboardString(raw)
                else { return }

                DispatchQueue.main.async {
                    routeCrossServerCopy(drag: drag, destTab: tab, destDir: destDir)
                }
            }
        }
        return true
    }

    /// Decide relay-now vs. offer-direct. Small payloads relay
    /// immediately (today's behaviour); payloads at or above the
    /// threshold park in `pendingLargeCopy` for the user to choose.
    /// Directory sizes are estimated with an early-bail walk so the
    /// check costs listings only until the threshold is proven.
    private func routeCrossServerCopy(drag: RemoteFileDrag, destTab: TerminalTab, destDir: String) {
        guard drag.connectionId != destTab.connectionId else { return }

        Task {
            let estimated: UInt64
            if drag.isDirectory {
                estimated = await RemoteCopyCoordinator.estimatedSize(
                    connectionId: drag.connectionId,
                    rootPath: drag.remotePath,
                    atLeast: Self.directCopyOfferThreshold
                )
            } else {
                estimated = drag.size
            }

            guard estimated >= Self.directCopyOfferThreshold else {
                RemoteCopyCoordinator.copy(
                    drag: drag,
                    toConnection: destTab.connectionId,
                    destDir: destDir,
                    transfers: transfers,
                    onError: { message in copyError = message }
                )
                return
            }

            let sourceTab = tabsStore.tabs.first { $0.connectionId == drag.connectionId }
            pendingLargeCopy = PendingLargeCopy(
                drag: drag,
                destConnectionId: destTab.connectionId,
                destProfile: destTab.profile,
                destDir: destDir,
                estimatedBytes: estimated,
                sourceLabel: sourceTab?.profile.name ?? "the source host",
                canCopyDirectly: sourceTab?.effectiveKind.supportsTerminal == true
                    && sourceTab?.status == .connected
            )
        }
    }
}

// MARK: - Direct copy status cards

/// Compact bottom-trailing stack showing each direct server→server
/// copy: current step with a spinner while running, a green check or
/// red failure (with detail) when done. Finished cards stay until
/// dismissed — a transfer the user can't see complete is a transfer
/// they'll re-run.
private struct DirectCopyStatusList: View {
    @ObservedObject var store: DirectCopyStore

    var body: some View {
        if !store.copies.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(store.copies) { copy in
                    card(for: copy)
                }
            }
            .padding(12)
        }
    }

    private func card(for copy: DirectCopyStore.DirectCopy) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch copy.status {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(copy.name) — \(copy.sourceLabel) → \(copy.destLabel)")
                    .font(MidnightMacDesign.FontToken.subheadline)
                    .lineLimit(1)

                switch copy.status {
                case let .running(step):
                    Text(step)
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                case .completed:
                    Text("Done")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message)
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }
            }

            if isFinished(copy) {
                Button {
                    store.dismiss(copy.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func isFinished(_ copy: DirectCopyStore.DirectCopy) -> Bool {
        switch copy.status {
        case .running: return false
        case .completed, .failed: return true
        }
    }
}
