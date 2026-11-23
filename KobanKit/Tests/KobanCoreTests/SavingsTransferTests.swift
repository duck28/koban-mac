import XCTest
@testable import KobanCore

/// Mirrors sections 11–12 of scripts/test-recurring.ts in koban-windows.
final class SavingsTransferTests: XCTestCase {
    private func account(_ id: String, _ cls: AccountLiquidityClass = .liquid, start: Double = 1000,
                         autoTrack: Bool = true, updatedAt: String = "2026-01-01") -> FinancialAccount {
        FinancialAccount(id: id, name: id, mode: .home, type: .checking, classification: cls,
                         startingBalance: start, currentBalance: start, autoTrackTransactions: autoTrack,
                         includeInNetWorth: true, color: "#000", updatedAt: updatedAt)
    }

    private func saving(_ id: String, date: String) -> TransactionItem {
        TransactionItem(id: id, date: date, monthKey: String(date.prefix(7)), mode: .home, type: .expense,
                        categoryId: "c-etf", accountId: "chk", description: "ETF", amount: 500)
    }

    func testSavingsMoveBetweenAccounts() {
        let txs = [saving("t1", date: "2026-01-15"), saving("t2", date: "2026-02-15")]
        let targets = ["c-etf": "etf"]
        let chk = account("chk").liveBalance(transactions: txs, savingsTargets: targets).liveBalance
        let etf = account("etf", .investment, start: 5000).liveBalance(transactions: txs, savingsTargets: targets).liveBalance
        XCTAssertEqual(chk, 0)
        XCTAssertEqual(etf, 6000)
        XCTAssertEqual(chk + etf, 6000) // net worth unchanged

        // Manually valued target: only transfers after its last valuation count
        let manual = account("etf2", .investment, start: 5000, autoTrack: false, updatedAt: "2026-02-01")
        XCTAssertEqual(manual.liveBalance(transactions: txs, savingsTargets: ["c-etf": "etf2"]).liveBalance, 5500)

        // No target: the saving only leaves the source account (old behaviour)
        XCTAssertEqual(account("etf", .investment, start: 5000).liveBalance(transactions: txs).liveBalance, 5000)
    }

    func testSavingsTargetsMapAndNetWorth() {
        var state = LedgerState.empty()
        state.categories = [
            CategoryItem(id: "c-etf", groupId: "g", mode: .home, name: "ETF", kind: .savings,
                         defaultBudget: 0, order: 0, targetAccountId: "etf"),
            CategoryItem(id: "c-food", groupId: "g2", mode: .home, name: "Food", kind: .expense,
                         defaultBudget: 0, order: 0, targetAccountId: "etf"),
        ]
        XCTAssertEqual(state.savingsTargets, ["c-etf": "etf"]) // only savings categories
        state.accounts = [account("chk"), account("etf", .investment, start: 5000)]
        state.transactions = [saving("t1", date: "2026-01-15")]
        XCTAssertEqual(state.netWorthMetrics(workspace: .home).netWorth, 6000)
    }

    func testYearlyPlanSchedules() throws {
        XCTAssertEqual(YearlyPlanSchedule.biweekly.periodsPerYear, 26)
        XCTAssertEqual(YearlyPlanSchedule.quarterly.periodsPerYear, 4)
        XCTAssertEqual(YearlyPlanSchedule(frequency: .yearly), .annualLump)
        XCTAssertEqual(YearlyPlanSchedule(frequency: .bimonthly), .bimonthly)
        // Values written by the Windows build decode; unknown ones fall back instead of failing
        let decoded = try JSONDecoder().decode([YearlyPlanSchedule].self,
                                               from: Data(#"["biweekly","quarterly","annual_lump","weekly"]"#.utf8))
        XCTAssertEqual(decoded, [.biweekly, .quarterly, .annualLump, .monthly])
    }
}
