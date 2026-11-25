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
    /// Transfers & worksheet savings dated on or after the account's last manual valuation.
    var pendingTransferIn: Double = 0

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

struct WorksheetSavingsTransfer: Sendable {
    var total: Double
    var count: Int
    var byMonth: [(monthEnd: String, amount: Double)]

    func pendingAfter(_ updatedAt: String) -> Double {
        byMonth.reduce(0) { $1.monthEnd >= updatedAt ? $0 + $1.amount : $0 }
    }
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

    func worksheetSavingsTransfers(upToMonthKey: String? = nil) -> [String: WorksheetSavingsTransfer] {
        let catById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var txStats: [String: (sum: Double, count: Int)] = [:]
        for tx in transactions {
            if let upToMonthKey, tx.monthKey > upToMonthKey { continue }
            let key = "\(tx.monthKey)::\(tx.categoryId)"
            var cur = txStats[key] ?? (0, 0)
            cur.sum += tx.amount
            cur.count += 1
            txStats[key] = cur
        }

        var latestBudgets: [String: MonthlyBudgetEntry] = [:]
        for mb in monthlyBudgets {
            if let upToMonthKey, mb.monthKey > upToMonthKey { continue }
            latestBudgets["\(mb.monthKey)::\(mb.categoryId)"] = mb
        }

        var scheduledCache: [String: [String: Double]] = [:]
        var accEntries: [String: (byMonth: [(monthEnd: String, amount: Double)], count: Int)] = [:]

        for (key, mb) in latestBudgets {
            guard let cat = catById[mb.categoryId], cat.kind == .savings,
                  let targetId = cat.targetAccountId, !targetId.isEmpty else { continue }
            let stats = txStats[key] ?? (0, 0)
            if scheduledCache[mb.monthKey] == nil {
                scheduledCache[mb.monthKey] = scheduledBudgetByCategory(inMonth: mb.monthKey)
            }
            let scheduled = scheduledCache[mb.monthKey]?[cat.id]
            let effectiveBudget = (scheduled != nil && !(mb.budgetManual ?? false)) ? scheduled! : mb.budget

            let worksheetVal: Double
            if let direct = mb.directActual {
                worksheetVal = direct
            } else if stats.count == 0 {
                worksheetVal = effectiveBudget
            } else {
                worksheetVal = stats.sum
            }

            let extra = worksheetVal - stats.sum
            guard abs(extra) > 1e-9 else { continue }
            var bucket = accEntries[targetId] ?? ([], 0)
            bucket.byMonth.append(("\(mb.monthKey)-31", extra))
            bucket.count += 1
            accEntries[targetId] = bucket
        }

        var result: [String: WorksheetSavingsTransfer] = [:]
        for (accId, data) in accEntries {
            let total = data.byMonth.reduce(0) { $0 + $1.amount }
            result[accId] = WorksheetSavingsTransfer(total: total, count: data.count, byMonth: data.byMonth)
        }
        return result
    }
}

extension FinancialAccount {
    func liveBalance(
        transactions: [TransactionItem],
        savingsTargets: [String: String] = [:],
        worksheetSavings: (total: Double, pending: Double, count: Int)? = nil
    ) -> AccountComputedItem {
        var income = 0.0, expense = 0.0, count = worksheetSavings?.count ?? 0
        var transferIn = worksheetSavings?.total ?? 0
        // Manually valued accounts: only transfers & savings dated on or after the last valuation are added
        var pendingTransferIn = worksheetSavings?.pending ?? 0
        for tx in transactions {
            if tx.type == .expense, savingsTargets[tx.categoryId] == id {
                count += 1
                transferIn += tx.amount
                if tx.date >= updatedAt { pendingTransferIn += tx.amount }
            } else if tx.accountId == id {
                count += 1
                if tx.type == .income { income += tx.amount } else { expense += tx.amount }
                // Transfer pairs also move manually valued accounts after their last valuation
                if tx.isAccountTransfer && tx.date >= updatedAt {
                    pendingTransferIn += tx.type == .income ? tx.amount : -tx.amount
                }
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
            txTransferInSum: transferIn,
            pendingTransferIn: pendingTransferIn
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
        let wsTransfers = worksheetSavingsTransfers()
        let items = workspaceAccounts.map { acc in
            let ws = wsTransfers[acc.id].map { ($0.total, $0.pendingAfter(acc.updatedAt), $0.count) }
            return acc.liveBalance(transactions: transactions, savingsTargets: targets, worksheetSavings: ws)
        }
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
                let wsUpTo = worksheetSavingsTransfers(upToMonthKey: key)
                let monthItems = workspaceAccounts.map { acc in
                    let ws = wsUpTo[acc.id].map { ($0.total, $0.pendingAfter(acc.updatedAt), $0.count) }
                    return acc.liveBalance(transactions: upTo, savingsTargets: targets, worksheetSavings: ws)
                }
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
