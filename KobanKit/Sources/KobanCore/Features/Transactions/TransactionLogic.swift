import Foundation

// Transactions & Recurring logic, ported from src/components/TransactionsView.tsx,
// src/components/RecurringView.tsx and the handlers in src/App.tsx
// (handleDeleteTransaction, handleAddRecurringRule, handleUpdateRecurringRule,
// handleToggleRecurringRule, handleDeleteRecurringRule, handleApplyRecurringToMonth).
// `LedgerState.addTransaction` (handleAddTransaction) lives in Models/LedgerMutations.swift.

/// `String(n)` in JavaScript: "100" for whole numbers, "8.1" otherwise.
enum JSNumber {
    static func string(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    /// `parseFloat(text)`: leading numeric prefix ("12abc" → 12), nil when none.
    /// Also accepts a decimal comma / apostrophe grouping, which macOS users type.
    static func parseFloat(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: ",", with: ".")
        var prefix = ""
        var seenDot = false, seenDigit = false
        for (i, ch) in cleaned.enumerated() {
            if ch.isASCII, ch.isNumber { prefix.append(ch); seenDigit = true }
            else if ch == "." && !seenDot { prefix.append(ch); seenDot = true }
            else if (ch == "-" || ch == "+") && i == 0 { prefix.append(ch) }
            else { break }
        }
        guard seenDigit else { return nil }
        return Double(prefix)
    }

    /// `parseInt(text, 10)`.
    static func parseInt(_ text: String) -> Int? {
        guard let v = parseFloat(text) else { return nil }
        return Int(v.rounded(.towardZero))
    }
}

// MARK: - Transactions

enum TransactionTypeFilter: String, CaseIterable, Sendable {
    case all, income, expense
}

enum TransactionScopeFilter: String, Sendable {
    case month, year
}

/// Values of the "Log New Transaction" form (all inputs are strings, like the React state).
struct TransactionFormInput: Sendable {
    var date: String
    var categoryId: String
    var accountId: String
    var description: String
    var amount: String
    var client: String
    var invoiceRef: String
    var taxRate: String
    var deductiblePct: String
}

extension LedgerState {
    /// handleSubmit in TransactionsView.tsx: validates the form and builds the new entry.
    /// Returns nil when the category is missing or the amount is not a positive number.
    func buildTransaction(from form: TransactionFormInput, fallbackMonthKey: String,
                          id: String = KobanID.make("tx")) -> TransactionItem? {
        guard !form.categoryId.isEmpty,
              let amount = JSNumber.parseFloat(form.amount), amount > 0,
              let cat = categories.first(where: { $0.id == form.categoryId }) else { return nil }
        let prefix = String(form.date.prefix(7))
        let txMonthKey = prefix.isEmpty ? fallbackMonthKey : prefix
        let linkedAcc = form.accountId.isEmpty ? nil : accounts.first(where: { $0.id == form.accountId })
        let desc = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = form.client.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoice = form.invoiceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        return TransactionItem(
            id: id,
            date: form.date,
            monthKey: txMonthKey,
            mode: cat.mode,
            type: cat.kind == .income ? .income : .expense,
            categoryId: cat.id,
            accountId: form.accountId.isEmpty ? nil : form.accountId,
            description: desc.isEmpty ? cat.name : desc,
            amount: amount,
            client: client.isEmpty ? nil : client,
            invoiceRef: invoice.isEmpty ? nil : invoice,
            taxRate: JSNumber.parseFloat(form.taxRate) ?? 0,
            deductiblePct: JSNumber.parseFloat(form.deductiblePct) ?? 0,
            paymentMethod: linkedAcc?.name ?? "Main Account",
            status: .cleared
        )
    }

    /// handleDeleteTransaction.
    mutating func deleteTransaction(_ id: String) {
        transactions.removeAll { $0.id == id }
    }

