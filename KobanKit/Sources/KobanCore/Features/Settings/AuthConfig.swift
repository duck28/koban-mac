import Foundation

/// Any JSON value — used to carry fields this build doesn't know about through a load/save
/// round-trip untouched (the auth config is shared with the Windows build).
enum AuthJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AuthJSONValue])
    case object([String: AuthJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AuthJSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AuthJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// String-keyed coding key for the "keep unknown fields" logic.
struct AuthCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// PasskeyCredentialRecord in src/types/index.ts. Windows Hello / WebAuthn records can't be used on
/// macOS, but they are kept byte-for-byte (including unknown fields) so the Windows build keeps working.
struct PasskeyCredentialRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// 'webauthn_passkey' | 'windows_hello_native' (kept as a string so new kinds survive).
    var kind: String
    /// Seconds since epoch.
    var createdAt: Double
    var lastUsedAt: Double?
    var publicKeyB64: String?
    var wrappedVaultSecret: String?
    var extra: [String: AuthJSONValue] = [:]

    private static let known: Set<String> = ["id", "name", "kind", "createdAt", "lastUsedAt", "publicKeyB64", "wrappedVaultSecret"]

    init(id: String, name: String, kind: String, createdAt: Double, lastUsedAt: Double? = nil,
         publicKeyB64: String? = nil, wrappedVaultSecret: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.publicKeyB64 = publicKeyB64
        self.wrappedVaultSecret = wrappedVaultSecret
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AuthCodingKey.self)
        id = try c.decodeIfPresent(String.self, forKey: AuthCodingKey("id")) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: AuthCodingKey("name")) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: AuthCodingKey("kind")) ?? "webauthn_passkey"
        createdAt = try c.decodeIfPresent(Double.self, forKey: AuthCodingKey("createdAt")) ?? 0
        lastUsedAt = try c.decodeIfPresent(Double.self, forKey: AuthCodingKey("lastUsedAt"))
        publicKeyB64 = try c.decodeIfPresent(String.self, forKey: AuthCodingKey("publicKeyB64"))
        wrappedVaultSecret = try c.decodeIfPresent(String.self, forKey: AuthCodingKey("wrappedVaultSecret"))
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(AuthJSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AuthCodingKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AuthCodingKey(k)) }
        try c.encode(id, forKey: AuthCodingKey("id"))
        try c.encode(name, forKey: AuthCodingKey("name"))
        try c.encode(kind, forKey: AuthCodingKey("kind"))
        try c.encode(AuthJSONValue.number(createdAt), forKey: AuthCodingKey("createdAt"))
        if let lastUsedAt { try c.encode(AuthJSONValue.number(lastUsedAt), forKey: AuthCodingKey("lastUsedAt")) }
        try c.encodeIfPresent(publicKeyB64, forKey: AuthCodingKey("publicKeyB64"))
        try c.encodeIfPresent(wrappedVaultSecret, forKey: AuthCodingKey("wrappedVaultSecret"))
    }

    var isWindowsHelloNative: Bool { kind == "windows_hello_native" }
}

/// AuthConfig in src/types/index.ts — stored unencrypted as JSON in `vault_meta.auth_config`.
/// Decoding is lenient like `{ ...DEFAULT_AUTH_CONFIG, ...parsed }` in src/utils/auth.ts.
struct AuthConfig: Codable, Hashable, Sendable {
    var enabled: Bool
    var userDisplayName: String
    var autoPromptPasskeyOnLaunch: Bool
    var autoLockMinutes: Int
    var passkeys: [PasskeyCredentialRecord]
    var hasMasterPassphrase: Bool
    var passphraseSaltB64: String?
    var passphraseVerifierHashB64: String?
    var extra: [String: AuthJSONValue] = [:]

    /// DEFAULT_AUTH_CONFIG
    static let `default` = AuthConfig(enabled: false, userDisplayName: "Koban Owner", autoPromptPasskeyOnLaunch: false,
                                      autoLockMinutes: 15, passkeys: [], hasMasterPassphrase: false)

