import Foundation

/// Resolves stored credentials for a connection profile. Shared by the manual
/// connect flow's eligibility checks and by startup auto-connect so both agree
/// on what "has stored credentials" means.
@MainActor
enum MobileCredentialResolver {
    enum Resolution {
        /// Credentials are ready (password and/or passphrase may be nil when the
        /// auth method doesn't need them, e.g. an unencrypted key).
        case ready(password: String?, passphrase: String?)
        /// The profile needs the user to enter/save something first.
        case needsManualEntry(String)
        /// Credentials exist but could not be unlocked.
        case failed(String)
    }

    /// Whether a profile can connect without prompting the user to type or save
    /// a credential. Password profiles need a stored password; key profiles only
    /// need a key reference (the passphrase, if any, is optional).
    static func canAutoConnect(
        profile: MobileConnectionProfile,
        keychainManager: MobileKeychainManager
    ) -> Bool {
        switch profile.authMethod {
        case .password:
            return keychainManager.hasSecret(kind: .sshPassword, account: profile.keychainAccount)
        case .publicKey:
            return profile.sshKeyReference != nil
        }
    }

    static func resolve(
        profile: MobileConnectionProfile,
        keychainManager: MobileKeychainManager
    ) async -> Resolution {
        let reason = "Unlock saved credentials for \(profile.name)."

        switch profile.authMethod {
        case .password:
            guard keychainManager.hasSecret(kind: .sshPassword, account: profile.keychainAccount) else {
                return .needsManualEntry("Save a password before connecting.")
            }
            guard let password = await keychainManager.loadSecret(
                kind: .sshPassword,
                account: profile.keychainAccount,
                reason: reason
            ) else {
                return .failed("Could not unlock the saved password.")
            }
            return .ready(password: password, passphrase: nil)

        case .publicKey:
            guard profile.sshKeyReference != nil else {
                return .needsManualEntry("Generate or import an SSH key before connecting.")
            }
            guard keychainManager.hasSecret(kind: .sshKeyPassphrase, account: profile.keychainAccount) else {
                // Key without a stored passphrase — connect with no passphrase.
                return .ready(password: nil, passphrase: nil)
            }
            guard let passphrase = await keychainManager.loadSecret(
                kind: .sshKeyPassphrase,
                account: profile.keychainAccount,
                reason: reason
            ) else {
                return .failed("Could not unlock the saved key passphrase.")
            }
            return .ready(password: nil, passphrase: passphrase)
        }
    }
}

/// Drives startup auto-connect: every profile with stored credentials that
/// isn't already connecting/connected gets a connection attempt. Credentials
/// are resolved sequentially so the keychain vault unlock prompts at most once
/// for the whole batch (subsequent reads reuse the unlock TTL).
@MainActor
enum MobileAutoConnectCoordinator {
    @discardableResult
    static func connectEligible(
        profiles: [MobileConnectionProfile],
        sessionStore: MobileSessionStore,
        keychainManager: MobileKeychainManager,
        connectionStore: MobileConnectionStore
    ) async -> Int {
        let eligible = profiles.filter { profile in
            // Per-profile opt-out: only profiles marked "Connect on
            // launch" participate in startup auto-connect.
            guard profile.autoConnect else { return false }
            guard MobileCredentialResolver.canAutoConnect(
                profile: profile,
                keychainManager: keychainManager
            ) else { return false }

            switch sessionStore.status(for: profile) {
            case .connected, .connecting:
                return false
            case .disconnected, .failed:
                return true
            }
        }

        guard !eligible.isEmpty else { return 0 }

        var started = 0
        for profile in eligible {
            let resolution = await MobileCredentialResolver.resolve(
                profile: profile,
                keychainManager: keychainManager
            )
            guard case .ready(let password, let passphrase) = resolution else { continue }

            sessionStore.connect(
                profile: profile,
                password: password,
                passphrase: passphrase,
                onSuccess: { connectionStore.markConnected(profile) },
                onFailure: { _ in }
            )
            started += 1
        }
        return started
    }
}
