import CryptoKit
import Foundation

struct DbInfo: Hashable, Sendable {
    var dbPath: String
    var dbSize: Int64
    var lastModified: Date?
    var cipher: String
    var encryptedRecords: Int
    var hasCustomPassphrase: Bool
    var formatVersion: Int = 2
    var isCustomLocation: Bool
}

struct VaultAuthSettings: Codable, Hashable, Sendable {
    var autoPromptDevice: Bool
    var autoLockMinutes: Int
    var lockOnMinimize: Bool

    static let `default` = VaultAuthSettings(
        autoPromptDevice: true,
        autoLockMinutes: 15,
        lockOnMinimize: false
    )

    init(autoPromptDevice: Bool = true, autoLockMinutes: Int = 15, lockOnMinimize: Bool = false) {
        self.autoPromptDevice = autoPromptDevice
        self.autoLockMinutes = autoLockMinutes
        self.lockOnMinimize = lockOnMinimize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoPromptDevice = try c.decodeIfPresent(Bool.self, forKey: .autoPromptDevice) ?? true
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? 15
        lockOnMinimize = try c.decodeIfPresent(Bool.self, forKey: .lockOnMinimize) ?? false
    }
}

struct KeySlotSummary: Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var label: String
    var keyfileFingerprint: String?
    var createdAt: Int64
}

struct VaultStatus: Equatable, Sendable {
    var exists: Bool
    var hasLedgerState: Bool
    var formatVersion: Int
    var vaultID: String?
    var unlocked: Bool
    var needsMigration: Bool
    var hasLegacyCustomPassphrase: Bool
    var slots: [KeySlotSummary]
    var deviceSlotEnrolled: Bool
    var requiresKeyFile: Bool
    var authSettings: VaultAuthSettings
    var dbPath: String
    var dbSize: Int64
    var lastModified: Date?
    var isCustomLocation: Bool
}

enum VaultError: Error, Equatable, CustomStringConvertible {
    case passphraseRequired
    case keyFileRequired
    case wrongPassphrase
    case corruptSalt
    case invalidPayload(String)
    case unsupportedFormatVersion(Int)
    case externalDatabaseModified
    case vaultLocked
    case migrationRequired
    case validationError(String)

    var description: String {
        switch self {
        case .passphraseRequired:
            return "Please enter your Master Password to unlock this vault."
        case .keyFileRequired:
            return "This database requires its Key File (.key) in addition to your Master Password."
        case .wrongPassphrase:
            return "Incorrect credentials or corrupted database (AES-GCM authentication failed)."
        case .corruptSalt:
            return "Vault metadata or salt is corrupted."
        case .invalidPayload(let msg):
            return "The decrypted ledger could not be decoded: \(msg)"
        case .unsupportedFormatVersion(let v):
            return "This database uses vault format v\(v), which is newer than this version of Koban supports. Please update Koban."
        case .externalDatabaseModified:
            return "EXTERNAL_DB_MODIFIED: The database file on disk was modified by another device or cloud sync."
        case .vaultLocked:
            return "Vault is locked. Unlock it before saving or modifying credentials."
        case .migrationRequired:
            return "This database uses legacy Vault Format v1 and must be upgraded to v2."
        case .validationError(let msg):
            return msg
        }
    }
}

/// Encrypted SQLite database manager implementing Vault Format v2 (Argon2id + AES-256-GCM AAD + key slots)
/// plus read-only legacy v1 decoding for migration and historical backup recovery.
final class KobanVault {
    let url: URL

    private(set) var dek: SymmetricKey?
    private(set) var vaultIDB64: String?
    private(set) var vaultIDBytes: Data?
    private(set) var lastKnownDiskSHA256: String?
    private(set) var lastRecordCount: Int = 0

    /// Optional hooks wired by the macOS app layer to strip WebDAV passwords into macOS Keychain
    /// before encrypting `koban.db`, and re-inject them on unlock.
    var onStripWebDavPassword: ((LedgerState) -> LedgerState)?
    var onInjectWebDavPassword: ((LedgerState) -> LedgerState)?

    var isUnlocked: Bool { dek != nil && vaultIDB64 != nil && vaultIDBytes != nil }

    init(url: URL) {
        self.url = url
        self.lastKnownDiskSHA256 = VaultCrypto.sha256Hex(fileAt: url)
    }

    // MARK: - Slot Parameter Schemas (Matching Rust serde JSON)

    private struct StoredKeySlot {
        var id: String
        var kind: String
        var label: String
        var params: String
        var nonceB64: String
        var ciphertextB64: String
        var createdAt: Int64
    }

    private struct PassphraseSlotParams: Codable {
        var kdf: String
        var v: Int
        var mKib: UInt32
        var t: UInt32
        var p: UInt32
        var saltB64: String

        enum CodingKeys: String, CodingKey {
            case kdf, v
            case mKib = "m_kib"
            case t, p
            case saltB64 = "salt_b64"
        }
    }

    private struct CompositeSlotParams: Codable {
        var kdf: String
        var v: Int
        var mKib: UInt32
        var t: UInt32
        var p: UInt32
        var saltB64: String
        var keyfileFingerprint: String

        enum CodingKeys: String, CodingKey {
            case kdf, v
            case mKib = "m_kib"
            case t, p
            case saltB64 = "salt_b64"
            case keyfileFingerprint = "keyfile_fingerprint"
        }
    }

    private struct RecoverySlotParams: Codable {
        var kdf: String
        var saltB64: String

        enum CodingKeys: String, CodingKey {
            case kdf
            case saltB64 = "salt_b64"
        }
    }

    // MARK: - Format & Metadata Inspection (Read-Only)

    static func detectFormatVersion(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        return try detectFormatVersion(in: db)
    }

    private static func detectFormatVersion(in db: SQLiteConnection) throws -> Int {
        guard tableExists("vault_meta", in: db) else {
            return tableExists("app_state", in: db) ? 1 : 0
        }
        if let verStr = metaValue("format_version", in: db) {
            let trimmed = verStr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ver = Int(trimmed) else {
                throw VaultError.invalidPayload("Unknown vault format version '\(verStr)'.")
            }
            if ver > 2 {
                throw VaultError.unsupportedFormatVersion(ver)
            }
            return ver
        }
        if metaValue("kdf", in: db) != nil || metaValue("salt_b64", in: db) != nil {
            return 1
        }
        return 0
    }

