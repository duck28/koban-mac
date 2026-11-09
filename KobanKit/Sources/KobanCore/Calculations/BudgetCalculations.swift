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
                    let budget = mb?.budget ?? cat.defaultBudget
                    let stats = txByCategory[cat.id] ?? TxStats()
                    let directActual = mb?.directActual
                    let actual = directActual ?? stats.sum
                    let difference = group.kind == .income ? actual - budget : budget - actual

                    let catTaxRate = cat.taxRate ?? 0
                    let catDedPct = cat.deductiblePct ?? (cat.mode == .freelancer ? 100 : 0)

                    let deductibleActual: Double
                    let vatAmount: Double
                    if directActual != nil {
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
                        vatAmount: vatAmount
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
}
