import Testing
@testable import AgentSshMacOS

@MainActor
struct ServerActionConfirmationTests {
    private func action(command: String?, detail: String?) -> PendingServerAction {
        PendingServerAction(
            title: "Restart nginx.service?",
            confirmLabel: "Restart",
            target: "web-1",
            command: command,
            detail: detail,
            isDestructive: true,
            perform: {}
        )
    }

    @Test("The message names the target, then the exact command, then the consequence")
    func messageOrder() {
        let message = action(
            command: "sudo -n systemctl restart 'nginx.service'",
            detail: "The service is briefly unavailable."
        ).message
        #expect(message == """
        On web-1:

        sudo -n systemctl restart 'nginx.service'

        The service is briefly unavailable.
        """)
    }

    @Test("An action with no command shows only the target and consequence")
    func messageWithoutCommand() {
        #expect(action(command: nil, detail: "This cannot be undone.").message == "On web-1\n\nThis cannot be undone.")
    }

    @Test("Blank command and detail are omitted rather than rendered as empty lines")
    func blankPartsOmitted() {
        #expect(action(command: "", detail: "").message == "On web-1")
    }

    @Test("Confirming runs the stored action")
    func performRunsAction() async {
        var ran = false
        let pending = PendingServerAction(
            title: "Delete?", confirmLabel: "Delete", target: "This Mac",
            isDestructive: true, perform: { ran = true }
        )
        await pending.perform()
        #expect(ran)
    }
}
