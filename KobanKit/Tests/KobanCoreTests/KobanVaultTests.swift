import CryptoKit
import XCTest
@testable import KobanCore

final class KobanVaultTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koban-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testVaultV2PassphraseCompositeRecoveryAndRekey() throws {
        let dir = try tempDir()
        let dbURL = dir.appendingPathComponent("koban.db")
        let keyURL = dir.appendingPathComponent("vault.key")
        let (kfJSON, _, _) = try VaultCrypto.generateKeyFileJSON()
        try Data(kfJSON.utf8).write(to: keyURL)

        var state = LedgerState.empty(setupMode: .both, currency: "CHF")
        state.groups = [CategoryGroup(id: "g1", mode: .home, name: "Living", kind: .expense, color: "#111", column: 0, order: 0)]
        state.categories = [CategoryItem(id: "c1", groupId: "g1", mode: .home, name: "Rent", kind: .expense, defaultBudget: 1500, order: 0)]

        let vault = KobanVault(url: dbURL)
        let created = try vault.createV2(
            passphrase: "correct-horse-battery-staple",
            keyfileURL: keyURL,
            createRecoveryKey: true,
            initialState: state,
            memoryKiB: 1024,
            iterations: 2,
            parallelism: 2
        )
        XCTAssertEqual(created.status.formatVersion, 2)
        XCTAssertTrue(created.status.requiresKeyFile)
        let recoveryKey = try XCTUnwrap(created.recoveryKey)

        // Password without keyfile must fail with keyFileRequired
        let reopened = KobanVault(url: dbURL)
        XCTAssertThrowsError(try reopened.unlock(passphrase: "correct-horse-battery-staple")) { err in
            XCTAssertEqual(err as? VaultError, .keyFileRequired)
        }

        // Password + keyfile unlocks and preserves state
        let loaded = try reopened.unlock(passphrase: "correct-horse-battery-staple", keyfileURL: keyURL)
        XCTAssertEqual(loaded.categories.first?.name, "Rent")

        // Recovery key also unlocks after lock()
        reopened.lock()
        let viaRecovery = try reopened.unlockWithRecovery(recoveryKey)
        XCTAssertEqual(viaRecovery.groups.first?.id, "g1")

