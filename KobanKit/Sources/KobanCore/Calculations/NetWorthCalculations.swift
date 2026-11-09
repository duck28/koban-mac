import Foundation

// Port of computeAccountLiveBalance / computeNetWorthMetrics from src/utils/calculations.ts.

struct AccountComputedItem: Identifiable, Hashable, Sendable {
    var account: FinancialAccount
    var liveBalance: Double
    var txIncomeSum: Double
    var txExpenseSum: Double
    var txNetDelta: Double
    var txCount: Int

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

extension FinancialAccount {
    func liveBalance(transactions: [TransactionItem]) -> AccountComputedItem {
        var income = 0.0, expense = 0.0, count = 0
        for tx in transactions where tx.accountId == id {
            count += 1
            if tx.type == .income { income += tx.amount } else { expense += tx.amount }
        }
        let delta = classification == .liability ? expense - income : income - expense
        return AccountComputedItem(
            account: self,
            liveBalance: autoTrackTransactions ? startingBalance + delta : currentBalance,
            txIncomeSum: income,
            txExpenseSum: expense,
            txNetDelta: delta,
            txCount: count
        )
    }
}

extension LedgerState {
    func netWorthMetrics(workspace: ActiveWorkspace, monthlyOutflowReference: Double = 0) -> NetWorthSummaryMetrics {
        let items = accounts
            .filter { workspace.includes($0.mode) }
            .map { $0.liveBalance(transactions: transactions) }

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

        // 12-month trajectory for the active year: explicit snapshots win,
        // otherwise liquid assets are projected forward by cumulative net cashflow.
        let snapshots = Dictionary(netWorthSnapshots.map { ($0.monthKey, $0) }, uniquingKeysWith: { _, last in last })
        let cashflow = annualSeries(year: settings.activeYear, workspace: workspace)
        var cumulative = 0.0
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
            cumulative += cashflow[idx].netActual
            let projectedLiquid = max(0, liquid + cumulative)
            let projectedTotal = projectedLiquid + retirement + investment + fixed
            return NetWorthHistoryPoint(
                month: month, monthLabel: label, monthKey: key,
                liquidAssets: projectedLiquid,
                retirementAssets: retirement,
                investmentAssets: investment,
                fixedAssets: fixed,
                totalAssets: projectedTotal,
                totalLiabilities: liabilities,
                netWorth: projectedTotal - liabilities,
                hasExplicitSnapshot: false
            )
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
