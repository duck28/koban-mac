import XCTest
@testable import KobanCore

/// Mirrors scripts/test-recurring.ts (sections 8–10) in koban-windows plus the worksheet
/// effects of scheduled rules and fixed-cost auto actuals.
final class RecurringScheduleTests: XCTestCase {
    private func rule(id: String = "r", type: TransactionType = .expense, categoryId: String = "c-rent",
                      amount: Double = 100, frequency: RecurrenceFrequency = .monthly, day: Int = 5,
                      startDate: String? = nil, startMonth: String? = nil) -> RecurringRule {
        RecurringRule(id: id, mode: .home, type: type, categoryId: categoryId, description: "Test",
                      amount: amount, frequency: frequency, dayOfMonth: day, active: true,
                      startDate: startDate, startMonth: startMonth)
    }

    func testIsoWeekHelpers() {
        let d = RecurringSchedule.dayNumber("2026-11-20")!
        XCTAssertEqual(RecurringSchedule.isoWeek(d).week, 47)
        XCTAssertEqual(RecurringSchedule.isoWeek(d).year, 2026)
        XCTAssertEqual(RecurringSchedule.weekday(d), 4) // Friday
        XCTAssertEqual(RecurringSchedule.isoWeek(RecurringSchedule.dayNumber("2027-01-01")!).week, 53)
        XCTAssertEqual(RecurringSchedule.isoWeek(RecurringSchedule.dayNumber("2024-12-30")!).year, 2025)
        XCTAssertEqual(RecurringSchedule.date(isoYear: 2026, week: 47, weekday: 4), "2026-11-20")
        XCTAssertEqual(RecurringSchedule.date(isoYear: 2025, week: 1, weekday: 0), "2024-12-30")
        XCTAssertNil(RecurringSchedule.dayNumber("2026-02-30"))
    }

    func testBiweeklyWithStartWeek() {
        let r = rule(type: .income, amount: 1000, frequency: .biweekly, day: 2, startDate: "2026-01-02")
        XCTAssertTrue(r.isScheduled)
        XCTAssertEqual(r.occurrenceDates(inMonth: "2025-12"), [])
        XCTAssertEqual(r.occurrenceDates(inMonth: "2026-01"), ["2026-01-02", "2026-01-16", "2026-01-30"])
        XCTAssertEqual(r.occurrenceDates(inMonth: "2026-02"), ["2026-02-13", "2026-02-27"])
        XCTAssertEqual(r.amountDue(inMonth: "2026-01"), 3000)
        let total = (1...12).reduce(0) { $0 + (r.occurrenceDates(inMonth: String(format: "2026-%02d", $1))?.count ?? 0) }
        XCTAssertEqual(total, 26)

        var state = LedgerState.empty()
        state.recurringRules = [r]
        XCTAssertEqual(state.applyRecurring(toMonth: "2026-01", workspace: .home), .posted(3))
        XCTAssertEqual(state.transactions.map(\.date).sorted(), ["2026-01-02", "2026-01-16", "2026-01-30"])
        XCTAssertEqual(state.applyRecurring(toMonth: "2026-01", workspace: .home), .alreadyPosted)
    }

    func testStartMonthCadence() {
        let bm = rule(amount: 120, frequency: .bimonthly, day: 10, startMonth: "2026-12")
        XCTAssertTrue(bm.isScheduled)
        XCTAssertEqual(bm.amountDue(inMonth: "2026-11"), 0)
        XCTAssertEqual(bm.amountDue(inMonth: "2026-12"), 120)
        XCTAssertEqual(bm.amountDue(inMonth: "2027-01"), 0)
        XCTAssertEqual(bm.amountDue(inMonth: "2027-02"), 120)

        var state = LedgerState.empty()
        state.recurringRules = [bm]
        XCTAssertEqual(state.applyRecurring(toMonth: "2027-01", workspace: .home), .alreadyPosted)
        XCTAssertEqual(state.applyRecurring(toMonth: "2027-02", workspace: .home), .posted(1))
        XCTAssertEqual(state.transactions.first?.date, "2027-02-10")

        let q = rule(frequency: .quarterly, startMonth: "2026-02")
        XCTAssertEqual(q.amountDue(inMonth: "2026-05"), 100)
        XCTAssertEqual(q.amountDue(inMonth: "2026-06"), 0)

        let legacy = rule(frequency: .bimonthly)
        XCTAssertFalse(legacy.isScheduled)
        XCTAssertNil(legacy.amountDue(inMonth: "2026-11"))
    }

