import XCTest
@testable import KobanCore

/// Cross-platform golden test: the same ledger and expected results as koban-windows
/// (`fixtures/golden/`, identical copies in both repos; Windows checks them with `npm test`).
/// If this fails after an intended change, update the files as described in fixtures/golden/README.md.
final class GoldenLedgerTests: XCTestCase {
    private struct Expected: Decodable {
        struct Row: Decodable {
            var id: String
            var budget, actual, difference: Double
            var txCount: Int
            var autoActual, budgetFromSchedule, isFixedCost: Bool
        }
        struct Summary: Decodable {
            var monthKey: String
            var workspace: ActiveWorkspace
            var incomeBudget, incomeActual, expenseBudget, expenseActual: Double
            var savingsBudget, savingsActual, netBudget, netActual: Double
            var vatCollected, vatPaidOnExpenses: Double
            var rows: [Row]
        }
        struct OccurrenceMonth: Decodable { var monthKey: String; var dates: [String]? }
        struct Occurrences: Decodable { var id: String; var months: [OccurrenceMonth] }
        struct Balance: Decodable { var id: String; var liveBalance: Double }
        struct HistoryPoint: Decodable {
            var monthKey: String
            var netWorth, liquidAssets, totalLiabilities: Double
            var hasExplicitSnapshot: Bool
        }
        struct NetWorth: Decodable {
            var liquidAssets, investmentAssets, fixedAssets, totalLiabilities, netWorth: Double
            var history: [HistoryPoint]
        }
        var monthSummaries: [Summary]
        var recurringOccurrences: [Occurrences]
        var accountBalances: [Balance]
        var netWorth: NetWorth
    }

