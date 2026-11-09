import Foundation

// Platform-independent logic of the Yearly Budget & Account Forecast Planner.
// Ports the projection math of src/components/YearlyBudgetPlannerView.tsx and the
// yearly-plan handlers of src/App.tsx (handleUpsertYearlyPlanItem …).

// MARK: - Projections

struct YearlyPlanLinkedItem: Hashable, Sendable {
    enum Direction: Hashable, Sendable { case inflow, outflow }
    var label: String
    var amount: Double
    var direction: Direction
}

struct YearlyAccountProjection: Identifiable, Hashable, Sendable {
    var account: FinancialAccount
    var liveBalance: Double
    var currentStanding: Double
    var plannedInflows: Double
    var plannedOutflows: Double
    var netPlannedFlow: Double
    var returnRatePct: Double
    var estimatedReturn: Double
    var projectedEndBalance: Double
    var fiveYearEstimate: Double
    var linkedItems: [YearlyPlanLinkedItem]

    var id: String { account.id }
    var isLiability: Bool { account.classification == .liability }
    /// Non-liability account projected to end the year below zero.
    var isShortfall: Bool { !isLiability && projectedEndBalance < 0 }
    var isInvestmentOrRetirement: Bool {
        account.classification == .investment || account.classification == .retirement || account.type == .savings
    }
}

struct YearlyPlanTotals: Hashable, Sendable {
    var plannedIncome: Double
    var plannedExpenses: Double
    var plannedSavingsAndInvestments: Double
    var unallocatedCashflow: Double
    var estimatedInvestmentGrowth: Double
    var currentNetWorthStanding: Double
    var projectedYearEndNetWorth: Double
    var projectedFiveYearNetWorth: Double
}

enum YearlyPlanner {
    /// getDefaultReturnRateForAccount (src/data/templates.ts).
    static func returnRate(_ acc: FinancialAccount) -> Double {
        KobanTemplates.defaultReturnRate(type: acc.type, classification: acc.classification,
                                         expected: acc.expectedAnnualReturnPct)
    }

    /// Account-by-account standing & end-of-year projections (accountProjections useMemo).
    static func projections(accounts: [AccountComputedItem], items: [YearlyPlanItem]) -> [YearlyAccountProjection] {
        accounts.map { ar in
            let acc = ar.account
            let current = ar.liveBalance
            let rate = returnRate(acc)
            var inflows = 0.0, outflows = 0.0
            var linked: [YearlyPlanLinkedItem] = []

            for item in items where item.annualAmount > 0 {
                if item.kind == .income && item.accountId == acc.id {
                    inflows += item.annualAmount
                    linked.append(.init(label: item.label, amount: item.annualAmount, direction: .inflow))
                } else if item.kind == .expense && item.accountId == acc.id {
                    outflows += item.annualAmount
                    linked.append(.init(label: item.label, amount: item.annualAmount, direction: .outflow))
                } else if item.kind == .savings {
                    if item.accountId == acc.id && item.destinationAccountId != acc.id {
                        outflows += item.annualAmount
                        linked.append(.init(label: "Transfer → \(item.label)", amount: item.annualAmount, direction: .outflow))
                    }
                    if item.destinationAccountId == acc.id
                        || (isEmpty(item.destinationAccountId) && item.accountId == acc.id) {
                        inflows += item.annualAmount
                        linked.append(.init(label: item.label, amount: item.annualAmount, direction: .inflow))
                    }
                }
            }

            let net = inflows - outflows
            let liability = acc.classification == .liability
            // Existing standing compounds for the full year; net positive inflows for ~half a year.
            let baseForReturn = max(0, current + (net > 0 ? net * 0.5 : net))
            let estReturn = liability ? 0 : baseForReturn * (rate / 100)
            let projected = liability
                ? max(0, current - inflows + outflows)
                : current + net + estReturn

            var fiveYear = projected
            if !liability && rate > 0 {
                let r = rate / 100
                var bal = current
                let annualAdd = max(0, net)
                for _ in 0..<5 { bal = (bal + annualAdd * 0.5) * (1 + r) + annualAdd * 0.5 }
                fiveYear = bal
            } else if !liability {
                fiveYear = current + max(0, net) * 5
            }

            return YearlyAccountProjection(
                account: acc, liveBalance: ar.liveBalance, currentStanding: current,
                plannedInflows: inflows, plannedOutflows: outflows, netPlannedFlow: net,
                returnRatePct: rate, estimatedReturn: estReturn, projectedEndBalance: projected,
                fiveYearEstimate: fiveYear, linkedItems: linked)
        }
    }

