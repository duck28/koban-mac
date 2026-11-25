import Foundation

// Port of computeMonthSummary / computeAnnualSeries from src/utils/calculations.ts.
// Keep the two implementations behaviorally identical — numbers shown on macOS
// must match the Windows build for the same vault.

struct CategoryComputedRow: Identifiable, Hashable, Sendable {
    var category: CategoryItem
    var group: CategoryGroup
    var budget: Double
    var txActual: Double
    var directActual: Double?
    var actual: Double
    /// Vertex42 convention:
    /// - Income: Actual - Budget (positive = earned more than planned)
    /// - Expense / Savings: Budget - Actual (positive = under budget)
    var difference: Double
    var txCount: Int
    var deductibleActual: Double
    var vatAmount: Double
    /// Budget comes from a scheduled recurring rule (bi-weekly / bi-monthly / quarterly / yearly).
    var budgetFromSchedule: Bool = false
    /// Budget typed by hand this month although a recurring schedule exists.
    var budgetOverridesSchedule: Bool = false
    /// Category is marked as a fixed cost (anchor toggle).
    var isFixedCost: Bool = false
    /// Actual is the Budget filled in automatically (fixed cost, no transactions, no typed Actual).
    var autoActual: Bool = false

    var id: String { category.id }
}

struct GroupComputedSummary: Identifiable, Hashable, Sendable {
    var group: CategoryGroup
    var rows: [CategoryComputedRow]
    var totalBudget: Double
    var totalActual: Double
    var totalDifference: Double
    var totalDeductible: Double
    var totalVat: Double

    var id: String { group.id }
}

struct MonthSummaryMetrics: Hashable, Sendable {
    var monthKey: String
    var incomeBudget: Double
    var incomeActual: Double
    var incomeDifference: Double
    var expenseBudget: Double
    var expenseActual: Double
    var expenseDifference: Double
    var savingsBudget: Double
    var savingsActual: Double
    var savingsDifference: Double
    /// Vertex42 "Total Expenses" = all non-income groups (expenses + savings allocations).
    var totalOutflowBudget: Double
    var totalOutflowActual: Double
    var totalOutflowDifference: Double
    var netBudget: Double
    var netActual: Double
    var netDifference: Double
    var savingsRatePct: Double
    // Freelancer / business
    var deductibleExpensesActual: Double
    var vatCollected: Double
    var vatPaidOnExpenses: Double
    var netVatPayable: Double
    var estimatedTaxReserve: Double
    var groups: [GroupComputedSummary]
}

struct AnnualMonthPoint: Identifiable, Hashable, Sendable {
    var month: Int
    var monthLabel: String
    var monthKey: String
    var incomeBudget: Double
    var incomeActual: Double
    var outflowBudget: Double
    var outflowActual: Double
    var netBudget: Double
    var netActual: Double

    var id: String { monthKey }
}

private struct TxStats {
    var sum = 0.0
    var count = 0
    var deductible = 0.0
    var vat = 0.0
}

extension LedgerState {
    func scheduledBudgetByCategory(inMonth monthKey: String) -> [String: Double] {
        var scheduled: [String: Double] = [:]
        for r in recurringRules where r.active && r.amount > 0 && r.isScheduled {
            guard let amt = r.amountDue(inMonth: monthKey) else { continue }
            scheduled[r.categoryId, default: 0] += amt
        }
        return scheduled
    }

