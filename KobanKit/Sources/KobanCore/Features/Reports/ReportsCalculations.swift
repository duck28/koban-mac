import Foundation

// Derived data for the Reports & Charts view (the computations at the top of
// src/components/ReportsChartsView.tsx).

struct ReportsData: Sendable {
    /// Non-income groups with any budget or actual.
    var outflowGroups: [GroupComputedSummary]
    /// outflowGroups with actual > 0, largest first (donut + legend).
    var activeSpendingGroups: [GroupComputedSummary]
    /// max(1, totalOutflowActual): donut denominator.
    var totalOutflowActual: Double
    /// Top 10 non-income categories by actual spend.
    var topExpenseCategories: [CategoryComputedRow]
    var maxGroupBarValue: Double
    var maxAnnualValue: Double
    /// Income transactions of the month grouped by client (or description), largest first.
    var clientRevenue: [(name: String, amount: Double)]

    init(state: LedgerState, summary: MonthSummaryMetrics, annualSeries: [AnnualMonthPoint],
         workspace: ActiveWorkspace) {
        outflowGroups = summary.groups.filter {
            $0.group.kind != .income && ($0.totalActual > 0 || $0.totalBudget > 0)
        }
        activeSpendingGroups = Self.stableSorted(outflowGroups.filter { $0.totalActual > 0 }) {
            $0.totalActual > $1.totalActual
        }
        totalOutflowActual = max(1, summary.totalOutflowActual)

        let expenseRows = summary.groups.filter { $0.group.kind != .income }.flatMap(\.rows)
        topExpenseCategories = Array(Self.stableSorted(expenseRows.filter { $0.actual > 0 || $0.budget > 0 }) {
            $0.actual > $1.actual
        }.prefix(10))

        maxGroupBarValue = ([1] + outflowGroups.map { max($0.totalBudget, $0.totalActual) }).max() ?? 1
        maxAnnualValue = ([1000] + annualSeries.map { max($0.incomeActual, $0.outflowActual, $0.incomeBudget) }).max() ?? 1000

        // Map preserves insertion order in JS; replicate before the (stable) sort.
        var order: [String] = []
        var sums: [String: Double] = [:]
        for tx in state.transactions where tx.type == .income
            && (workspace == .combined || tx.mode.rawValue == workspace.rawValue)
            && tx.monthKey == summary.monthKey {
            let name = Self.firstNonEmpty(tx.client, tx.description) ?? "General Revenue"
            if sums[name] == nil { order.append(name) }
            sums[name, default: 0] += tx.amount
        }
        clientRevenue = Self.stableSorted(order.map { (name: $0, amount: sums[$0] ?? 0) }) { $0.amount > $1.amount }
    }

    /// JS `a || b` on strings: first non-empty.
    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Array.prototype.sort is stable; Swift's `sorted` is not guaranteed to be.
    static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