    /// <repo>/fixtures/golden — this file is <repo>/KobanKit/Tests/KobanCoreTests/GoldenLedgerTests.swift.
    private var goldenDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/golden")
    }

    /// "Today" for the fixture (matches NOW in scripts/test-golden.ts): every month of 2025 is history.
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    }

    /// Math.round(v * 100) / 100, like the Windows test.
    private func r2(_ v: Double) -> Double { (v * 100 + 0.5).rounded(.down) / 100 }

    private func assertClose(_ actual: Double, _ expected: Double, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r2(actual), expected, accuracy: 0.0051, what, file: file, line: line)
    }

    func testMatchesWindowsGoldenResults() throws {
        let ledger = try JSONDecoder().decode(
            LedgerState.self, from: Data(contentsOf: goldenDir.appendingPathComponent("basic-ledger.json")))
        let expected = try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: goldenDir.appendingPathComponent("basic-expected.json")))

        for exp in expected.monthSummaries {
            let s = ledger.monthSummary(monthKey: exp.monthKey, workspace: exp.workspace)
            let tag = "\(exp.monthKey) \(exp.workspace.rawValue)"
            assertClose(s.incomeBudget, exp.incomeBudget, "\(tag) incomeBudget")
            assertClose(s.incomeActual, exp.incomeActual, "\(tag) incomeActual")
            assertClose(s.expenseBudget, exp.expenseBudget, "\(tag) expenseBudget")
            assertClose(s.expenseActual, exp.expenseActual, "\(tag) expenseActual")
            assertClose(s.savingsBudget, exp.savingsBudget, "\(tag) savingsBudget")
            assertClose(s.savingsActual, exp.savingsActual, "\(tag) savingsActual")
            assertClose(s.netBudget, exp.netBudget, "\(tag) netBudget")
            assertClose(s.netActual, exp.netActual, "\(tag) netActual")
            assertClose(s.vatCollected, exp.vatCollected, "\(tag) vatCollected")
            assertClose(s.vatPaidOnExpenses, exp.vatPaidOnExpenses, "\(tag) vatPaidOnExpenses")

            let rows = s.groups.flatMap(\.rows)
            XCTAssertEqual(rows.map(\.category.id), exp.rows.map(\.id), "\(tag) row order")
            for (row, e) in zip(rows, exp.rows) {
                let rt = "\(tag) \(e.id)"
                assertClose(row.budget, e.budget, "\(rt) budget")
                assertClose(row.actual, e.actual, "\(rt) actual")
                assertClose(row.difference, e.difference, "\(rt) difference")
                XCTAssertEqual(row.txCount, e.txCount, "\(rt) txCount")
                XCTAssertEqual(row.autoActual, e.autoActual, "\(rt) autoActual")
                XCTAssertEqual(row.budgetFromSchedule, e.budgetFromSchedule, "\(rt) budgetFromSchedule")
                XCTAssertEqual(row.isFixedCost, e.isFixedCost, "\(rt) isFixedCost")
            }
        }

        for exp in expected.recurringOccurrences {
            let rule = try XCTUnwrap(ledger.recurringRules.first { $0.id == exp.id })
            for m in exp.months {
                XCTAssertEqual(rule.occurrenceDates(inMonth: m.monthKey), m.dates, "\(exp.id) \(m.monthKey)")
            }
        }

        let targets = ledger.savingsTargets
        for exp in expected.accountBalances {
            let acc = try XCTUnwrap(ledger.accounts.first { $0.id == exp.id })
            assertClose(acc.liveBalance(transactions: ledger.transactions, savingsTargets: targets).liveBalance,
                        exp.liveBalance, "\(exp.id) liveBalance")
        }

        let nw = ledger.netWorthMetrics(workspace: .home, now: now)
        assertClose(nw.liquidAssets, expected.netWorth.liquidAssets, "liquidAssets")
        assertClose(nw.investmentAssets, expected.netWorth.investmentAssets, "investmentAssets")
        assertClose(nw.fixedAssets, expected.netWorth.fixedAssets, "fixedAssets")
        assertClose(nw.totalLiabilities, expected.netWorth.totalLiabilities, "totalLiabilities")
        assertClose(nw.netWorth, expected.netWorth.netWorth, "netWorth")
        XCTAssertEqual(nw.historySeries.map(\.monthKey), expected.netWorth.history.map(\.monthKey))
        for (p, e) in zip(nw.historySeries, expected.netWorth.history) {
            assertClose(p.netWorth, e.netWorth, "\(e.monthKey) history netWorth")
            assertClose(p.liquidAssets, e.liquidAssets, "\(e.monthKey) history liquidAssets")
            assertClose(p.totalLiabilities, e.totalLiabilities, "\(e.monthKey) history totalLiabilities")
            XCTAssertEqual(p.hasExplicitSnapshot, e.hasExplicitSnapshot, "\(e.monthKey) snapshot")
        }
    }

    func testTransferPairMovesMoneyAndDeletesTogether() {
        var state = LedgerState.empty()
        state.accounts = [
            FinancialAccount(id: "a", name: "A", mode: .home, type: .checking, classification: .liquid,
                             startingBalance: 1000, currentBalance: 1000, autoTrackTransactions: true,
                             includeInNetWorth: true, color: "#000", updatedAt: "2025-01-01"),
            FinancialAccount(id: "b", name: "B", mode: .home, type: .savings, classification: .liquid,
                             startingBalance: 0, currentBalance: 0, autoTrackTransactions: false,
                             includeInNetWorth: true, color: "#000", updatedAt: "2025-01-01"),
        ]
        XCTAssertTrue(state.transferBetweenAccounts(from: "a", to: "b", amount: 250, note: "",
                                                    date: "2025-03-01", pairId: "x"))
        XCTAssertEqual(state.transactions.count, 2)
        XCTAssertTrue(state.transactions.allSatisfy(\.isAccountTransfer))
        let nw = state.netWorthMetrics(workspace: .home)
        XCTAssertEqual(nw.accounts.map(\.liveBalance), [750, 250])
        XCTAssertEqual(nw.netWorth, 1000)
        // Not income or spending in the month summary
        let s = state.monthSummary(monthKey: "2025-03", workspace: .home)
        XCTAssertEqual(s.incomeActual, 0)
        XCTAssertEqual(s.totalOutflowActual, 0)
        // Deleting one leg removes both
        state.deleteTransaction("x-in")
        XCTAssertTrue(state.transactions.isEmpty)
    }
}
