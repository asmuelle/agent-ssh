import SwiftTerm
import SwiftUI
import UIKit

struct MobileTerminalView: UIViewRepresentable {
    let connectionId: String
    let ptyGeneration: UInt64
    let themeId: String
    let fontSize: Double
    let scrollbackLines: Int
    let cursorStyleId: String
    let mouseReporting: Bool
    let optionAsMeta: Bool
    let copyOnSelect: Bool
    /// OSC 52 opt-in; see `Coordinator.clipboardCopy`.
    var allowRemoteClipboardWrite: Bool = false
    var onOutput: ((String) -> Void)?
    var onCurrentDirectoryChange: ((String?) -> Void)?
    @Binding var commandRequest: MobileTerminalViewCommand?

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let term = MobileFocusTerminalView(frame: .zero)
        applyAppearance(to: term)

        term.terminalDelegate = context.coordinator
        context.coordinator.term = term
        context.coordinator.allowRemoteClipboardWrite = allowRemoteClipboardWrite

        MobileTerminalSessionManager.shared.registerSession(
            connectionId: connectionId,
            generation: ptyGeneration
        ) { [weak term] data in
            DispatchQueue.main.async { [weak term] in
                guard let term else { return }
                let bytes = Array(data)
                term.feed(byteArray: bytes[...])
                if let output = String(data: data, encoding: .utf8) {
                    onOutput?(output)
                }
            }
        }

        return term
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        applyAppearance(to: uiView)
        context.coordinator.allowRemoteClipboardWrite = allowRemoteClipboardWrite
        context.coordinator.handle(commandRequest, in: uiView)
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        MobileTerminalSessionManager.shared.unregisterSession(
            connectionId: coordinator.connectionId,
            generation: coordinator.ptyGeneration
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connectionId: connectionId,
            ptyGeneration: ptyGeneration,
            onCurrentDirectoryChange: onCurrentDirectoryChange
        )
    }

    private func applyAppearance(to term: SwiftTerm.TerminalView) {
        let targetFont = UIFont.monospacedSystemFont(
            ofSize: CGFloat(min(22, max(10, fontSize))),
            weight: .regular
        )

        MobileTerminalTheme.resolve(themeId).apply(to: term)
        if term.font.pointSize != targetFont.pointSize || term.font.fontName != targetFont.fontName {
            term.font = targetFont
        }
        term.getTerminal().changeScrollback(min(100_000, max(500, scrollbackLines)))
        term.getTerminal().setCursorStyle(CursorStyle.from(string: cursorStyleId) ?? .blinkBlock)
        term.allowMouseReporting = mouseReporting
        term.optionAsMetaKey = optionAsMeta
        // Never set keyboardDismissMode on the terminal: TerminalView IS a
        // UIScrollView, so `.interactive` turns every pan inside the outer
        // SwiftUI ScrollView into an interactive dismissal of the input
        // session — which resigns first responder and silently kills
        // hardware-keyboard input (no on-screen keyboard, no visual cue).
    }

    // SwiftTerm's delegate protocol predates concurrency annotations but is
    // driven from UIKit event and layout callbacks on the main thread;
    // `@preconcurrency` makes that assumption checked at runtime.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let connectionId: String
        let ptyGeneration: UInt64
        let onCurrentDirectoryChange: ((String?) -> Void)?
        weak var term: SwiftTerm.TerminalView?
        var allowRemoteClipboardWrite = false

        /// Upper bound for an OSC 52 payload placed on the pasteboard.
        static let remoteClipboardByteLimit = 64 * 1024

        private var lastCols = 0
        private var lastRows = 0
        private var resizeWorkItem: DispatchWorkItem?
        private var lastHandledCommandId: UUID?

        init(
            connectionId: String,
            ptyGeneration: UInt64,
            onCurrentDirectoryChange: ((String?) -> Void)?
        ) {
            self.connectionId = connectionId
            self.ptyGeneration = ptyGeneration
            self.onCurrentDirectoryChange = onCurrentDirectoryChange
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: Data(data))
        }

        func handle(_ command: MobileTerminalViewCommand?, in terminalView: SwiftTerm.TerminalView) {
            guard let command, command.id != lastHandledCommandId else { return }
            lastHandledCommandId = command.id

            switch command.action {
            case .focus:
                _ = terminalView.becomeFirstResponder()
            case .copySelection:
                terminalView.copy(nil)
            case .pasteClipboard:
                terminalView.paste(nil)
            case .selectAll:
                terminalView.selectAll(nil)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard newCols != lastCols || newRows != lastRows else { return }
            lastCols = newCols
            lastRows = newRows
            resizeWorkItem?.cancel()

            let connectionId = self.connectionId
            let item = DispatchWorkItem {
                MobileTerminalBridge.shared.resize(
                    connectionId: connectionId,
                    cols: newCols,
                    rows: newRows
                )
            }
            resizeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            _ = title
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            onCurrentDirectoryChange?(Self.remotePath(from: directory))
        }

        private static func remotePath(from directory: String?) -> String? {
            guard var value = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            if value.hasPrefix("file://"),
               let url = URL(string: value) {
                value = url.path
            }
            return value.hasPrefix("/") ? value : nil
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            _ = position
        }

        func requestOpenLink(
            source: SwiftTerm.TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: SwiftTerm.TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            // OSC 52 — the remote side asked to write the local clipboard.
            // Opt-in only, bounded, and only for the terminal the user is
            // actually typing into, so a background pane cannot stage a
            // payload for a later paste.
            guard allowRemoteClipboardWrite,
                  content.count <= Self.remoteClipboardByteLimit,
                  source.isFirstResponder,
                  let string = String(data: content, encoding: .utf8)
            else { return }
            UIPasteboard.general.string = string
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {
            _ = content
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            _ = (startY, endY)
        }
    }
}

/// Grabs keyboard focus exactly when the view lands in a window — the only
/// moment `becomeFirstResponder` is guaranteed to be answerable. The previous
/// fire-and-forget calls from makeUIView/updateUIView could run before window
/// attachment, silently return false, and leave the terminal deaf to the
/// hardware keyboard.
private final class MobileFocusTerminalView: SwiftTerm.TerminalView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFirstResponder else { return }
            _ = self.becomeFirstResponder()
        }
    }
}
