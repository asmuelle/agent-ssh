import Foundation
import Testing
@testable import AgentSshMacOS

struct CommandTemplateRenderingTests {
    private let restart = CommandTemplate(
        id: "test.systemd.restart",
        segments: [.literal("systemctl"), .literal("restart"), .literal("--"),
                   .slot(.init(name: "unit", kind: .systemdUnit))],
        risk: .modifiesService,
        requiresPrivilege: true
    )

    @Test("A valid binding renders a quoted, complete command")
    func rendersQuoted() throws {
        let rendered = try CommandTemplateRenderer.render(restart, values: ["unit": "nginx.service"])
        #expect(rendered.command == "systemctl restart -- 'nginx.service'")
        #expect(rendered.templateId == "test.systemd.restart")
        #expect(rendered.risk == .modifiesService)
        #expect(rendered.requiresPrivilege)
    }

    @Test("A value its slot kind rejects refuses the whole render, with a reason")
    func invalidValueRefuses() {
        for hostile in ["*.service", "-delete", "nginx.service\nrm -rf /", "a'\u{0301}; id #"] {
            #expect(throws: CommandTemplateError.self) {
                _ = try CommandTemplateRenderer.render(restart, values: ["unit": hostile])
            }
        }
    }

    @Test("Refusal names the slot, so the UI can say what it could not accept")
    func refusalIsExplainable() {
        do {
            _ = try CommandTemplateRenderer.render(restart, values: ["unit": "*.service"])
            Issue.record("expected a refusal")
        } catch let error as CommandTemplateError {
            #expect(error.slotName == "unit")
            #expect(!error.explanation.isEmpty)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("Missing, unknown, and surplus bindings all refuse — never a partial render")
    func bindingMismatchRefuses() {
        #expect(throws: CommandTemplateError.self) {
            _ = try CommandTemplateRenderer.render(restart, values: [:])
        }
        #expect(throws: CommandTemplateError.self) {
            _ = try CommandTemplateRenderer.render(restart, values: ["wrong": "nginx.service"])
        }
        #expect(throws: CommandTemplateError.self) {
            _ = try CommandTemplateRenderer.render(
                restart, values: ["unit": "nginx.service", "extra": "x"]
            )
        }
    }

    @Test("The same binding always renders the same command — the verdict is a property of the template")
    func renderingIsDeterministic() throws {
        let a = try CommandTemplateRenderer.render(restart, values: ["unit": "getty@tty1.service"])
        let b = try CommandTemplateRenderer.render(restart, values: ["unit": "getty@tty1.service"])
        #expect(a.command == b.command)
    }
}

/// Invariants asserted over every shipped template. A catalog entry is
/// the one place a mistake becomes an executable command, so these are
/// checked for the whole catalog rather than per entry.
struct CommandTemplateCatalogTests {
    @Test("Template ids are unique")
    func idsUnique() {
        let ids = CommandTemplateCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Lookup is exact and fails closed on an unknown id")
    func lookupFailsClosed() {
        #expect(CommandTemplateCatalog.template(id: "nope") == nil)
        for template in CommandTemplateCatalog.all {
            #expect(CommandTemplateCatalog.template(id: template.id)?.id == template.id)
        }
    }

    @Test("No literal smuggles a shell construct, a second command, or privilege")
    func literalsAreInert() {
        // Privilege is applied by the runner from `requiresPrivilege`, so
        // a template that says `sudo` itself is escaping that decision.
        let banned = ["sudo", "su ", "doas", "pkexec", "sh -c", "bash -c",
                      "$(", "`", ";", "&&", "||", "|", ">", "<", "\n"]
        for template in CommandTemplateCatalog.all {
            for case .literal(let literal) in template.segments {
                let text = literal.description
                for needle in banned {
                    #expect(!text.contains(needle),
                            "template \(template.id) literal '\(text)' contains '\(needle)'")
                }
            }
        }
    }