    private static func tableExists(_ name: String, in db: SQLiteConnection) -> Bool {
        ((try? db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1", [.text(name)])) ?? 0) > 0
    }

    private static func metaValue(_ key: String, in db: SQLiteConnection) -> String? {
        try? db.scalarString("SELECT value FROM vault_meta WHERE key = ?1 LIMIT 1", [.text(key)])
    }

    private static func hasLedgerState(in db: SQLiteConnection) -> Bool {
        guard tableExists("encrypted_vault", in: db) else { return false }
        return ((try? db.scalarInt("SELECT COUNT(*) FROM encrypted_vault WHERE key = 'ledger_state'")) ?? 0) > 0
    }

    private static func loadSlots(in db: SQLiteConnection) throws -> [StoredKeySlot] {
        guard tableExists("key_slots", in: db) else { return [] }
        let rows = try db.query("SELECT id, kind, label, params, nonce_b64, ciphertext_b64, created_at FROM key_slots ORDER BY created_at ASC")
        return rows.compactMap { row in
            guard row.count >= 7,
                  let id = row[0], let kind = row[1], let label = row[2],
                  let params = row[3], let nonce = row[4], let ct = row[5] else { return nil }
            let created = row[6].flatMap { Int64($0) } ?? 0
            return StoredKeySlot(id: id, kind: kind, label: label, params: params, nonceB64: nonce, ciphertextB64: ct, createdAt: created)
        }
    }

    private static func summarize(_ slots: [StoredKeySlot]) -> [KeySlotSummary] {
        slots.map { slot in
            let fp: String? = (slot.kind == "composite_keyfile")
                ? (try? JSONDecoder().decode(CompositeSlotParams.self, from: Data(slot.params.utf8)))?.keyfileFingerprint
                : nil
            return KeySlotSummary(id: slot.id, kind: slot.kind, label: slot.label, keyfileFingerprint: fp, createdAt: slot.createdAt)
        }
    }

    private static func parseAuthSettings(in db: SQLiteConnection) -> VaultAuthSettings {
        guard tableExists("vault_meta", in: db),
              let raw = metaValue("auth_settings", in: db),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(VaultAuthSettings.self, from: data) else {
            return .default
        }
        return parsed
    }

    func status(deviceSlotEnrolled: @escaping (String) -> Bool = { _ in false }, isCustomLocation: Bool = false) throws -> VaultStatus {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let attrs = exists ? (try? fm.attributesOfItem(atPath: url.path)) : nil
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mod = attrs?[.modificationDate] as? Date

        guard exists else {
            return VaultStatus(
                exists: false,
                hasLedgerState: false,
                formatVersion: 0,
                vaultID: nil,
                unlocked: false,
                needsMigration: false,
                hasLegacyCustomPassphrase: false,
                slots: [],
                deviceSlotEnrolled: false,
                requiresKeyFile: false,
                authSettings: .default,
                dbPath: url.path,
                dbSize: 0,
                lastModified: nil,
                isCustomLocation: isCustomLocation
            )
        }

        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let formatVer = try Self.detectFormatVersion(in: db)
        let hasState = Self.hasLedgerState(in: db)
        let vid = Self.metaValue("vault_id", in: db)
        let slots = try Self.loadSlots(in: db)
        let summaries = Self.summarize(slots)
        let hasComposite = slots.contains { $0.kind == "composite_keyfile" }
        let hasPass = slots.contains { $0.kind == "passphrase" }
        let requiresKF = hasComposite && !hasPass
        let hasLegacyCustom = Self.metaValue("custom_passphrase", in: db) == "true"
        let deviceEnrolled = vid.map(deviceSlotEnrolled) ?? false

        return VaultStatus(
            exists: true,
            hasLedgerState: hasState,
            formatVersion: formatVer,
            vaultID: vid,
            unlocked: isUnlocked && vaultIDB64 == vid,
            needsMigration: formatVer == 1,
            hasLegacyCustomPassphrase: hasLegacyCustom,
            slots: summaries,
            deviceSlotEnrolled: deviceEnrolled,
            requiresKeyFile: requiresKF,
            authSettings: Self.parseAuthSettings(in: db),
            dbPath: url.path,
            dbSize: size,
            lastModified: mod,
            isCustomLocation: isCustomLocation
        )
    }

    // MARK: - Create / Unlock / Lock

    func createV2(
        passphrase: String,
        keyfileURL: URL? = nil,
        createRecoveryKey: Bool = true,
        initialState: LedgerState,
        memoryKiB: UInt32 = VaultCrypto.defaultArgon2MemoryKiB,
        iterations: UInt32 = VaultCrypto.defaultArgon2Iterations,
        parallelism: UInt32 = VaultCrypto.defaultArgon2Parallelism
    ) throws -> (status: VaultStatus, recoveryKey: String?) {
        let keyfileData = try keyfileURL.map { url -> (Data, String) in
            let raw = try Data(contentsOf: url)
            let extracted = try VaultCrypto.extractKeyFileSecret(from: raw)
            return (extracted.secret, extracted.fingerprint)
        }

        try validateNewPassphrase(passphrase, hasKeyFile: keyfileData != nil)

        let vidBytes = VaultCrypto.randomBytes(16)
        let vidB64 = vidBytes.base64EncodedString()
        let newDEK = SymmetricKey(data: VaultCrypto.randomBytes(32))

        var slots: [StoredKeySlot] = []
        if let kf = keyfileData {
            slots.append(try buildCompositeSlot(vaultIDB64: vidB64, dek: newDEK, passphrase: passphrase, keyfileSecret: kf.0, fingerprint: kf.1, mKib: memoryKiB, t: iterations, p: parallelism))
        } else {
            slots.append(try buildPassphraseSlot(vaultIDB64: vidB64, dek: newDEK, passphrase: passphrase, mKib: memoryKiB, t: iterations, p: parallelism))
        }

        var recKey: String? = nil
        if createRecoveryKey {
            let (slot, formatted) = try buildRecoverySlot(vaultIDB64: vidB64, dek: newDEK)
            slots.append(slot)
            recKey = formatted
        }

        let cleanState = onStripWebDavPassword?(initialState) ?? initialState
        let ledgerData = try JSONEncoder().encode(cleanState)
        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: newDEK, vaultIDBytes: vidBytes)
        let ledgerSealed = try VaultCrypto.seal(ledgerData, key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vidB64))

        let authJSON = String(data: try JSONEncoder().encode(VaultAuthSettings.default), encoding: .utf8) ?? "{}"
        let now = Int64(Date().timeIntervalSince1970)
        let saltTripwire = VaultCrypto.randomBytes(16).base64EncodedString()

        try writeAtomicDatabase { db in
            try initV2Schema(in: db)
            try db.transaction {
                try db.run("DELETE FROM key_slots")
                try db.run("DELETE FROM encrypted_vault")
                try setMeta("format_version", "2", in: db)
                try setMeta("vault_id", vidB64, in: db)
                try setMeta("cipher", "AES-256-GCM", in: db)
                try setMeta("custom_passphrase", "true", in: db)
                try setMeta("salt_b64", saltTripwire, in: db)
                try setMeta("auth_settings", authJSON, in: db)
                try setMeta("schema_version", "2", in: db)
                for slot in slots { try insertSlot(slot, in: db) }
                try db.run("""
                    INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                    VALUES ('ledger_state', ?1, ?2, ?3)
                    """, [.text(ledgerSealed.nonceB64), .text(ledgerSealed.ciphertextB64), .int(now)])
            }
        }

        self.dek = newDEK
        self.vaultIDB64 = vidB64
        self.vaultIDBytes = vidBytes
        self.lastRecordCount = countRecords(cleanState)

        let st = try status()
        return (st, recKey)
    }