    /// The filtered, date-descending list shown in the Transactions table.
    func filteredTransactions(workspace: ActiveWorkspace, monthKey: String, scope: TransactionScopeFilter,
                              type: TransactionTypeFilter, accountId: String?, query: String) -> [TransactionItem] {
        let catMap = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grpMap = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accMap = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.lowercased()

        let filtered = transactions.filter { t in
            if !workspace.includes(t.mode) { return false }
            if scope == .month && t.monthKey != monthKey { return false }
            switch type {
            case .all: break
            case .income: if t.type != .income { return false }
            case .expense: if t.type != .expense { return false }
            }
            if let accountId, t.accountId != accountId { return false }
            if !trimmed.isEmpty {
                let cat = catMap[t.categoryId]
                let catName = cat?.name.lowercased() ?? ""
                let catLoc = cat.map { L10n.categoryName($0).lowercased() } ?? ""
                let grp = grpMap[cat?.groupId ?? ""]
                let grpName = grp?.name.lowercased() ?? ""
                let grpLoc = grp.map { L10n.groupName($0).lowercased() } ?? ""
                let acc = t.accountId.flatMap { accMap[$0] }
                let accName = acc?.name.lowercased() ?? ""
                let accLoc = acc.map { L10n.accountName($0).lowercased() } ?? ""
                return t.description.lowercased().contains(q)
                    || catName.contains(q) || catLoc.contains(q)
                    || grpName.contains(q) || grpLoc.contains(q)
                    || accName.contains(q) || accLoc.contains(q)
                    || (t.client?.lowercased().contains(q) ?? false)
                    || (t.invoiceRef?.lowercased().contains(q) ?? false)
            }
            return true
        }
        // Array.sort is stable in JS; keep it stable here too.
        return filtered.enumerated()
            .sorted { a, b in a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset }
            .map(\.element)
    }
}

// MARK: - Recurring rules

extension RecurringRule {
    /// Monthly equivalent used by the summary banner (biweekly * 26 / 12, bimonthly / 2, quarterly / 3, yearly / 12).
    var monthlyEquivalent: Double {
        switch frequency {
        case .biweekly: return (amount * 26) / 12
        case .monthly: return amount
        case .bimonthly: return amount / 2
        case .quarterly: return amount / 3
        case .yearly: return amount / 12
        }
    }

    /// Annual equivalent used by Yearly Planner seeding.
    var annualEquivalent: Double {
        switch frequency {
        case .biweekly: return amount * 26
        case .monthly: return amount * 12
        case .bimonthly: return amount * 6
        case .quarterly: return amount * 4
        case .yearly: return amount
        }
    }

    /// Month spacing between postings (>1 for bimonthly, quarterly, yearly).
    var monthInterval: Int {
        switch frequency {
        case .biweekly, .monthly: return 1
        case .bimonthly: return 2
        case .quarterly: return 3
        case .yearly: return 12
        }
    }

    /// Days in the month this rule posts on (biweekly yields two dates 14 days apart within 1...28).
    var postingDaysInMonth: [Int] {
        let d = min(28, max(1, dayOfMonth))
        if frequency == .biweekly {
            return d <= 14 ? [d, d + 14] : [d - 14, d]
        }
        return [d]
    }

    /// Day input clamp: Math.min(28, Math.max(1, parseInt(v, 10) || 1)).
    static func clampDay(_ text: String) -> Int {
        let parsed = JSNumber.parseInt(text) ?? 0
        return min(28, max(1, parsed == 0 ? 1 : parsed))
    }
}

private func parseMonthIndex(_ monthKey: String) -> Int? {
    let parts = monthKey.split(separator: "-")
    guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
          (1...12).contains(month) else { return nil }
    return year * 12 + (month - 1)
}

/// Partial<RecurringRule> as used by RecurringView's inline editors.
struct RecurringRulePatch: Sendable {
    var frequency: RecurrenceFrequency?
    var dayOfMonth: Int?
    var amount: Double?
}

enum RecurringPostResult: Equatable, Sendable {
    /// No active rule with a non-zero amount in this workspace.
    case nothingToPost
    case posted(Int)
    case alreadyPosted
}

extension LedgerState {
    /// The add-rule form's handleSubmit: nil when the category is missing or the amount is invalid.
    func buildRecurringRule(categoryId: String, description: String, amount: String,
                            frequency: RecurrenceFrequency, dayOfMonth: String) -> RecurringRule? {
        guard !categoryId.isEmpty, let amt = JSNumber.parseFloat(amount), amt >= 0,
              let cat = categories.first(where: { $0.id == categoryId }) else { return nil }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecurringRule(
            id: "",
            mode: cat.mode,
            type: cat.kind == .income ? .income : .expense,
            categoryId: cat.id,
            description: desc.isEmpty ? cat.name : desc,
            amount: amt,
            frequency: frequency,
            dayOfMonth: RecurringRule.clampDay(dayOfMonth),
            taxRate: cat.taxRate ?? 0,
            deductiblePct: cat.deductiblePct ?? 100,
            active: true
        )
    }

    /// handleAddRecurringRule: marks the category recurring and appends the rule as `rec-<ms>`.
    mutating func addRecurringRule(_ rule: RecurringRule) {
        var rule = rule
        rule.id = KobanID.make("rec", suffix: false)
        for i in categories.indices where categories[i].id == rule.categoryId {
            categories[i].isRecurring = true
        }
        recurringRules.append(rule)
    }

