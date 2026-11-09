import CryptoKit
import Foundation

struct DbInfo: Hashable, Sendable {
    var dbPath: String
    var dbSize: Int64
    var lastModified: Date?
    var cipher: String
    var encryptedRecords: Int
    var hasCustomPassphrase: Bool
    var isCustomLocation: Bool
}

enum VaultError: Error, Equatable, CustomStringConvertible {
    /// The vault was saved with a custom passphrase and none was supplied.
    case passphraseRequired
    /// Decryption failed — wrong passphrase or corrupted database.
    case wrongPassphrase
    case corruptSalt
    case invalidPayload(String)

    var description: String {
        switch self {
        case .passphraseRequired: return "This vault is protected with a custom passphrase."
        case .wrongPassphrase: return "Decryption failed: invalid passphrase or corrupted database."
        case .corruptSalt: return "The vault salt stored in vault_meta is corrupt."
        case .invalidPayload(let msg): return "The decrypted ledger could not be read: \(msg)"
        }
    }
}

/// The encrypted SQLite vault (`koban.db`). Same schema and crypto as src-tauri/src/lib.rs:
///
/// - `vault_meta(key, value)`             — salt_b64, cipher, kdf, custom_passphrase, auth_config
/// - `encrypted_vault(key='ledger_state')` — full LedgerState JSON, AES-256-GCM
/// - `encrypted_records(id, record_kind)`  — each record encrypted separately (mirror / stats)
///
/// The full-state row is the source of truth on load; `encrypted_records` is rewritten on every save.
final class KobanVault {
    let url: URL
    private let db: SQLiteConnection
    /// Custom vault passphrase for this session; nil = default secret.
    private(set) var passphrase: String?

    private var activeSecret: String {
        if let p = passphrase, !p.isEmpty { return p }
        return VaultCrypto.defaultSecret
    }

