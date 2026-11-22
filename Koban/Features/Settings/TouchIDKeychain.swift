import Foundation
import LocalAuthentication
import Security

/// Native macOS credential storage for Vault Format v2 and WebDAV.
///
/// - Touch ID Quick Unlock stores the raw 32-byte Vault DEK (never the Master Password) in
///   Keychain (`service = "com.roland-matuz.koban.vault"`, `account = "vault2:<vaultID>"`).
///   When entitled (Developer ID + keychain-access-groups), it uses the Data Protection Keychain
///   with `.biometryCurrentSet`; for ad-hoc signed builds it falls back to the login Keychain
///   gated by an explicit `LAContext` evaluation.
/// - WebDAV passwords are stored separately in Keychain (`service = "com.roland-matuz.koban.webdav"`)
///   so `koban.db` synced via iCloud/Synology/WebDAV never carries plaintext WebDAV passwords.
enum TouchIDKeychain {
    static let vaultService = "com.roland-matuz.koban.vault"
    static let legacyTouchIDService = "com.roland-matuz.koban.touchid"
    static let webdavService = "com.roland-matuz.koban.webdav"
    private static let keyfilePrefPrefix = "koban_v2_keyfile_"

    enum AuthError: LocalizedError {
        case unavailable(String)
        case failed(String)
        case notEnrolled
        var errorDescription: String? {
            switch self {
            case .unavailable(let m), .failed(let m): return m
            case .notEnrolled: return "Touch ID Quick Unlock is not enrolled for this vault."
            }
        }
    }

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var anyAuthAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var methodName: String { biometryAvailable ? "Touch ID" : "Mac Login Password" }

    private static func accountKey(for vaultID: String) -> String {
        "vault2:\(vaultID)"
    }

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

    // MARK: - Vault v2 DEK Storage

    static func enrollDEK(_ rawDEK: Data, vaultID: String, displayName: String) async throws {
        guard rawDEK.count == 32 else { throw AuthError.failed("Invalid DEK length.") }
        _ = try await verify(reason: "enable \(methodName) Quick Unlock for \(displayName) in Koban Vault")
        try storeDEK(rawDEK, vaultID: vaultID)
    }

    static func hasDEK(vaultID: String) -> Bool {
        let account = accountKey(for: vaultID)
        for dataProtection in [true, false] {
            var q = vaultQuery(account: account, dataProtection: dataProtection)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess || status == errSecInteractionNotAllowed {
                return true
            }
        }
        return false
    }

    static func unlockDEK(vaultID: String, displayName: String) async throws -> Data {
        let context = try await verify(reason: "unlock Koban Vault for \(displayName)")
        let account = accountKey(for: vaultID)
        for dataProtection in [true, false] {
            var q = vaultQuery(account: account, dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationContext as String] = context
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data, data.count == 32 {
                return data
            }
        }
        throw AuthError.notEnrolled
    }

    static func storeDEK(_ rawDEK: Data, vaultID: String) throws {
        let account = accountKey(for: vaultID)
        removeDEK(vaultID: vaultID)

        if let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) {
            var q = vaultQuery(account: account, dataProtection: true)
            q[kSecAttrAccessControl as String] = access
            q[kSecAttrLabel as String] = "Koban Vault v2 DEK (\(methodName))"
            q[kSecValueData as String] = rawDEK
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        }

        var q = vaultQuery(account: account, dataProtection: false)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "Koban Vault v2 DEK (\(methodName))"
        q[kSecValueData as String] = rawDEK
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.failed("Could not store Vault DEK in Keychain (\(status)).")
        }
    }

    static func removeDEK(vaultID: String) {
        let account = accountKey(for: vaultID)
        for dataProtection in [true, false] {
            SecItemDelete(vaultQuery(account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }

    static func cleanupLegacyTouchIDItems() {
        for dataProtection in [true, false] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyTouchIDService,
            ]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            SecItemDelete(q as CFDictionary)
        }
    }

    private static func vaultQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: - Remembered Key File Path (Local Machine Preference Only)

    static func rememberKeyfileURL(_ url: URL?, vaultID: String) {
        let key = "\(keyfilePrefPrefix)\(vaultID)"
        if let url {
            UserDefaults.standard.set(url.path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func rememberedKeyfileURL(vaultID: String) -> URL? {
        let key = "\(keyfilePrefPrefix)\(vaultID)"
        guard let path = UserDefaults.standard.string(forKey: key),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - WebDAV Password Keychain Storage

    private static func webdavAccountKey(url: String, username: String) -> String {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let n = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(u)|\(n)"
    }

    static func saveWebDavPassword(_ password: String, url: String, username: String) {
        let acct = webdavAccountKey(url: url, username: username)
        guard !acct.hasPrefix("|"), !acct.hasSuffix("|"), !password.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webdavService,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Koban WebDAV Sync"
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func loadWebDavPassword(url: String, username: String) -> String? {
        let acct = webdavAccountKey(url: url, username: username)
        guard !acct.hasPrefix("|"), !acct.hasSuffix("|") else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webdavService,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    static func stripAndStoreWebDavPassword(in state: LedgerState) -> LedgerState {
        guard var webdav = state.settings.webdav else { return state }
        if let pw = webdav.password, !pw.isEmpty,
           !webdav.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !webdav.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveWebDavPassword(pw, url: webdav.url, username: webdav.username)
        }
        webdav.password = nil
        var next = state
        next.settings.webdav = webdav
        return next
    }

    static func injectLocalWebDavPassword(in state: LedgerState) -> LedgerState {
        guard var webdav = state.settings.webdav else { return state }
        let cur = webdav.password ?? ""
        if !cur.isEmpty {
            saveWebDavPassword(cur, url: webdav.url, username: webdav.username)
            return state
        }
        if let stored = loadWebDavPassword(url: webdav.url, username: webdav.username) {
            webdav.password = stored
            var next = state
            next.settings.webdav = webdav
            return next
        }
        return state
    }
}