    @Test("Every template begins with a literal — a slot can never be the command name")
    func commandNameIsAlwaysLiteral() {
        for template in CommandTemplateCatalog.all {
            guard case .literal = template.segments.first else {
                Issue.record("template \(template.id) does not begin with a literal")
                continue
            }
        }
    }

    @Test("Every positional slot is preceded by an end-of-options marker; option arguments must not be")
    func slotsAreAfterEndOfOptions() {
        for template in CommandTemplateCatalog.all {
            guard template.segments.contains(where: { if case .slot = $0 { return true }; return false })
            else { continue }
            if template.endOfOptionsUnsupportedReason != nil { continue }
            var sawMarker = false
            for segment in template.segments {
                switch segment {
                case .literal(let literal) where literal.description == "--":
                    sawMarker = true
                case .slot(let slot) where slot.isOptionArgument:
                    // `-u -- nginx.service` would make `--` the unit, so a
                    // marker here would be a bug rather than a safeguard.
                    #expect(!sawMarker,
                            "template \(template.id) puts '--' before option argument '\(slot.name)'")
                case .slot(let slot):
                    #expect(sawMarker, "template \(template.id) slot '\(slot.name)' precedes '--'")
                default:
                    break
                }
            }
        }
    }

    @Test("Every template's command name is on an explicit allowlist of vetted binaries")
    func commandNameIsAllowlisted() {
        // No interpreters, on purpose. `sh -c <slot>`, `perl -e <slot>`,
        // `awk <slot>` and `find … -exec <slot>` each turn a validated
        // single word back into code, and neither the per-literal ban
        // list nor the end-of-options rule can see it: `-c` legitimately
        // takes its slot as an option argument, so the correct annotation
        // is also the evasion.
        let allowed: Set<String> = ["systemctl", "journalctl", "df"]
        for template in CommandTemplateCatalog.all {
            guard case .literal(let name) = template.segments.first else { continue }
            #expect(allowed.contains(name.description),
                    "template \(template.id) runs unvetted binary '\(name.description)'")
        }
    }

    @Test("No slot is the argument of an option that takes code")
    func slotsAreNotCodeArguments() {
        // Survives the allowlist growing: the danger is the flag, not the
        // binary. Kept alongside the allowlist rather than instead of it.
        let codeFlags: Set<String> = [
            "-c", "-e", "--eval", "-exec", "-execdir", "--command", "-command",
            "--expression", "-i", "--filter", "-f",
        ]
        for template in CommandTemplateCatalog.all {
            var previous: String?
            for segment in template.segments {
                switch segment {
                case .literal(let literal):
                    previous = literal.description
                case .slot(let slot):
                    #expect(!codeFlags.contains(previous ?? ""),
                            "template \(template.id) binds slot '\(slot.name)' to code flag '\(previous ?? "")'")
                    previous = nil
                }
            }
        }
    }

    @Test("Rendering by id fails closed on an id the catalog does not contain")
    func renderByIdFailsClosed() {
        #expect(throws: CommandTemplateError.self) {
            _ = try CommandTemplateRenderer.render(templateId: "shell.exec", values: [:])
        }
    }

    @Test("Rendering by id produces the catalog entry's own command")
    func renderByIdUsesCatalogEntry() throws {
        let rendered = try CommandTemplateRenderer.render(
            templateId: "systemd.restart", values: ["unit": "nginx.service"]
        )
        #expect(rendered.command == "systemctl restart -- 'nginx.service'")
    }

    @Test("Every catalog template renders with a plausible value for its slots")
    func catalogTemplatesRender() throws {
        let sample: [CommandSlotKind: String] = [
            .systemdUnit: "nginx.service",
            .absolutePath: "/var/log",
            .packageName: "openssl",
            .sshdConfigToken: "hmac-sha1",
            .shellWord: "value",
        ]
        for template in CommandTemplateCatalog.all {
            var values: [String: String] = [:]
            for case .slot(let slot) in template.segments {
                values[slot.name] = sample[slot.kind]
            }
            let rendered = try CommandTemplateRenderer.render(template, values: values)
            #expect(!rendered.command.isEmpty)
        }
    }
}
