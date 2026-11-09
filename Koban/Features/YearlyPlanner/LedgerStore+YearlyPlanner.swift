import Foundation

// Yearly Planner handlers of App.tsx (~1257–1400), with their notifications.
extension LedgerStore {
    func upsertYearlyPlanItem(_ item: YearlyPlanItem) {
        update { $0.upsertYearlyPlanItem(item) }
    }

    func deleteYearlyPlanItem(id: String) {
        update { $0.deleteYearlyPlanItem(id: id) }
        notify("Removed item from yearly plan.")
    }

    func bulkSetYearlyPlan(year: Int, items: [YearlyPlanItem]) {
        update { $0.bulkSetYearlyPlan(year: year, items: items) }
        notify("Seeded \(items.count) categories into \(year) plan.")
    }

    func setYearlyPlannerReturnRate(accountId: String, returnPct: Double) {
        update { $0.setYearlyPlannerReturnRate(accountId: accountId, returnPct: returnPct) }
    }

    func applyYearlyPlanToMonthlyBudgets(year: Int, items: [YearlyPlanItem]) {
        update { $0.applyYearlyPlanToMonthlyBudgets(year: year, items: items) }
        notify("Applied \(year) yearly plan across all 12 monthly budget worksheets.")
    }

    func addCategoryAndPlanItem(_ req: YearlyPlanNewItemRequest) {
        update { $0.addCategoryAndPlanItem(req) }
        notify("Added \"\(req.label)\" (\(state.settings.currency) \(YearlyPlanner.localeString(req.annualAmount))) to \(req.year) Yearly Planner.")
    }
}
