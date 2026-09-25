@testable import AgentSshApp
import AgentSshMacOS
import Foundation
import Testing

/// The systemd action path used to build `systemctl \(verb) \(unit)` from
/// a runtime `String` verb — what looked like one parameterized command
/// was really two unvalidated slots. These pin the migrated path.
struct SystemdVerbTests {
    @Test("Every verb the UI offers resolves to a real catalog template", arguments: SystemdVerb.allCases)
    func everyVerbHasATemplate(verb: SystemdVerb) {
        #expect(CommandTemplateCatalog.template(id: verb.templateId) != nil)
    }

    @Test("A verb renders the command it names, with the unit quoted", arguments: SystemdVerb.allCases)
    func verbRendersItsOwnCommand(verb: SystemdVerb) throws {
        let rendered = try CommandTemplateRenderer.render(
            templateId: verb.templateId, values: ["unit": "nginx.service"]
        )
        #expect(rendered.command == "systemctl \(verb.rawValue) -- 'nginx.service'")
        #expect(rendered.requiresPrivilege)
    }

    @Test("A hostile unit name is refused before any command exists", arguments: [
        "*.service", "-delete", "nginx.service\nrm -rf /", "a'\u{0301}; id #", "",
    ])
    func hostileUnitRefused(unit: String) {
        #expect(throws: CommandTemplateError.self) {
            _ = try CommandTemplateRenderer.render(
                templateId: SystemdVerb.restart.templateId, values: ["unit": unit]
            )
        }
    }

    @Test("Refusal explains itself, so the UI can tell the user why")
    func refusalIsExplainable() {
        do {
            _ = try CommandTemplateRenderer.render(
                templateId: SystemdVerb.stop.templateId, values: ["unit": "*.service"]
            )
            Issue.record("expected a refusal")
        } catch let error as CommandTemplateError {
            #expect(error.explanation.contains("service name"))
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("Legitimate template-instance units still work — the guard must not break real hosts")
    func templateInstanceUnitsWork() throws {
        for unit in ["getty@tty1.service", "user@1000.service", "-.mount"] {
            let rendered = try CommandTemplateRenderer.render(
                templateId: SystemdVerb.start.templateId, values: ["unit": unit]
            )
            #expect(rendered.command.contains(ShellQuoting.singleQuoted(unit)))
        }
    }

    @Test("Only stop, restart and disable are treated as destructive")
    func destructiveVerbs() {
        #expect(SystemdVerb.allCases.filter(\.destructive).map(\.rawValue).sorted()
            == ["disable", "restart", "stop"])
    }
}
