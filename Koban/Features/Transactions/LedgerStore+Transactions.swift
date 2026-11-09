import SwiftUI
import Observation

/// Feature state that outlives the Transactions view (LedgerStore can't get stored properties
/// from an extension). Mirrors `preselectedAccountId` in App.tsx.
@MainActor
@Observable
final class TransactionsNavigation {
    static let shared = TransactionsNavigation()
    /// Account to filter by when the Transactions view opens ("View transactions" on an account).
    var preselectedAccountId: String?
}

// Transactions & Recurring handlers from src/App.tsx.
extension LedgerStore {
    /// onInspectAccountTransactions in App.tsx: opens Transactions filtered to one account
    /// (all months). Called by the Accounts view.
    func inspectAccountTransactions(_ accountId: String) {
        TransactionsNavigation.shared.preselectedAccountId = accountId
        selectedTab = .transactions
    }

    /// handleAddTransaction.
    func logTransaction(_ tx: TransactionItem) {
        update { $0.addTransaction(tx) }
        notify("Logged \(tx.description) (\(state.settings.currency) \(String(format: "%.2f", tx.amount))).")
    }

    /// handleDeleteTransaction.
    func deleteTransaction(_ id: String) {
        update { $0.deleteTransaction(id) }
    }

    /// handleAddRecurringRule.
    func addRecurringRule(_ rule: RecurringRule) {
        update { $0.addRecurringRule(rule) }
        notify("Added recurring rule \"\(rule.description)\".")
    }

    /// handleUpdateRecurringRule.
    func updateRecurringRule(_ id: String, patch: RecurringRulePatch) {
        let key = state.activeMonthKey
        update { $0.updateRecurringRule(id, patch: patch, monthKey: key) }
    }

    /// handleToggleRecurringRule.
    func toggleRecurringRule(_ id: String) {
        update { $0.toggleRecurringRule(id) }
    }

    /// handleDeleteRecurringRule.
    func deleteRecurringRule(_ id: String) {
        update { $0.deleteRecurringRule(id) }
    }

    /// handleApplyRecurringToMonth.
    func applyRecurringToMonth() {
        let key = state.activeMonthKey
        let workspace = state.settings.activeWorkspace
        var probe = state
        switch probe.applyRecurring(toMonth: key, workspace: workspace) {
        case .nothingToPost:
            notify("Set a non-zero amount on your active recurring rules (or Monthly Budget) before posting.")
        case .alreadyPosted:
            notify("All active recurring items are already posted for \(key).")
        case .posted(let count):
            update { $0 = probe }
            notify("Posted \(count) recurring item(s) to \(key).")
        }
    }
}
