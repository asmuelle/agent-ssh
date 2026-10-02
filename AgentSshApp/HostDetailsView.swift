import SwiftUI
import AgentSshMacOS

// MARK: - Host details

/// Static metadata for a saved host plus the server's offered SSH
/// algorithms. Shown on the host screen while the host isn't connected,
/// so the sidebar can stay a plain list.
struct HostDetailsView: View {
    let profile: ConnectionProfile
    let status: TerminalConnectionStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Host", profile.host)
            detailRow("Port", "\(profile.port)")
            detailRow("User", profile.username)
            if let status {
                statusRow(status)
            }
            detailRow("Protocol", profile.kind.displayName)
            detailRow("Auth", profile.authMethod.displayName)
            detailRow("Key", profile.sshKeyReference != nil ? "Configured" : "Not configured")
            if let folderPath = profile.folderPath {
                detailRow("Folder", folderPath)
            }
            if let last = profile.lastConnected {
                detailRow(
                    "Last Connected",
                    last.formatted(.relative(presentation: .named))
                )
            }
            if !profile.tags.isEmpty {
                detailRow("Tags", profile.tags.joined(separator: ", "))
            }

            SSHAlgorithmsSection(profile: profile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(_ status: TerminalConnectionStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("State")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 78, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: status.sidebarSymbol)
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(status.sidebarColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 12, height: 12)
                Text(status.sidebarLabel)
                    .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - SSH algorithms section

/// Server-offered key exchange algorithms and MACs, read from the
/// plaintext `SSH_MSG_KEXINIT` via `SSHAlgorithmProbe`. Probed once
/// per host:port per app session; weak algorithms are flagged.
private struct SSHAlgorithmsSection: View {
    let profile: ConnectionProfile
    @ObservedObject private var cache = SSHAlgorithmProbeCache.shared
    /// Non-nil while the explainer sheet for a clicked orange row is up.
    @State private var advice: SSHWeakAlgorithmAdvice?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.vertical, 2)

            HStack {
                Text("SSH Algorithms")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if case .loaded = cache.state(host: profile.host, port: profile.port) {
                    Button {
                        cache.probeIfNeeded(host: profile.host, port: profile.port, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(MidnightMacDesign.FontToken.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Probe \(profile.host) again")
                }
            }

            switch cache.state(host: profile.host, port: profile.port) {
            case nil, .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Probing \(profile.host)…")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                }

            case .failed(let message):
                HStack(spacing: 6) {
                    Text("Unavailable — \(message)")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    Button("Retry") {
                        cache.probeIfNeeded(host: profile.host, port: profile.port, force: true)
                    }
                    .buttonStyle(.plain)
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(Color.accentColor)
                }

            case .loaded(let algorithms):
                VStack(alignment: .leading, spacing: 8) {
                    serverRow(algorithms.serverBanner)
                    algorithmGroup(
                        "Key Exchange",
                        algorithms.kexAlgorithms,
                        category: .kex,
                        isWeak: SSHAlgorithmStrength.isWeakKex
                    )
                    algorithmGroup(
                        "MACs",
                        algorithms.macs,
                        category: .mac,
                        isWeak: SSHAlgorithmStrength.isWeakMac
                    )
                }
            }
        }
        .task(id: SSHAlgorithmProbeCache.key(host: profile.host, port: profile.port)) {
            cache.probeIfNeeded(host: profile.host, port: profile.port)
        }
        .sheet(item: $advice) { advice in
            SSHWeakAlgorithmSheet(
                advice: advice,
                host: profile.host,
                onRecheck: {
                    cache.probeIfNeeded(
                        host: profile.host,
                        port: profile.port,
                        force: true
                    )
                    self.advice = nil
                },
                onDismiss: { self.advice = nil }
            )
        }
    }

    private func serverRow(_ banner: String) -> some View {
        // "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3" → "OpenSSH_9.6p1 Ubuntu-3"
        let software = banner
            .split(separator: "-", maxSplits: 2)
            .dropFirst(2)
            .joined(separator: "-")

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Server")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(software.isEmpty ? banner : software)
                .font(MidnightMacDesign.FontToken.metadataMono)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(banner)
        }
    }

    private func algorithmGroup(
        _ label: String,
        _ algorithms: [String],
        category: SSHWeakAlgorithmAdvice.Category,
        isWeak: @escaping (String) -> Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)

            ForEach(algorithms, id: \.self) { algorithm in
                if isWeak(algorithm) {
                    Button {
                        advice = SSHWeakAlgorithmAdvice.advice(
                            for: algorithm,
                            category: category
                        )
                    } label: {
                        algorithmRow(algorithm, isWeak: true)
                    }
                    .buttonStyle(.plain)
                    .help("\(algorithm) is deprecated or weakened — click for why, and how to disable it")
                    .accessibilityHint("Opens an explanation and the sshd_config fix")
                } else {
                    algorithmRow(algorithm, isWeak: false)
                }
            }

            if algorithms.isEmpty {
                Text("none offered")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func algorithmRow(_ algorithm: String, isWeak: Bool) -> some View {
        HStack(spacing: 5) {
            Text(algorithm)
                .font(MidnightMacDesign.FontToken.metadataMono)
                .foregroundStyle(isWeak ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)

            if isWeak {
                Text("weak")
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .foregroundStyle(MidnightMacDesign.StatusTone.warning.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.12))
                    )
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
