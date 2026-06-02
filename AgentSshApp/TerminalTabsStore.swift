import Combine
import Foundation
import OSLog
import AgentSshMacOS

/// Owns the set of terminal tabs visible in `MainPanel`. The sidebar
/// drives this when the user picks a profile to connect; `MainPanel`
/// observes it and renders one tab per entry.
///
/// Connect flow (entirely on the main actor — FFI calls hop to the
/// bridge queue internally):
///
///   sidebar.onConnect(profile)
///     → store.openConnection(profile)
///         → CredentialResolver.resolve()
///         → performConnect(...) → SSH handshake + PTY start
///         → append a TerminalTab and select it
///
/// Errors surface as the optional `lastError` string for the UI to
/// display — actual presentation (toast / sheet) is up to the consumer.
@MainActor
final class TerminalTabsStore: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?
    @Published var lastError: String?
    /// Set when a tab was demoted from SSH to SFTP because the
    /// server denied the shell channel. The wrapped profile id lets
    /// the host alert offer a one-click "convert this profile to
    /// SFTP permanently" action — without the id, the user would
    /// have to find the profile in the sidebar, open the editor,
    /// flip the kind, and save, every time they reconnect.
    @Published var pendingFallback: PendingFallback?

    /// Carries the data the SSH→SFTP fallback alert needs: which
    /// profile to convert if the user opts in, and what to display.
    struct PendingFallback: Equatable {
        let profileId: String
        let profileName: String

        var message: String {
            "\"\(profileName)\" was switched to SFTP-only mode for this session because the server denied shell access. Convert the saved profile to SFTP so future connects skip the shell attempt?"
        }
    }
    /// Profile ids currently inside an in-flight `openConnection` call.
    /// The sidebar reads this to swap the row's icon for a spinner and
    /// guard the click so a double-tap can't fire a second connect for
    /// the same profile while the first is still in handshake / PTY
    /// start.
    @Published private(set) var connectingProfileIds: Set<String> = []

    private let logger = Logger(subsystem: "com.mc-ssh", category: "terminal-tabs")
    private var cancellables = Set<AnyCancellable>()

    init() {
        AgentSshEventBus.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleEvent(_ event: AgentSshEvent) {
        switch event {
        case .terminalTitleChanged(let connectionId, let title):
            guard !title.isEmpty else { return }
            setTitle(title, forConnectionId: connectionId)

        case .connectionStatus(let connectionId, let payload):
            setStatus(
                TerminalConnectionStatus.parse(payload: payload),
                forConnectionId: connectionId
            )

        case .transferProgress, .showCommandPalette, .showDashboard, .tcpdumpLine:
            break
        }
    }

    /// Update the displayed title for a tab matched by its connection id.
    func setTitle(_ title: String, forConnectionId connectionId: String) {
        guard let idx = tabs.firstIndex(where: { $0.connectionId == connectionId })
        else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[idx].title = trimmed
    }

    /// Update the connection status for a tab.
    func setStatus(_ status: TerminalConnectionStatus, forConnectionId connectionId: String) {
        guard let idx = tabs.firstIndex(where: { $0.connectionId == connectionId })
        else { return }
        guard tabs[idx].status != status else { return }
        logger.info("\(connectionId, privacy: .public) status: \(status.rawValue)")
        tabs[idx].status = status
        publishWidgetSnapshot(for: tabs[idx])
    }

    // MARK: - Open connection

    /// Open a terminal tab for a saved connection. Credential resolution
    /// (Keychain → prompt → evict → retry) is delegated to
    /// `CredentialResolver`; `performConnect` does the actual SSH/PTY work.
    func openConnection(
        _ profile: ConnectionProfile,
        password: String? = nil,
        passphrase: String? = nil
    ) async {
        logger.info("Opening connection \(profile.name, privacy: .public)")
        lastError = nil

        // One tab per profile.
        if password == nil && passphrase == nil,
           let existing = tabs.first(where: { $0.profile.id == profile.id }) {
            activeTabId = existing.id
            logger.info("Reusing existing tab for \(profile.name, privacy: .public)")
            return
        }

        let isOutermost = !connectingProfileIds.contains(profile.id)
        if isOutermost {
            connectingProfileIds.insert(profile.id)
        }
        defer {
            if isOutermost {
                connectingProfileIds.remove(profile.id)
            }
        }

        let sessionId = String(UUID().uuidString.prefix(8))
        let resolver = CredentialResolver(
            profile: profile,
            passwordProvider: { account, message in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        cont.resume(returning: KeychainManager.shared.promptPassword(account: account, message: message))
                    }
                }
            },
            passphraseProvider: { keyPath in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        cont.resume(returning: KeychainManager.shared.promptPassphrase(keyPath: keyPath))
                    }
                }
            }
        )
        await connectWithRetry(profile: profile, resolver: resolver, sessionId: sessionId, tabId: nil)
    }

    // MARK: - Reconnect

    /// Re-establish a dead session in place. Reuses the original
    /// connection id and sessionId. Credential resolution now uses the
    /// same `CredentialResolver` + `connectWithRetry` loop as
    /// `openConnection`, so a stale password triggers a re-prompt
    /// rather than silently failing.
    func reconnect(tabId: UUID) async {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[idx]
        let profile = tab.profile
        let sessionId = tab.sessionId

        logger.info("Reconnecting \(tab.connectionId, privacy: .public)")
        tabs[idx].status = .connecting
        publishWidgetSnapshot(for: tabs[idx])
        lastError = nil

        BridgeManager.shared.disconnect(connectionId: tab.connectionId)

        let resolver = CredentialResolver(
            profile: profile,
            passwordProvider: { account, message in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        cont.resume(returning: KeychainManager.shared.promptPassword(account: account, message: message))
                    }
                }
            },
            passphraseProvider: { keyPath in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        cont.resume(returning: KeychainManager.shared.promptPassphrase(keyPath: keyPath))
                    }
                }
            }
        )
        await connectWithRetry(profile: profile, resolver: resolver, sessionId: sessionId, tabId: tabId)
    }

    // MARK: - Shared connect + retry loop

    /// Core connect loop shared by `openConnection` and `reconnect`.
    /// `tabId` is nil for first-time connects; non-nil for reconnect
    /// (allowing the existing tab's generation and session to update
    /// in-place).
    ///
    /// Retry policy: stored-credential failures trigger eviction +
    /// re-prompt (once). Host-key mismatch triggers forget + retry
    /// (once, user opt-in). Passphrase-missing triggers prompt + retry
    /// (once).
    ///
    /// `explicitPassword` / `explicitPassphrase` override credential
    /// resolution for the retry path — when set, `resolver.resolve()`
    /// is skipped and the given credential is used directly, preventing
    /// a double prompt.
    private func connectWithRetry(
        profile: ConnectionProfile,
        resolver: CredentialResolver,
        sessionId: String,
        tabId: UUID?,
        explicitPassword: String? = nil,
        explicitPassphrase: String? = nil
    ) async {
        let isReconnect = tabId != nil

        let credential: CredentialResolver.ResolvedCredential?
        if explicitPassword != nil || explicitPassphrase != nil {
            credential = CredentialResolver.ResolvedCredential(
                password: explicitPassword,
                passphrase: explicitPassphrase,
                usedStoredPassword: false,
                usedStoredPassphrase: false
            )
        } else {
            guard let resolved = await resolver.resolve() else {
                logger.info("Credential resolution cancelled for \(profile.name, privacy: .public)")
                return
            }
            credential = resolved
        }
        guard let credential else { return }

        let connectionId: String
        let preparedKey: PreparedSSHKey?
        do {
            if profile.authMethod == .publicKey {
                preparedKey = try SSHKeyAccessCoordinator.prepare(
                    profile.sshKeyReference,
                    profile: profile,
                    sessionId: sessionId
                )
            } else {
                preparedKey = nil
            }
            defer { preparedKey?.stop() }

            let resolvedId: String
            if isReconnect {
                resolvedId = try await BridgeManager.shared.connect(
                    profile: profile,
                    password: credential.password,
                    keyPath: preparedKey?.keyPath,
                    passphrase: credential.passphrase,
                    useAgent: preparedKey?.useAgent ?? false,
                    agentIdentityHint: preparedKey?.agentIdentityHint,
                    sessionId: sessionId
                )
                // Reconnect must land on the same connection id.
                guard let tabId, let idx = tabs.firstIndex(where: { $0.id == tabId }),
                      let existingConnId = tabs[idx].connectionId as String?,
                      resolvedId == existingConnId
                else {
                    lastError = "Reconnect routed to a different connection id; aborting"
                    logger.error("Reconnect mismatch for \(sessionId, privacy: .public)")
                    if let tabId { markTabError(tabId) }
                    return
                }
            } else {
                resolvedId = try await BridgeManager.shared.connect(
                    profile: profile,
                    password: credential.password,
                    keyPath: preparedKey?.keyPath,
                    passphrase: credential.passphrase,
                    useAgent: preparedKey?.useAgent ?? false,
                    agentIdentityHint: preparedKey?.agentIdentityHint,
                    sessionId: sessionId
                )
            }
            connectionId = resolvedId

            // Persist freshly-prompted credentials that just worked.
            if let pw = credential.password {
                resolver.persistPasswordIfPrompted(
                    pw,
                    usedStoredPassword: credential.usedStoredPassword
                )
            }
            if let pp = credential.passphrase {
                resolver.persistPassphraseIfPrompted(
                    pp,
                    usedStoredPassphrase: credential.usedStoredPassphrase
                )
            }

        } catch let error as BridgeError {
            let retried = await handleConnectError(
                error, profile: profile, resolver: resolver, sessionId: sessionId, tabId: tabId
            )
            if retried { return }
            // Not retried — surface and bail.
            lastError = error.localizedDescription
            logConnectFailure(profile: profile, message: error.localizedDescription)
            if let tabId { markTabError(tabId) }
            return
        } catch {
            lastError = error.localizedDescription
            logConnectFailure(profile: profile, message: error.localizedDescription)
            if let tabId { markTabError(tabId) }
            return
        }

        // PTY start or SFTP mode.
        var generation: UInt64 = 0
        var kindOverride: ConnectionKind? = nil
        var displayTitle = profile.name

        if profile.kind.supportsTerminal {
            do {
                generation = try await BridgeManager.shared.openTerminal(connectionId: connectionId)
            } catch {
                if await BridgeManager.shared.canUseSftp(connectionId: connectionId) {
                    logger.info("Server denied PTY but accepts SFTP; demoting tab for \(connectionId, privacy: .public)")
                    kindOverride = .sftp
                    displayTitle = "\(profile.name) (SFTP)"
                    pendingFallback = PendingFallback(
                        profileId: profile.id,
                        profileName: profile.name
                    )
                } else {
                    lastError = "Server refused both shell and SFTP. Connection is unusable."
                    BridgeManager.shared.disconnect(connectionId: connectionId)
                    if let tabId { markTabError(tabId) }
                    return
                }
            }
        }

        if let tabId, let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            // Reconnect: update existing tab in place.
            tabs[idx].ptyGeneration = generation
            tabs[idx].kindOverride = kindOverride
            tabs[idx].title = displayTitle
            tabs[idx].status = .connected
            WidgetMonitoringSnapshotCenter.shared.remove(id: "ssh-failure:\(profile.id)")
            publishWidgetSnapshot(for: tabs[idx])
            if generation > 0 {
                TerminalSessionManager.shared.updateGeneration(generation, forConnectionId: connectionId)
            }
            ActivityLogStore.shared.record(
                title: "Reconnected",
                detail: profile.name,
                profileId: profile.id,
                connectionId: connectionId,
                icon: "arrow.clockwise",
                severity: .success
            )
            await PortForwardingCoordinator.shared.autoStart(
                profileId: profile.id,
                connectionId: connectionId
            )
        } else {
            // First connect: append new tab.
            let tab = TerminalTab(
                id: UUID(),
                profile: profile,
                sessionId: sessionId,
                connectionId: connectionId,
                ptyGeneration: generation,
                title: displayTitle,
                order: tabs.count,
                kindOverride: kindOverride
            )
            tabs.append(tab)
            activeTabId = tab.id
            WidgetMonitoringSnapshotCenter.shared.remove(id: "ssh-failure:\(profile.id)")
            publishWidgetSnapshot(for: tab)
            ActivityLogStore.shared.record(
                title: "Connected",
                detail: "\(profile.username)@\(profile.host):\(profile.port)",
                profileId: profile.id,
                connectionId: connectionId,
                icon: profile.kind.supportsTerminal ? "terminal" : "folder",
                severity: .success
            )
            await PortForwardingCoordinator.shared.autoStart(
                profileId: profile.id,
                connectionId: connectionId
            )
        }
    }

    /// Handle a `BridgeError` from the connect attempt. Returns `true`
    /// if the error was handled by a retry (the caller must not continue),
    /// `false` if the error is fatal.
    private func handleConnectError(
        _ error: BridgeError,
        profile: ConnectionProfile,
        resolver: CredentialResolver,
        sessionId: String,
        tabId: UUID?
    ) async -> Bool {
        switch error {
        // Stored password rejected → evict, re-prompt, retry once.
        case .authFailed where profile.authMethod == .password:
            let cred = await resolver.resolve()
            guard cred?.password != nil,
                  cred?.usedStoredPassword == true
            else { return false }
            logger.info("Evicting stale Keychain password and re-prompting")
            resolver.evictStalePassword()
            guard let fresh = await KeychainManager.shared.promptPasswordAsync(
                account: profile.keychainAccount,
                message: "The stored password was rejected. Enter a new password."
            ) else { return false }
            await connectWithRetry(
                profile: profile, resolver: resolver, sessionId: sessionId, tabId: tabId,
                explicitPassword: fresh
            )
            return true

        // Host key changed → prompt trust, forget + retry on confirm.
        case .hostKeyMismatch(let host, let port, let detail):
            let promptHost = host.isEmpty ? profile.host : host
            let promptPort = port == 0 ? profile.port : port
            let outcome = await HostKeyPrompt.presentMismatch(
                host: promptHost,
                port: promptPort,
                detail: detail
            )
            if outcome == .trust {
                logger.info("User trusted new host key for \(promptHost, privacy: .public):\(promptPort); retrying")
                await connectWithRetry(profile: profile, resolver: resolver, sessionId: sessionId, tabId: tabId)
                return true
            }
            return false

        // Stored passphrase rejected → evict, re-prompt, retry once.
        // Also handles encrypted-key-with-no-passphrase → prompt once.
        case .passphraseRequired where profile.authMethod == .publicKey:
            let cred = await resolver.resolve()
            if cred?.usedStoredPassphrase == true {
                logger.info("Evicting stale key passphrase and re-prompting")
                resolver.evictStalePassphrase()
            }
            guard let fresh = await KeychainManager.shared.promptPassphraseAsync(
                keyPath: keyPromptLabel(for: profile)
            ) else { return false }
            logger.info("Retrying connect with prompted passphrase")
            await connectWithRetry(
                profile: profile, resolver: resolver, sessionId: sessionId, tabId: tabId,
                explicitPassphrase: fresh
            )
            return true

        default:
            return false
        }
    }

    private func markTabError(_ tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].status = .error
        publishWidgetSnapshot(for: tabs[idx])
    }

    private func logConnectFailure(profile: ConnectionProfile, message: String) {
        WidgetMonitoringSnapshotCenter.shared.upsert(
            .sshFailure(profile: profile, message: message)
        )
        ActivityLogStore.shared.record(
            title: "Connection failed",
            detail: "\(profile.name): \(message)",
            profileId: profile.id,
            icon: "exclamationmark.triangle.fill",
            severity: .critical
        )
        logger.error("Connect failed: \(message, privacy: .public)")
    }

    private func keyPromptLabel(for profile: ConnectionProfile) -> String {
        SSHKeyVault.shared.metadata(for: profile.sshKeyReference)?.label
            ?? profile.sshKeyReference?.displayName
            ?? profile.keychainAccount
    }

    // MARK: - Close

    /// Close a tab, tearing down the PTY (when present) and disconnecting
    /// the SSH transport.
    func closeTab(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        let wasActive = activeTabId == tabId

        if tab.effectiveKind.supportsTerminal {
            BridgeManager.shared.flushPendingInput(connectionId: tab.connectionId)
            BridgeManager.shared.closeTerminal(
                connectionId: tab.connectionId,
                generation: tab.ptyGeneration
            )
        }
        BridgeManager.shared.disconnect(connectionId: tab.connectionId)
        SSHAgentApprovalCoordinator.shared.revokeSession(sessionId: tab.sessionId)
        PortForwardingCoordinator.shared.markStopped(
            profileId: tab.profile.id,
            connectionId: tab.connectionId
        )
        removeWidgetSnapshot(for: tab)
        ActivityLogStore.shared.record(
            title: "Disconnected",
            detail: tab.profile.name,
            profileId: tab.profile.id,
            connectionId: tab.connectionId,
            icon: "xmark.circle",
            severity: .info
        )

        tabs.remove(at: index)
        for i in tabs.indices {
            tabs[i].order = i
        }

        if wasActive {
            if tabs.indices.contains(index) {
                activeTabId = tabs[index].id
            } else {
                activeTabId = tabs.last?.id
            }
        }
    }

    func closeActiveTab() {
        guard let activeTabId else { return }
        closeTab(activeTabId)
    }

    func reconnectActive() async {
        guard let activeTabId else { return }
        await reconnect(tabId: activeTabId)
    }

    func setActive(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
    }

    func selectAdjacentTab(forward: Bool) {
        guard tabs.count > 1 else { return }
        let sorted = tabs.sorted { $0.order < $1.order }
        let currentIndex = sorted.firstIndex { $0.id == activeTabId } ?? 0
        let nextIndex = forward
            ? (currentIndex + 1) % sorted.count
            : (currentIndex - 1 + sorted.count) % sorted.count
        activeTabId = sorted[nextIndex].id
    }

    /// Set or clear the per-tab theme override. `nil` falls back to the
    /// global `@AppStorage("terminalTheme")`.
    func setTheme(_ themeId: String?, forTabId tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].themeOverride = themeId
    }

    var activeTab: TerminalTab? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }

    var activeOpenSSHTab: TerminalTab? {
        guard let tab = activeTab,
              tab.effectiveKind.supportsTerminal,
              tab.status == .connected
        else { return nil }
        return tab
    }

    var connectedSSHTabs: [TerminalTab] {
        tabs
            .filter {
                $0.effectiveKind.supportsTerminal && $0.status == .connected
            }
            .sorted { $0.order < $1.order }
    }

    private func publishWidgetSnapshot(for tab: TerminalTab) {
        WidgetMonitoringSnapshotCenter.shared.upsert(
            .sshConnection(
                profile: tab.profile,
                connectionId: tab.connectionId,
                status: tab.status,
                effectiveKind: tab.effectiveKind
            )
        )
    }

    private func removeWidgetSnapshot(for tab: TerminalTab) {
        WidgetMonitoringSnapshotCenter.shared.remove(id: "ssh:\(tab.profile.id)")
    }
}

// MARK: - Async prompt helpers

private extension KeychainManager {
    func promptPasswordAsync(account: String, message: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                cont.resume(returning: self.promptPassword(account: account, message: message))
            }
        }
    }

    func promptPassphraseAsync(keyPath: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                cont.resume(returning: self.promptPassphrase(keyPath: keyPath))
            }
        }
    }
}