        // Rekeying invalidates the old recovery key
        try reopened.changeCredentials(
            newPassphrase: "another-strong-passphrase-2026",
            newKeyfileURL: nil,
            rekeyDEK: true,
            memoryKiB: 1024,
            iterations: 2,
            parallelism: 2,
            currentState: loaded
        )
        reopened.lock()
        XCTAssertThrowsError(try reopened.unlockWithRecovery(recoveryKey))
        XCTAssertEqual(try reopened.unlock(passphrase: "another-strong-passphrase-2026").categories.count, 1)
    }

    func testV1ToV2MigrationAndFutureVersionRefusal() throws {
        let dir = try tempDir()
        let dbURL = dir.appendingPathComponent("legacy.db")

        // Construct an authentic legacy v1 vault
        var state = LedgerState.empty(setupMode: .home, currency: "EUR")
        state.transactions = [TransactionItem(id: "tx1", date: "2026-11-10", monthKey: "2026-11", mode: .home, type: .expense, categoryId: "c1", description: "Coffee", amount: 4.5)]
        let salt = VaultCrypto.randomBytes(16)
        let v1Key = VaultCrypto.LegacyV1.deriveKey(secret: "legacy-pass", salt: salt)
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(state), using: v1Key)
        let nonceB64 = sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() }
        let ctB64 = (sealed.ciphertext + sealed.tag).base64EncodedString()

        let conn = try SQLiteConnection(path: dbURL.path)
        try conn.execute("""
            CREATE TABLE vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE encrypted_vault (key TEXT PRIMARY KEY, nonce_b64 TEXT NOT NULL, ciphertext_b64 TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE encrypted_records (id TEXT PRIMARY KEY, record_kind TEXT NOT NULL, nonce_b64 TEXT NOT NULL, ciphertext_b64 TEXT NOT NULL, updated_at INTEGER NOT NULL);
            """)
        try conn.run("INSERT INTO vault_meta VALUES ('salt_b64', ?1)", [.text(salt.base64EncodedString())])
        try conn.run("INSERT INTO vault_meta VALUES ('kdf', 'SHA256-10000-Salted')")
        try conn.run("INSERT INTO vault_meta VALUES ('custom_passphrase', 'true')")
        try conn.run("INSERT INTO encrypted_vault VALUES ('ledger_state', ?1, ?2, 1700000000)", [.text(nonceB64), .text(ctB64)])
        try conn.run("INSERT INTO encrypted_records VALUES ('tx:tx1', 'transaction', 'n', 'c', 1700000000)")
        conn.close()

        let vault = KobanVault(url: dbURL)
        let st = try vault.status()
        XCTAssertEqual(st.formatVersion, 1)
        XCTAssertTrue(st.needsMigration)

        let migrated = try vault.migrateV1ToV2(
            v1Passphrase: "legacy-pass",
            newPassphrase: "upgraded-master-passphrase",
            createRecoveryKey: true,
            memoryKiB: 1024,
            iterations: 2,
            parallelism: 2
        )
        XCTAssertNotNil(migrated.recoveryKey)
        XCTAssertEqual(migrated.state.transactions.count, 1)

        // Check encrypted_records dropped & format_version == 2
        let checkConn = try SQLiteConnection(path: dbURL.path, readOnly: true)
        XCTAssertEqual(try checkConn.scalarString("SELECT value FROM vault_meta WHERE key='format_version'"), "2")
        XCTAssertEqual(try checkConn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='encrypted_records'"), 0)

        // Future version refusal
        let futureURL = dir.appendingPathComponent("future.db")
        let fc = try SQLiteConnection(path: futureURL.path)
        try fc.execute("CREATE TABLE vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try fc.run("INSERT INTO vault_meta VALUES ('format_version', '99')")
        fc.close()
        XCTAssertThrowsError(try KobanVault.detectFormatVersion(at: futureURL)) { err in
            XCTAssertEqual(err as? VaultError, .unsupportedFormatVersion(99))
        }
    }

    func testExternalChangeDetectionAndLedgerMerge() throws {
        let dir = try tempDir()
        let dbURL = dir.appendingPathComponent("sync.db")

        var base = LedgerState.empty(setupMode: .home, currency: "CHF")
        base.transactions = [TransactionItem(id: "t-local", date: "2026-11-20", monthKey: "2026-11", mode: .home, type: .expense, categoryId: "c1", description: "Local", amount: 10)]

        let vaultA = KobanVault(url: dbURL)
        _ = try vaultA.createV2(passphrase: "sync-strong-passphrase-1", createRecoveryKey: false, initialState: base, memoryKiB: 1024, iterations: 2, parallelism: 2)

        // Simulate second device writing another transaction cleanly
        let vaultB = KobanVault(url: dbURL)
        var remote = try vaultB.unlock(passphrase: "sync-strong-passphrase-1")
        remote.transactions.append(TransactionItem(id: "t-remote", date: "2026-11-21", monthKey: "2026-11", mode: .home, type: .expense, categoryId: "c1", description: "Remote", amount: 25))
        try vaultB.save(remote)

        // First device sees external change on save and merges deterministically
        XCTAssertThrowsError(try vaultA.save(base)) { err in
            XCTAssertEqual(err as? VaultError, .externalDatabaseModified)
        }
        let check = try vaultA.checkExternalChange()
        XCTAssertTrue(check.changed)
        let extState = try XCTUnwrap(check.externalState)
        let (merged, summary) = LedgerMerge.merge(local: base, remote: extState, preferLocal: true)
        XCTAssertEqual(summary.transactionsAdded, 1)
        XCTAssertEqual(merged.transactions.count, 2)
    }
}
