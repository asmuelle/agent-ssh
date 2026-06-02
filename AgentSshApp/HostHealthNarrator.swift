import Foundation
import AgentSshMacOS

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a finished diagnosis into a single plain-language line suitable for a
/// sidebar badge, a notification body, or a Shortcuts answer. Uses the on-device
/// model when available; otherwise falls back to the report's own summary so the
/// proactive surfaces always have something honest to show.
enum HostHealthNarrator {
    static func narrate(report: ServerDoctorReport) async -> (headline: String, onDevice: Bool) {
        let fallback = fallbackHeadline(report)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *),
           case .available = SystemLanguageModel.default.availability {
            if let line = await modelHeadline(report: report) {
                return (line, true)
            }
        }
        #endif

        return (fallback, false)
    }

    static func fallbackHeadline(_ report: ServerDoctorReport) -> String {
        if let top = report.findings.first(where: { $0.severity >= .warning }) {
            return oneLine(top.title)
        }
        if let top = report.findings.first {
            return oneLine(top.title)
        }
        return oneLine(report.summary)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private static func modelHeadline(report: ServerDoctorReport) async -> String? {
        let findings = report.findings.prefix(5)
            .map { "- [\($0.severity.rawValue)] \($0.title)" }
            .joined(separator: "\n")

        let session = LanguageModelSession {
            """
            You write a single short status line about a server, for a sidebar badge. \
            One sentence, under 90 characters, no leading label, no quotes, no emoji. \
            Lead with the most serious issue. If nothing is wrong, say it briefly.
            """
        }
        let prompt = """
        Host: \(report.hostLabel)
        Overall severity: \(report.overallSeverity.rawValue)
        Findings:
        \(findings.isEmpty ? "(none)" : findings)

        Write the one-line status.
        """
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2)
            )
            let line = oneLine(response.content)
            return line.isEmpty ? nil : line
        } catch {
            return nil
        }
    }
    #endif

    private static func oneLine(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(140))
    }
}