    func monthSummary(monthKey: String, workspace: ActiveWorkspace) -> MonthSummaryMetrics {
        let activeGroups = groups
            .filter { workspace.includes($0.mode) }
            .sorted { $0.order < $1.order }
        let activeCategories = categories
            .filter { workspace.includes($0.mode) }
            .sorted { $0.order < $1.order }

        var monthBudgets: [String: MonthlyBudgetEntry] = [:]
        for mb in monthlyBudgets where mb.monthKey == monthKey {
            monthBudgets[mb.categoryId] = mb // last entry wins, like Map.set in TS
        }

        // Fixed costs: Actual follows Budget (setting, absent ⇒ on)
        let autoFillFixed = settings.autoFillFixedActuals ?? true

        // Recurring rules with a start week / month: the budget varies per month
        let scheduledBudgetByCat = scheduledBudgetByCategory(inMonth: monthKey)

        var txByCategory: [String: TxStats] = [:]
        for tx in transactions where tx.monthKey == monthKey && workspace.includes(tx.mode) {
            var cur = txByCategory[tx.categoryId] ?? TxStats()
            cur.sum += tx.amount
            cur.count += 1
            let dedPct = tx.deductiblePct ?? 100
            let taxRate = tx.taxRate ?? 0
            if tx.type == .expense {
                cur.deductible += tx.amount * (dedPct / 100)
            }
            if taxRate > 0 {
                cur.vat += tx.amount - tx.amount / (1 + taxRate / 100)
            }
            txByCategory[tx.categoryId] = cur
        }

        let groupSummaries: [GroupComputedSummary] = activeGroups.map { group in
            let rows: [CategoryComputedRow] = activeCategories
                .filter { $0.groupId == group.id }
                .map { cat in
                    let mb = monthBudgets[cat.id]
                    let scheduledBudget = scheduledBudgetByCat[cat.id]
                    let budgetManual = mb?.budgetManual ?? false
                    let budgetFromSchedule = scheduledBudget != nil && !budgetManual
                    let budget = budgetFromSchedule ? scheduledBudget! : (mb?.budget ?? cat.defaultBudget)
                    let stats = txByCategory[cat.id] ?? TxStats()
                    let directActual = mb?.directActual
                    let isFixedCost = cat.isFixedCost ?? false
                    let autoActual = autoFillFixed && isFixedCost && directActual == nil && stats.count == 0
                    // A typed or auto-filled Actual is not backed by transactions: derive VAT/deductible from it
                    let derivedActual = directActual ?? (autoActual ? budget : nil)
                    let actual = derivedActual ?? stats.sum
                    let difference = group.kind == .income ? actual - budget : budget - actual

                    let catTaxRate = cat.taxRate ?? 0
                    let catDedPct = cat.deductiblePct ?? (cat.mode == .freelancer ? 100 : 0)

                    let deductibleActual: Double
                    let vatAmount: Double
                    if derivedActual != nil {
                        deductibleActual = group.kind != .income ? actual * (catDedPct / 100) : 0
                        vatAmount = catTaxRate > 0 ? actual - actual / (1 + catTaxRate / 100) : 0
                    } else {
                        deductibleActual = stats.deductible
                        vatAmount = stats.vat
                    }

                    return CategoryComputedRow(
                        category: cat,
                        group: group,
                        budget: budget,
                        txActual: stats.sum,
                        directActual: directActual,
                        actual: actual,
                        difference: difference,
                        txCount: stats.count,
                        deductibleActual: deductibleActual,
                        vatAmount: vatAmount,
                        budgetFromSchedule: budgetFromSchedule,
                        budgetOverridesSchedule: scheduledBudget != nil && budgetManual,
                        isFixedCost: isFixedCost,
                        autoActual: autoActual
                    )
                }

            let totalBudget = rows.reduce(0) { $0 + $1.budget }
            let totalActual = rows.reduce(0) { $0 + $1.actual }
            return GroupComputedSummary(
                group: group,
                rows: rows,
                totalBudget: totalBudget,
                totalActual: totalActual,
                totalDifference: group.kind == .income ? totalActual - totalBudget : totalBudget - totalActual,
                totalDeductible: rows.reduce(0) { $0 + $1.deductibleActual },
                totalVat: rows.reduce(0) { $0 + $1.vatAmount }
            )
        }

        var incomeBudget = 0.0, incomeActual = 0.0
        var expenseBudget = 0.0, expenseActual = 0.0
        var savingsBudget = 0.0, savingsActual = 0.0
        var deductibleExpensesActual = 0.0
        var vatCollected = 0.0, vatPaidOnExpenses = 0.0

        for gs in groupSummaries {
            switch gs.group.kind {
            case .income:
                incomeBudget += gs.totalBudget
                incomeActual += gs.totalActual
                vatCollected += gs.totalVat
            case .savings:
                savingsBudget += gs.totalBudget
                savingsActual += gs.totalActual
                deductibleExpensesActual += gs.totalDeductible
            case .expense:
                expenseBudget += gs.totalBudget
                expenseActual += gs.totalActual
                deductibleExpensesActual += gs.totalDeductible
                vatPaidOnExpenses += gs.totalVat
            }
        }

        let totalOutflowBudget = expenseBudget + savingsBudget
        let totalOutflowActual = expenseActual + savingsActual
        let netBudget = incomeBudget - totalOutflowBudget
        let netActual = incomeActual - totalOutflowActual
        let retainedOrSaved = netActual + savingsActual
        let savingsRatePct = incomeActual > 0 ? max(0, retainedOrSaved / incomeActual * 100) : 0
        let netOperatingProfit = max(0, incomeActual - deductibleExpensesActual)
        // TS uses `taxReserveRate || 25`, so 0 falls back to 25.
        let reserveRate = settings.taxReserveRate == 0 ? 25 : settings.taxReserveRate

        return MonthSummaryMetrics(
            monthKey: monthKey,
            incomeBudget: incomeBudget,
            incomeActual: incomeActual,
            incomeDifference: incomeActual - incomeBudget,
            expenseBudget: expenseBudget,
            expenseActual: expenseActual,
            expenseDifference: expenseBudget - expenseActual,
            savingsBudget: savingsBudget,
            savingsActual: savingsActual,
            savingsDifference: savingsBudget - savingsActual,
            totalOutflowBudget: totalOutflowBudget,
            totalOutflowActual: totalOutflowActual,
            totalOutflowDifference: totalOutflowBudget - totalOutflowActual,
            netBudget: netBudget,
            netActual: netActual,
            netDifference: netActual - netBudget,
            savingsRatePct: savingsRatePct,
            deductibleExpensesActual: deductibleExpensesActual,
            vatCollected: vatCollected,
            vatPaidOnExpenses: vatPaidOnExpenses,
            netVatPayable: max(0, vatCollected - vatPaidOnExpenses),
            estimatedTaxReserve: netOperatingProfit * (reserveRate / 100),
            groups: groupSummaries
        )
    }

