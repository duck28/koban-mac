import Foundation
import LocalAuthentication
import Security

/// macOS substitute for Windows Hello / WebAuthn passkeys (registerPasskeyOrWindowsHello /
/// authenticateWithPasskeyOrWindowsHello in src/utils/auth.ts).
///
/// Enrollment is recorded exactly like the Onboarding port does it: a passkey record
/// `{id, name, kind: "windows_hello_native", createdAt}` in the shared AuthConfig. A
/// `windows_hello_native` record is a plain OS user-verification (no credential key), so on macOS it is
/// verified with LocalAuthentication (Touch ID, or the Mac password without Touch ID) and on Windows with
/// Windows Hello — the same record works on both. WebAuthn passkey records stay Windows-only.
///
/// To open a vault encrypted with a custom passphrase, the passphrase is kept in the Keychain
/// (service `com.roland-matuz.koban.touchid`, account = the vault's salt). It is written with
/// `.biometryCurrentSet` access control to the data-protection keychain when the build is entitled,
/// otherwise to the login keychain with every read gated by an LAContext evaluation. It is stored on
/// enrollment and refreshed after every successful passphrase unlock, so vaults enrolled during
/// onboarding (no secret yet) pick it up the first time the passphrase is typed. A Windows record's
/// `wrappedVaultSecret` (unwrap_vault_secret_for_credential) is used as a fallback.
enum TouchIDKeychain {
    static let service = "com.roland-matuz.koban.touchid"
    /// PasskeyCredentialRecord.kind used for Touch ID enrollments (shared with Onboarding).
    static let recordKind = "windows_hello_native"

    enum AuthError: LocalizedError {
        case unavailable(String)
        case failed(String)
        case notEnrolled
        var errorDescription: String? {
            switch self {
            case .unavailable(let m), .failed(let m): return m
            case .notEnrolled: return "No Touch ID credential is registered for this vault."
            }
        }
    }

    // MARK: Availability

    /// Touch ID when the Mac has it; otherwise the Mac login password (like Windows Hello's PIN fallback).
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var anyAuthAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var methodName: String { biometryAvailable ? "Touch ID" : "Mac Login Password" }

    // MARK: Account (vault identity)

    static func account(for databaseURL: URL) -> String {
        if let salt = AuthCrypto.vaultSaltB64(databaseURL: databaseURL) { return "vault:\(salt)" }
        return "path:\(databaseURL.standardizedFileURL.path)"
    }

    // MARK: Verification

    /// Shows the Touch ID (or password) prompt. Returns the evaluated context for Keychain reads.
    static func verify(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw AuthError.unavailable(error?.localizedDescription ?? "Touch ID is not available on this Mac.")
        }
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard ok else { throw AuthError.failed("Touch ID verification did not complete.") }
            return context
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel:
                throw AuthError.failed("Touch ID verification was canceled.")
            default:
                throw AuthError.failed(e.localizedDescription)
            }
        }
    }

    // MARK: Enrollment

    /// Verifies the user, stores the vault secret (if any) and returns the new passkey record.
    static func enroll(account: String, label: String, vaultSecret: String?, displayName: String) async throws -> PasskeyCredentialRecord {
        _ = try await verify(reason: "register \(methodName) for \(displayName) in Koban Vault")
        if let vaultSecret, !vaultSecret.isEmpty { try storeSecret(vaultSecret, account: account) }
        let now = Date().timeIntervalSince1970.rounded(.down)
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PasskeyCredentialRecord(id: "winhello-\(AuthCrypto.base64URL(Data(bytes)))",
                                       name: label.isEmpty ? methodName : label,
                                       kind: recordKind, createdAt: now, lastUsedAt: now)
    }

    /// Stores / replaces the vault secret for Touch ID unlock (no prompt). nil/empty removes it.
    static func updateSecret(_ secret: String?, account: String) {
        if let secret, !secret.isEmpty { try? storeSecret(secret, account: account) } else { deleteItems(account: account) }
    }

    static func removeSecret(account: String) { deleteItems(account: account) }

    // MARK: Sign-in

    /// Prompts, then returns the vault passphrase from the Keychain (nil if none is stored).
    static func authenticate(account: String, displayName: String) async throws -> String? {
        let context = try await verify(reason: "unlock Koban Vault for \(displayName)")
        return readSecret(account: account, context: context)
    }

    // MARK: Keychain

    private struct Payload: Codable { var v = 1; var secret: String? }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private static func storeSecret(_ secret: String, account: String) throws {
        deleteItems(account: account)
        let data = try JSONEncoder().encode(Payload(secret: secret))

        // 1. Biometry-bound item in the data-protection keychain (needs a signed build with entitlements).
        if let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                        .biometryCurrentSet, nil) {
            var q = baseQuery(account: account, dataProtection: true)
            q[kSecAttrAccessControl as String] = access
            q[kSecAttrLabel as String] = "Koban Vault (Touch ID)"
            q[kSecValueData as String] = data
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        }

        // 2. Login keychain; reads are gated by LAContext.
        var q = baseQuery(account: account, dataProtection: false)
        q[kSecAttrLabel as String] = "Koban Vault (Touch ID)"
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.failed("Could not store the Touch ID credential in the Keychain (\(status)).")
        }
    }

    private static func readSecret(account: String, context: LAContext) -> String? {
        for dataProtection in [true, false] {
            var q = baseQuery(account: account, dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationContext as String] = context
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data {
                return (try? JSONDecoder().decode(Payload.self, from: data))?.secret
            }
        }
        return nil
    }

    private static func deleteItems(account: String) {
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }
}
