import Foundation

// Port of computeAccountLiveBalance / computeNetWorthMetrics from src/utils/calculations.ts.

struct AccountComputedItem: Identifiable, Hashable, Sendable {
    var account: FinancialAccount
    var liveBalance: Double
    var txIncomeSum: Double
    var txExpenseSum: Double
    var txNetDelta: Double
    var txCount: Int
    /// Savings moved in from other accounts (savings categories whose target is this account).
    var txTransferInSum: Double = 0

    var id: String { account.id }
}

struct NetWorthHistoryPoint: Identifiable, Hashable, Sendable {
    var month: Int
    var monthLabel: String
    var monthKey: String
    var liquidAssets: Double
    var retirementAssets: Double
    var investmentAssets: Double
    var fixedAssets: Double
    var totalAssets: Double
    var totalLiabilities: Double
    var netWorth: Double
    var hasExplicitSnapshot: Bool

    var id: String { monthKey }
}

struct NetWorthSummaryMetrics: Hashable, Sendable {
    var accounts: [AccountComputedItem]
    var liquidAssets: Double
    var retirementAssets: Double
    var investmentAssets: Double
    var fixedAssets: Double
    var totalAssets: Double
    var totalLiabilities: Double
    var netWorth: Double
    var liquidSharePct: Double
    var retirementSharePct: Double
    var investmentSharePct: Double
    var fixedAssetSharePct: Double
    var debtToAssetRatioPct: Double
    var liquidRunwayMonths: Double
    var historySeries: [NetWorthHistoryPoint]
}

extension LedgerState {
    /// categoryId → target account id, for savings categories that have one (savingsTargetMap).
    var savingsTargets: [String: String] {
        var map: [String: String] = [:]
        for c in categories where c.kind == .savings {
            if let t = c.targetAccountId, !t.isEmpty { map[c.id] = t }
        }
        return map
    }
}

extension FinancialAccount {
    func liveBalance(transactions: [TransactionItem], savingsTargets: [String: String] = [:]) -> AccountComputedItem {
        var income = 0.0, expense = 0.0, count = 0
        var transferIn = 0.0
        // Manually valued accounts: only savings moved in after the last valuation are added
        var pendingTransferIn = 0.0
        for tx in transactions {
            if tx.accountId == id {
                count += 1
                if tx.type == .income { income += tx.amount } else { expense += tx.amount }
                // Transfer pairs also move manually valued accounts after their last valuation
                if tx.isAccountTransfer && tx.date > updatedAt {
                    pendingTransferIn += tx.type == .income ? tx.amount : -tx.amount
                }
            } else if tx.type == .expense, savingsTargets[tx.categoryId] == id {
                count += 1
                transferIn += tx.amount
                if tx.date > updatedAt { pendingTransferIn += tx.amount }
            }
        }
        // A transfer in raises an asset and pays down a liability
        let inflow = income + transferIn
        let delta = classification == .liability ? expense - inflow : inflow - expense
        let manual = currentBalance + (classification == .liability ? -pendingTransferIn : pendingTransferIn)
        return AccountComputedItem(
            account: self,
            liveBalance: autoTrackTransactions ? startingBalance + delta : manual,
            txIncomeSum: income,
            txExpenseSum: expense,
            txNetDelta: delta,
            txCount: count,
            txTransferInSum: transferIn
        )
    }
}

/// Net-worth buckets of a set of account balances (assets floored at 0, like the KPI cards).
private struct ClassTotals {
    var liquid = 0.0, retirement = 0.0, investment = 0.0, fixed = 0.0, liabilities = 0.0

    init() {}

    init(_ items: [AccountComputedItem]) {
        for item in items where item.account.includeInNetWorth {
            let val = max(0, item.liveBalance)
            switch item.account.classification {
            case .liquid: liquid += val
            case .retirement: retirement += val
            case .investment: investment += val
            case .fixedAsset: fixed += val
            case .liability: liabilities += abs(item.liveBalance)
            }
        }
    }

    func point(month: Int, label: String, key: String) -> NetWorthHistoryPoint {
        let assets = liquid + retirement + investment + fixed
        return NetWorthHistoryPoint(
            month: month, monthLabel: label, monthKey: key,
            liquidAssets: liquid, retirementAssets: retirement, investmentAssets: investment,
            fixedAssets: fixed, totalAssets: assets, totalLiabilities: liabilities,
            netWorth: assets - liabilities, hasExplicitSnapshot: false)
    }
}