    private func ledgerWithRentAndSalary() -> LedgerState {
        var state = LedgerState.empty()
        state.groups = [
            CategoryGroup(id: "g-inc", mode: .home, name: "Income", kind: .income, color: "#000", column: 0, order: 0),
            CategoryGroup(id: "g-exp", mode: .home, name: "Home", kind: .expense, color: "#000", column: 1, order: 1),
        ]
        state.categories = [
            CategoryItem(id: "c-salary", groupId: "g-inc", mode: .home, name: "Salary", kind: .income,
                         defaultBudget: 0, isRecurring: true, order: 0),
            CategoryItem(id: "c-rent", groupId: "g-exp", mode: .home, name: "Rent", kind: .expense,
                         defaultBudget: 1800, isRecurring: true, order: 0, isFixedCost: true),
            CategoryItem(id: "c-netflix", groupId: "g-exp", mode: .home, name: "Netflix", kind: .expense,
                         defaultBudget: 20, isRecurring: true, order: 1),
        ]
        state.recurringRules = [
            rule(id: "r-sal", type: .income, categoryId: "c-salary", amount: 2000, frequency: .biweekly,
                 startDate: "2026-01-02"),
            rule(id: "r-rent", categoryId: "c-rent", amount: 1800),
        ]
        return state
    }

    func testWorksheetUsesScheduleAndAutoFillsFixedCosts() throws {
        var state = ledgerWithRentAndSalary()
        // 3 bi-weekly paydays; the fixed cost's Actual equals its Budget
        let jan = state.monthSummary(monthKey: "2026-01", workspace: .home)
        let salary = try XCTUnwrap(jan.groups[0].rows.first)
        XCTAssertTrue(salary.budgetFromSchedule)
        XCTAssertEqual(salary.budget, 6000)
        XCTAssertFalse(salary.autoActual) // income is never auto-filled
        let rent = try XCTUnwrap(jan.groups[1].rows.first)
        XCTAssertTrue(rent.isFixedCost)
        XCTAssertTrue(rent.autoActual)
        XCTAssertEqual(rent.actual, 1800)
        // A recurring (subscription) category that is not a fixed cost is not auto-filled
        let netflix = try XCTUnwrap(jan.groups[1].rows.first { $0.id == "c-netflix" })
        XCTAssertFalse(netflix.isFixedCost)
        XCTAssertFalse(netflix.autoActual)
        XCTAssertEqual(netflix.actual, 0)
        // Changing the Budget moves the auto Actual with it
        state.setBudget(1900, categoryId: "c-rent", monthKey: "2026-01")
        XCTAssertEqual(state.monthSummary(monthKey: "2026-01", workspace: .home).groups[1].rows[0].actual, 1900)

        // A typed budget overrides the schedule for that month only
        state.setBudget(5000, categoryId: "c-salary", monthKey: "2026-01")
        let janTyped = state.monthSummary(monthKey: "2026-01", workspace: .home)
        XCTAssertEqual(janTyped.groups[0].rows[0].budget, 5000)
        XCTAssertTrue(janTyped.groups[0].rows[0].budgetOverridesSchedule)
        XCTAssertEqual(state.monthSummary(monthKey: "2026-02", workspace: .home).groups[0].rows[0].budget, 4000)
        state.resetScheduledBudget(categoryId: "c-salary", monthKey: "2026-01")
        XCTAssertEqual(state.monthSummary(monthKey: "2026-01", workspace: .home).groups[0].rows[0].budget, 6000)

        // A typed Actual wins over the auto-filled one
        state.setDirectActual(1750, categoryId: "c-rent", monthKey: "2026-01")
        let rentTyped = state.monthSummary(monthKey: "2026-01", workspace: .home).groups[1].rows[0]
        XCTAssertFalse(rentTyped.autoActual)
        XCTAssertEqual(rentTyped.actual, 1750)

        // Toggling the flag off stops the auto-fill
        XCTAssertEqual(state.toggleCategoryFixed("c-rent"), false)
        XCTAssertFalse(state.monthSummary(monthKey: "2026-02", workspace: .home).groups[1].rows[0].autoActual)
        state.toggleCategoryFixed("c-rent")

        // The setting turns auto-fill off
        state.settings.autoFillFixedActuals = false
        let off = state.monthSummary(monthKey: "2026-02", workspace: .home).groups[1].rows[0]
        XCTAssertFalse(off.autoActual)
        XCTAssertEqual(off.actual, 0)
    }

    func testNewFieldsRoundTripThroughJSON() throws {
        var state = ledgerWithRentAndSalary()
        state.settings.autoFillFixedActuals = false
        state.setBudget(5000, categoryId: "c-salary", monthKey: "2026-01")
        let again = try JSONDecoder().decode(LedgerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again.recurringRules.first?.startDate, "2026-01-02")
        XCTAssertEqual(again.monthlyBudgets.first?.budgetManual, true)
        XCTAssertEqual(again.settings.autoFillFixedActuals, false)
        XCTAssertEqual(again.categories.first { $0.id == "c-rent" }?.isFixedCost, true)
    }
}
