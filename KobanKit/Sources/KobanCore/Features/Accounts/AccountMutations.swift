import Foundation

// Accounts, net-worth snapshots and savings goals: ports of the App.tsx handlers
// handleAddAccount / handleUpdateAccount / handleDeleteAccount / handleTransferBetweenAccounts /
// handleSaveNetWorthSnapshot / handleDeleteNetWorthSnapshot / handleUpdateAccountReturnRate and
// handleAddGoal / handleUpdateGoalAmount / handleDeleteGoal, plus the small calculations the
// AccountsNetWorthView / SavingsGoalsView components do inline.

/// Fields of a new account (Omit<FinancialAccount, 'id' | 'updatedAt'> in App.tsx).
struct NewAccountInput: Hashable, Sendable {
    var name: String
    var institution: String?
    var accountNumberMasked: String?
    var mode: LedgerMode
    var type: AccountType
    var customTypeLabel: String?
    var classification: AccountLiquidityClass
    var startingBalance: Double
    var currentBalance: Double
    var autoTrackTransactions: Bool
    var includeInNetWorth: Bool
    var expectedAnnualReturnPct: Double?
    var color: String
    var notes: String?
}

/// Fields of a new savings goal (Omit<SavingsGoal, 'id'>).
struct NewGoalInput: Hashable, Sendable {
    var mode: LedgerMode
    var name: String
    var targetAmount: Double
    var currentAmount: Double
    var monthlyContribution: Double
    var targetDate: String?
    var color: String
    var linkedCategoryId: String?
    var linkedAccountId: String?
}

extension LedgerState {
    // MARK: Accounts

    /// handleAddAccount: appends the account with a fresh `acc-<ms>-<rand4>` id and today's date.
    @discardableResult
    mutating func addAccount(_ input: NewAccountInput, today: String = KobanTemplates.today()) -> FinancialAccount {
        let account = FinancialAccount(
            id: KobanID.make("acc"),
            name: input.name,
            institution: input.institution,
            accountNumberMasked: input.accountNumberMasked,
            mode: input.mode,
            type: input.type,
            customTypeLabel: input.customTypeLabel,
            classification: input.classification,
            startingBalance: input.startingBalance,
            currentBalance: input.currentBalance,
            autoTrackTransactions: input.autoTrackTransactions,
            includeInNetWorth: input.includeInNetWorth,
            expectedAnnualReturnPct: input.expectedAnnualReturnPct,
            color: input.color,
            notes: input.notes,
            updatedAt: today
        )
        accounts.append(account)
        return account
    }

    /// handleUpdateAccount: `{ ...a, ...patch }` expressed as an in-place edit.
    mutating func updateAccount(_ id: String, _ patch: (inout FinancialAccount) -> Void) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        patch(&accounts[idx])
    }

    /// handleDeleteAccount (after confirmation): removes the account; linked transactions are kept
    /// but unassigned.
    mutating func deleteAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        for i in transactions.indices where transactions[i].accountId == id {
            transactions[i].accountId = nil
        }
    }

    /// handleTransferBetweenAccounts: moves `amount` between the two accounts' starting and current
    /// balances (a payment *into* a liability reduces its debt).
    mutating func transferBetweenAccounts(from fromId: String, to toId: String, amount: Double,
                                          today: String = KobanTemplates.today()) {
        for i in accounts.indices {
            let isLiability = accounts[i].classification == .liability
            let delta: Double
            if accounts[i].id == fromId {
                delta = isLiability ? amount : -amount
            } else if accounts[i].id == toId {
                delta = isLiability ? -amount : amount
            } else {
                continue
            }
            accounts[i].startingBalance += delta
            accounts[i].currentBalance += delta
            accounts[i].updatedAt = today
        }
    }

    /// commitBalanceEdit in AccountsNetWorthView: reconciles an account to `newBalance`.
    /// Auto-tracked accounts shift their starting balance so start + tx delta = new balance.
    mutating func reconcileAccountBalance(_ item: AccountComputedItem, to newBalance: Double,
                                          today: String = KobanTemplates.today()) {
        updateAccount(item.account.id) { acc in
            if acc.autoTrackTransactions {
                acc.startingBalance = newBalance - item.txNetDelta
            } else {
                acc.startingBalance = newBalance
            }
            acc.currentBalance = newBalance
            acc.updatedAt = today
        }
    }

    /// handleUpdateAccountReturnRate.
    mutating func setAccountReturnRate(_ id: String, returnPct: Double) {
        updateAccount(id) { $0.expectedAnnualReturnPct = returnPct }
    }

    // MARK: Net worth snapshots

    /// handleSaveNetWorthSnapshot: records (or replaces) the snapshot for `monthKey`, newest first.
    @discardableResult
    mutating func saveNetWorthSnapshot(monthKey: String, metrics: NetWorthSummaryMetrics, note: String? = nil,
                                       today: String = KobanTemplates.today()) -> NetWorthSnapshot {
        let snap = NetWorthSnapshot(
            id: "nw-snap-\(monthKey)",
            monthKey: monthKey,
            recordedAt: today,
            liquidAssets: metrics.liquidAssets,
            retirementAssets: metrics.retirementAssets,
            investmentAssets: metrics.investmentAssets,
            fixedAssets: metrics.fixedAssets,
            totalAssets: metrics.totalAssets,
            totalLiabilities: metrics.totalLiabilities,
            netWorth: metrics.netWorth,
            note: note
        )
        netWorthSnapshots = [snap] + netWorthSnapshots.filter { $0.monthKey != monthKey }
        return snap
    }

    /// handleDeleteNetWorthSnapshot.
    mutating func deleteNetWorthSnapshot(_ id: String) {
        netWorthSnapshots.removeAll { $0.id == id }
    }

    // MARK: Savings goals

    /// handleAddGoal: appends the goal with a `goal-<ms>` id.
    @discardableResult
    mutating func addGoal(_ input: NewGoalInput) -> SavingsGoal {
        let goal = SavingsGoal(
            id: KobanID.make("goal", suffix: false),
            mode: input.mode,
            name: input.name,
            targetAmount: input.targetAmount,
            currentAmount: input.currentAmount,
            monthlyContribution: input.monthlyContribution,
            targetDate: input.targetDate,
            color: input.color,
            linkedCategoryId: input.linkedCategoryId,
            linkedAccountId: input.linkedAccountId
        )
        savingsGoals.append(goal)
        return goal
    }

    /// handleUpdateGoalAmount.
    mutating func updateGoalAmount(_ id: String, currentAmount: Double) {
        guard let idx = savingsGoals.firstIndex(where: { $0.id == id }) else { return }
        savingsGoals[idx].currentAmount = currentAmount
    }

    /// handleDeleteGoal.
    mutating func deleteGoal(_ id: String) {
        savingsGoals.removeAll { $0.id == id }
    }
}