    func unlock(passphrase: String, keyfileURL: URL? = nil) throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.invalidPayload("Database file does not exist.")
        }
        let keyfileSecret: Data? = try keyfileURL.map { url in
            let raw = try Data(contentsOf: url)
            return try VaultCrypto.extractKeyFileSecret(from: raw).secret
        }

        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let ver = try Self.detectFormatVersion(in: db)
        if ver == 1 { throw VaultError.migrationRequired }
        guard ver == 2, let vidB64 = Self.metaValue("vault_id", in: db),
              let vidBytes = Data(base64Encoded: vidB64) else {
            throw VaultError.corruptSalt
        }

        let slots = try Self.loadSlots(in: db)
        let matching = try findMatchingSlotAndDEK(slots: slots, vaultIDB64: vidB64, passphrase: passphrase, keyfileSecret: keyfileSecret)
        let state = try readEncryptedLedger(in: db, vaultIDB64: vidB64, vaultIDBytes: vidBytes, dek: matching)

        self.dek = matching
        self.vaultIDB64 = vidB64
        self.vaultIDBytes = vidBytes
        self.lastKnownDiskSHA256 = VaultCrypto.sha256Hex(fileAt: url)
        self.lastRecordCount = countRecords(state)

        return onInjectWebDavPassword?(state) ?? state
    }

    func unlockWithRecovery(_ recoveryKey: String) throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.invalidPayload("Database file does not exist.")
        }
        let recBytes = try VaultCrypto.decodeCrockfordBase32(recoveryKey)
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let ver = try Self.detectFormatVersion(in: db)
        if ver == 1 { throw VaultError.migrationRequired }
        guard ver == 2, let vidB64 = Self.metaValue("vault_id", in: db),
              let vidBytes = Data(base64Encoded: vidB64) else {
            throw VaultError.corruptSalt
        }

        let slots = try Self.loadSlots(in: db).filter { $0.kind == "recovery" }
        var recoveredDEK: SymmetricKey? = nil
        for slot in slots {
            guard let params = try? JSONDecoder().decode(RecoverySlotParams.self, from: Data(slot.params.utf8)),
                  let salt = Data(base64Encoded: params.saltB64) else { continue }
            let kek = VaultCrypto.deriveRecoveryKEK(recoveryBytes: recBytes, salt: salt)
            let aad = VaultCrypto.slotAAD(vaultIDB64: vidB64, slotID: slot.id, kind: slot.kind)
            if let dekData = try? VaultCrypto.open(nonceB64: slot.nonceB64, ciphertextB64: slot.ciphertextB64, key: kek, aad: aad),
               dekData.count == 32 {
                recoveredDEK = SymmetricKey(data: dekData)
                break
            }
        }
        guard let finalDEK = recoveredDEK else { throw VaultError.wrongPassphrase }

        let state = try readEncryptedLedger(in: db, vaultIDB64: vidB64, vaultIDBytes: vidBytes, dek: finalDEK)
        self.dek = finalDEK
        self.vaultIDB64 = vidB64
        self.vaultIDBytes = vidBytes
        self.lastKnownDiskSHA256 = VaultCrypto.sha256Hex(fileAt: url)
        self.lastRecordCount = countRecords(state)
        return onInjectWebDavPassword?(state) ?? state
    }

    func unlockWithDEK(_ rawDEK: Data) throws -> LedgerState {
        guard rawDEK.count == 32 else { throw VaultError.wrongPassphrase }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.invalidPayload("Database file does not exist.")
        }
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let ver = try Self.detectFormatVersion(in: db)
        if ver == 1 { throw VaultError.migrationRequired }
        guard ver == 2, let vidB64 = Self.metaValue("vault_id", in: db),
              let vidBytes = Data(base64Encoded: vidB64) else {
            throw VaultError.corruptSalt
        }

        let candidate = SymmetricKey(data: rawDEK)
        let state = try readEncryptedLedger(in: db, vaultIDB64: vidB64, vaultIDBytes: vidBytes, dek: candidate)
        self.dek = candidate
        self.vaultIDB64 = vidB64
        self.vaultIDBytes = vidBytes
        self.lastKnownDiskSHA256 = VaultCrypto.sha256Hex(fileAt: url)
        self.lastRecordCount = countRecords(state)
        return onInjectWebDavPassword?(state) ?? state
    }

    func lock() {
        dek = nil
        vaultIDB64 = nil
        vaultIDBytes = nil
    }

    // MARK: - Save & External Cloud-Folder Sync Protection

    @discardableResult
    func save(_ state: LedgerState, forceOverwrite: Bool = false) throws -> Int {
        guard let activeDEK = dek, let vidB64 = vaultIDB64, let vidBytes = vaultIDBytes else {
            throw VaultError.vaultLocked
        }

        if FileManager.default.fileExists(atPath: url.path) {
            let db = try SQLiteConnection(path: url.path, readOnly: true)
            let ver = try Self.detectFormatVersion(in: db)
            if ver > 2 { throw VaultError.unsupportedFormatVersion(ver) }

            if !forceOverwrite, let expectedHash = lastKnownDiskSHA256,
               let currentHash = VaultCrypto.sha256Hex(fileAt: url),
               currentHash != expectedHash {
                throw VaultError.externalDatabaseModified
            }
        }

        let cleanState = onStripWebDavPassword?(state) ?? state
        let ledgerData = try JSONEncoder().encode(cleanState)
        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: activeDEK, vaultIDBytes: vidBytes)
        let sealed = try VaultCrypto.seal(ledgerData, key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vidB64))
        let ts = Int64(Date().timeIntervalSince1970)

        try writeAtomicDatabase { db in
            try initV2Schema(in: db)
            try db.transaction {
                try db.run("""
                    INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                    VALUES ('ledger_state', ?1, ?2, ?3)
                    ON CONFLICT(key) DO UPDATE SET
                        nonce_b64 = excluded.nonce_b64,
                        ciphertext_b64 = excluded.ciphertext_b64,
                        updated_at = excluded.updated_at
                    """, [.text(sealed.nonceB64), .text(sealed.ciphertextB64), .int(ts)])
            }
        }

        let count = countRecords(cleanState)
        lastRecordCount = count
        return count
    }

    func saveAuthSettings(_ settings: VaultAuthSettings) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let json = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? "{}"
        try writeAtomicDatabase { db in
            let ver = try Self.detectFormatVersion(in: db)
            if ver > 2 { throw VaultError.unsupportedFormatVersion(ver) }
            try db.transaction {
                try setMeta("auth_settings", json, in: db)
            }
        }
    }

    func checkExternalChange() throws -> (changed: Bool, formatVersion: Int, externalState: LedgerState?, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, 0, nil, nil)
        }
        guard let currentHash = VaultCrypto.sha256Hex(fileAt: url) else {
            return (false, 0, nil, nil)
        }
        if currentHash == lastKnownDiskSHA256 {
            return (false, 2, nil, nil)
        }

        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let ver = try Self.detectFormatVersion(in: db)
        if ver != 2 {
            return (true, ver, nil, "External database format version changed.")
        }
        guard let diskVidB64 = Self.metaValue("vault_id", in: db),
              let diskVidBytes = Data(base64Encoded: diskVidB64) else {
            return (true, ver, nil, "Corrupt external vault_id.")
        }
        guard let activeDEK = dek else {
            return (true, ver, nil, "Vault is locked.")
        }

        do {
            let extState = try readEncryptedLedger(in: db, vaultIDB64: diskVidB64, vaultIDBytes: diskVidBytes, dek: activeDEK)
            lastKnownDiskSHA256 = currentHash
            return (true, ver, onInjectWebDavPassword?(extState) ?? extState, nil)
        } catch {
            return (true, ver, nil, "External database could not be decrypted with current key (credentials may have changed).")
        }
    }

    // MARK: - Migration v1 -> v2

    func unlockV1ForMigration(passphrase: String? = nil) throws -> (state: LedgerState, hadCustomPassphrase: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.invalidPayload("Database file does not exist.")
        }
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        let ver = try Self.detectFormatVersion(in: db)
        guard ver == 1 else { throw VaultError.invalidPayload("Database is not a legacy v1 vault.") }
        let hadCustom = Self.metaValue("custom_passphrase", in: db) == "true"
        let jsonData = try readLegacyV1LedgerData(in: db, passphrase: passphrase)
        let decoded = try JSONDecoder().decode(LedgerState.self, from: jsonData)
        return (onInjectWebDavPassword?(decoded) ?? decoded, hadCustom)
    }

    func migrateV1ToV2(
        v1Passphrase: String? = nil,
        newPassphrase: String,
        keyfileURL: URL? = nil,
        createRecoveryKey: Bool = true,
        memoryKiB: UInt32 = VaultCrypto.defaultArgon2MemoryKiB,
        iterations: UInt32 = VaultCrypto.defaultArgon2Iterations,
        parallelism: UInt32 = VaultCrypto.defaultArgon2Parallelism,
        currentState: LedgerState? = nil
    ) throws -> (state: LedgerState, recoveryKey: String?) {
        let keyfileData = try keyfileURL.map { url -> (Data, String) in
            let raw = try Data(contentsOf: url)
            let extracted = try VaultCrypto.extractKeyFileSecret(from: raw)
            return (extracted.secret, extracted.fingerprint)
        }
        try validateNewPassphrase(newPassphrase, hasKeyFile: keyfileData != nil)

        let existingV1 = try unlockV1ForMigration(passphrase: v1Passphrase)
        let stateToMigrate = currentState ?? existingV1.state
        let cleanState = onStripWebDavPassword?(stateToMigrate) ?? stateToMigrate

        let vidBytes = VaultCrypto.randomBytes(16)
        let vidB64 = vidBytes.base64EncodedString()
        let newDEK = SymmetricKey(data: VaultCrypto.randomBytes(32))

        var slots: [StoredKeySlot] = []
        if let kf = keyfileData {
            slots.append(try buildCompositeSlot(vaultIDB64: vidB64, dek: newDEK, passphrase: newPassphrase, keyfileSecret: kf.0, fingerprint: kf.1, mKib: memoryKiB, t: iterations, p: parallelism))
        } else {
            slots.append(try buildPassphraseSlot(vaultIDB64: vidB64, dek: newDEK, passphrase: newPassphrase, mKib: memoryKiB, t: iterations, p: parallelism))
        }
        var recKey: String? = nil
        if createRecoveryKey {
            let (slot, formatted) = try buildRecoverySlot(vaultIDB64: vidB64, dek: newDEK)
            slots.append(slot)
            recKey = formatted
        }

        let ledgerData = try JSONEncoder().encode(cleanState)
        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: newDEK, vaultIDBytes: vidBytes)
        let sealed = try VaultCrypto.seal(ledgerData, key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vidB64))
        let authJSON = String(data: try JSONEncoder().encode(VaultAuthSettings.default), encoding: .utf8) ?? "{}"
        let now = Int64(Date().timeIntervalSince1970)

        try writeAtomicDatabase { db in
            try db.execute("PRAGMA secure_delete = ON;")
            try initV2Schema(in: db)
            try db.transaction {
                try db.execute("DROP TABLE IF EXISTS encrypted_records;")
                try db.execute("DROP TABLE IF EXISTS app_state;")
                try db.run("DELETE FROM vault_meta WHERE key IN ('kdf', 'auth_config')")
                try db.run("DELETE FROM key_slots")
                try db.run("DELETE FROM encrypted_vault")
                try setMeta("format_version", "2", in: db)
                try setMeta("vault_id", vidB64, in: db)
                try setMeta("cipher", "AES-256-GCM", in: db)
                try setMeta("custom_passphrase", "true", in: db)
                if Self.metaValue("salt_b64", in: db) == nil {
                    try setMeta("salt_b64", VaultCrypto.randomBytes(16).base64EncodedString(), in: db)
                }
                try setMeta("auth_settings", authJSON, in: db)
                try setMeta("schema_version", "2", in: db)
                for slot in slots { try insertSlot(slot, in: db) }
                try db.run("""
                    INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                    VALUES ('ledger_state', ?1, ?2, ?3)
                    """, [.text(sealed.nonceB64), .text(sealed.ciphertextB64), .int(now)])
            }
            try db.execute("VACUUM;")
        }

        self.dek = newDEK
        self.vaultIDB64 = vidB64
        self.vaultIDBytes = vidBytes
        self.lastRecordCount = countRecords(cleanState)
        return (onInjectWebDavPassword?(cleanState) ?? cleanState, recKey)
    }

    // MARK: - Credentials & Recovery Key Rotation

    func changeCredentials(
        currentPassphrase: String? = nil,
        currentKeyfileURL: URL? = nil,
        newPassphrase: String,
        newKeyfileURL: URL? = nil,
        rekeyDEK: Bool = false,
        memoryKiB: UInt32 = VaultCrypto.defaultArgon2MemoryKiB,
        iterations: UInt32 = VaultCrypto.defaultArgon2Iterations,
        parallelism: UInt32 = VaultCrypto.defaultArgon2Parallelism,
        currentState: LedgerState
    ) throws {
        guard let sessionDEK = dek, let vidB64 = vaultIDB64, let vidBytes = vaultIDBytes else {
            throw VaultError.vaultLocked
        }
        let newKF = try newKeyfileURL.map { url -> (Data, String) in
            let raw = try Data(contentsOf: url)
            return try VaultCrypto.extractKeyFileSecret(from: raw)
        }
        try validateNewPassphrase(newPassphrase, hasKeyFile: newKF != nil)

        if let curPw = currentPassphrase, !curPw.isEmpty {
            let db = try SQLiteConnection(path: url.path, readOnly: true)
            let slots = try Self.loadSlots(in: db)
            let curKF = try currentKeyfileURL.map { try VaultCrypto.extractKeyFileSecret(from: try Data(contentsOf: $0)).secret }
            _ = try findMatchingSlotAndDEK(slots: slots, vaultIDB64: vidB64, passphrase: curPw, keyfileSecret: curKF)
        }

        let targetDEK = rekeyDEK ? SymmetricKey(data: VaultCrypto.randomBytes(32)) : sessionDEK
        let newSlot: StoredKeySlot
        if let kf = newKF {
            newSlot = try buildCompositeSlot(vaultIDB64: vidB64, dek: targetDEK, passphrase: newPassphrase, keyfileSecret: kf.0, fingerprint: kf.1, mKib: memoryKiB, t: iterations, p: parallelism)
        } else {
            newSlot = try buildPassphraseSlot(vaultIDB64: vidB64, dek: targetDEK, passphrase: newPassphrase, mKib: memoryKiB, t: iterations, p: parallelism)
        }

        let cleanState = onStripWebDavPassword?(currentState) ?? currentState
        let ledgerSealed: VaultCrypto.SealedValue?
        if rekeyDEK {
            let ledgerKey = VaultCrypto.deriveLedgerKey(dek: targetDEK, vaultIDBytes: vidBytes)
            ledgerSealed = try VaultCrypto.seal(try JSONEncoder().encode(cleanState), key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vidB64))
        } else {
            ledgerSealed = nil
        }

        let ts = Int64(Date().timeIntervalSince1970)
        try writeAtomicDatabase { db in
            try db.transaction {
                try db.run("DELETE FROM key_slots WHERE kind IN ('passphrase', 'composite_keyfile')")
                if rekeyDEK {
                    try db.run("DELETE FROM key_slots WHERE kind = 'recovery'")
                }
                try insertSlot(newSlot, in: db)
                if let sealed = ledgerSealed {
                    try db.run("""
                        INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                        VALUES ('ledger_state', ?1, ?2, ?3)
                        ON CONFLICT(key) DO UPDATE SET
                            nonce_b64 = excluded.nonce_b64,
                            ciphertext_b64 = excluded.ciphertext_b64,
                            updated_at = excluded.updated_at
                        """, [.text(sealed.nonceB64), .text(sealed.ciphertextB64), .int(ts)])
                }
            }
        }

        self.dek = targetDEK
    }

    func generateRecoveryKey() throws -> String {
        guard let activeDEK = dek, let vidB64 = vaultIDB64 else {
            throw VaultError.vaultLocked
        }
        let (slot, formatted) = try buildRecoverySlot(vaultIDB64: vidB64, dek: activeDEK)
        try writeAtomicDatabase { db in
            try db.transaction {
                try db.run("DELETE FROM key_slots WHERE kind = 'recovery'")
                try insertSlot(slot, in: db)
            }
        }
        return formatted
    }

    // MARK: - Read-Only External / Backup Decryption

    static func openBackup(
        at backupURL: URL,
        passphrase: String? = nil,
        keyfileURL: URL? = nil,
        sessionDEK: SymmetricKey? = nil
    ) throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw VaultError.invalidPayload("Backup file does not exist.")
        }
        let db = try SQLiteConnection(path: backupURL.path, readOnly: true)
        let ver = try detectFormatVersion(in: db)

        if ver == 2 {
            guard let vidB64 = metaValue("vault_id", in: db),
                  let vidBytes = Data(base64Encoded: vidB64) else {
                throw VaultError.corruptSalt
            }

            if (passphrase?.isEmpty ?? true) && keyfileURL == nil, let dek = sessionDEK {
                if let state = try? readStaticEncryptedLedger(in: db, vaultIDB64: vidB64, vaultIDBytes: vidBytes, dek: dek) {
                    return state
                }
            }

            guard let pw = passphrase, !pw.isEmpty else {
                throw VaultError.passphraseRequired
            }

            let kfSecret = try keyfileURL.map { try VaultCrypto.extractKeyFileSecret(from: try Data(contentsOf: $0)).secret }
            let slots = try loadSlots(in: db)
            let slotDEK = try findStaticMatchingSlotAndDEK(slots: slots, vaultIDB64: vidB64, passphrase: pw, keyfileSecret: kfSecret)
            return try readStaticEncryptedLedger(in: db, vaultIDB64: vidB64, vaultIDBytes: vidBytes, dek: slotDEK)
        }

        if ver == 1 {
            let jsonData = try readStaticLegacyV1LedgerData(in: db, passphrase: passphrase)
            return try JSONDecoder().decode(LedgerState.self, from: jsonData)
        }

        throw VaultError.invalidPayload("Database does not contain recognizable encrypted Koban vault tables.")
    }

    /// Re-encrypts a legacy v1 backup snapshot into Vault Format v2 using the active vault's DEK/slots.
    func upgradeLegacyV1Backup(at backupURL: URL, v1Passphrase: String? = nil) throws {
        guard let activeDEK = dek, let vidB64 = vaultIDB64, let vidBytes = vaultIDBytes else {
            throw VaultError.vaultLocked
        }
        let mainDB = try SQLiteConnection(path: url.path, readOnly: true)
        let currentSlots = try Self.loadSlots(in: mainDB)
        let backupState = try Self.openBackup(at: backupURL, passphrase: v1Passphrase, keyfileURL: nil, sessionDEK: nil)
        let cleanState = onStripWebDavPassword?(backupState) ?? backupState

        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: activeDEK, vaultIDBytes: vidBytes)
        let sealed = try VaultCrypto.seal(try JSONEncoder().encode(cleanState), key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vidB64))
        let now = Int64(Date().timeIntervalSince1970)
        let tempBackup = Self(url: backupURL)
        try tempBackup.writeAtomicDatabase { db in
            try db.execute("PRAGMA secure_delete = ON;")
            try initV2Schema(in: db)
            try db.transaction {
                try db.execute("DROP TABLE IF EXISTS encrypted_records;")
                try db.execute("DROP TABLE IF EXISTS app_state;")
                try db.run("DELETE FROM vault_meta WHERE key IN ('kdf', 'auth_config')")
                try db.run("DELETE FROM key_slots")
                try db.run("DELETE FROM encrypted_vault")
                try setMeta("format_version", "2", in: db)
                try setMeta("vault_id", vidB64, in: db)
                try setMeta("cipher", "AES-256-GCM", in: db)
                try setMeta("custom_passphrase", "true", in: db)
                try setMeta("schema_version", "2", in: db)
                for slot in currentSlots { try insertSlot(slot, in: db) }
                try db.run("""
                    INSERT INTO encrypted_vault (key, nonce_b64, ciphertext_b64, updated_at)
                    VALUES ('ledger_state', ?1, ?2, ?3)
                    """, [.text(sealed.nonceB64), .text(sealed.ciphertextB64), .int(now)])
            }
            try db.execute("VACUUM;")
        }
    }

    func info(isCustomLocation: Bool) -> DbInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let ver = (try? Self.detectFormatVersion(at: url)) ?? 0
        return DbInfo(
            dbPath: url.path,
            dbSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            lastModified: attrs?[.modificationDate] as? Date,
            cipher: ver == 2 ? "Argon2id + AES-256-GCM" : "AES-256-GCM",
            encryptedRecords: max(lastRecordCount, (try? status().hasLedgerState == true ? 1 : 0) ?? 0),
            hasCustomPassphrase: ver == 2 || ((try? status().hasLegacyCustomPassphrase) ?? false),
            formatVersion: ver,
            isCustomLocation: isCustomLocation
        )
    }

    // MARK: - Private Crypto / Schema Helpers

    private func validateNewPassphrase(_ passphrase: String, hasKeyFile: Bool) throws {
        let minLen = hasKeyFile ? VaultCrypto.minCompositePassphraseLength : VaultCrypto.minPassphraseLength
        if passphrase.count < minLen {
            throw VaultError.validationError("Master Password must be at least \(minLen) characters.")
        }
        if passphrase.trimmingCharacters(in: .whitespacesAndNewlines) != passphrase {
            throw VaultError.validationError("Master Password cannot start or end with whitespace.")
        }
    }

    private func buildPassphraseSlot(
        vaultIDB64: String,
        dek: SymmetricKey,
        passphrase: String,
        mKib: UInt32,
        t: UInt32,
        p: UInt32
    ) throws -> StoredKeySlot {
        let nfc = VaultCrypto.normalizeNFC(passphrase)
        let salt = VaultCrypto.randomBytes(16)
        let kek = try VaultCrypto.derivePassphraseKEK(passphraseNFC: nfc, salt: salt, memoryKiB: mKib, iterations: t, parallelism: p)
        let slotID = VaultCrypto.base64URLEncode(VaultCrypto.randomBytes(16))
        let kind = "passphrase"
        let aad = VaultCrypto.slotAAD(vaultIDB64: vaultIDB64, slotID: slotID, kind: kind)
        let dekData = dek.withUnsafeBytes { Data($0) }
        let sealed = try VaultCrypto.seal(dekData, key: kek, aad: aad)
        let params = PassphraseSlotParams(kdf: "argon2id", v: 19, mKib: mKib, t: t, p: p, saltB64: salt.base64EncodedString())
        let paramsJSON = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? "{}"
        return StoredKeySlot(id: slotID, kind: kind, label: "Master Passphrase (Argon2id)", params: paramsJSON, nonceB64: sealed.nonceB64, ciphertextB64: sealed.ciphertextB64, createdAt: Int64(Date().timeIntervalSince1970))
    }

    private func buildCompositeSlot(
        vaultIDB64: String,
        dek: SymmetricKey,
        passphrase: String,
        keyfileSecret: Data,
        fingerprint: String,
        mKib: UInt32,
        t: UInt32,
        p: UInt32
    ) throws -> StoredKeySlot {
        let nfc = VaultCrypto.normalizeNFC(passphrase)
        let salt = VaultCrypto.randomBytes(16)
        let kek = try VaultCrypto.deriveCompositeKEK(passphraseNFC: nfc, keyfileSecret: keyfileSecret, salt: salt, memoryKiB: mKib, iterations: t, parallelism: p)
        let slotID = VaultCrypto.base64URLEncode(VaultCrypto.randomBytes(16))
        let kind = "composite_keyfile"
        let aad = VaultCrypto.slotAAD(vaultIDB64: vaultIDB64, slotID: slotID, kind: kind)
        let dekData = dek.withUnsafeBytes { Data($0) }
        let sealed = try VaultCrypto.seal(dekData, key: kek, aad: aad)
        let params = CompositeSlotParams(kdf: "argon2id-composite", v: 19, mKib: mKib, t: t, p: p, saltB64: salt.base64EncodedString(), keyfileFingerprint: fingerprint)
        let paramsJSON = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? "{}"
        return StoredKeySlot(id: slotID, kind: kind, label: "Master Password + Key File (\(fingerprint))", params: paramsJSON, nonceB64: sealed.nonceB64, ciphertextB64: sealed.ciphertextB64, createdAt: Int64(Date().timeIntervalSince1970))
    }

    private func buildRecoverySlot(vaultIDB64: String, dek: SymmetricKey) throws -> (StoredKeySlot, String) {
        let recBytes = VaultCrypto.randomBytes(20)
        let formatted = VaultCrypto.encodeCrockfordBase32(recBytes)
        let salt = VaultCrypto.randomBytes(16)
        let kek = VaultCrypto.deriveRecoveryKEK(recoveryBytes: recBytes, salt: salt)
        let slotID = VaultCrypto.base64URLEncode(VaultCrypto.randomBytes(16))
        let kind = "recovery"
        let aad = VaultCrypto.slotAAD(vaultIDB64: vaultIDB64, slotID: slotID, kind: kind)
        let dekData = dek.withUnsafeBytes { Data($0) }
        let sealed = try VaultCrypto.seal(dekData, key: kek, aad: aad)
        let params = RecoverySlotParams(kdf: "hkdf-sha256", saltB64: salt.base64EncodedString())
        let paramsJSON = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? "{}"
        let slot = StoredKeySlot(id: slotID, kind: kind, label: "160-bit Recovery Key", params: paramsJSON, nonceB64: sealed.nonceB64, ciphertextB64: sealed.ciphertextB64, createdAt: Int64(Date().timeIntervalSince1970))
        return (slot, formatted)
    }

    private func findMatchingSlotAndDEK(slots: [StoredKeySlot], vaultIDB64: String, passphrase: String, keyfileSecret: Data?) throws -> SymmetricKey {
        try Self.findStaticMatchingSlotAndDEK(slots: slots, vaultIDB64: vaultIDB64, passphrase: passphrase, keyfileSecret: keyfileSecret)
    }

    private static func findStaticMatchingSlotAndDEK(slots: [StoredKeySlot], vaultIDB64: String, passphrase: String, keyfileSecret: Data?) throws -> SymmetricKey {
        let nfc = VaultCrypto.normalizeNFC(passphrase)
        let hasComposite = slots.contains { $0.kind == "composite_keyfile" }

        if let kfSecret = keyfileSecret {
            for slot in slots where slot.kind == "composite_keyfile" {
                guard let params = try? JSONDecoder().decode(CompositeSlotParams.self, from: Data(slot.params.utf8)),
                      let salt = Data(base64Encoded: params.saltB64) else { continue }
                let kek = try VaultCrypto.deriveCompositeKEK(passphraseNFC: nfc, keyfileSecret: kfSecret, salt: salt, memoryKiB: params.mKib, iterations: params.t, parallelism: params.p)
                let aad = VaultCrypto.slotAAD(vaultIDB64: vaultIDB64, slotID: slot.id, kind: slot.kind)
                if let dekData = try? VaultCrypto.open(nonceB64: slot.nonceB64, ciphertextB64: slot.ciphertextB64, key: kek, aad: aad),
                   dekData.count == 32 {
                    return SymmetricKey(data: dekData)
                }
            }
        }

        for slot in slots where slot.kind == "passphrase" {
            guard let params = try? JSONDecoder().decode(PassphraseSlotParams.self, from: Data(slot.params.utf8)),
                  let salt = Data(base64Encoded: params.saltB64) else { continue }
            let kek = try VaultCrypto.derivePassphraseKEK(passphraseNFC: nfc, salt: salt, memoryKiB: params.mKib, iterations: params.t, parallelism: params.p)
            let aad = VaultCrypto.slotAAD(vaultIDB64: vaultIDB64, slotID: slot.id, kind: slot.kind)
            if let dekData = try? VaultCrypto.open(nonceB64: slot.nonceB64, ciphertextB64: slot.ciphertextB64, key: kek, aad: aad),
               dekData.count == 32 {
                return SymmetricKey(data: dekData)
            }
        }

        if hasComposite && keyfileSecret == nil {
            throw VaultError.keyFileRequired
        }
        throw VaultError.wrongPassphrase
    }

    private func readEncryptedLedger(in db: SQLiteConnection, vaultIDB64: String, vaultIDBytes: Data, dek: SymmetricKey) throws -> LedgerState {
        try Self.readStaticEncryptedLedger(in: db, vaultIDB64: vaultIDB64, vaultIDBytes: vaultIDBytes, dek: dek)
    }

    private static func readStaticEncryptedLedger(in db: SQLiteConnection, vaultIDB64: String, vaultIDBytes: Data, dek: SymmetricKey) throws -> LedgerState {
        let rows = try db.query("SELECT nonce_b64, ciphertext_b64 FROM encrypted_vault WHERE key = 'ledger_state' LIMIT 1")
        guard let row = rows.first, let nonce = row[0], let ct = row[1] else {
            throw VaultError.invalidPayload("Missing ledger_state row in encrypted_vault.")
        }
        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: dek, vaultIDBytes: vaultIDBytes)
        let plaintext = try VaultCrypto.open(nonceB64: nonce, ciphertextB64: ct, key: ledgerKey, aad: VaultCrypto.ledgerAAD(vaultIDB64: vaultIDB64))
        do {
            return try JSONDecoder().decode(LedgerState.self, from: plaintext)
        } catch {
            throw VaultError.invalidPayload(String(describing: error))
        }
    }

    private func readLegacyV1LedgerData(in db: SQLiteConnection, passphrase: String?) throws -> Data {
        try Self.readStaticLegacyV1LedgerData(in: db, passphrase: passphrase)
    }

    private static func readStaticLegacyV1LedgerData(in db: SQLiteConnection, passphrase: String?) throws -> Data {
        if let saltB64 = metaValue("salt_b64", in: db),
           let salt = Data(base64Encoded: saltB64),
           let row = try? db.query("SELECT nonce_b64, ciphertext_b64 FROM encrypted_vault WHERE key = 'ledger_state' LIMIT 1").first,
           let nonce = row[0], let ct = row[1] {
            let customRequired = metaValue("custom_passphrase", in: db) == "true"
            let rawSecret = (passphrase?.isEmpty == false) ? passphrase! : (customRequired ? "" : VaultCrypto.LegacyV1.defaultSecret)
            if customRequired && rawSecret.isEmpty {
                throw VaultError.passphraseRequired
            }
            if let plain = try? VaultCrypto.LegacyV1.open(nonceB64: nonce, ciphertextB64: ct, key: VaultCrypto.LegacyV1.deriveKey(secret: rawSecret, salt: salt)) {
                return plain
            }
            let trimmed = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != rawSecret, !trimmed.isEmpty,
               let plainTrim = try? VaultCrypto.LegacyV1.open(nonceB64: nonce, ciphertextB64: ct, key: VaultCrypto.LegacyV1.deriveKey(secret: trimmed, salt: salt)) {
                return plainTrim
            }
            throw VaultError.wrongPassphrase
        }
        if tableExists("app_state", in: db), let raw = try? db.scalarString("SELECT data_json FROM app_state WHERE id = 1 LIMIT 1"), !raw.isEmpty {
            return Data(raw.utf8)
        }
        throw VaultError.invalidPayload("Legacy database contains no ledger data.")
    }

    private func initV2Schema(in db: SQLiteConnection) throws {
        try db.execute("""
            PRAGMA journal_mode = DELETE;
            PRAGMA synchronous = FULL;

            CREATE TABLE IF NOT EXISTS vault_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS key_slots (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                label TEXT NOT NULL,
                params TEXT NOT NULL,
                nonce_b64 TEXT NOT NULL,
                ciphertext_b64 TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS encrypted_vault (
                key TEXT PRIMARY KEY,
                nonce_b64 TEXT NOT NULL,
                ciphertext_b64 TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """)
    }

    private func setMeta(_ key: String, _ value: String, in db: SQLiteConnection) throws {
        try db.run("INSERT OR REPLACE INTO vault_meta (key, value) VALUES (?1, ?2)", [.text(key), .text(value)])
    }

    private func insertSlot(_ slot: StoredKeySlot, in db: SQLiteConnection) throws {
        try db.run("""
            INSERT INTO key_slots (id, kind, label, params, nonce_b64, ciphertext_b64, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """, [
                .text(slot.id),
                .text(slot.kind),
                .text(slot.label),
                .text(slot.params),
                .text(slot.nonceB64),
                .text(slot.ciphertextB64),
                .int(slot.createdAt),
            ])
    }

    /// Writes database updates atomically to a sibling staged temp SQLite file (DELETE journal +
    /// synchronous=FULL), removes sidecars, swaps cleanly into place, and updates `lastKnownDiskSHA256`.
    private func writeAtomicDatabase(_ body: (SQLiteConnection) throws -> Void) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        removeSidecars(at: tempURL)
        try? fm.removeItem(at: tempURL)
        defer {
            removeSidecars(at: tempURL)
            try? fm.removeItem(at: tempURL)
        }

        if fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: tempURL)
        }

        do {
            let db = try SQLiteConnection(path: tempURL.path)
            try db.execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL;")
            try body(db)
            db.close()
        } catch {
            throw error
        }

        removeSidecars(at: tempURL)
        removeSidecars(at: url)

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
        removeSidecars(at: url)
        lastKnownDiskSHA256 = VaultCrypto.sha256Hex(fileAt: url)
    }

    private func removeSidecars(at dbURL: URL) {
        let fm = FileManager.default
        for suffix in ["-journal", "-wal", "-shm"] {
            try? fm.removeItem(atPath: dbURL.path + suffix)
        }
    }

    private func countRecords(_ state: LedgerState) -> Int {
        1 + state.groups.count + state.categories.count + state.monthlyBudgets.count +
        state.transactions.count + state.savingsGoals.count + state.accounts.count +
        state.netWorthSnapshots.count + (state.yearlyPlanItems?.count ?? 0)
    }
}