    static func totals(items: [YearlyPlanItem], projections: [YearlyAccountProjection]) -> YearlyPlanTotals {
        func sum(_ kind: CategoryKind) -> Double {
            items.filter { $0.kind == kind }.reduce(0) { $0 + $1.annualAmount }
        }
        let income = sum(.income), expenses = sum(.expense), savings = sum(.savings)
        var growth = 0.0, current = 0.0, yearEnd = 0.0, fiveYear = 0.0
        for p in projections {
            growth += p.estimatedReturn
            current += p.isLiability ? -p.currentStanding : p.currentStanding
            yearEnd += p.isLiability ? -p.projectedEndBalance : p.projectedEndBalance
            fiveYear += p.isLiability ? -p.projectedEndBalance : p.fiveYearEstimate
        }
        return YearlyPlanTotals(
            plannedIncome: income, plannedExpenses: expenses, plannedSavingsAndInvestments: savings,
            unallocatedCashflow: income - expenses - savings, estimatedInvestmentGrowth: growth,
            currentNetWorthStanding: current, projectedYearEndNetWorth: yearEnd,
            projectedFiveYearNetWorth: fiveYear)
    }

    /// Per-row compounded estimate of a planned savings allocation (yr1Gain / yr5Value).
    static func allocationGrowth(kind: CategoryKind, annualAmount: Double, rate: Double) -> (yr1Gain: Double, yr5Value: Double) {
        guard kind == .savings && annualAmount > 0 && rate > 0 else { return (0, annualAmount * 5) }
        let r = rate / 100
        var v = 0.0
        for _ in 0..<5 { v = (v + annualAmount * 0.5) * (1 + r) + annualAmount * 0.5 }
        return (annualAmount * (rate / 100) * 0.5, v)
    }

    /// handleSeedFromCurrentBudget: yearly plan from the active month's budgets (×12)
    /// and active recurring rules (annualised). Uses all categories, like Windows.
    static func seedItems(state: LedgerState, year: Int) -> [YearlyPlanItem] {
        let activeKey = MonthKey.format(year: state.settings.activeYear, month: state.settings.activeMonth)
        var mbMap: [String: Double] = [:]
        for mb in state.monthlyBudgets where mb.monthKey == activeKey && mb.budget > 0 {
            mbMap[mb.categoryId] = mb.budget
        }
        var recMap: [String: Double] = [:]
        for r in state.recurringRules where r.active && r.amount > 0 {
            switch r.frequency {
            case .monthly: recMap[r.categoryId] = r.amount * 12
            case .quarterly: recMap[r.categoryId] = r.amount * 4
            case .yearly: recMap[r.categoryId] = r.amount
            }
        }

        let accounts = state.accounts
        let homeChecking = accounts.first { $0.mode == .home && $0.type == .checking }?.id
            ?? accounts.first { $0.classification == .liquid }?.id
        let bizChecking = accounts.first { $0.mode == .freelancer && $0.type == .businessBank }?.id ?? homeChecking
        let savingsAcc = accounts.first { $0.type == .savings }?.id
        let retirementAcc = accounts.first { $0.classification == .retirement }?.id
        let brokerageAcc = accounts.first { $0.classification == .investment }?.id
        let taxReserveAcc = accounts.first { $0.type == .taxReserve }?.id

        let existingItems = state.yearlyPlanItems ?? []
        var seeded: [YearlyPlanItem] = []
        for cat in state.categories {
            let existing = existingItems.first { $0.year == year && $0.categoryId == cat.id }
            if let existing, existing.annualAmount > 0 {
                seeded.append(existing)
                continue
            }
            let monthlyVal = mbMap[cat.id] ?? cat.defaultBudget
            let annualVal = recMap[cat.id] ?? (monthlyVal > 0 ? monthlyVal * 12 : 0)
            guard annualVal > 0 else { continue }

            let primary = cat.mode == .freelancer ? bizChecking : homeChecking
            var dest: String?
            if cat.kind == .savings {
                let lower = cat.name.lowercased()
                if lower.contains("retirement") || lower.contains("3a") || lower.contains("pension") {
                    dest = retirementAcc ?? brokerageAcc ?? savingsAcc
                } else if lower.contains("invest") || lower.contains("etf") || lower.contains("portfolio") {
                    dest = brokerageAcc ?? retirementAcc ?? savingsAcc
                } else if lower.contains("tax") || lower.contains("vat") {
                    dest = taxReserveAcc ?? savingsAcc
                } else {
                    dest = savingsAcc ?? brokerageAcc
                }
            }
            seeded.append(YearlyPlanItem(
                id: existing?.id ?? "yp-\(year)-\(cat.id)", year: year, mode: cat.mode,
                categoryId: cat.id, label: cat.name, kind: cat.kind, annualAmount: annualVal,
                schedule: .monthly, accountId: primary, destinationAccountId: dest))
        }
        return seeded
    }

