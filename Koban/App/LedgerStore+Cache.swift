import Foundation

/// Cached versions of the ledger calculations, invalidated whenever `state` changes.
extension LedgerStore {
    private func cached<T>(_ key: String, _ compute: () -> T) -> T {
        if let hit = calcCache[key] as? T { return hit }
        let value = compute()
        calcCache[key] = value
        return value
    }

    func monthSummary(monthKey: String, workspace: ActiveWorkspace) -> MonthSummaryMetrics {
        cached("summary|\(monthKey)|\(workspace.rawValue)") {
            state.monthSummary(monthKey: monthKey, workspace: workspace)
        }
    }

    /// The active month in the active workspace (what most views show).
    var activeSummary: MonthSummaryMetrics {
        monthSummary(monthKey: state.activeMonthKey, workspace: state.settings.activeWorkspace)
    }

    func annualSeries(year: Int, workspace: ActiveWorkspace) -> [AnnualMonthPoint] {
        cached("annual|\(year)|\(workspace.rawValue)") {
            state.annualSeries(year: year, workspace: workspace)
        }
    }

    func netWorthMetrics(workspace: ActiveWorkspace, monthlyOutflowReference: Double) -> NetWorthSummaryMetrics {
        cached("networth|\(workspace.rawValue)|\(monthlyOutflowReference)") {
            state.netWorthMetrics(workspace: workspace, monthlyOutflowReference: monthlyOutflowReference)
        }
    }

    func monthHasData(monthKey: String, workspace: ActiveWorkspace) -> Bool {
        let s = monthSummary(monthKey: monthKey, workspace: workspace)
        return s.incomeBudget > 0 || s.incomeActual > 0 || s.totalOutflowBudget > 0 || s.totalOutflowActual > 0
    }
}
