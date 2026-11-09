import AppKit
import Foundation
import Observation

/// Auth state that App.tsx keeps in useState (authConfig, …) — LedgerStore extensions can't add
/// stored properties, so it lives in this singleton. Loaded per database file.
@MainActor
@Observable
final class AuthCenter {
    static let shared = AuthCenter()

    /// The AuthConfig of the active koban.db (vault_meta.auth_config).
    private(set) var config: AuthConfig = .default
    /// Database path the config/credential were loaded for.
    private(set) var loadedPath: String?
    /// Keychain account (vault salt) of the active vault.
    private(set) var account: String = ""
    /// vault_meta.salt_b64 of the active vault (for unwrapping Windows-wrapped vault secrets).
    private(set) var vaultSaltB64: String?
    /// Set once the launch-time lock decision was made (only the first load of a session locks).
    @ObservationIgnored var didLaunchCheck = false

    /// Passkey records usable on macOS: `windows_hello_native` (OS user verification → Touch ID).
    /// Includes records enrolled by the Onboarding wizard ({name: "Touch ID", kind: "windows_hello_native"}).
    var macCredentials: [PasskeyCredentialRecord] { config.passkeys.filter { $0.kind == TouchIDKeychain.recordKind } }
    var hasMacCredential: Bool { !macCredentials.isEmpty }

    /// Vault passphrase for a Touch ID unlock: the Keychain secret, else a Windows-wrapped secret.
    func resolveSecret(keychainSecret: String?) -> String? {
        if let keychainSecret, !keychainSecret.isEmpty { return keychainSecret }
        guard let saltB64 = vaultSaltB64, let salt = Data(base64Encoded: saltB64) else { return nil }
        for rec in macCredentials {
            if let token = rec.wrappedVaultSecret,
               let s = try? AuthCrypto.unwrapVaultSecret(token, credentialId: rec.id, vaultSalt: salt), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Updates lastUsedAt of the macOS-usable records after a Touch ID sign-in (handleSignInWithPasskey).
    func configMarkingUsed() -> AuthConfig {
        var next = config
        let now = Date().timeIntervalSince1970.rounded(.down)
        if let idx = next.passkeys.firstIndex(where: { $0.kind == TouchIDKeychain.recordKind }) {
            next.passkeys[idx].lastUsedAt = now
        }
        return next
    }

    /// Re-reads the auth config + Touch ID metadata if the active database changed (or `force`).
    func refresh(store: LedgerStore, force: Bool = false) {
        let url = KobanPaths.activeDatabaseURL
        guard force || loadedPath != url.path else { return }
        loadedPath = url.path
        var json: String?
        if let vault = store.vault, vault.url.standardizedFileURL == url.standardizedFileURL {
            json = (try? vault.loadAuthConfigJSON()) ?? nil
        } else if FileManager.default.fileExists(atPath: url.path), let vault = try? KobanVault(url: url) {
            json = (try? vault.loadAuthConfigJSON()) ?? nil
        }
        config = AuthConfig.parse(json)
        vaultSaltB64 = AuthCrypto.vaultSaltB64(databaseURL: url)
        account = TouchIDKeychain.account(for: url)
    }

    /// In-memory only (like setAuthConfig without saveAuthConfig).
    func setInMemory(_ next: AuthConfig) { config = next }

    /// handleUpdateAuthConfig: state + persist to vault_meta.
    func save(_ next: AuthConfig, store: LedgerStore) {
        config = next
        do {
            let json = try next.jsonString()
            if let vault = store.vault, vault.url.standardizedFileURL == KobanPaths.activeDatabaseURL.standardizedFileURL {
                try vault.saveAuthConfigJSON(json)
            } else {
                try KobanVault(url: KobanPaths.activeDatabaseURL).saveAuthConfigJSON(json)
            }
        } catch {
            store.notify("Could not save login settings: \(error.localizedDescription)")
        }
    }

}

/// Inactivity auto-lock (the useEffect timer in App.tsx): any key press or click resets the timer;
/// after `autoLockMinutes` idle the app lock screen is shown.
@MainActor
enum AutoLockMonitor {
    private static var monitor: Any?
    private static var timer: Timer?
    private static var lastActivity = Date()
    private static weak var store: LedgerStore?

    static func install(store: LedgerStore) {
        self.store = store
        guard monitor == nil else { return }
        lastActivity = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            lastActivity = Date()
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    /// Restart the idle period (e.g. right after unlocking).
    static func resetIdle() { lastActivity = Date() }

    private static func tick() {
        guard let store, store.isReady, !store.isAppLocked else {
            lastActivity = Date()
            return
        }
        let minutes = AuthCenter.shared.config.autoLockMinutes
        guard minutes > 0 else { return }
        if Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 {
            store.lockVault()
        }
    }
}