    init(url: URL, passphrase: String? = nil) throws {
        self.url = url
        self.passphrase = passphrase?.isEmpty == true ? nil : passphrase
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path)
        try initSchema()
    }

    // MARK: - Schema

    private func initSchema() throws {
        try db.execute("""
            PRAGMA journal_mode = DELETE;
            PRAGMA synchronous = NORMAL;

            CREATE TABLE IF NOT EXISTS vault_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS encrypted_vault (
                key TEXT PRIMARY KEY,
                nonce_b64 TEXT NOT NULL,
                ciphertext_b64 TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS encrypted_records (
                id TEXT PRIMARY KEY,
                record_kind TEXT NOT NULL,
                nonce_b64 TEXT NOT NULL,
                ciphertext_b64 TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """)
        _ = try ensureSalt()
        // TODO(port): migrate_and_drop_plaintext_tables — only relevant for very old
        // Windows vaults that still contain the plaintext `app_state` table.
    }

    private func ensureSalt() throws -> Data {
        if let b64 = try db.scalarString("SELECT value FROM vault_meta WHERE key = 'salt_b64' LIMIT 1") {
            guard let salt = Data(base64Encoded: b64) else { throw VaultError.corruptSalt }
            return salt
        }
        let salt = VaultCrypto.randomBytes(16)
        try db.run("INSERT INTO vault_meta (key, value) VALUES ('salt_b64', ?1)", [.text(salt.base64EncodedString())])
        try db.run("INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('cipher', 'AES-256-GCM')")
        try db.run("INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('kdf', 'SHA256-10000-Salted')")
        return salt
    }

    // MARK: - Meta

    /// Whether the last save used a custom passphrase (as recorded by either platform).
    var hasCustomPassphrase: Bool {
        (try? db.scalarString("SELECT value FROM vault_meta WHERE key = 'custom_passphrase' LIMIT 1")) == "true"
    }

    var hasLedgerState: Bool {
        ((try? db.scalarInt("SELECT COUNT(*) FROM encrypted_vault WHERE key = 'ledger_state'")) ?? 0) > 0
    }

    /// Raw AuthConfig JSON (stored unencrypted in vault_meta, like on Windows).
    func loadAuthConfigJSON() throws -> String? {
        try db.scalarString("SELECT value FROM vault_meta WHERE key = 'auth_config' LIMIT 1")
    }

    func saveAuthConfigJSON(_ json: String) throws {
        try db.run("INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('auth_config', ?1)", [.text(json)])
    }

    // MARK: - Load / save

    /// Decrypts the ledger. Returns nil for a brand-new, empty vault.
    func load(passphrase override: String? = nil) throws -> LedgerState? {
        if let override, !override.isEmpty { passphrase = override }

        let rows = try db.query("SELECT nonce_b64, ciphertext_b64 FROM encrypted_vault WHERE key = 'ledger_state' LIMIT 1")
        guard let row = rows.first, let nonce = row[0], let ciphertext = row[1] else { return nil }

        if hasCustomPassphrase && passphrase == nil {
            throw VaultError.passphraseRequired
        }

        let key = VaultCrypto.deriveKey(secret: activeSecret, salt: try ensureSalt())
        let plaintext: Data
        do {
            plaintext = try VaultCrypto.open(nonceB64: nonce, ciphertextB64: ciphertext, key: key)
        } catch {
            throw VaultError.wrongPassphrase
        }

        do {
            return try JSONDecoder().decode(LedgerState.self, from: plaintext)
        } catch {
            throw VaultError.invalidPayload(String(describing: error))
        }
    }

    /// Encrypts and writes the full state plus per-record mirror rows. Returns the record count.
    @discardableResult
    func save(_ state: LedgerState) throws -> Int {
        let key = VaultCrypto.deriveKey(secret: activeSecret, salt: try ensureSalt())
        let encoder = JSONEncoder()
        let stateJSON = try encoder.encode(state)
        let vaultSealed = try VaultCrypto.seal(stateJSON, key: key)
        let ts = Int64(Date().timeIntervalSince1970)

        return try db.transaction { () throws -> Int in
            try db.run(
                "INSERT OR REPLACE INTO vault_meta (key, value) VALUES ('custom_passphrase', ?1)",
                [.text(passphrase == nil ? "false" : "true")]
            )
            try db.run("""
                INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                VALUES ('ledger_state', ?1, ?2, ?3)
                ON CONFLICT(key) DO UPDATE SET
                    nonce_b64 = excluded.nonce_b64,
                    ciphertext_b64 = excluded.ciphertext_b64,
                    updated_at = excluded.updated_at
                """, [.text(vaultSealed.nonceB64), .text(vaultSealed.ciphertextB64), .int(ts)])

            try db.run("DELETE FROM encrypted_records")
            var count = 1

            func insert<T: Encodable>(_ kind: String, _ items: [T], id: (T) -> String?) throws {
                for (idx, item) in items.enumerated() {
                    let recordId = "\(kind):\(id(item) ?? String(idx))"
                    let sealed = try VaultCrypto.seal(try encoder.encode(item), key: key)
                    try db.run("""
                        INSERT INTO encrypted_records (id, record_kind, nonce_b64, ciphertext_b64, updated_at)
                        VALUES (?1, ?2, ?3, ?4, ?5)
                        """, [.text(recordId), .text(kind), .text(sealed.nonceB64), .text(sealed.ciphertextB64), .int(ts)])
                    count += 1
                }
            }

            // Same kinds and order as write_encrypted_state in lib.rs.
            try insert("group", state.groups) { $0.id }
            try insert("category", state.categories) { $0.id }
            try insert("budget", state.monthlyBudgets) { _ in nil }
            try insert("transaction", state.transactions) { $0.id }
            try insert("goal", state.savingsGoals) { $0.id }
            try insert("account", state.accounts) { $0.id }
            try insert("net_worth_snapshot", state.netWorthSnapshots) { $0.id }
            try insert("yearly_plan_item", state.yearlyPlanItems ?? []) { $0.id }
            return count
        }
    }

    /// Sets (or clears, with nil/empty) the custom passphrase and re-encrypts `state` with it.
    func setPassphrase(_ newPassphrase: String?, reencrypting state: LedgerState?) throws {
        let trimmed = newPassphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        passphrase = (trimmed?.isEmpty ?? true) ? nil : newPassphrase
        if let state { try save(state) }
    }

    func info(isCustomLocation: Bool) -> DbInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let records = ((try? db.scalarInt("SELECT COUNT(*) FROM encrypted_records")) ?? 0)
            + ((try? db.scalarInt("SELECT COUNT(*) FROM encrypted_vault")) ?? 0)
        return DbInfo(
            dbPath: url.path,
            dbSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            lastModified: attrs?[.modificationDate] as? Date,
            cipher: "AES-256-GCM",
            encryptedRecords: records,
            hasCustomPassphrase: hasCustomPassphrase,
            isCustomLocation: isCustomLocation
        )
    }
}
