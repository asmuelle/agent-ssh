import SwiftUI

struct MobileTerminalPane: View {
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences

    let connectionId: String
    let profileName: String
    let remoteUsername: String

    @State private var generation: UInt64?
    @State private var terminalError: String?
    @State private var isStarting = false
    @State private var showingTerminalSettings = false
    @State private var showingCommandPalette = false
    @State private var showingTmuxManager = false
    @State private var terminalViewCommand: MobileTerminalViewCommand?
    @State private var currentDirectory: String?
    @State private var detectedPaths: [MobileTerminalDetectedPath] = []
    @State private var pathPreview: MobileTerminalPathPreview?
    @State private var pathExport: MobileTerminalPathExport?
    @State private var pathActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(profileName, systemImage: "terminal")
                    .font(MidnightMobileDesign.FontToken.headline)

                Spacer()

                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showingCommandPalette = true
                } label: {
                    Image(systemName: "command")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Terminal commands")

                terminalActionsMenu

                Button {
                    showingTerminalSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Terminal settings")
            }

            VStack(spacing: 0) {
                ZStack {
                    if let generation {
                        MobileTerminalView(
                            connectionId: connectionId,
                            ptyGeneration: generation,
                            themeId: terminalPreferences.themeId,
                            fontSize: terminalPreferences.clampedFontSize,
                            scrollbackLines: terminalPreferences.clampedScrollbackLines,
                            cursorStyleId: terminalPreferences.cursorStyleId,
                            mouseReporting: terminalPreferences.mouseReporting,
                            optionAsMeta: terminalPreferences.optionAsMeta,
                            copyOnSelect: terminalPreferences.copyOnSelect,
                            onOutput: handleTerminalOutput,
                            onCurrentDirectoryChange: { currentDirectory = $0 },
                            commandRequest: $terminalViewCommand
                        )
                    } else if let terminalError {
                        ContentUnavailableView(
                            "Terminal Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(terminalError)
                        )
                    } else {
                        ContentUnavailableView(
                            "Starting Terminal",
                            systemImage: "terminal",
                            description: Text("Opening a PTY on the server.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 420)

                if generation != nil {
                    MobileTerminalAccessoryBar(connectionId: connectionId)
                    detectedPathBar
                }
            }
            .background(Color(uiColor: terminalPreferences.theme.background))
            .clipShape(RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.medium))
        }
        .sheet(isPresented: $showingTerminalSettings) {
            MobileTerminalSettingsView()
                .environmentObject(terminalPreferences)
        }
        .sheet(isPresented: $showingCommandPalette) {
            MobileTerminalCommandPaletteView { command in
                performCommand(command)
            }
        }
        .sheet(isPresented: $showingTmuxManager) {
            MobileTmuxSessionManagerView(
                connectionId: connectionId,
                onSendCommand: sendTerminalCommand
            )
        }
        .sheet(item: $pathPreview) { preview in
            MobileTerminalPathPreviewView(preview: preview)
        }
        .sheet(item: $pathExport) { export in
            MobileTerminalPathShareSheet(url: export.url)
        }
        .alert(
            "Path Action Failed",
            isPresented: Binding(
                get: { pathActionError != nil },
                set: { if !$0 { pathActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pathActionError ?? "")
        }
        .background {
            keyboardShortcuts
        }
        .task {
            await startIfNeeded()
        }
        .onDisappear {
            if let generation {
                MobileTerminalBridge.shared.closeTerminal(
                    connectionId: connectionId,
                    generation: generation
                )
                MobileTerminalSessionManager.shared.unregisterSession(connectionId: connectionId)
                self.generation = nil
            }
        }
    }

    private var terminalActionsMenu: some View {
        Menu {
            ForEach(MobileTerminalCommand.allCases) { command in
                Button {
                    performCommand(command)
                } label: {
                    Label(command.label, systemImage: command.systemImage)
                }
                .disabled(command == .restartPty && generation == nil)
            }
            Divider()
            Button {
                showingTmuxManager = true
            } label: {
                Label("tmux Sessions", systemImage: "rectangle.connected.to.line.below")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Terminal actions")
    }

    @ViewBuilder
    private var detectedPathBar: some View {
        if !detectedPaths.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(detectedPaths) { path in
                        Menu {
                            Button {
                                UIPasteboard.general.string = path.remotePath
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }

                            if path.entry?.kind == .file {
                                Button {
                                    Task { await preview(path) }
                                } label: {
                                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                                }

                                Button {
                                    Task { await downloadAndShare(path) }
                                } label: {
                                    Label("Download and Share", systemImage: "square.and.arrow.down")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: path.symbolName)
                                Text(path.remotePath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if path.isVerifying {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color(uiColor: terminalPreferences.theme.foreground))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(
                                Color(uiColor: terminalPreferences.theme.foreground).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                        .draggable(path.remotePath)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(uiColor: terminalPreferences.theme.background))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(uiColor: terminalPreferences.theme.foreground).opacity(0.12))
                    .frame(height: 1)
            }
        }
    }

    private var keyboardShortcuts: some View {
        ZStack {
            shortcutButton("Focus Terminal", key: "`", modifiers: .command) {
                performCommand(.focus)
            }
            shortcutButton("Terminal Commands", key: "p", modifiers: [.command, .shift]) {
                showingCommandPalette = true
            }
            shortcutButton("Paste", key: "v", modifiers: .command) {
                performCommand(.pasteClipboard)
            }
            shortcutButton("Copy Selection", key: "c", modifiers: .command) {
                performCommand(.copySelection)
            }
            shortcutButton("Select All", key: "a", modifiers: .command) {
                performCommand(.selectAll)
            }
            shortcutButton("Clear Screen", key: "k", modifiers: .command) {
                performCommand(.clearScreen)
            }
            shortcutButton("Interrupt Command", key: ".", modifiers: .command) {
                performCommand(.interrupt)
            }
            shortcutButton("Restart Terminal", key: "r", modifiers: .command) {
                performCommand(.restartPty)
            }
            shortcutButton("Terminal Settings", key: ",", modifiers: .command) {
                performCommand(.settings)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(
        _ title: String,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }

    private func performCommand(_ command: MobileTerminalCommand) {
        switch command {
        case .focus:
            issueTerminalViewCommand(.focus)
        case .pasteClipboard:
            issueTerminalViewCommand(.pasteClipboard)
        case .copySelection:
            issueTerminalViewCommand(.copySelection)
        case .selectAll:
            issueTerminalViewCommand(.selectAll)
        case .clearScreen:
            sendInput([0x0C])
            issueTerminalViewCommand(.focus)
        case .interrupt:
            sendInput([0x03])
            issueTerminalViewCommand(.focus)
        case .restartPty:
            Task { await restartTerminal() }
        case .settings:
            showingTerminalSettings = true
        }
    }

    private func issueTerminalViewCommand(_ action: MobileTerminalViewCommand.Action) {
        terminalViewCommand = MobileTerminalViewCommand(action: action)
    }

    private func sendInput(_ bytes: [UInt8]) {
        MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: Data(bytes))
    }

    private func sendTerminalCommand(_ command: String) {
        MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: Data(command.utf8))
        issueTerminalViewCommand(.focus)
    }

    private func handleTerminalOutput(_ output: String) {
        let candidates = TerminalPathDetector.candidates(
            in: output,
            currentDirectory: currentDirectory,
            username: remoteUsername
        )
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            if let index = detectedPaths.firstIndex(where: { $0.remotePath == candidate.remotePath }) {
                var existing = detectedPaths.remove(at: index)
                existing.lastSeenAt = Date()
                detectedPaths.insert(existing, at: 0)
                continue
            }

            let detected = MobileTerminalDetectedPath(
                originalText: candidate.originalText,
                remotePath: candidate.remotePath,
                isVerifying: true,
                entry: nil,
                lastSeenAt: Date()
            )
            detectedPaths.insert(detected, at: 0)
            detectedPaths = Array(detectedPaths.prefix(10))

            Task { await verifyPath(candidate.remotePath) }
        }
    }

    @MainActor
    private func verifyPath(_ path: String) async {
        do {
            let entry = try await MobileSFTPBridge.shared.verifyPath(connectionId: connectionId, path: path)
            updateDetectedPath(path) {
                $0.entry = entry
                $0.isVerifying = false
            }
        } catch {
            detectedPaths.removeAll { $0.remotePath == path }
        }
    }

    @MainActor
    private func preview(_ path: MobileTerminalDetectedPath) async {
        guard let entry = path.entry else { return }
        do {
            let content = try await MobileSFTPBridge.shared.readRemoteTextFile(
                connectionId: connectionId,
                remotePath: path.remotePath,
                fileName: entry.name,
                expectedSize: entry.size
            )
            pathPreview = MobileTerminalPathPreview(
                remotePath: path.remotePath,
                content: content
            )
        } catch {
            pathActionError = error.localizedDescription
        }
    }

    @MainActor
    private func downloadAndShare(_ path: MobileTerminalDetectedPath) async {
        guard let entry = path.entry else { return }
        do {
            let url = try await MobileSFTPBridge.shared.downloadForExport(
                connectionId: connectionId,
                remotePath: path.remotePath,
                fileName: entry.name,
                expectedSize: entry.size
            )
            pathExport = MobileTerminalPathExport(url: url)
        } catch {
            pathActionError = error.localizedDescription
        }
    }

    private func updateDetectedPath(
        _ path: String,
        update: (inout MobileTerminalDetectedPath) -> Void
    ) {
        guard let index = detectedPaths.firstIndex(where: { $0.remotePath == path }) else { return }
        update(&detectedPaths[index])
    }

    private func startIfNeeded() async {
        guard generation == nil, !isStarting else { return }

        isStarting = true
        terminalError = nil
        defer { isStarting = false }

        do {
            generation = try await MobileTerminalBridge.shared.openTerminal(
                connectionId: connectionId,
                cols: 100,
                rows: 30
            )
        } catch {
            terminalError = error.localizedDescription
        }
    }

    private func restartTerminal() async {
        guard !isStarting else { return }

        if let generation {
            MobileTerminalBridge.shared.closeTerminal(
                connectionId: connectionId,
                generation: generation
            )
            MobileTerminalSessionManager.shared.unregisterSession(connectionId: connectionId)
            self.generation = nil
        }

        await startIfNeeded()
    }
}

private struct MobileTerminalDetectedPath: Identifiable, Equatable {
    let id = UUID()
    var originalText: String
    var remotePath: String
    var isVerifying: Bool
    var entry: FfiFileEntry?
    var lastSeenAt: Date

    var symbolName: String {
        switch entry?.kind {
        case .directory:
            return "folder"
        case .symlink:
            return "link"
        case .file:
            return "doc.text"
        case nil:
            return "questionmark.app"
        }
    }
}

private struct MobileTerminalPathPreview: Identifiable {
    let id = UUID()
    let remotePath: String
    let content: String
}

private struct MobileTerminalPathExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobileTerminalPathPreviewView: View {
    let preview: MobileTerminalPathPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(preview.content)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(URL(fileURLWithPath: preview.remotePath).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = preview.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}

private struct MobileTerminalPathShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
