import AppKit
import Foundation

// OWNER: Settings & Auth — Vault Format v2 lock/unlock/credentials/Touch ID hooks on LedgerStore.
extension LedgerStore {
    var canLockVault: Bool { isUnlockedAndReady }

    func lockVault() {
        guard isUnlockedAndReady else { return }
        dismissModal()
        openMenu = nil
        lock()
    }

    // MARK: - Vault Unlock Flows

    func unlockWithCredentials(passphrase: String, keyfileURL: URL?, rememberKeyfile: Bool) throws {
        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        let loaded = try v.unlock(passphrase: passphrase, keyfileURL: keyfileURL)
        if let vid = v.vaultIDB64 {
            TouchIDKeychain.rememberKeyfileURL(rememberKeyfile ? keyfileURL : nil, vaultID: vid)
        }
        finishUnlock(loaded: loaded)
    }

    func unlockWithRecovery(_ recoveryKey: String) throws {
        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        let loaded = try v.unlockWithRecovery(recoveryKey)
        finishUnlock(loaded: loaded)
    }

    func unlockWithTouchID() async throws {
        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        AuthCenter.shared.refresh(store: self, force: true)
        guard let st = AuthCenter.shared.vaultStatus, let vid = st.vaultID, st.deviceSlotEnrolled else {
            throw TouchIDKeychain.AuthError.notEnrolled
        }
        let owner = (state.settings.ownerDisplayName ?? "").isEmpty ? "Koban Owner" : state.settings.ownerDisplayName!
        let rawDEK = try await TouchIDKeychain.unlockDEK(vaultID: vid, displayName: owner)
        let loaded = try v.unlockWithDEK(rawDEK)
        finishUnlock(loaded: loaded)
    }

    // MARK: - Legacy v1 -> Vault v2 Migration

    func unlockV1ForMigration(passphrase: String?) throws -> (state: LedgerState, hadCustomPassphrase: Bool) {
        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        return try v.unlockV1ForMigration(passphrase: passphrase)
    }

    func migrateV1ToV2(
        v1Passphrase: String?,
        newPassphrase: String,
        keyfileURL: URL?,
        rememberKeyfile: Bool,
        createRecoveryKey: Bool
    ) throws {
        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        let migrated = try v.migrateV1ToV2(
            v1Passphrase: v1Passphrase,
            newPassphrase: newPassphrase,
            keyfileURL: keyfileURL,
            createRecoveryKey: createRecoveryKey
        )
        TouchIDKeychain.cleanupLegacyTouchIDItems()
        if let vid = v.vaultIDB64, rememberKeyfile, let keyfileURL {
            TouchIDKeychain.rememberKeyfileURL(keyfileURL, vaultID: vid)
        }
        AuthCenter.shared.pendingRecoveryKey = migrated.recoveryKey
        finishUnlock(loaded: migrated.state, greet: false)
        notify("Upgraded database to Vault Format v2 (Argon2id + AES-256-GCM).")
    }

    // MARK: - Credentials, Recovery & Touch ID Management

    func changeVaultCredentials(
        currentPassphrase: String?,
        currentKeyfileURL: URL?,
        newPassphrase: String,
        newKeyfileURL: URL?,
        rememberNewKeyfile: Bool,
        rekeyDEK: Bool
    ) throws {
        guard let v = vault, v.isUnlocked else { throw VaultError.vaultLocked }
        flushPendingSave()
        try v.changeCredentials(
            currentPassphrase: currentPassphrase,
            currentKeyfileURL: currentKeyfileURL,
            newPassphrase: newPassphrase,
            newKeyfileURL: newKeyfileURL,
            rekeyDEK: rekeyDEK,
            currentState: state
        )
        if let vid = v.vaultIDB64 {
            TouchIDKeychain.rememberKeyfileURL(rememberNewKeyfile ? newKeyfileURL : nil, vaultID: vid)
            if rekeyDEK, let dek = v.dek {
                if TouchIDKeychain.hasDEK(vaultID: vid) {
                    try? TouchIDKeychain.storeDEK(dek.withUnsafeBytes { Data($0) }, vaultID: vid)
                }
            }
        }
        AuthCenter.shared.refresh(store: self, force: true)
        notify(rekeyDEK
            ? "Updated Master Credentials and rotated 256-bit vault encryption key."
            : "Updated Vault Master Credentials successfully.")
    }

    func generateNewRecoveryKey() throws {
        guard let v = vault, v.isUnlocked else { throw VaultError.vaultLocked }
        let key = try v.generateRecoveryKey()
        AuthCenter.shared.refresh(store: self, force: true)
        AuthCenter.shared.pendingRecoveryKey = key
    }

    func enrollTouchID() async throws {
        guard let v = vault, v.isUnlocked, let vid = v.vaultIDB64, let dek = v.dek else {
            throw VaultError.vaultLocked
        }
        let owner = (state.settings.ownerDisplayName ?? "").isEmpty ? "Koban Owner" : state.settings.ownerDisplayName!
        let dekData = dek.withUnsafeBytes { Data($0) }
        try await TouchIDKeychain.enrollDEK(dekData, vaultID: vid, displayName: owner)
        AuthCenter.shared.refresh(store: self, force: true)
        notify("Enabled Touch ID Quick Unlock (protected by Keychain).")
    }

    func removeTouchID() {
        if let vid = AuthCenter.shared.vaultStatus?.vaultID {
            TouchIDKeychain.removeDEK(vaultID: vid)
        }
        AuthCenter.shared.refresh(store: self, force: true)
        notify("Removed Touch ID Quick Unlock from this Mac.")
    }

    func updateAuthSettings(_ settings: VaultAuthSettings) {
        AuthCenter.shared.updateAuthSettings(settings, store: self)
    }

    // MARK: - App Appearance & Settings

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

    func selectLanguage(_ code: String) {
        L10n.setLanguage(code)
        guard isReady, state.settings.language != code else { return }
        update { $0.settings.language = code }
    }
}
