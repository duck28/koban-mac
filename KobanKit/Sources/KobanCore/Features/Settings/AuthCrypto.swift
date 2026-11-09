import CommonCrypto
import CryptoKit
import Foundation

/// Port of the crypto helpers in src/utils/auth.ts and the passkey wrap commands in
/// src-tauri/src/lib.rs. Formats are identical, so a vault shared with Windows keeps working.
enum AuthCrypto {
    static let verifierIterations: UInt32 = 100_000

    // MARK: base64url (bufferToBase64Url / base64UrlToUint8Array)

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }

    // MARK: Master passphrase verifier

    /// hashPassphraseVerifier: PBKDF2-HMAC-SHA256, 100 000 iterations, 256-bit output,
    /// 16-byte random salt; both base64url without padding.
    static func hashPassphraseVerifier(_ passphrase: String, existingSaltB64: String? = nil) -> (saltB64: String, hashB64: String) {
        let salt = existingSaltB64.flatMap { data(base64URL: $0) } ?? VaultCrypto.randomBytes(16)
        let hash = pbkdf2SHA256(password: Data(passphrase.utf8), salt: salt, iterations: verifierIterations, length: 32)
        return (base64URL(salt), base64URL(hash))
    }

    /// verifyMasterPassphrase
    static func verifyMasterPassphrase(_ passphrase: String, config: AuthConfig) -> Bool {
        guard config.hasMasterPassphrase, let salt = config.passphraseSaltB64, !salt.isEmpty,
              let expected = config.passphraseVerifierHashB64, !expected.isEmpty else { return false }
        return hashPassphraseVerifier(passphrase, existingSaltB64: salt).hashB64 == expected
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: UInt32, length: Int) -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (\(status))")
        return out
    }

    // MARK: Vault secret wrapping (wrap/unwrap_vault_secret_for_credential in lib.rs)

    /// key = derive_aes256_key("koban-passkey-wrap:<credentialId>", vault salt); token = "nonce_b64.ct_b64".
    static func wrapVaultSecret(_ secret: String, credentialId: String, vaultSalt: Data) throws -> String {
        let key = VaultCrypto.deriveKey(secret: "koban-passkey-wrap:\(credentialId)", salt: vaultSalt)
        let sealed = try VaultCrypto.seal(Data(secret.utf8), key: key)
        return "\(sealed.nonceB64).\(sealed.ciphertextB64)"
    }

    enum WrapError: Error, Equatable { case invalidFormat, notUTF8 }

    static func unwrapVaultSecret(_ token: String, credentialId: String, vaultSalt: Data) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw WrapError.invalidFormat }
        let key = VaultCrypto.deriveKey(secret: "koban-passkey-wrap:\(credentialId)", salt: vaultSalt)
        let plain = try VaultCrypto.open(nonceB64: String(parts[0]), ciphertextB64: String(parts[1]), key: key)
        guard let s = String(data: plain, encoding: .utf8) else { throw WrapError.notUTF8 }
        return s
    }

    /// The vault salt (vault_meta.salt_b64) of a koban.db, needed for wrapping and as a stable
    /// identifier of the vault (it survives moves / copies of the file).
    static func vaultSaltB64(databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let db = try? SQLiteConnection(path: databaseURL.path) else { return nil }
        return try? db.scalarString("SELECT value FROM vault_meta WHERE key = 'salt_b64' LIMIT 1")
    }
}

/// Lock rules from App.tsx (initial load effect).
enum AuthRules {
    /// Windows: once setup is completed, the login screen is shown on every launch
    /// (`enabled: loadedAuth.enabled || … || true`). A brand-new ledger goes to setup instead.
    static func shouldLockOnLaunch(setupCompleted: Bool) -> Bool { setupCompleted }

    /// hasCredentialsConfigured in AuthLockScreen.tsx, with the macOS Touch ID credential in place of
    /// Windows passkeys (those can only be verified on Windows).
    static func hasCredentialsConfigured(config: AuthConfig, hasMacCredential: Bool, hasCustomDbPassphrase: Bool) -> Bool {
        hasMacCredential || config.hasMasterPassphrase || hasCustomDbPassphrase
    }

    /// Passphrase sign-in over an already decrypted ledger (handleSignInWithPassphrase): the master
    /// passphrase must match when one is set; a custom vault passphrase is accepted too. Without either,
    /// Windows accepts any input (it only uses it as a vault secret).
    static func acceptsAppPassphrase(_ input: String, config: AuthConfig, vaultPassphrase: String?) -> Bool {
        if config.hasMasterPassphrase, AuthCrypto.verifyMasterPassphrase(input, config: config) { return true }
        if let vp = vaultPassphrase, !vp.isEmpty, vp == input || vp.trimmingCharacters(in: .whitespacesAndNewlines) == input {
            return true
        }
        return !config.hasMasterPassphrase && (vaultPassphrase ?? "").isEmpty
    }

    /// Auto-lock options in SettingsView.tsx (minutes, 0 = never).
    static let autoLockOptions = [0, 5, 15, 30, 60]
}
