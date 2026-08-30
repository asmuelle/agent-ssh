import AppKit
import SwiftUI

/// Explainer for a weak algorithm the probed server still offers.
/// Opened by clicking an orange row in the sidebar's SSH Algorithms
/// section: what the weakness is, what it costs to remove it, and the
/// exact sshd_config change plus a validate-then-reload command.
struct SSHWeakAlgorithmSheet: View {
    let advice: SSHWeakAlgorithmAdvice
    let host: String
    /// Re-runs the KEXINIT probe. The offered list is cached per
    /// host:port for the app session, so without this the row stays
    /// orange after the user has already fixed the server.
    let onRecheck: () -> Void
    let onDismiss: () -> Void

    @State private var copiedSnippet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            section("Why it matters", advice.detail)
            section("What you lose by removing it", advice.compatibilityNote)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionTitle("Fix on \(host)")
                    Spacer()
                    Button(copiedSnippet ? "Copied" : "Copy") {
                        copy(advice.sshdSnippet + "\n" + advice.applyCommand)
                    }
                    .buttonStyle(.plain)
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(Color.accentColor)
                }
                codeBlock(advice.sshdSnippet)
                Text("Then validate and reload — never restart blind, a rejected config can lock you out:")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                codeBlock(advice.applyCommand)
            }

            HStack {
                Text("Already fixed it? The list below is cached — re-read it from the server.")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Re-check", action: onRecheck)
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                Text(advice.algorithm)
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .textSelection(.enabled)
            }
            Text(advice.headline)
                .font(.headline)
            Text("\(advice.category.label) · offered by \(host)")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
            Text(body)
                .font(MidnightMacDesign.FontToken.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(MidnightMacDesign.FontToken.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(MidnightMacDesign.FontToken.metadataMono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.xsmall)
                    .fill(Color.primary.opacity(0.05))
            )
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSnippet = true
    }
}
