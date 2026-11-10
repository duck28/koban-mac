import XCTest
@testable import KobanCore

/// Regression tests for the input-hardening fixes from the 2026-11 security audit.
final class SecurityHardeningTests: XCTestCase {
    func testCsvExportNeutralizesFormulas() {
        XCTAssertEqual(SheetCSV.escape(.string("=HYPERLINK(\"https://evil\",\"x\")")),
                       "\"'=HYPERLINK(\"\"https://evil\"\",\"\"x\"\")\"")
        XCTAssertEqual(SheetCSV.escape(.string("+cmd")), "'+cmd")
        XCTAssertEqual(SheetCSV.escape(.string("@SUM(A1)")), "'@SUM(A1)")
        XCTAssertEqual(SheetCSV.escape(.string("\tx")), "'\tx")
        // Numbers, also when stored as text, stay numeric.
        XCTAssertEqual(SheetCSV.escape(.string("-12.50")), "-12.50")
        XCTAssertEqual(SheetCSV.escape(.number(-5)), "-5")
        XCTAssertEqual(SheetCSV.escape(.string("Groceries")), "Groceries")
        // A lone CR is quoted like LF.
        XCTAssertEqual(SheetCSV.escape(.string("a\rb")), "\"a\rb\"")
    }

    func testNonFiniteImportValuesBecomeZero() {
        XCTAssertEqual(DataIOJS.orZero(DataIOJS.parseFloat("Infinity")), 0)
        XCTAssertEqual(DataIOJS.orZero(DataIOJS.parseFloat("-Infinity")), 0)
        XCTAssertEqual(DataIOJS.orZero(DataIOJS.parseFloat("abc")), 0)
        XCTAssertEqual(DataIOJS.orZero(DataIOJS.parseFloat("12.5")), 12.5)
    }

    func testOutOfRangeActiveMonthIsClampedOnDecode() throws {
        let json = #"""
        {"settings": {"setupCompleted": true, "setupMode": "both", "activeWorkspace": "home",
          "currency": "CHF", "theme": "system", "backupDir": "", "autoBackup": false, "maxBackups": 20,
          "defaultVatRate": 8.1, "taxReserveRate": 25, "activeYear": -5, "activeMonth": 13}}
        """#
        let state = try JSONDecoder().decode(LedgerState.self, from: Data(json.utf8))
        XCTAssertEqual(state.settings.activeMonth, 12)
        XCTAssertEqual(state.settings.activeYear, 1900)
    }
}