extension LedgerState {
    /// `now` decides which months are history and which are forecast (tests pass a fixed date).
    func netWorthMetrics(workspace: ActiveWorkspace, monthlyOutflowReference: Double = 0,
                         now: Date = Date()) -> NetWorthSummaryMetrics {
        let targets = savingsTargets
        let workspaceAccounts = accounts.filter { workspace.includes($0.mode) }
        let items = workspaceAccounts.map { $0.liveBalance(transactions: transactions, savingsTargets: targets) }
        let accountById = Dictionary(workspaceAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var liquid = 0.0, retirement = 0.0, investment = 0.0, fixed = 0.0, liabilities = 0.0
        for item in items where item.account.includeInNetWorth {
            let val = max(0, item.liveBalance)
            switch item.account.classification {
            case .liquid: liquid += val
            case .retirement: retirement += val
            case .investment: investment += val
            case .fixedAsset: fixed += val
            case .liability: liabilities += abs(item.liveBalance)
            }
        }

        let totalAssets = liquid + retirement + investment + fixed
        func share(_ v: Double) -> Double { totalAssets > 0 ? v / totalAssets * 100 : 0 }

        // 12-month trajectory for the active year (computeNetWorthMetrics on Windows):
        // - an explicit snapshot wins;
        // - past & current months are rebuilt from the transactions dated up to that month's end;
        // - future months start from today's balances and add each month's planned (budget) net,
        //   with savings that have a target account moved into that account's class.
        let snapshots = Dictionary(netWorthSnapshots.map { ($0.monthKey, $0) }, uniquingKeysWith: { _, last in last })
        let todayMonth = MonthKey.current(now)
        var forecast = ClassTotals(items)
        let history: [NetWorthHistoryPoint] = MonthKey.shortMonthLabels.enumerated().map { idx, label in
            let month = idx + 1
            let key = MonthKey.format(year: settings.activeYear, month: month)
            if let snap = snapshots[key] {
                return NetWorthHistoryPoint(
                    month: month, monthLabel: label, monthKey: key,
                    liquidAssets: snap.liquidAssets,
                    retirementAssets: snap.retirementAssets,
                    investmentAssets: snap.investmentAssets,
                    fixedAssets: snap.fixedAssets,
                    totalAssets: snap.totalAssets,
                    totalLiabilities: snap.totalLiabilities,
                    netWorth: snap.netWorth,
                    hasExplicitSnapshot: true
                )
            }
            if key <= todayMonth {
                let monthEnd = "\(key)-31"
                let upTo = transactions.filter { $0.date <= monthEnd }
                let monthItems = workspaceAccounts.map { $0.liveBalance(transactions: upTo, savingsTargets: targets) }
                return ClassTotals(monthItems).point(month: month, label: label, key: key)
            }
            // Forecast: planned net of this month on top of the running forecast
            let summary = monthSummary(monthKey: key, workspace: workspace)
            for gs in summary.groups where gs.group.kind == .savings {
                for row in gs.rows where row.budget != 0 {
                    guard let tid = targets[row.category.id], let target = accountById[tid],
                          target.includeInNetWorth else { continue }
                    switch target.classification {
                    case .liquid: forecast.liquid += row.budget
                    case .retirement: forecast.retirement += row.budget
                    case .investment: forecast.investment += row.budget
                    case .fixedAsset: forecast.fixed += row.budget
                    case .liability: forecast.liabilities -= row.budget
                    }
                }
            }
            // netBudget already subtracts the savings; the part moved into tracked accounts is not lost
            forecast.liquid += summary.netBudget
            var clamped = forecast
            clamped.liquid = max(0, clamped.liquid)
            clamped.liabilities = max(0, clamped.liabilities)
            return clamped.point(month: month, label: label, key: key)
        }

        return NetWorthSummaryMetrics(
            accounts: items,
            liquidAssets: liquid,
            retirementAssets: retirement,
            investmentAssets: investment,
            fixedAssets: fixed,
            totalAssets: totalAssets,
            totalLiabilities: liabilities,
            netWorth: totalAssets - liabilities,
            liquidSharePct: share(liquid),
            retirementSharePct: share(retirement),
            investmentSharePct: share(investment),
            fixedAssetSharePct: share(fixed),
            debtToAssetRatioPct: share(liabilities),
            liquidRunwayMonths: monthlyOutflowReference > 0 ? liquid / monthlyOutflowReference : 0,
            historySeries: history
        )
    }
}
