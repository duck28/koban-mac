import AppKit
import Foundation

// OWNER: Settings & Auth — lock hooks used by the TopBar, menus and LedgerStore.
// Port of the auth logic in src/App.tsx (auth config load, lock-on-launch, auto-lock,
// handleUnlockSuccess, handleUpdateAuthConfig, handleUpdateVaultPassphrase).
extension LedgerStore {
    /// Called right after a ledger loads; return true to show the app lock screen (isAppLocked).
    func shouldLockAfterLoad() -> Bool {
        let auth = AuthCenter.shared
        auth.refresh(store: self, force: true)
        L10n.setLanguage(state.settings.language)
        applyPersonalization()
        AutoLockMonitor.install(store: self)
        AutoLockMonitor.resetIdle()

        // Only the first load of a session locks (restores, DB moves and passphrase changes reload too).
        guard !auth.didLaunchCheck else { return false }
        auth.didLaunchCheck = true
        // The vault was just decrypted with its passphrase on the lock screen — that was the sign-in.
        if let vault, vault.passphrase != nil { return false }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["KOBAN_SNAPSHOT"] != nil, env["KOBAN_SNAPSHOT_ACTION"] != "auth-lock" { return false }
        #endif
        let lock = AuthRules.shouldLockOnLaunch(setupCompleted: state.settings.setupCompleted)
        if lock {
            // Windows forces `enabled` on in memory ("Require login on existing setup").
            var next = auth.config
            next.enabled = true
            auth.setInMemory(next)
        }
        return lock
    }

    /// Windows lets you lock at any time (setIsLocked(true)).
    var canLockVault: Bool { isReady }

    /// TopBar lock button / ⌘L / Settings "Lock Vault Now" / auto-lock.
    /// A vault with a custom passphrase is fully locked (decrypted ledger and key dropped); otherwise
    /// the login screen is shown over the loaded app, like on Windows.
    func lockVault() {
        guard isReady else { return }
        flushPendingSave()
        dismissModal()
        openMenu = nil
        if hasCustomPassphrase, vault?.passphrase != nil {
            lock()
        } else {
            isAppLocked = true
        }
    }

    // MARK: - Auth config

    var authConfig: AuthConfig { AuthCenter.shared.config }

    /// handleUpdateAuthConfig
    func updateAuthConfig(_ next: AuthConfig) {
        AuthCenter.shared.save(next, store: self)
    }

    /// handleUnlockSuccess: persists an updated config, hides the lock screen, greets the user.
    func completeSignIn(updatedConfig: AuthConfig? = nil) {
        if let updatedConfig { AuthCenter.shared.save(updatedConfig, store: self) }
        isAppLocked = false
        AutoLockMonitor.resetIdle()
        let name = (updatedConfig?.userDisplayName).flatMap { $0.isEmpty ? nil : $0 }
            ?? (authConfig.userDisplayName.isEmpty ? "Koban Owner" : authConfig.userDisplayName)
        notify("Signed in as \(name).")
    }

    // MARK: - Vault passphrase (set_vault_passphrase / handleUpdateVaultPassphrase)

    /// Sets (or clears with nil / empty) the custom vault passphrase and re-encrypts the ledger with it.
    /// Also refreshes the secret stored for Touch ID unlock.
    func applyVaultPassphrase(_ passphrase: String?) {
        flushPendingSave()
        let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let vault = try self.vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
            self.vault = vault
            try vault.setPassphrase(trimmed.isEmpty ? nil : passphrase, reencrypting: state)
            hasCustomPassphrase = vault.hasCustomPassphrase
            if AuthCenter.shared.hasMacCredential {
                TouchIDKeychain.updateSecret(vault.passphrase, account: AuthCenter.shared.account)
            }
            notify(trimmed.isEmpty ? "Reverted AES-256-GCM vault to default key."
                                   : "Updated AES-256-GCM vault to use your custom passphrase.")
        } catch {
            notify("Could not change the vault passphrase: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings (onUpdateSettings)

    /// updateSettings(patch) — applies theme / palette / personalization side effects too.
    func applySettingsChange(_ patch: (inout AppSettings) -> Void) {
        let before = state.settings
        update { patch(&$0.settings) }
        let after = state.settings
        if before.theme != after.theme || before.themePalette != after.themePalette { applyAppearance() }
        if before.density != after.density || before.highContrastAmounts != after.highContrastAmounts {
            applyPersonalization()
        }
        if before.language != after.language { L10n.setLanguage(after.language) }
    }

    /// LanguageSelect onChanged → settings.language.
    func selectLanguage(_ code: String) {
        L10n.setLanguage(code)
        guard isReady, state.settings.language != code else { return }
        update { $0.settings.language = code }
    }
}
