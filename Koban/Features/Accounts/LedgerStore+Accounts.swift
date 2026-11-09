import Foundation

// Store-level wrappers around the core mutations (App.tsx account / snapshot / goal handlers),
// including the notifications the Windows build shows.
extension LedgerStore {
    /// computeNetWorthMetrics(state, activeWorkspace, summary.totalOutflowActual) as App.tsx renders it.
    var accountsNetWorthMetrics: NetWorthSummaryMetrics {
        let workspace = state.settings.activeWorkspace
        let outflow = monthSummary(monthKey: state.activeMonthKey, workspace: workspace).totalOutflowActual
        return netWorthMetrics(workspace: workspace, monthlyOutflowReference: outflow)
    }

    // MARK: Accounts

    func addAccount(_ input: NewAccountInput) {
        var created: FinancialAccount?
        update { created = $0.addAccount(input) }
        if let created { notify("Created account \"\(created.name)\".") }
    }

    func updateAccount(_ id: String, _ patch: (inout FinancialAccount) -> Void) {
        update { $0.updateAccount(id, patch) }
    }

    /// Deletes without asking; the view asks first when `confirmBeforeDelete` is on
    /// (see `shouldConfirmAccountDelete`).
    func deleteAccount(_ id: String) {
        update { $0.deleteAccount(id) }
        notify("Removed account.")
    }

    var shouldConfirmAccountDelete: Bool { state.settings.confirmBeforeDelete != false }

    func transferBetweenAccounts(from fromId: String, to toId: String, amount: Double, note: String) {
        let fromName = state.accounts.first(where: { $0.id == fromId })?.name ?? "Source"
        let toName = state.accounts.first(where: { $0.id == toId })?.name ?? "Destination"
        update { $0.transferBetweenAccounts(from: fromId, to: toId, amount: amount) }
        notify("Transferred \(state.settings.currency) \(AccountsJS.fixed(amount, 2)) from \(fromName) → \(toName) (\(note)).")
    }

    func reconcileAccountBalance(_ item: AccountComputedItem, to newBalance: Double) {
        update { $0.reconcileAccountBalance(item, to: newBalance) }
    }

    /// handleUpdateAccountReturnRate (used by the Yearly Planner's growth forecast).
    func updateAccountReturnRate(_ id: String, returnPct: Double) {
        update { $0.setAccountReturnRate(id, returnPct: returnPct) }
    }

    // MARK: Net worth snapshots

    func saveNetWorthSnapshot(note: String? = nil) {
        let key = state.activeMonthKey
        let metrics = accountsNetWorthMetrics
        update { $0.saveNetWorthSnapshot(monthKey: key, metrics: metrics, note: note) }
        notify("Recorded Net Worth snapshot for \(key).")
    }

    func deleteNetWorthSnapshot(_ id: String) {
        update { $0.deleteNetWorthSnapshot(id) }
    }

    // MARK: Savings goals

    func addGoal(_ input: NewGoalInput) {
        update { $0.addGoal(input) }
    }

    func updateGoalAmount(_ id: String, currentAmount: Double) {
        update { $0.updateGoalAmount(id, currentAmount: currentAmount) }
    }

    func deleteGoal(_ id: String) {
        update { $0.deleteGoal(id) }
    }
}
