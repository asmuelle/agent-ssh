import Foundation

enum MobileSessionStatus: Equatable {
    case disconnected
    case connecting
    case connected(connectionId: String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

@MainActor
final class MobileSessionStore: ObservableObject {
    @Published private var statuses: [String: MobileSessionStatus] = [:]
    /// Set when a connect pinned a host key the store had never seen. The
    /// root view presents it; `confirmPendingHostKey` / `rejectPendingHostKey`
    /// resolve it.
    @Published private(set) var pendingHostKeyConfirmation: MobilePendingHostKeyConfirmation?

    func status(for profile: MobileConnectionProfile) -> MobileSessionStatus {
        statuses[profile.id] ?? .disconnected
    }

    func diagnosticsSnapshot(for profiles: [MobileConnectionProfile]) -> [MobileSessionDiagnostics] {
        profiles.map { profile in
            MobileSessionDiagnostics(
                profileIdHash: MobileDiagnosticsRedactor.hash(profile.id),
                status: status(for: profile).diagnosticsLabel
            )
        }
    }

    func connect(
        profile: MobileConnectionProfile,
        password: String?,
        passphrase: String?,
        onSuccess: @escaping () -> Void,
        onFailure: ((String) -> Void)? = nil
    ) {
        guard !status(for: profile).isBusy else { return }

        guard MobileBridgeManager.shared.initialized else {
            let message = "The Rust bridge is still initializing. Try connecting again in a moment."
            statuses[profile.id] = .failed(message)
            onFailure?(message)
            return
        }

        statuses[profile.id] = .connecting
        MobileWidgetSnapshotCenter.shared.publish(profile: profile, status: .connecting)
        let sessionId = UUID().uuidString
        let preparedKey: PreparedMobileSSHKey?

        do {
            preparedKey = profile.authMethod == .publicKey
                ? try MobileSSHKeyAccessCoordinator.prepare(profile.sshKeyReference)
                : nil
        } catch {
            let message = Self.describeConnectFailure(error, profile: profile)
            statuses[profile.id] = .failed(message)
            MobileWidgetSnapshotCenter.shared.publish(profile: profile, status: .failed(message), detail: message)
            onFailure?(message)
            return
        }

        connectInBackground(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            preparedKey: preparedKey,
            passphrase: passphrase,
            networkOptions: profile.networkOptions,
            sessionId: sessionId
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    if let firstConnection = outcome.firstConnection {
                        // The core pinned a never-seen host key. Hold the
                        // session in `.connecting` until the user has compared
                        // the fingerprint; nothing runs over it before then.
                        self.pendingHostKeyConfirmation = MobilePendingHostKeyConfirmation(
                            profile: profile,
                            connectionId: outcome.connectionId,
                            host: firstConnection.host,
                            port: firstConnection.port,
                            fingerprint: firstConnection.fingerprint,
                            onSuccess: onSuccess,
                            onFailure: onFailure
                        )
                        return
                    }
                    self.finishConnect(profile: profile, connectionId: outcome.connectionId, onSuccess: onSuccess)
                case .failure(let error):
                    let message = Self.describeConnectFailure(error, profile: profile)
                    self.statuses[profile.id] = .failed(message)
                    MobileWidgetSnapshotCenter.shared.publish(profile: profile, status: .failed(message), detail: message)
                    MobileActivityLogStore.shared.record(
                        title: "Connection failed",
                        detail: "\(profile.name): \(message)",
                        profileId: profile.id,
                        systemImage: "exclamationmark.triangle.fill",
                        severity: .critical
                    )
                    onFailure?(message)
                }
            }
        }
    }

    private func finishConnect(
        profile: MobileConnectionProfile,
        connectionId: String,
        onSuccess: () -> Void
    ) {
        statuses[profile.id] = .connected(connectionId: connectionId)
        MobileWidgetSnapshotCenter.shared.publish(
            profile: profile,
            status: .connected(connectionId: connectionId),
            connectionId: connectionId
        )
        MobileActivityLogStore.shared.record(
            title: "Connected",
            detail: "\(profile.username)@\(profile.host):\(profile.port)",
            profileId: profile.id,
            connectionId: connectionId,
            systemImage: profile.kind.supportsTerminal ? "terminal" : "folder",
            severity: .ok
        )
        onSuccess()
    }

    /// User compared the first-connection fingerprint and accepted it.
    func confirmPendingHostKey() {
        guard let pending = pendingHostKeyConfirmation else { return }
        pendingHostKeyConfirmation = nil
        finishConnect(profile: pending.profile, connectionId: pending.connectionId, onSuccess: pending.onSuccess)
    }

