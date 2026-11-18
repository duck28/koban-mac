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
            Text(L10n.t("tx.title"))
                .font(.zen(20))
                .foregroundStyle(Zen.ink)
            Text(L10n.t("tx.subtitle"))
                .font(.zen(12))
                .foregroundStyle(Zen.ink2)
        }
    }

    private func headerActions(monthKey: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                TxSegment(label: L10n.tf("tx.thisMonth", ["month": monthKey]), active: scopeFilter == .month) { scopeFilter = .month }
                TxSegment(label: L10n.t("tx.allMonths"), active: scopeFilter == .year) { scopeFilter = .year }
            }
            .padding(2)
            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

            Button { store.openImport() } label: {
                HStack(spacing: 6) {
                    ZIcon("square.and.arrow.up", size: 14).foregroundStyle(Zen.indigo)
                    Text(L10n.t("tx.importBtn"))
                }
            }
            .buttonStyle(.zenOutline)

            Button { store.exportTransactionsCSV() } label: {
                HStack(spacing: 6) {
                    ZIcon("arrow.down.doc", size: 14)
                    Text(L10n.t("tx.exportBtn"))
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
                let modeLabel = L10n.t(grp.mode == .home ? "workspace.home" : "workspace.freelancer").uppercased()
                return TxOptionGroup(label: "\(L10n.groupName(grp)) (\(modeLabel))",
                                     options: state.categories
                                        .filter { $0.groupId == grp.id && workspace.includes($0.mode) }
                                        .map { ($0.id, L10n.categoryName($0)) })
            }
        let accountOptions: [(String, String)] = [("", L10n.t("tx.noSpecificAccount"))]
            + availableAccounts.map { ($0.id, L10n.accountName($0)) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("tx.logNew").uppercased())
                    .font(.zen(11, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Zen.ink3)
                Spacer()
                if let selectedCat {
                    let income = selectedCat.kind == .income
                    Text(L10n.t(income ? "tx.incomeEntry" : "tx.expenseOutflow"))
                        .font(.zen(11, .medium))
                        .foregroundStyle(income ? Zen.positive : Zen.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background((income ? Zen.positive : Zen.accent).opacity(0.15), in: Capsule())
                }
            }

            TxGridLayout(columns: columns, spacing: 12) {
                TxField(label: L10n.t("finance.date")) { TxDateField(date: $date) }

                TxField(label: L10n.t("finance.category")) {
                    TxSelect(groups: categoryGroups, selection: $categoryId) { handleCategoryChange($0) }
                }
                .txGridSpan(2)

                TxField(label: L10n.t("finance.account")) {
                    TxSelect(options: accountOptions, selection: $accountId)
                }

                TxField(label: L10n.t("tx.descPayeeLabel")) {
                    TextField("", text: $description, prompt: txPrompt(L10n.t("tx.descPlaceholder")))
                        .txInput()
                        .onSubmit(submit)
                }

                TxField(label: L10n.tf("tx.amountCurrency", ["currency": currency])) {
                    HStack(spacing: 8) {
                        TextField("", text: $amount, prompt: txPrompt("0.00"))
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .txInput(invalid: amountInvalid)
                            .focused($amountFocused)
                            .onSubmit(submit)
                            .onChange(of: amount) { _, _ in amountInvalid = false }
                        Button(action: submit) {
                            HStack(spacing: 4) {
                                ZIcon("plus", size: 14)
                                Text(L10n.t("common.add")).fontWeight(.medium)
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
                    TxField(label: L10n.t("tx.clientProjectLabel"), size: 10, color: Zen.ink3) {
                        TextField("", text: $client, prompt: txPrompt(L10n.t("tx.clientPlaceholder")))
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: L10n.t("tx.invoiceRefLabel"), size: 10, color: Zen.ink3) {
                        TextField("", text: $invoiceRef, prompt: txPrompt("e.g. INV-2026-04"))
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: L10n.t("tx.vatRateLabel"), size: 10, color: Zen.ink3) {
                        TextField("", text: $taxRate)
                            .monospacedDigit()
                            .txInput(height: 28, radius: 4, padding: 8)
                            .onSubmit(submit)
                    }
                    TxField(label: L10n.t("tx.taxDeductibleLabel"), size: 10, color: Zen.ink3) {
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
        var options = [("100", L10n.t("tx.ded100")), ("50", L10n.t("tx.ded50")), ("0", L10n.t("tx.ded0"))]
        // Categories can carry other percentages (e.g. 80); show them instead of a wrong label.
        if !options.contains(where: { $0.0 == deductiblePct }), !deductiblePct.isEmpty {
            options.insert((deductiblePct, "\(deductiblePct)%"), at: 0)
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
                ForEach(TransactionTypeFilter.allCases, id: \.self) { tfFilter in
                    let label = tfFilter == .all ? L10n.t("tx.filterAll")
                        : tfFilter == .income ? L10n.t("tx.filterIncome") : L10n.t("tx.filterExpense")
                    TxSegment(label: label, active: typeFilter == tfFilter,
                              activeBackground: Zen.raised, shadow: false) { typeFilter = tfFilter }
                }
            }
            .padding(2)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .fixedSize()

            if !availableAccounts.isEmpty {
                TxSelect(options: [("all", L10n.t("tx.allAccounts"))] + availableAccounts.map { ($0.id, L10n.tf("tx.accountPrefix", ["name": L10n.accountName($0)])) },
                         selection: $accountFilter, background: Zen.surface, fullWidth: false) { value in
                    if value == "all" { nav.preselectedAccountId = nil }
                }
            }
        }
        let totals = HStack(spacing: 16) {
            (Text("\(L10n.t("tx.inflow")) ").foregroundStyle(Zen.ink2)
             + Text(KobanFormat.currency(income, code: currency)).fontWeight(.bold).foregroundStyle(Zen.positive))
            (Text("\(L10n.t("tx.outflow")) ").foregroundStyle(Zen.ink2)
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
            TextField("", text: $searchQuery, prompt: txPrompt(L10n.t("tx.searchPlaceholder")))
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
            description = L10n.categoryName(cat)
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
        if description.isEmpty { description = L10n.categoryName(cat) }
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
                    Text(L10n.t("tx.emptyFilter"))
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
            head(L10n.t("finance.date")).frame(width: TxCol.date, alignment: .leading)
            head(L10n.t("tx.colCategoryGroup")).frame(maxWidth: .infinity, alignment: .leading)
            head(L10n.t("finance.account")).frame(width: TxCol.account, alignment: .leading)
            head(L10n.t("finance.description")).frame(maxWidth: .infinity, alignment: .leading)
            if showFreelancerFields {
                head(L10n.t("tx.colClientRef")).frame(width: TxCol.client, alignment: .leading)
                head(L10n.t("tx.colTaxDed")).frame(width: TxCol.tax, alignment: .trailing)
            }
            head(L10n.t("finance.amount")).frame(width: TxCol.amount, alignment: .trailing)
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
                    Text(category.map { L10n.categoryName($0) } ?? L10n.t("tx.uncategorized"))
                        .font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                    Text((group.map { L10n.groupName($0) } ?? L10n.t(tx.mode == .home ? "workspace.home" : "workspace.freelancer")).uppercased())
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
                    Text(tx.taxRate.map { $0 != 0 ? "\(JSNumber.string($0))% \(L10n.t("worksheet.vatShort"))" : "0% \(L10n.t("worksheet.vatShort"))" } ?? "0% \(L10n.t("worksheet.vatShort"))")
                        .foregroundStyle(Zen.ink2)
                    if tx.type == .expense && tx.mode == .freelancer {
                        Text("\(JSNumber.string(tx.deductiblePct ?? 100))% \(L10n.t("worksheet.dedShort"))").foregroundStyle(Zen.indigo)
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
                          help: L10n.t("tx.deleteTip"), action: onDelete)
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
                Text(L10n.accountName(account)).lineLimit(1)
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
                Text(tx.paymentMethod.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.t("tx.general")).lineLimit(1)
            }
            .font(.zen(11))
            .foregroundStyle(Zen.ink3)
        }
    }
}
