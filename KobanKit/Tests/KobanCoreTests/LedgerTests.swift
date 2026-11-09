import XCTest
@testable import KobanCore

final class LedgerTests: XCTestCase {
    /// A trimmed LedgerState JSON in the shape the Windows build writes (JSON.stringify output).
    private let windowsJSON = #"""
    {
      "version": 1,
      "settings": {
        "setupCompleted": true, "setupMode": "both", "activeWorkspace": "home", "currency": "CHF",
        "theme": "system", "themePalette": "default", "density": "comfortable",
        "backupDir": "", "autoBackup": false, "maxBackups": 20,
        "defaultVatRate": 8.1, "taxReserveRate": 25, "activeYear": 2026, "activeMonth": 11,
        "monthCopyScope": "budgets_and_actuals"
      },
      "groups": [
        {"id": "g-inc", "mode": "home", "name": "Income", "kind": "income", "color": "#3f704d", "column": 0, "order": 0},
        {"id": "g-exp", "mode": "home", "name": "Home", "kind": "expense", "color": "#b9432f", "column": 1, "order": 1},
        {"id": "g-sav", "mode": "home", "name": "Savings", "kind": "savings", "color": "#3f704d", "column": 1, "order": 2}
      ],
      "categories": [
        {"id": "c-salary", "groupId": "g-inc", "mode": "home", "name": "Salary", "kind": "income", "defaultBudget": 5000, "order": 0},
        {"id": "c-rent", "groupId": "g-exp", "mode": "home", "name": "Rent", "kind": "expense", "defaultBudget": 1800, "order": 0},
        {"id": "c-food", "groupId": "g-exp", "mode": "home", "name": "Groceries", "kind": "expense", "defaultBudget": 600, "order": 1},
        {"id": "c-etf", "groupId": "g-sav", "mode": "home", "name": "ETF", "kind": "savings", "defaultBudget": 500, "order": 0}
      ],
      "monthlyBudgets": [
        {"monthKey": "2026-11", "categoryId": "c-rent", "budget": 1800, "directActual": 1800},
        {"monthKey": "2026-11", "categoryId": "c-salary", "budget": 5200, "directActual": null}
      ],
      "transactions": [
        {"id": "t1", "date": "2026-11-25", "monthKey": "2026-11", "mode": "home", "type": "income", "categoryId": "c-salary", "description": "Pay", "amount": 5200, "accountId": "a1"},
        {"id": "t2", "date": "2026-11-03", "monthKey": "2026-11", "mode": "home", "type": "expense", "categoryId": "c-food", "description": "Market", "amount": 450.5, "accountId": "a1"},
        {"id": "t3", "date": "2026-11-04", "monthKey": "2026-11", "mode": "freelancer", "type": "expense", "categoryId": "c-food", "description": "Other ledger", "amount": 999}
      ],
      "recurringRules": [],
      "savingsGoals": [],
      "accounts": [
        {"id": "a1", "name": "Checking", "mode": "home", "type": "checking", "classification": "liquid",
         "startingBalance": 1000, "currentBalance": 0, "autoTrackTransactions": true, "includeInNetWorth": true,
         "color": "#3f6e8c", "updatedAt": "2026-11-01"}
      ],
      "netWorthSnapshots": []
    }
    """#

    private func decode() throws -> LedgerState {
        try JSONDecoder().decode(LedgerState.self, from: Data(windowsJSON.utf8))
    }

    func testDecodesWindowsLedgerJSON() throws {
        let state = try decode()
        XCTAssertEqual(state.settings.themePalette, .zen)
        XCTAssertEqual(state.settings.monthCopyScope, .budgetsAndActuals)
        XCTAssertNil(state.yearlyPlanItems)
        XCTAssertNil(state.monthlyBudgets[1].directActual)
    }

    func testReencodedJSONDecodesToSameState() throws {
        let state = try decode()
        let again = try JSONDecoder().decode(LedgerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again, state)
    }

    func testMonthSummaryMatchesWindowsLogic() throws {
        let s = try decode().monthSummary(monthKey: "2026-11", workspace: .home)

        XCTAssertEqual(s.incomeBudget, 5200)       // monthly override beats defaultBudget
        XCTAssertEqual(s.incomeActual, 5200)       // from transaction
        XCTAssertEqual(s.expenseBudget, 2400)      // 1800 + 600 default
        XCTAssertEqual(s.expenseActual, 2250.5)    // 1800 direct + 450.5 tx (freelancer tx excluded)
        XCTAssertEqual(s.savingsBudget, 500)
        XCTAssertEqual(s.savingsActual, 0)
        XCTAssertEqual(s.totalOutflowBudget, 2900)
        XCTAssertEqual(s.netActual, 2949.5)
        XCTAssertEqual(s.savingsRatePct, 2949.5 / 5200 * 100, accuracy: 1e-9)
        XCTAssertEqual(s.groups.map(\.group.id), ["g-inc", "g-exp", "g-sav"])

        let food = try XCTUnwrap(s.groups[1].rows.first { $0.id == "c-food" })
        XCTAssertEqual(food.difference, 149.5)     // expense: budget - actual
        XCTAssertEqual(food.txCount, 1)
    }

    func testCombinedWorkspaceIncludesFreelancerTransactions() throws {
        let s = try decode().monthSummary(monthKey: "2026-11", workspace: .combined)
        XCTAssertEqual(s.expenseActual, 2250.5 + 999)
    }

    func testNetWorthUsesAutoTrackedBalance() throws {
        let m = try decode().netWorthMetrics(workspace: .home)
        XCTAssertEqual(m.accounts.first?.liveBalance, 1000 + 5200 - 450.5)
        XCTAssertEqual(m.liquidAssets, 5749.5)
        XCTAssertEqual(m.historySeries.count, 12)
    }

    func testShiftActiveMonthRollsYear() {
        var state = LedgerState.empty()
        state.settings.activeYear = 2026
        state.settings.activeMonth = 12
        state.shiftActiveMonth(by: 1)
        XCTAssertEqual(state.activeMonthKey, "2027-01")
        state.shiftActiveMonth(by: -13)
        XCTAssertEqual(state.activeMonthKey, "2025-12")
    }
}