    /// User did not recognise the fingerprint: tear the session down and
    /// drop the pinned key so the next attempt prompts again.
    func rejectPendingHostKey() {
        guard let pending = pendingHostKeyConfirmation else { return }
        pendingHostKeyConfirmation = nil
        let message = "Disconnected: the host key for \(pending.profile.host):\(pending.profile.port) was not verified."
        statuses[pending.profile.id] = .failed(message)
        MobileWidgetSnapshotCenter.shared.publish(
            profile: pending.profile,
            status: .failed(message),
            connectionId: pending.connectionId,
            detail: message
        )
        MobileActivityLogStore.shared.record(
            title: "Host key rejected",
            detail: "\(pending.profile.name): \(pending.fingerprint)",
            profileId: pending.profile.id,
            connectionId: pending.connectionId,
            systemImage: "exclamationmark.shield",
            severity: .warning
        )
        let connectionId = pending.connectionId
        let host = pending.host
        let port = pending.port
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rshellDisconnect(connectionId: connectionId)
            _ = rshellForgetHostKey(host: host, port: port)
        }
        pending.onFailure?(message)
    }

    func disconnect(profile: MobileConnectionProfile) {
        guard case .connected(let connectionId) = status(for: profile) else {
            statuses[profile.id] = .disconnected
            return
        }

        statuses[profile.id] = .disconnected
        MobileWidgetSnapshotCenter.shared.publish(
            profile: profile,
            status: .disconnected,
            connectionId: connectionId
        )
        disconnectInBackground(connectionId: connectionId) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                let stillDisconnected = self.status(for: profile) == .disconnected
                if success {
                    MobileActivityLogStore.shared.record(
                        title: "Disconnected",
                        detail: profile.name,
                        profileId: profile.id,
                        connectionId: connectionId,
                        systemImage: "xmark.circle",
                        severity: .info
                    )
                } else {
                    let message = MobileDiagnosticsRedactor.redactSecrets(error ?? "Disconnect failed")
                    if stillDisconnected {
                        self.statuses[profile.id] = .failed(message)
                        MobileWidgetSnapshotCenter.shared.publish(
                            profile: profile,
                            status: .failed(message),
                            connectionId: connectionId,
                            detail: message
                        )
                    }
                    MobileActivityLogStore.shared.record(
                        title: "Disconnect failed",
                        detail: "\(profile.name): \(message)",
                        profileId: profile.id,
                        connectionId: connectionId,
                        systemImage: "exclamationmark.triangle.fill",
                        severity: .warning
                    )
                }
            }
        }
    }

    private static func describeConnectFailure(
        _ error: Error,
        profile: MobileConnectionProfile
    ) -> String {
        let fallback = error.localizedDescription == "The operation couldn’t be completed."
            ? String(reflecting: error)
            : error.localizedDescription

        guard let connectError = error as? ConnectError else {
            return MobileDiagnosticsRedactor.redactSecrets(fallback)
        }

        let message: String
        switch connectError {
        case .ConfigInvalid(let detail):
            message = detail
        case .PassphraseRequired(let detail):
            message = "The private key needs a passphrase. Edit this connection, enter the key passphrase, and save it in iOS Keychain. Detail: \(detail)"
        case .AuthFailed(let detail):
            if profile.authMethod == .publicKey {
                message = """
                The server rejected this SSH key. Make sure the exact public key from agent-ssh is on one line in \(profile.username)'s ~/.ssh/authorized_keys, the file belongs to \(profile.username), ~/.ssh is chmod 700, authorized_keys is chmod 600, and sshd allows PubkeyAuthentication. Detail: \(detail)
                """
            } else {
                message = "Authentication failed. Check the saved password for \(profile.username). Detail: \(detail)"
            }
        case .HostKeyMismatch(let detail):
            message = "The server host key changed. Detail: \(detail)"
        case .Network(let detail):
            message = "Could not reach \(profile.host):\(profile.port). Detail: \(detail)"
        case .Other(let detail):
            message = detail
        }

        return MobileDiagnosticsRedactor.redactSecrets(message)
    }

    private nonisolated func connectInBackground(
        host: String,
        port: UInt16,
        username: String,
        password: String?,
        preparedKey: PreparedMobileSSHKey?,
        passphrase: String?,
        networkOptions: NetworkConnectionOptions,
        sessionId: String,
        completion: @escaping (Result<MobileConnectOutcome, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                preparedKey?.stop()
            }

            let resolution: TailscaleHostResolution
            do {
                resolution = try NetworkPolishResolver.resolve(
                    host: host,
                    port: port,
                    options: networkOptions
                )
            } catch {
                completion(.failure(error))
                return
            }

            let config = FfiConnectConfig(
                host: resolution.connectHost,
                port: port,
                username: username,
                password: password,
                keyPath: preparedKey?.keyPath,
                passphrase: passphrase,
                useAgent: false,
                agentIdentityHint: nil,
                sessionId: sessionId
            )

            do {
                let connectionId = try rshellConnect(config: config)
                completion(.success(MobileConnectOutcome(
                    connectionId: connectionId,
                    firstConnection: rshellTakeFirstConnection(connectionId: connectionId)
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private nonisolated func disconnectInBackground(
        connectionId: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = rshellDisconnect(connectionId: connectionId)
            completion(result.success, result.error)
        }
    }
}

/// Result of a successful `rshellConnect`, plus whether that connect was the
/// first contact with the host (in which case the key was auto-pinned).
struct MobileConnectOutcome {
    let connectionId: String
    let firstConnection: FfiFirstConnection?
}

/// A live session that is waiting for the user to verify the host key
/// fingerprint before it is reported as connected.
struct MobilePendingHostKeyConfirmation: Identifiable {
    let profile: MobileConnectionProfile
    let connectionId: String
    let host: String
    let port: UInt16
    let fingerprint: String
    let onSuccess: () -> Void
    let onFailure: ((String) -> Void)?

    var id: String { connectionId }
}

struct MobileSessionDiagnostics: Codable {
    let profileIdHash: String
    let status: String
}

private extension MobileSessionStatus {
    var diagnosticsLabel: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .failed:
            return "failed"
        }
    }
}
