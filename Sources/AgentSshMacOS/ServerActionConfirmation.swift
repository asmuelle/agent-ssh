import SwiftUI

/// A change about to be made to a server — or irreversibly to local data —
/// held until the user consents.
///
/// Every mutating action in the app goes through
/// `View.serverActionConfirmation(_:)`, so consent always looks the same on
/// both platforms: what happens, where, and the exact command. Build
/// `command` from the same string that `perform` executes; never describe a
/// command and then run a different one.
public struct PendingServerAction: Identifiable {
    public let id = UUID()
    /// The question, e.g. "Restart nginx.service?".
    public let title: String
    /// The confirm button's label, e.g. "Restart".
    public let confirmLabel: String
    /// Where it happens: a host label, or "This Mac" / "This device" for
    /// local deletions.
    public let target: String
    /// The exact command that will run, shown verbatim. `nil` for actions
    /// that run no shell command (e.g. deleting a saved profile).
    public let command: String?
    /// A consequence the user should weigh, e.g. "This cannot be undone."
    public let detail: String?
    /// Red confirm button for actions that stop, remove, or overwrite.
    public let isDestructive: Bool
    let perform: @MainActor () async -> Void

    public init(
        title: String,
        confirmLabel: String,
        target: String,
        command: String? = nil,
        detail: String? = nil,
        isDestructive: Bool,
        perform: @escaping @MainActor () async -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.target = target
        self.command = command
        self.detail = detail
        self.isDestructive = isDestructive
        self.perform = perform
    }

    /// The dialog body: target, then the command, then the consequence.
    public var message: String {
        var parts = ["On \(target)"]
        if let command, !command.isEmpty {
            parts[0] += ":"
            parts.append(command)
        }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: "\n\n")
    }
}

public extension View {
    /// Presents `pending` as the app's one confirmation dialog and runs it
    /// on confirm. Set the binding to ask; it clears itself either way.
    func serverActionConfirmation(_ pending: Binding<PendingServerAction?>) -> some View {
        modifier(ServerActionConfirmationModifier(pending: pending))
    }
}

private struct ServerActionConfirmationModifier: ViewModifier {
    @Binding var pending: PendingServerAction?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                Task { await action.perform() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }
}
