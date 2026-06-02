import SwiftUI

struct MobileTmuxSessionManagerView: View {
    let connectionId: String
    let onSendCommand: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [MobileTmuxSession] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var newSessionName = "midnight"

    var body: some View {
        NavigationStack {
            List {
                Section("Sessions") {
                    if isLoading {
                        ProgressView()
                    } else if sessions.isEmpty {
                        ContentUnavailableView(
                            "No tmux Sessions",
                            systemImage: "rectangle.connected.to.line.below",
                            description: Text("Create a named session or refresh after starting tmux on the server.")
                        )
                    } else {
                        ForEach(sessions) { session in
                            DisclosureGroup {
                                Button {
                                    attach(session.name)
                                } label: {
                                    Label("Attach Session", systemImage: "rectangle.connected.to.line.below")
                                }

                                if session.windows.isEmpty {
                                    Text("No windows reported.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(session.windows) { window in
                                        windowRow(window, sessionName: session.name)
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(session.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if session.attachedCount > 0 {
                                        Label("Attached", systemImage: "person.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    attach(session.name)
                                } label: {
                                    Label("Attach Session", systemImage: "rectangle.connected.to.line.below")
                                }
                            }
                        }
                    }
                }

                Section("New Session") {
                    TextField("Session name", text: $newSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        newOrAttach()
                    } label: {
                        Label("Create or Attach", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(normalizedNewSessionName.isEmpty)
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadSessions() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task {
                await loadSessions()
            }
        }
    }

    private var normalizedNewSessionName: String {
        newSessionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private func windowRow(_ window: MobileTmuxWindow, sessionName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: window.isActive ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                    .foregroundStyle(window.isActive ? .green : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(window.index): \(window.name)")
                        .font(.caption.weight(.semibold))
                    Text("\(window.paneCount) pane\(window.paneCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    attachWindow(sessionName: sessionName, windowIndex: window.index)
                } label: {
                    Label("Attach Window", systemImage: "arrowshape.turn.up.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(window.panes) { pane in
                paneRow(pane, sessionName: sessionName, windowIndex: window.index)
            }
        }
        .padding(.vertical, 4)
    }

    private func paneRow(
        _ pane: MobileTmuxPane,
        sessionName: String,
        windowIndex: Int
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.isActive ? "square.split.bottomrightquarter.fill" : "square.split.bottomrightquarter")
                .foregroundStyle(pane.isActive ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("#\(pane.index) \(pane.command)")
                    .font(.caption2.weight(.semibold))
                if !pane.currentPath.isEmpty {
                    Text(pane.currentPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                attachPane(
                    sessionName: sessionName,
                    windowIndex: windowIndex,
                    paneIndex: pane.index
                )
            } label: {
                Label("Attach Pane", systemImage: "arrowshape.turn.up.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.leading, 22)
    }

    @MainActor
    private func loadSessions() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let command = """
            if ! command -v tmux >/dev/null 2>&1; then
              echo "__MIDNIGHT_TMUX_MISSING__"
              exit 0
            fi
            tmux list-sessions -F 'S\t#{session_name}\t#{session_windows}\t#{session_attached}' 2>/dev/null || true
            tmux list-windows -a -F 'W\t#{session_name}\t#{window_index}\t#{window_name}\t#{window_panes}\t#{window_active}' 2>/dev/null || true
            tmux list-panes -a -F 'P\t#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}' 2>/dev/null || true
            """
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: command
            )
            if output.contains("__MIDNIGHT_TMUX_MISSING__") {
                sessions = []
                errorMessage = "tmux is not installed on this server."
                return
            }
            sessions = MobileTmuxSession.parseInventory(output)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attach(_ sessionName: String) {
        onSendCommand("tmux attach -t \(shellQuote(sessionName))\r")
        dismiss()
    }

    private func attachWindow(sessionName: String, windowIndex: Int) {
        let windowTarget = "\(sessionName):\(windowIndex)"
        onSendCommand(
            "tmux attach -t \(shellQuote(sessionName)) \\; select-window -t \(shellQuote(windowTarget))\r"
        )
        dismiss()
    }

    private func attachPane(sessionName: String, windowIndex: Int, paneIndex: Int) {
        let windowTarget = "\(sessionName):\(windowIndex)"
        let paneTarget = "\(sessionName):\(windowIndex).\(paneIndex)"
        onSendCommand(
            "tmux attach -t \(shellQuote(sessionName)) \\; select-window -t \(shellQuote(windowTarget)) \\; select-pane -t \(shellQuote(paneTarget))\r"
        )
        dismiss()
    }

    private func newOrAttach() {
        let name = normalizedNewSessionName
        guard !name.isEmpty else { return }
        onSendCommand("tmux new -As \(shellQuote(name))\r")
        dismiss()
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private struct MobileTmuxSession: Identifiable, Hashable {
    let id: String
    var name: String
    var windowCount: Int
    var attachedCount: Int
    var windows: [MobileTmuxWindow] = []

    var summary: String {
        "\(windowCount) window\(windowCount == 1 ? "" : "s"), \(paneCount) pane\(paneCount == 1 ? "" : "s")"
    }

    private var paneCount: Int {
        windows.reduce(0) { $0 + $1.panes.count }
    }

    static func parseInventory(_ output: String) -> [MobileTmuxSession] {
        var order: [String] = []
        var sessions: [String: MobileTmuxSession] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = parts.first else { continue }

            switch recordType {
            case "S":
                guard parts.count >= 4, !parts[1].isEmpty else { continue }
                let name = parts[1]
                if sessions[name] == nil {
                    order.append(name)
                }
                sessions[name] = MobileTmuxSession(
                    id: name,
                    name: name,
                    windowCount: Int(parts[2]) ?? 0,
                    attachedCount: Int(parts[3]) ?? 0,
                    windows: sessions[name]?.windows ?? []
                )
            case "W":
                guard parts.count >= 6, !parts[1].isEmpty else { continue }
                let sessionName = parts[1]
                ensureSession(sessionName, in: &sessions, order: &order)
                sessions[sessionName]?.upsertWindow(
                    MobileTmuxWindow(
                        sessionName: sessionName,
                        index: Int(parts[2]) ?? 0,
                        name: parts[3].isEmpty ? "window" : parts[3],
                        paneCount: Int(parts[4]) ?? 0,
                        isActive: parts[5] == "1",
                        panes: []
                    )
                )
            case "P":
                guard parts.count >= 7, !parts[1].isEmpty else { continue }
                let sessionName = parts[1]
                let windowIndex = Int(parts[2]) ?? 0
                ensureSession(sessionName, in: &sessions, order: &order)
                sessions[sessionName]?.ensureWindow(index: windowIndex)
                sessions[sessionName]?.upsertPane(
                    MobileTmuxPane(
                        windowIndex: windowIndex,
                        index: Int(parts[3]) ?? 0,
                        command: parts[4].isEmpty ? "shell" : parts[4],
                        currentPath: parts[5],
                        isActive: parts[6] == "1"
                    )
                )
            default:
                continue
            }
        }

        return order.compactMap { sessions[$0] }
    }

    private static func ensureSession(
        _ name: String,
        in sessions: inout [String: MobileTmuxSession],
        order: inout [String]
    ) {
        guard sessions[name] == nil else { return }
        order.append(name)
        sessions[name] = MobileTmuxSession(
            id: name,
            name: name,
            windowCount: 0,
            attachedCount: 0
        )
    }

    private mutating func upsertWindow(_ window: MobileTmuxWindow) {
        if let index = windows.firstIndex(where: { $0.index == window.index }) {
            windows[index].name = window.name
            windows[index].paneCount = window.paneCount
            windows[index].isActive = window.isActive
        } else {
            windows.append(window)
            windows.sort { $0.index < $1.index }
        }
    }

    private mutating func ensureWindow(index: Int) {
        guard !windows.contains(where: { $0.index == index }) else { return }
        windows.append(
            MobileTmuxWindow(
                sessionName: name,
                index: index,
                name: "window",
                paneCount: 0,
                isActive: false,
                panes: []
            )
        )
        windows.sort { $0.index < $1.index }
    }

    private mutating func upsertPane(_ pane: MobileTmuxPane) {
        guard let windowIndex = windows.firstIndex(where: { $0.index == pane.windowIndex }) else {
            return
        }
        windows[windowIndex].upsertPane(pane)
    }
}

private struct MobileTmuxWindow: Identifiable, Hashable {
    var sessionName: String
    var index: Int
    var name: String
    var paneCount: Int
    var isActive: Bool
    var panes: [MobileTmuxPane]

    var id: String { "\(sessionName):\(index)" }

    mutating func upsertPane(_ pane: MobileTmuxPane) {
        if let index = panes.firstIndex(where: { $0.index == pane.index }) {
            panes[index] = pane
        } else {
            panes.append(pane)
            panes.sort { $0.index < $1.index }
        }
    }
}

private struct MobileTmuxPane: Identifiable, Hashable {
    var windowIndex: Int
    var index: Int
    var command: String
    var currentPath: String
    var isActive: Bool

    var id: String { "\(windowIndex).\(index)" }
}
