import XCTest
@testable import KobanCore

final class KobanVaultTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("koban-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testNewVaultIsEmpty() throws {
        let vault = try KobanVault(url: dir.appendingPathComponent("koban.db"))
        XCTAssertNil(try vault.load())
        XCTAssertFalse(vault.hasLedgerState)
    }

    func testRoundTripWithDefaultSecret() throws {
        let url = dir.appendingPathComponent("koban.db")
        var state = LedgerState.empty(currency: "EUR")
        state.groups = [CategoryGroup(id: "g1", mode: .home, name: "Income", kind: .income, color: "#3f704d", column: 0, order: 0)]

        let records = try KobanVault(url: url).save(state)
        XCTAssertEqual(records, 2) // full-state row + 1 group

        let reopened = try KobanVault(url: url)
        XCTAssertFalse(reopened.hasCustomPassphrase)
        XCTAssertEqual(try reopened.load(), state)
    }

    func testCustomPassphraseIsRequiredAndVerified() throws {
        let url = dir.appendingPathComponent("koban.db")
        let state = LedgerState.empty()
        let vault = try KobanVault(url: url)
        try vault.setPassphrase("s3cret", reencrypting: state)

        XCTAssertThrowsError(try KobanVault(url: url).load()) {
            XCTAssertEqual($0 as? VaultError, .passphraseRequired)
        }
        XCTAssertThrowsError(try KobanVault(url: url).load(passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        XCTAssertEqual(try KobanVault(url: url).load(passphrase: "s3cret"), state)
    }

    func testBackupCreatesLatestAndPrunesSnapshots() throws {
        let url = dir.appendingPathComponent("koban.db")
        try KobanVault(url: url).save(LedgerState.empty())
        let backups = dir.appendingPathComponent("backups")

        try BackupManager.backup(database: url, to: backups, timestamped: false, maxBackups: 1)
        let names = try BackupManager.list(in: backups).map(\.name)
        XCTAssertTrue(names.contains("koban-latest.db"))
        XCTAssertEqual(names.filter { $0.hasPrefix("koban-daily-") }.count, 1)
    }
}