    init(enabled: Bool, userDisplayName: String, autoPromptPasskeyOnLaunch: Bool, autoLockMinutes: Int,
         passkeys: [PasskeyCredentialRecord], hasMasterPassphrase: Bool,
         passphraseSaltB64: String? = nil, passphraseVerifierHashB64: String? = nil) {
        self.enabled = enabled
        self.userDisplayName = userDisplayName
        self.autoPromptPasskeyOnLaunch = autoPromptPasskeyOnLaunch
        self.autoLockMinutes = autoLockMinutes
        self.passkeys = passkeys
        self.hasMasterPassphrase = hasMasterPassphrase
        self.passphraseSaltB64 = passphraseSaltB64
        self.passphraseVerifierHashB64 = passphraseVerifierHashB64
    }

    private static let known: Set<String> = ["enabled", "userDisplayName", "autoPromptPasskeyOnLaunch", "autoLockMinutes",
                                             "passkeys", "hasMasterPassphrase", "passphraseSaltB64", "passphraseVerifierHashB64"]

    init(from decoder: Decoder) throws {
        let d = AuthConfig.default
        let c = try decoder.container(keyedBy: AuthCodingKey.self)
        func opt<T: Decodable>(_ k: String, _ t: T.Type) -> T? { try? c.decodeIfPresent(T.self, forKey: AuthCodingKey(k)) }
        enabled = opt("enabled", Bool.self) ?? d.enabled
        userDisplayName = opt("userDisplayName", String.self) ?? d.userDisplayName
        autoPromptPasskeyOnLaunch = opt("autoPromptPasskeyOnLaunch", Bool.self) ?? d.autoPromptPasskeyOnLaunch
        autoLockMinutes = opt("autoLockMinutes", Double.self).map { Int($0) } ?? d.autoLockMinutes
        passkeys = opt("passkeys", [PasskeyCredentialRecord].self) ?? []
        hasMasterPassphrase = opt("hasMasterPassphrase", Bool.self) ?? d.hasMasterPassphrase
        passphraseSaltB64 = opt("passphraseSaltB64", String.self)
        passphraseVerifierHashB64 = opt("passphraseVerifierHashB64", String.self)
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(AuthJSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AuthCodingKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AuthCodingKey(k)) }
        try c.encode(enabled, forKey: AuthCodingKey("enabled"))
        try c.encode(userDisplayName, forKey: AuthCodingKey("userDisplayName"))
        try c.encode(autoPromptPasskeyOnLaunch, forKey: AuthCodingKey("autoPromptPasskeyOnLaunch"))
        try c.encode(autoLockMinutes, forKey: AuthCodingKey("autoLockMinutes"))
        try c.encode(passkeys, forKey: AuthCodingKey("passkeys"))
        try c.encode(hasMasterPassphrase, forKey: AuthCodingKey("hasMasterPassphrase"))
        try c.encodeIfPresent(passphraseSaltB64, forKey: AuthCodingKey("passphraseSaltB64"))
        try c.encodeIfPresent(passphraseVerifierHashB64, forKey: AuthCodingKey("passphraseVerifierHashB64"))
    }

    /// loadAuthConfig(): parses the stored JSON, falling back to the defaults.
    static func parse(_ json: String?) -> AuthConfig {
        guard let json, let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(AuthConfig.self, from: data) else { return .default }
        return config
    }

    /// JSON.stringify(config)
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    // MARK: - Master passphrase (handleSetMasterPassphrase / Remove Passphrase)

    func withMasterPassphrase(_ passphrase: String) -> AuthConfig {
        let v = AuthCrypto.hashPassphraseVerifier(passphrase)
        var next = self
        next.enabled = true
        next.hasMasterPassphrase = true
        next.passphraseSaltB64 = v.saltB64
        next.passphraseVerifierHashB64 = v.hashB64
        return next
    }

    func withoutMasterPassphrase() -> AuthConfig {
        var next = self
        next.hasMasterPassphrase = false
        next.passphraseSaltB64 = nil
        next.passphraseVerifierHashB64 = nil
        return next
    }
}