// MARK: - Inline view calculations

/// Progress figures shown on a savings goal card (SavingsGoalsView).
struct GoalProgress: Hashable, Sendable {
    /// 0...100
    var pct: Double
    var remaining: Double
    /// ceil(remaining / monthlyContribution); nil without a monthly plan.
    var monthsToGoal: Int?

    init(_ goal: SavingsGoal) {
        pct = goal.targetAmount > 0 ? min(100, goal.currentAmount / goal.targetAmount * 100) : 0
        remaining = max(0, goal.targetAmount - goal.currentAmount)
        monthsToGoal = goal.monthlyContribution > 0 ? Int((remaining / goal.monthlyContribution).rounded(.up)) : nil
    }
}

extension SavingsGoal {
    var progress: GoalProgress { GoalProgress(self) }
}

extension FinancialAccount {
    /// getTypeBadgeLabel: the custom label for custom accounts, else the type's short label.
    var typeBadgeLabel: String {
        if type == .custom, let label = customTypeLabel, !label.isEmpty { return label }
        return KobanTemplates.accountType(type).shortLabel
    }
}

extension NetWorthSummaryMetrics {
    /// maxHistoryAbs: scale of the 12-month trajectory bars.
    var maxHistoryAbs: Double {
        max(1, historySeries.map { max(abs($0.netWorth), $0.totalAssets) }.max() ?? 1)
    }

    func accountCount(_ cls: AccountLiquidityClass) -> Int {
        accounts.filter { $0.account.classification == cls }.count
    }
}

extension NetWorthHistoryPoint {
    /// Bar height in percent of the chart (min 4 %, rounded like Math.round).
    func barHeightPct(maxAbs: Double) -> Double {
        max(4, (abs(netWorth) / maxAbs * 100).rounded(.toNearestOrAwayFromZero))
    }
}

/// JavaScript number parsing / printing helpers, so inputs behave like the Windows build.
enum AccountsJS {
    /// parseFloat: parses the longest numeric prefix (after leading whitespace); nil = NaN.
    static func parseFloat(_ text: String) -> Double? {
        let s = text.drop(while: { $0.isWhitespace })
        var best: Double?
        var idx = s.startIndex
        var buffer = ""
        while idx < s.endIndex {
            buffer.append(s[idx])
            idx = s.index(after: idx)
            if let v = Double(buffer), !buffer.lowercased().contains("n"), !buffer.lowercased().contains("x") {
                best = v
            }
            if buffer.count > 64 { break }
        }
        return best
    }

    /// `parseFloat(value.replace(/[^0-9.-]/g, ''))` (the balance reconcile input).
    static func parseLooseAmount(_ text: String) -> Double? {
        parseFloat(String(text.filter { $0.isNumber || $0 == "." || $0 == "-" }))
    }

    /// String(n) for a JS number: integers without decimals, others in shortest form.
    static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == value.rounded(), abs(value) < 1e21 { return String(Int64(value)) }
        return String(value)
    }

    /// Number.prototype.toFixed.
    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