    func annualSeries(year: Int, workspace: ActiveWorkspace) -> [AnnualMonthPoint] {
        MonthKey.shortMonthLabels.enumerated().map { idx, label in
            let month = idx + 1
            let key = MonthKey.format(year: year, month: month)
            let s = monthSummary(monthKey: key, workspace: workspace)
            return AnnualMonthPoint(
                month: month,
                monthLabel: label,
                monthKey: key,
                incomeBudget: s.incomeBudget,
                incomeActual: s.incomeActual,
                outflowBudget: s.totalOutflowBudget,
                outflowActual: s.totalOutflowActual,
                netBudget: s.netBudget,
                netActual: s.netActual
            )
        }
    }

    static func sortWorksheetRows(
        _ rows: [CategoryComputedRow],
        by sortBy: WorksheetSortField = .manual,
        direction sortDir: WorksheetSortDirection = .asc,
        displayName: (CategoryItem) -> String = \.name
    ) -> [CategoryComputedRow] {
        let dir = sortDir == .desc ? -1 : 1
        return rows.sorted { a, b in
            if sortBy == .manual {
                return a.category.order < b.category.order
            }
            let cmp: Int
            switch sortBy {
            case .manual:
                cmp = 0
            case .name:
                let r = displayName(a.category).localizedStandardCompare(displayName(b.category))
                cmp = r == .orderedAscending ? -1 : (r == .orderedDescending ? 1 : 0)
            case .budget:
                cmp = a.budget < b.budget ? -1 : (a.budget > b.budget ? 1 : 0)
            case .actual:
                cmp = a.actual < b.actual ? -1 : (a.actual > b.actual ? 1 : 0)
            case .diff:
                cmp = a.difference < b.difference ? -1 : (a.difference > b.difference ? 1 : 0)
            }
            if cmp != 0 { return cmp * dir < 0 }
            return a.category.order < b.category.order
        }
    }
}