    /// handleUpdateRecurringRule: applies the patch; a positive amount also seeds the category's
    /// default budget and this month's planned budget (in monthly equivalent) when those are still 0.
    mutating func updateRecurringRule(_ id: String, patch: RecurringRulePatch, monthKey: String) {
        guard let rIdx = recurringRules.firstIndex(where: { $0.id == id }) else { return }
        let target = recurringRules[rIdx]
        if let f = patch.frequency { recurringRules[rIdx].frequency = f }
        if let d = patch.dayOfMonth { recurringRules[rIdx].dayOfMonth = d }
        if let a = patch.amount { recurringRules[rIdx].amount = a }

        if let amount = patch.amount, amount > 0 {
            let eq = (recurringRules[rIdx].monthlyEquivalent * 100).rounded() / 100
            if let cIdx = categories.firstIndex(where: { $0.id == target.categoryId }),
               categories[cIdx].defaultBudget == 0 {
                categories[cIdx].defaultBudget = eq
            }
            if let mIdx = monthlyBudgets.firstIndex(where: { $0.monthKey == monthKey && $0.categoryId == target.categoryId }),
               monthlyBudgets[mIdx].budget == 0 {
                monthlyBudgets[mIdx].budget = eq
            }
        }
    }

    /// handleToggleRecurringRule (active ⇄ paused).
    mutating func toggleRecurringRule(_ id: String) {
        for i in recurringRules.indices where recurringRules[i].id == id {
            recurringRules[i].active.toggle()
        }
    }

    /// handleDeleteRecurringRule: clears the category's recurring flag when no other rule uses it.
    mutating func deleteRecurringRule(_ id: String) {
        let removed = recurringRules.first(where: { $0.id == id })
        recurringRules.removeAll { $0.id == id }
        if let removed, !recurringRules.contains(where: { $0.categoryId == removed.categoryId }) {
            for i in categories.indices where categories[i].id == removed.categoryId {
                categories[i].isRecurring = false
            }
        }
    }

    /// handleApplyRecurringToMonth: posts every active, non-zero rule of the workspace,
    /// respecting bimonthly/quarterly/yearly month intervals and posting twice for biweekly.
    mutating func applyRecurring(toMonth monthKey: String, workspace: ActiveWorkspace) -> RecurringPostResult {
        let activeRules = recurringRules.filter { $0.active && $0.amount > 0 && workspace.includes($0.mode) }
        guard !activeRules.isEmpty else { return .nothingToPost }

        let targetIdx = parseMonthIndex(monthKey)
        var newTxs: [TransactionItem] = []

        for r in activeRules {
            let interval = r.monthInterval
            if interval > 1 {
                let blockedByIntervalOrSameMonth = transactions.contains { tx in
                    if tx.recurringId == r.id, let targetIdx, let txIdx = parseMonthIndex(tx.monthKey),
                       abs(targetIdx - txIdx) < interval {
                        return true
                    }
                    return tx.monthKey == monthKey && (tx.recurringId == r.id
                        || (tx.categoryId == r.categoryId && tx.description == r.description
                            && abs(tx.amount - r.amount) < 0.01))
                }
                if blockedByIntervalOrSameMonth { continue }
            }

            for day in r.postingDaysInMonth {
                let dayStr = String(format: "%02d", day)
                let dateStr = "\(monthKey)-\(dayStr)"
                let alreadyExists: Bool
                if r.frequency == .biweekly {
                    alreadyExists = transactions.contains { tx in
                        tx.monthKey == monthKey && tx.date == dateStr && (tx.recurringId == r.id
                            || (tx.categoryId == r.categoryId && tx.description == r.description
                                && abs(tx.amount - r.amount) < 0.01))
                    }
                } else {
                    alreadyExists = transactions.contains { tx in
                        tx.monthKey == monthKey && (tx.recurringId == r.id
                            || (tx.categoryId == r.categoryId && tx.description == r.description
                                && abs(tx.amount - r.amount) < 0.01))
                    }
                }
                guard !alreadyExists else { continue }
                let txId = r.frequency == .biweekly ? "tx-rec-\(r.id)-\(monthKey)-\(dayStr)" : "tx-rec-\(r.id)-\(monthKey)"
                newTxs.append(TransactionItem(
                    id: txId,
                    date: dateStr,
                    monthKey: monthKey,
                    mode: r.mode,
                    type: r.type,
                    categoryId: r.categoryId,
                    description: r.description,
                    amount: r.amount,
                    client: r.client,
                    taxRate: r.taxRate,
                    deductiblePct: r.deductiblePct,
                    paymentMethod: "Recurring Auto",
                    status: .cleared,
                    recurringId: r.id
                ))
            }
        }
        guard !newTxs.isEmpty else { return .alreadyPosted }
        transactions.insert(contentsOf: newTxs, at: 0)
        return .posted(newTxs.count)
    }
}
