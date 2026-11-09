import SwiftUI

/// Port of src/components/TransactionsView.tsx — quick-add form, filters and the ledger table.
struct TransactionsView: View {
    @Environment(LedgerStore.self) private var store
    private var nav: TransactionsNavigation { TransactionsNavigation.shared }

    // Form (useState in the React view)
    @State private var date = ""
    @State private var categoryId = ""
    @State private var accountId = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var client = ""
    @State private var invoiceRef = ""
    @State private var taxRate = ""
    @State private var deductiblePct = "100"
    @State private var amountInvalid = false
    @FocusState private var amountFocused: Bool

    // Filters
    @State private var searchQuery = ""
    @State private var typeFilter: TransactionTypeFilter = .all
    @State private var accountFilter = "all"
    @State private var scopeFilter: TransactionScopeFilter = .month

    @State private var didInit = false
    @State private var contentWidth: CGFloat = 1000

    var body: some View {
        let state = store.state
        let workspace = state.settings.activeWorkspace
        let monthKey = state.activeMonthKey
        let currency = state.settings.currency
        let availableAccounts = state.accounts.filter { workspace.includes($0.mode) }
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let selectedCat = catMap[categoryId]
        let showFreelancerFields = workspace != .home || selectedCat?.mode == .freelancer
        let filtered = state.filteredTransactions(
            workspace: workspace, monthKey: monthKey, scope: scopeFilter, type: typeFilter,
            accountId: accountFilter == "all" ? nil : accountFilter, query: searchQuery)
        let totalIncome = filtered.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
        let totalExpense = filtered.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(monthKey: monthKey)
                entryForm(state: state, workspace: workspace, currency: currency, selectedCat: selectedCat,
                          availableAccounts: availableAccounts, showFreelancerFields: showFreelancerFields)
                filterBar(availableAccounts: availableAccounts, currency: currency,
                          income: totalIncome, expense: totalExpense)
                TransactionsTable(transactions: filtered, state: state, currency: currency,
                                  showFreelancerFields: showFreelancerFields, availableWidth: contentWidth) {
                    store.deleteTransaction($0)
                }
            }
            .padding(24)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 - 48 }
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: initialize)
        .onChange(of: monthKey) { _, key in date = "\(key)-08" }
        .onChange(of: store.preselectedCategoryId) { _, _ in consumePreselectedCategory() }
        .onChange(of: nav.preselectedAccountId) { _, _ in applyPreselectedAccount() }
        .onChange(of: workspace) { _, _ in ensureValidCategory() }
        .onChange(of: state.categories) { _, _ in ensureValidCategory() }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            switch note.userInfo?["name"] as? String {
            case "tx-all-months": scopeFilter = .year
            case "tx-quickadd":
                let ws = store.state.settings.activeWorkspace
                let cat = store.state.categories.last { ws.includes($0.mode) && $0.kind != .income }
                store.openQuickAdd(categoryId: cat?.id)
            default: break
            }
        }
    }

    // MARK: Header

    private func header(monthKey: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                headerActions(monthKey: monthKey)
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                headerActions(monthKey: monthKey)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Transactions & Multi-Account Ledger")
                .font(.zen(20))
                .foregroundStyle(Zen.ink)
            Text("Every entry automatically rolls up into your Monthly Budget Actuals, Account Balances, and Tax Reports.")
                .font(.zen(12))
                .foregroundStyle(Zen.ink2)
        }
    }

    private func headerActions(monthKey: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                TxSegment(label: "This Month (\(monthKey))", active: scopeFilter == .month) { scopeFilter = .month }
                TxSegment(label: "All Months", active: scopeFilter == .year) { scopeFilter = .year }
            }
            .padding(2)
            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

            Button { store.openImport() } label: {
                HStack(spacing: 6) {
                    ZIcon("square.and.arrow.up", size: 14).foregroundStyle(Zen.indigo)
                    Text("Import CSV / Excel")
                }
            }
            .buttonStyle(.zenOutline)

            Button { store.exportTransactionsCSV() } label: {
                HStack(spacing: 6) {
                    ZIcon("arrow.down.doc", size: 14)
                    Text("Export CSV")
                }
            }
            .buttonStyle(.zenOutline)
        }
        .fixedSize()
    }

    // MARK: Quick add form

    private func entryForm(state: LedgerState, workspace: ActiveWorkspace, currency: String,
                           selectedCat: CategoryItem?, availableAccounts: [FinancialAccount],
                           showFreelancerFields: Bool) -> some View {
        let columns = contentWidth >= 740 ? 6 : (contentWidth >= 420 ? 2 : 1)
        let categoryGroups: [TxOptionGroup<String>] = state.groups
            .filter { workspace.includes($0.mode) }
            .map { grp in
                TxOptionGroup(label: "\(grp.name) (\(grp.mode.rawValue.uppercased()))",
                              options: state.categories
                                .filter { $0.groupId == grp.id && workspace.includes($0.mode) }
                                .map { ($0.id, $0.name) })
            }
        let accountOptions: [(String, String)] = [("", "No specific account")]
            + availableAccounts.map { ($0.id, $0.name) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LOG NEW TRANSACTION")
                    .font(.zen(11, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Zen.ink3)
                Spacer()
                if let selectedCat {
                    let income = selectedCat.kind == .income
                    Text(income ? "Income Entry" : "Expense / Outflow")
                        .font(.zen(11, .medium))
                        .foregroundStyle(income ? Zen.positive : Zen.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background((income ? Zen.positive : Zen.accent).opacity(0.15), in: Capsule())
                }
            }

            TxGridLayout(columns: columns, spacing: 12) {
                TxField(label: "Date") { TxDateField(date: $date) }

                TxField(label: "Category") {
                    TxSelect(groups: categoryGroups, selection: $categoryId) { handleCategoryChange($0) }
                }
                .txGridSpan(2)

                TxField(label: "Account") {
                    TxSelect(options: accountOptions, selection: $accountId)
                }

                TxField(label: "Description / Payee") {
                    TextField("", text: $description, prompt: txPrompt("e.g. Groceries, Client Invoice, Rent"))
                        .txInput()
                        .onSubmit(submit)
                }

                TxField(label: "Amount (\(currency))") {
                    HStack(spacing: 8) {
                        TextField("", text: $amount, prompt: txPrompt("0.00"))
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .txInput(invalid: amountInvalid)
                            .focused($amountFocused)
                            .onSubmit(submit)
                            .onChange(of: amount) { _, _ in amountInvalid = false }
                            .help(amountInvalid ? "Please enter an amount greater than 0." : "")
                        Button(action: submit) {
                            HStack(spacing: 4) {
                                ZIcon("plus", size: 14)
                                Text("Add").fontWeight(.medium)
                            }
                        }
                        .buttonStyle(.zen(.ink, padding: 14))
                        .fixedSize()
                    }
                }
            }

            if showFreelancerFields {
                Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1)
                TxGridLayout(columns: columns >= 6 ? 4 : 2, spacing: 12) {
                    TxField(label: "Client / Project (Freelancer)", size: 10, color: Zen.ink3) {
                        TextField("", text: $client, prompt: txPrompt("Optional client name"))
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: "Invoice / Receipt Ref", size: 10, color: Zen.ink3) {
                        TextField("", text: $invoiceRef, prompt: txPrompt("e.g. INV-2026-04"))
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: "VAT Rate %", size: 10, color: Zen.ink3) {
                        TextField("", text: $taxRate)
                            .monospacedDigit()
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: "Tax Deductible %", size: 10, color: Zen.ink3) {
                        TxSelect(options: deductibleOptions, selection: $deductiblePct, height: 28, radius: 4)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    private var deductibleOptions: [(String, String)] {
        var options = [("100", "100% Deductible"), ("50", "50% (Client Meals)"), ("0", "0% Non-Deductible")]
        // Categories can carry other percentages (e.g. 80); show them instead of a wrong label.
        if !options.contains(where: { $0.0 == deductiblePct }), !deductiblePct.isEmpty {
            options.insert((deductiblePct, "\(deductiblePct)% Deductible"), at: 0)
        }
        return options
    }

    // MARK: Filter bar

    private func filterBar(availableAccounts: [FinancialAccount], currency: String,
                           income: Double, expense: Double) -> some View {
        let filters = HStack(spacing: 8) {
            searchField
            HStack(spacing: 4) {
                ZIcon("line.3.horizontal.decrease", size: 14)
                    .foregroundStyle(Zen.ink3)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                ForEach(TransactionTypeFilter.allCases, id: \.self) { t in
                    TxSegment(label: t.rawValue.capitalized, active: typeFilter == t,
                              activeBackground: Zen.raised, shadow: false) { typeFilter = t }
                }
            }
            .padding(2)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .fixedSize()

            if !availableAccounts.isEmpty {
                TxSelect(options: [("all", "All Accounts")] + availableAccounts.map { ($0.id, "Account: \($0.name)") },
                         selection: $accountFilter, background: Zen.surface, fullWidth: false) { value in
                    if value == "all" { nav.preselectedAccountId = nil }
                }
            }
        }
        let totals = HStack(spacing: 16) {
            (Text("Inflow: ").foregroundStyle(Zen.ink2)
             + Text(KobanFormat.currency(income, code: currency)).fontWeight(.bold).foregroundStyle(Zen.positive))
            (Text("Outflow: ").foregroundStyle(Zen.ink2)
             + Text(KobanFormat.currency(expense, code: currency)).fontWeight(.bold).foregroundStyle(Zen.ink))
        }
        .font(.zen(12))
        .monospacedDigit()
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filters.frame(minWidth: 520, alignment: .leading)
                Spacer(minLength: 0)
                totals
            }
            VStack(alignment: .leading, spacing: 12) {
                filters
                totals
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            ZIcon("magnifyingglass", size: 14).foregroundStyle(Zen.ink3)
            TextField("", text: $searchQuery, prompt: txPrompt("Filter by description, category, account, client…"))
                .textFieldStyle(.plain)
                .font(.zen(12))
                .foregroundStyle(Zen.ink)
            if !searchQuery.isEmpty {
                ZenMiniButton(icon: "xmark", size: 14) { searchQuery = "" }
                    .padding(.trailing, -4)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
        .frame(minWidth: 180, maxWidth: 384)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: Behaviour

    private func availableCategories() -> [CategoryItem] {
        let ws = store.state.settings.activeWorkspace
        return store.state.categories.filter { ws.includes($0.mode) }
    }

    private func initialize() {
        guard !didInit else {
            consumePreselectedCategory()
            applyPreselectedAccount()
            return
        }
        didInit = true
        let state = store.state
        let ws = state.settings.activeWorkspace
        date = "\(state.activeMonthKey)-08"
        categoryId = availableCategories().first?.id ?? ""
        accountId = state.accounts.first { ws.includes($0.mode) }?.id ?? ""
        taxRate = JSNumber.string(state.settings.defaultVatRate)
        applyPreselectedAccount()
        consumePreselectedCategory()
    }

    /// The preselectedCategoryId effect: select it, prefill description / VAT / deductible,
    /// focus the amount, then hand the request back to the store.
    private func consumePreselectedCategory() {
        guard let id = store.preselectedCategoryId else {
            ensureValidCategory()
            return
        }
        categoryId = id
        if let cat = store.state.categories.first(where: { $0.id == id }) {
            description = cat.name
            taxRate = JSNumber.string(cat.taxRate ?? 0)
            deductiblePct = JSNumber.string(cat.deductiblePct ?? 100)
        }
        store.preselectedCategoryId = nil
        DispatchQueue.main.async { amountFocused = true }
    }

    private func ensureValidCategory() {
        let avail = availableCategories()
        if let first = avail.first, !avail.contains(where: { $0.id == categoryId }) {
            categoryId = first.id
        }
    }

    private func applyPreselectedAccount() {
        guard let id = nav.preselectedAccountId else { return }
        accountFilter = id
        accountId = id
        scopeFilter = .year
    }

    private func handleCategoryChange(_ newId: String) {
        guard let cat = store.state.categories.first(where: { $0.id == newId }) else { return }
        if description.isEmpty { description = cat.name }
        if let rate = cat.taxRate { taxRate = JSNumber.string(rate) }
        if let ded = cat.deductiblePct { deductiblePct = JSNumber.string(ded) }
    }

    private func submit() {
        let form = TransactionFormInput(date: date, categoryId: categoryId, accountId: accountId,
                                        description: description, amount: amount, client: client,
                                        invoiceRef: invoiceRef, taxRate: taxRate, deductiblePct: deductiblePct)
        guard let tx = store.state.buildTransaction(from: form, fallbackMonthKey: store.state.activeMonthKey) else {
            // <input required>: the browser blocks the submit and points at the amount.
            if (JSNumber.parseFloat(amount) ?? 0) <= 0 {
                amountInvalid = true
                amountFocused = true
            }
            return
        }
        store.logTransaction(tx)
        amount = ""
        description = ""
        invoiceRef = ""
    }
}

// MARK: - Table

private enum TxCol {
    static let date: CGFloat = 108
    static let account: CGFloat = 160
    static let client: CGFloat = 150
    static let tax: CGFloat = 96
    static let amount: CGFloat = 140
    static let actions: CGFloat = 40
    static let minFlexible: CGFloat = 150
}

private struct TransactionsTable: View {
    let transactions: [TransactionItem]
    let state: LedgerState
    let currency: String
    let showFreelancerFields: Bool
    let availableWidth: CGFloat
    let onDelete: (String) -> Void

    private var minWidth: CGFloat {
        TxCol.date + TxCol.account + TxCol.amount + TxCol.actions + 2 * TxCol.minFlexible
            + (showFreelancerFields ? TxCol.client + TxCol.tax : 0)
    }

    var body: some View {
        let width = max(availableWidth, minWidth)
        let grpMap = Dictionary(state.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accMap = Dictionary(state.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // A horizontal ScrollView measures its whole content, which disables the LazyVStack below
        // (every row was built on each render). Only wrap the table when it really needs to scroll.
        horizontalScrollIfNeeded(availableWidth < minWidth) {
            VStack(spacing: 0) {
                headerRow
                Rectangle().fill(Zen.line).frame(height: 1)
                if transactions.isEmpty {
                    Text("No transactions match your current filter. Add an entry above, import a CSV/Excel file, or edit values directly in the Monthly Budget sheet.")
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .padding(.horizontal, 12)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(transactions.enumerated()), id: \.element.id) { idx, tx in
                            if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                            let cat = catMap[tx.categoryId]
                            TransactionRow(tx: tx, category: cat, group: cat.flatMap { grpMap[$0.groupId] },
                                           account: tx.accountId.flatMap { accMap[$0] }, currency: currency,
                                           showFreelancerFields: showFreelancerFields) { onDelete(tx.id) }
                        }
                    }
                }
            }
            .frame(width: width)
        }
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    @ViewBuilder
    private func horizontalScrollIfNeeded<C: View>(_ needed: Bool, @ViewBuilder _ content: () -> C) -> some View {
        if needed {
            ScrollView(.horizontal, showsIndicators: true) { content() }
        } else {
            content()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            head("Date").frame(width: TxCol.date, alignment: .leading)
            head("Category & Group").frame(maxWidth: .infinity, alignment: .leading)
            head("Account").frame(width: TxCol.account, alignment: .leading)
            head("Description").frame(maxWidth: .infinity, alignment: .leading)
            if showFreelancerFields {
                head("Client / Ref").frame(width: TxCol.client, alignment: .leading)
                head("Tax / Ded.").frame(width: TxCol.tax, alignment: .trailing)
            }
            head("Amount").frame(width: TxCol.amount, alignment: .trailing)
            Color.clear.frame(width: TxCol.actions, height: 1)
        }
        .padding(.vertical, 10)
        .background(Zen.raised.opacity(0.7))
    }

    private func head(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.zen(11, .semibold))
            .tracking(0.55)
            .foregroundStyle(Zen.ink2)
            .lineLimit(1)
            .padding(.horizontal, 12)
    }
}

private struct TransactionRow: View {
    let tx: TransactionItem
    let category: CategoryItem?
    let group: CategoryGroup?
    let account: FinancialAccount?
    let currency: String
    let showFreelancerFields: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let isIncome = tx.type == .income
        HStack(alignment: .center, spacing: 0) {
            Text(tx.date)
                .font(.zen(12)).monospacedDigit().foregroundStyle(Zen.ink2).lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: TxCol.date, alignment: .leading)

            HStack(spacing: 8) {
                Circle().fill(group.map { Color(hexString: $0.color) } ?? Zen.ink3).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category?.name ?? "Uncategorized")
                        .font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                    Text((group?.name ?? tx.mode.rawValue).uppercased())
                        .font(.zen(10)).tracking(0.5).foregroundStyle(Zen.ink3).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            accountCell
                .padding(.horizontal, 12)
                .frame(width: TxCol.account, alignment: .leading)

            Text(tx.description)
                .font(.zen(12)).foregroundStyle(Zen.ink)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showFreelancerFields {
                VStack(alignment: .leading, spacing: 1) {
                    if let client = tx.client, !client.isEmpty {
                        Text(client).font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                    }
                    if let ref = tx.invoiceRef, !ref.isEmpty {
                        Text(ref).font(.zen(11)).monospacedDigit().foregroundStyle(Zen.ink3).lineLimit(1)
                    }
                    if (tx.client ?? "").isEmpty && (tx.invoiceRef ?? "").isEmpty {
                        Text("—").font(.zen(12)).foregroundStyle(Zen.ink3)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: TxCol.client, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(tx.taxRate.map { $0 != 0 ? "\(JSNumber.string($0))% VAT" : "0% VAT" } ?? "0% VAT")
                        .foregroundStyle(Zen.ink2)
                    if tx.type == .expense && tx.mode == .freelancer {
                        Text("\(JSNumber.string(tx.deductiblePct ?? 100))% Ded.").foregroundStyle(Zen.indigo)
                    }
                }
                .font(.zen(11))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .frame(width: TxCol.tax, alignment: .trailing)
            }

            HStack(spacing: 4) {
                ZIcon(isIncome ? "arrow.up.right" : "arrow.down.right", size: 14)
                    .foregroundStyle(isIncome ? Zen.positive : Zen.ink3)
                Text((isIncome ? "+" : "") + KobanFormat.currency(tx.amount, code: currency))
                    .font(.zen(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isIncome ? Zen.positive : Zen.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(width: TxCol.amount, alignment: .trailing)

            ZenMiniButton(icon: "trash", size: 14, tint: Zen.ink3, hoverTint: Zen.accent,
                          help: "Delete transaction", action: onDelete)
                .opacity(hovering ? 1 : 0)
                .frame(width: TxCol.actions)
        }
        .padding(.vertical, 10)
        .background(hovering ? Zen.raised.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var accountCell: some View {
        if let account {
            HStack(spacing: 6) {
                Circle().fill(Color(hexString: account.color)).frame(width: 6, height: 6)
                Text(account.name).lineLimit(1)
            }
            .font(.zen(11))
            .foregroundStyle(Zen.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
        } else {
            HStack(spacing: 4) {
                ZIcon("building.columns", size: 12)
                Text(tx.paymentMethod.flatMap { $0.isEmpty ? nil : $0 } ?? "General").lineLimit(1)
            }
            .font(.zen(11))
            .foregroundStyle(Zen.ink3)
        }
    }
}