    /// `Number#toString` for display of percentages (7 → "7", 7.5 → "7.5").
    static func jsNumber(_ value: Double) -> String {
        if value.isFinite && value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
        var s = String(format: "%.10f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// `Number#toLocaleString()` (en-US, max 3 fraction digits) used in the add-item toast.
    static func localeString(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        return f.string(from: NSNumber(value: value)) ?? jsNumber(value)
    }

    private static func isEmpty(_ s: String?) -> Bool { s == nil || s == "" }
}

// MARK: - Mutations (App.tsx handlers)

struct YearlyPlanNewItemRequest: Hashable, Sendable {
    var year: Int
    var groupId: String
    var mode: LedgerMode
    var kind: CategoryKind
    var label: String
    var annualAmount: Double
    var schedule: YearlyPlanSchedule
    var accountId: String?
    var destinationAccountId: String?
}

extension LedgerState {
    /// handleUpsertYearlyPlanItem: match by id, or by (year, categoryId); replace or append.
    mutating func upsertYearlyPlanItem(_ item: YearlyPlanItem) {
        var items = yearlyPlanItems ?? []
        if let idx = items.firstIndex(where: {
            $0.id == item.id || (!item.categoryId.isEmpty && $0.year == item.year && $0.categoryId == item.categoryId)
        }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        yearlyPlanItems = items
    }

    /// handleDeleteYearlyPlanItem
    mutating func deleteYearlyPlanItem(id: String) {
        yearlyPlanItems = (yearlyPlanItems ?? []).filter { $0.id != id }
    }

    /// handleBulkSetYearlyPlanForYear: replaces every item of `year`.
    mutating func bulkSetYearlyPlan(year: Int, items: [YearlyPlanItem]) {
        yearlyPlanItems = (yearlyPlanItems ?? []).filter { $0.year != year } + items
    }

    /// handleUpdateAccountReturnRate (Yearly Planner copy).
    mutating func setYearlyPlannerReturnRate(accountId: String, returnPct: Double) {
        for idx in accounts.indices where accounts[idx].id == accountId {
            accounts[idx].expectedAnnualReturnPct = returnPct
        }
    }

    /// handleApplyYearlyPlanToMonthlyBudgets: writes annual/12 (rounded to cents) into all 12 months.
    mutating func applyYearlyPlanToMonthlyBudgets(year: Int, items: [YearlyPlanItem]) {
        var budgets = monthlyBudgets
        for item in items where !item.categoryId.isEmpty && item.annualAmount > 0 {
            let monthly = ((item.annualAmount / 12) * 100).rounded() / 100
            for m in 1...12 {
                let key = MonthKey.format(year: year, month: m)
                if let idx = budgets.firstIndex(where: { $0.monthKey == key && $0.categoryId == item.categoryId }) {
                    budgets[idx].budget = monthly
                } else {
                    budgets.append(MonthlyBudgetEntry(monthKey: key, categoryId: item.categoryId, budget: monthly))
                }
            }
        }
        monthlyBudgets = budgets
    }

    /// handleAddCategoryAndPlanItem: creates a category in the group plus its plan item.
    @discardableResult
    mutating func addCategoryAndPlanItem(_ req: YearlyPlanNewItemRequest, now: Date = Date()) -> String {
        let millis = Int(now.timeIntervalSince1970 * 1000)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<4).map { _ in alphabet.randomElement()! })
        let catId = "cat-\(millis)-\(suffix)"
        let monthlyDefault = ((req.annualAmount / 12) * 100).rounded() / 100
        categories.append(CategoryItem(
            id: catId, groupId: req.groupId, mode: req.mode, name: req.label, kind: req.kind,
            defaultBudget: monthlyDefault, isRecurring: nil, taxRate: nil, deductiblePct: nil,
            order: categories.count + 1))
        yearlyPlanItems = (yearlyPlanItems ?? []) + [YearlyPlanItem(
            id: "yp-\(req.year)-\(catId)", year: req.year, mode: req.mode, categoryId: catId,
            label: req.label, kind: req.kind, annualAmount: req.annualAmount, schedule: req.schedule,
            accountId: req.accountId, destinationAccountId: req.destinationAccountId)]
        return catId
    }
}
