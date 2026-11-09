import SwiftUI

/// Port of src/components/AccountsNetWorthView.tsx — multi-account treasury & net worth tracker.
struct AccountsView: View {
    @Environment(LedgerStore.self) private var store

    @State private var filterBucket: AccountLiquidityClass?   // nil = all
    @State private var showAddForm = false
    @State private var showTransferForm = false
    @State private var editingBalanceId: String?
    @State private var pendingDelete: FinancialAccount?
    @State private var scrollWidth: CGFloat = 1100

    // New account form
    @State private var newName = ""
    @State private var newInstitution = ""
    @State private var newMaskedNumber = ""
    @State private var newMode: LedgerMode?
    @State private var newType: AccountType = .checking
    @State private var newCustomTypeLabel = ""
    @State private var newClassification: AccountLiquidityClass = .liquid
    @State private var newBalance = ""
    @State private var newAutoTrack = true
    @State private var newIncludeInNw = true
    @State private var newColor = "#3f704d"

    // Transfer form
    @State private var fromAccId = ""
    @State private var toAccId = ""
    @State private var transferAmount = ""
    @State private var transferNote = ""

    private var currency: String { store.state.settings.currency }
    private var monthKey: String { store.state.activeMonthKey }
    private var bp: AccBreakpoints { AccBreakpoints(viewport: scrollWidth + (store.isSidebarOpen ? 256 : 0)) }

    var body: some View {
        let netWorth = store.accountsNetWorthMetrics

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(netWorth)
                heroStrip(netWorth)
                if showAddForm { addAccountForm }
                if showTransferForm { transferForm(netWorth) }
                accountsSection(netWorth)
                allocationAndTrajectory(netWorth).id("accounts-bottom")
            }
            .padding(24)
            .frame(maxWidth: 1440)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            if note.userInfo?["name"] as? String == "accounts-scroll-bottom" { proxy.scrollTo("accounts-bottom", anchor: .bottom) }
        }
        }
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scrollWidth = $0 }
        .onAppear {
            if newMode == nil { newMode = store.state.settings.activeWorkspace == .freelancer ? .freelancer : .home }
            resetTransferSelection(netWorth)
        }
        .alert("Remove Account", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { acc in
            Button("Remove", role: .destructive) { store.deleteAccount(acc.id) }
            Button("Cancel", role: .cancel) {}
        } message: { acc in
            Text("Are you sure you want to remove account \"\(acc.name)\"? Linked transactions will be kept as unassigned.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            switch note.userInfo?["name"] as? String {
            case "accounts-add": showAddForm = true; showTransferForm = false
            case "accounts-add-custom": showAddForm = true; handleTypeSelect(.custom)
            case "accounts-transfer": openTransfer(netWorth)
            case "accounts-edit": editingBalanceId = netWorth.accounts.first?.account.id
            case "accounts-delete": pendingDelete = netWorth.accounts.first?.account
            case "accounts-filter-liability": filterBucket = .liability
            default: break
            }
        }
    }

    // MARK: - Header

    private func header(_ netWorth: NetWorthSummaryMetrics) -> some View {
        let title = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("MULTI-ACCOUNT TREASURY & BALANCE SHEET")
                    .font(.zen(11, .medium)).tracking(1.54).foregroundStyle(Zen.ink3)
                Text("·").font(.zen(11)).foregroundStyle(Zen.ink3)
                Text("\(netWorth.accounts.count) Active Account\(netWorth.accounts.count == 1 ? "" : "s")")
                    .font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
            }
            Text("Accounts & Comprehensive Net Worth Tracker")
                .font(.zen(20, .medium)).foregroundStyle(Zen.ink)
        }
        let buttons = HStack(spacing: 8) {
            Button {
                store.saveNetWorthSnapshot(note: nil)
            } label: {
                HStack(spacing: 6) {
                    ZIcon("camera", size: 14).foregroundStyle(Zen.indigo)
                    Text("Snapshot \(monthKey)")
                }
            }
            .buttonStyle(.zenOutline)
            .help("Record Net Worth snapshot for \(monthKey)")

            if netWorth.accounts.count >= 2 {
                Button {
                    if showTransferForm { showTransferForm = false } else { openTransfer(netWorth) }
                } label: {
                    HStack(spacing: 6) {
                        ZIcon("arrow.left.arrow.right", size: 14).foregroundStyle(Zen.positive)
                        Text("Transfer Funds")
                    }
                }
                .buttonStyle(.zen(.outline, active: true))
            }

            Button {
                showAddForm.toggle()
                showTransferForm = false
            } label: {
                HStack(spacing: 6) {
                    ZIcon("plus", size: 14)
                    Text("Add Account").fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 14))
        }

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { title; Spacer(minLength: 16); buttons }
            VStack(alignment: .leading, spacing: 16) { title; buttons }
        }
        .padding(.bottom, 16)
        .accBottomHairline()
    }

    // MARK: - Hero strip

    private func heroStrip(_ nw: NetWorthSummaryMetrics) -> some View {
        AccGrid(columns: bp.lg ? 5 : (bp.sm ? 2 : 1), hSpacing: 14, vSpacing: 14) {
            heroCard(title: "Total Net Worth", titleColor: Zen.ink, titleWeight: .medium, icon: "sparkles",
                     iconColor: Zen.positive, amount: nw.netWorth, amountSize: 20,
                     amountColor: nw.netWorth >= 0 ? Zen.positive : Zen.accent,
                     left: "Assets: \(KobanFormat.currency(nw.totalAssets, code: currency))",
                     right: Text("Debt: \(AccountsJS.fixed(nw.debtToAssetRatioPct, 1))%"), highlighted: true)
            heroCard(title: "Liquid Assets (Bank & Cash)", icon: "building.columns", iconColor: Zen.positive,
                     amount: nw.liquidAssets,
                     left: "\(AccountsJS.fixed(nw.liquidSharePct, 1))% of assets",
                     right: nw.liquidRunwayMonths > 0
                        ? Text("\(AccountsJS.fixed(nw.liquidRunwayMonths, 1)) mo runway").fontWeight(.medium).foregroundColor(Zen.positive)
                        : nil)
            heroCard(title: "Retirement & Pension", icon: "shield", iconColor: Color(hexString: "#8a6fb0"),
                     amount: nw.retirementAssets, left: "Pillar 2 / 3a / Pension",
                     right: Text("\(AccountsJS.fixed(nw.retirementSharePct, 1))% of assets"))
            heroCard(title: "Investments & Fixed Assets", icon: "chart.line.uptrend.xyaxis", iconColor: Zen.indigo,
                     amount: nw.investmentAssets + nw.fixedAssets, left: "ETFs, Crypto & Equity",
                     right: Text("\(AccountsJS.fixed(nw.investmentSharePct + nw.fixedAssetSharePct, 1))% of assets"))
            heroCard(title: "Liabilities & Debt", icon: "creditcard", iconColor: Zen.accent,
                     amount: nw.totalLiabilities, amountColor: Zen.accent, left: "Cards, Loans & Mortgages",
                     right: Text("Subtracted"))
        }
    }

    private func heroCard(title: String, titleColor: Color = Zen.ink2, titleWeight: Font.Weight = .regular,
                          icon: String, iconColor: Color, amount: Double, amountSize: CGFloat = 18,
                          amountColor: Color = Zen.ink, left: String, right: Text?, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.zen(12, titleWeight)).foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ZIcon(icon, size: 14).foregroundStyle(iconColor)
            }
            Text(KobanFormat.currency(amount, code: currency))
                .font(.zen(amountSize, .semibold)).monospacedDigit().foregroundStyle(amountColor)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .top) {
                Text(left).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let right { right.multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true) }
            }
            .font(.zen(11)).monospacedDigit().foregroundStyle(Zen.ink3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accSurfaceCard(padding: 16, border: highlighted ? Zen.ink.opacity(0.4) : Zen.line)
        .shadow(color: highlighted ? .black.opacity(0.05) : .clear, radius: 0, y: 1)
    }

    // MARK: - Add account form

    private var typeSections: [AccSelect<AccountType>.Section] {
        [
            .init(title: "Liquid Bank & Cash Accounts", options: [
                (.checking, "Bank Checking / Everyday Account"),
                (.savings, "Bank Savings / High-Yield Account"),
                (.businessBank, "Freelancer / Business Bank Account"),
                (.taxReserve, "Tax & VAT Reserve Account"),
                (.cash, "Cash / Digital Wallet"),
            ]),
            .init(title: "Retirement & Long-Term Wealth", options: [
                (.retirement, "Retirement / Pension (Pillar 2 / 3a / 401k / IRA)"),
                (.brokerage, "Brokerage / ETFs & Stocks"),
                (.crypto, "Crypto & Digital Assets"),
                (.realEstate, "Property / Real Estate Equity"),
            ]),
            .init(title: "Liabilities & Debt", options: [
                (.creditCard, "Credit Card Balance"),
                (.loan, "Loan / Mortgage / Debt"),
            ]),
            .init(title: "Custom", options: [(.custom, "Custom Account Type…")]),
        ]
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Create Financial Account").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    Text("Add a bank account, retirement fund, investment portfolio, credit card, loan, or define a custom account type.")
                        .font(.zen(11)).foregroundStyle(Zen.ink2)
                }
                Spacer(minLength: 8)
                AccTextButton(title: "Close") { showAddForm = false }
            }
            .padding(.bottom, 8)
            .accBottomHairline()

            AccGrid(columns: bp.lg ? 4 : (bp.sm ? 2 : 1), hSpacing: 14, vSpacing: 14) {
                AccLabeledField("Account Type") {
                    AccSelect(sections: typeSections, selection: Binding(get: { newType }, set: { handleTypeSelect($0) }))
                }
                if newType == .custom {
                    AccLabeledField("Custom Type Label") {
                        AccTextField(placeholder: "e.g. Precious Metals, Pillar 3a, Co-op Shares",
                                     text: $newCustomTypeLabel, onSubmit: createAccount)
                    }
                }
                AccLabeledField("Net Worth Classification") {
                    AccSelect(options: [
                        (.liquid, "Liquid Asset (Bank / Cash)"),
                        (.retirement, "Retirement / Pension Asset"),
                        (.investment, "Investment / Market Asset"),
                        (.fixedAsset, "Fixed / Real Estate Asset"),
                        (.liability, "Liability / Debt (Subtracted)"),
                    ], selection: $newClassification)
                }
                AccLabeledField("Account Name") {
                    AccTextField(placeholder: "e.g. UBS Personal Checking, VIAC Pillar 3a", text: $newName,
                                 onSubmit: createAccount)
                }
                AccLabeledField("Bank / Institution (optional)") {
                    AccTextField(placeholder: "e.g. ZKB, PostFinance, Interactive Brokers", text: $newInstitution,
                                 onSubmit: createAccount)
                }
                AccLabeledField("Account / IBAN Ref (optional)") {
                    AccTextField(placeholder: "e.g. CH93 •••• 4820", text: $newMaskedNumber, onSubmit: createAccount)
                }
                AccLabeledField("Current / Opening Balance (\(currency))") {
                    AccTextField(placeholder: "0.00", text: $newBalance, monospacedDigits: true, onSubmit: createAccount)
                }
                AccLabeledField("Ledger Assignment") {
                    AccSelect(options: [(LedgerMode.home, "Home / Personal"), (.freelancer, "Freelancer / Business")],
                              selection: Binding(get: { newMode ?? .home }, set: { newMode = $0 }))
                }
            }

            HStack(alignment: .center, spacing: 16) {
                FlowLayout(spacing: 16) {
                    AccCheckbox(isOn: newAutoTrack, label: "Automatically adjust balance from logged transactions") {
                        newAutoTrack.toggle()
                    }
                    AccCheckbox(isOn: newIncludeInNw, label: "Include in Net Worth total") { newIncludeInNw.toggle() }
                    HStack(spacing: 4) {
                        ForEach(Array(ZenGroupPalette.colors.prefix(7)), id: \.self) { swatch in
                            Button { newColor = swatch } label: {
                                Circle().fill(Color(hexString: swatch))
                                    .frame(width: 16, height: 16)
                                    .padding(newColor == swatch ? 1 : 0)
                                    .overlay {
                                        if newColor == swatch {
                                            Circle().strokeBorder(Zen.ink, lineWidth: 2).frame(width: 22, height: 22)
                                        }
                                    }
                                    .frame(width: 18, height: 18)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 8)
                Button("Create Account", action: createAccount)
                    .buttonStyle(.zen(.ink, height: 36, padding: 16))
                    .fontWeight(.medium)
            }
            .padding(.top, 8)
            .accTopHairline()
        }
        .accSurfaceCard(padding: 20)
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private func handleTypeSelect(_ type: AccountType) {
        newType = type
        let meta = KobanTemplates.accountType(type)
        newClassification = meta.defaultClass
        newAutoTrack = meta.autoTrackDefault
        newColor = meta.defaultColor
        if type == .businessBank || type == .taxReserve { newMode = .freelancer }
    }

    private func createAccount() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // `required` inputs: the browser blocks submit while they are empty.
        guard !name.isEmpty, newType != .custom || !newCustomTypeLabel.isEmpty else { return }
        let bal = NumberParsing.parse(newBalance) ?? 0
        let inst = newInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        let masked = newMaskedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = newCustomTypeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.addAccount(NewAccountInput(
            name: name,
            institution: inst.isEmpty ? nil : inst,
            accountNumberMasked: masked.isEmpty ? nil : masked,
            mode: newMode ?? .home,
            type: newType,
            customTypeLabel: newType == .custom ? (custom.isEmpty ? "Custom Account" : custom) : nil,
            classification: newClassification,
            startingBalance: bal,
            currentBalance: bal,
            autoTrackTransactions: newAutoTrack,
            includeInNetWorth: newIncludeInNw,
            color: newColor
        ))
        newName = ""
        newInstitution = ""
        newMaskedNumber = ""
        newCustomTypeLabel = ""
        newBalance = ""
        showAddForm = false
    }

    // MARK: - Transfer form

    private func openTransfer(_ netWorth: NetWorthSummaryMetrics) {
        resetTransferSelection(netWorth)
        showTransferForm = true
        showAddForm = false
    }

    private func resetTransferSelection(_ netWorth: NetWorthSummaryMetrics) {
        let ids = netWorth.accounts.map(\.account.id)
        if !ids.contains(fromAccId) { fromAccId = ids.first ?? "" }
        if !ids.contains(toAccId) { toAccId = ids.count > 1 ? ids[1] : "" }
    }

    private func transferForm(_ netWorth: NetWorthSummaryMetrics) -> some View {
        let options = netWorth.accounts.map {
            ($0.account.id, "\($0.account.name) (\(KobanFormat.currency($0.liveBalance, code: currency)))")
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    ZIcon("arrow.left.arrow.right", size: 16).foregroundStyle(Zen.positive)
                    Text("Transfer Funds Between Accounts").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                }
                Spacer()
                AccTextButton(title: "Close") { showTransferForm = false }
            }
            .padding(.bottom, 8)
            .accBottomHairline()

            AccGrid(columns: bp.sm ? 5 : 1, hSpacing: 12, vSpacing: 12, alignment: .bottom) {
                AccLabeledField("From Account") { AccSelect(options: options, selection: $fromAccId) }
                AccLabeledField("To Account") { AccSelect(options: options, selection: $toAccId) }
                AccLabeledField("Amount (\(currency))") {
                    AccTextField(placeholder: "0.00", text: $transferAmount, monospacedDigits: true, onSubmit: submitTransfer)
                }
                AccLabeledField("Note / Reference") {
                    AccTextField(placeholder: "e.g. Monthly Savings / Pillar 3a Transfer", text: $transferNote,
                                 onSubmit: submitTransfer)
                }
                Button(action: submitTransfer) {
                    Text("Execute Transfer").fontWeight(.medium).frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(.ink, height: 36, padding: 16))
            }
        }
        .accSurfaceCard(padding: 20)
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    private func submitTransfer() {
        let amt = AccountsJS.parseFloat(transferAmount) ?? 0
        guard !fromAccId.isEmpty, !toAccId.isEmpty, fromAccId != toAccId, amt > 0 else { return }
        let note = transferNote.trimmingCharacters(in: .whitespacesAndNewlines)
        store.transferBetweenAccounts(from: fromAccId, to: toAccId, amount: amt,
                                      note: note.isEmpty ? "Account Transfer" : note)
        transferAmount = ""
        transferNote = ""
        showTransferForm = false
    }

    // MARK: - Accounts filter + cards

    private func accountsSection(_ nw: NetWorthSummaryMetrics) -> some View {
        let tabs: [(AccountLiquidityClass?, String)] = [
            (nil, "All Accounts (\(nw.accounts.count))"),
            (.liquid, "Liquid / Bank (\(nw.accountCount(.liquid)))"),
            (.retirement, "Retirement (\(nw.accountCount(.retirement)))"),
            (.investment, "Investments (\(nw.accountCount(.investment)))"),
            (.fixedAsset, "Fixed Assets (\(nw.accountCount(.fixedAsset)))"),
            (.liability, "Liabilities (\(nw.accountCount(.liability)))"),
        ]
        let filtered = nw.accounts.filter { filterBucket == nil || $0.account.classification == filterBucket }
        let tabButtons = ForEach(tabs, id: \.1) { id, label in
            Button { filterBucket = id } label: {
                Text(label).fontWeight(filterBucket == id ? .medium : .regular)
            }
            .buttonStyle(.zen(filterBucket == id ? .ink : .outline, height: 28, padding: 12))
        }
        let hint = Text("Click any balance to update or reconcile directly").font(.zen(11)).foregroundStyle(Zen.ink3)

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) { tabButtons }
                    Spacer(minLength: 8)
                    hint
                }
                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6) { tabButtons }
                    hint
                }
            }

            if filtered.isEmpty {
                emptyAccounts
            } else {
                AccGrid(columns: bp.lg ? 3 : (bp.md ? 2 : 1), hSpacing: 16, vSpacing: 16) {
                    ForEach(filtered) { item in
                        AccountCard(
                            item: item,
                            currency: currency,
                            isEditing: editingBalanceId == item.account.id,
                            onStartEdit: { editingBalanceId = item.account.id },
                            onCommit: { value in
                                if let value { store.reconcileAccountBalance(item, to: value) }
                                editingBalanceId = nil
                            },
                            onCancel: { editingBalanceId = nil },
                            onToggleAuto: {
                                store.updateAccount(item.account.id) { $0.autoTrackTransactions.toggle() }
                            },
                            onToggleNw: {
                                store.updateAccount(item.account.id) { $0.includeInNetWorth.toggle() }
                            },
                            onInspect: { store.inspectAccountTransactions(item.account.id) },
                            onDelete: {
                                if store.shouldConfirmAccountDelete { pendingDelete = item.account }
                                else { store.deleteAccount(item.account.id) }
                            }
                        )
                    }
                }
            }
        }
    }

    private var emptyAccounts: some View {
        VStack(spacing: 8) {
            ZIcon("wallet.bifold", size: 24).foregroundStyle(Zen.ink3)
            Text("No accounts in this category yet").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
            Text("Add your bank checking & savings accounts, Pillar 2 / 3a retirement accounts, investment portfolios, or custom accounts to track your complete Net Worth.")
                .font(.zen(12)).foregroundStyle(Zen.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 448)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showAddForm = true
            } label: {
                HStack(spacing: 6) {
                    ZIcon("plus", size: 14)
                    Text("Add First Account").fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 14))
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .accSurfaceCard(padding: 32)
    }

    // MARK: - Allocation + trajectory

    private func allocationAndTrajectory(_ nw: NetWorthSummaryMetrics) -> some View {
        Group {
            if bp.lg {
                AccSpanRow(spans: [5, 7], total: 12, spacing: 24) {
                    allocationCard(nw)
                    trajectoryCard(nw)
                }
            } else {
                VStack(spacing: 24) {
                    allocationCard(nw)
                    trajectoryCard(nw)
                }
            }
        }
    }

    private func allocationCard(_ nw: NetWorthSummaryMetrics) -> some View {
        let segments: [(AccountLiquidityClass, Double, String)] = [
            (.liquid, nw.liquidSharePct, "Liquid Assets"),
            (.retirement, nw.retirementSharePct, "Retirement"),
            (.investment, nw.investmentSharePct, "Investments"),
            (.fixedAsset, nw.fixedAssetSharePct, "Fixed Assets"),
        ]
        let rows: [(AccountLiquidityClass, Double, Double)] = [
            (.liquid, nw.liquidAssets, nw.liquidSharePct),
            (.retirement, nw.retirementAssets, nw.retirementSharePct),
            (.investment, nw.investmentAssets, nw.investmentSharePct),
            (.fixedAsset, nw.fixedAssets, nw.fixedAssetSharePct),
            (.liability, nw.totalLiabilities, nw.debtToAssetRatioPct),
        ]
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Asset Allocation & Wealth Structure").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                Text("Distribution across liquid bank reserves, retirement funds, and investments")
                    .font(.zen(12)).foregroundStyle(Zen.ink2)
            }

            // Stacked horizontal allocation bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if nw.totalAssets > 0 {
                        ForEach(segments.filter { $0.1 > 0 }, id: \.0) { cls, pct, label in
                            Rectangle()
                                .fill(Color(hexString: KobanTemplates.accountClass(cls).color))
                                .frame(width: geo.size.width * pct / 100)
                                .help("\(label): \(AccountsJS.fixed(pct, 1))%")
                        }
                        Spacer(minLength: 0)
                    } else {
                        Zen.line.opacity(0.4)
                    }
                }
            }
            .frame(height: 16)
            .background(Zen.raised)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Zen.line, lineWidth: 1))

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    let (cls, amount, pct) = row
                    let meta = KobanTemplates.accountClass(cls)
                    let negative = cls == .liability && amount > 0
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hexString: meta.color)).frame(width: 10, height: 10)
                            Text(meta.label).foregroundStyle(Zen.ink).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 12) {
                            Text("\(AccountsJS.fixed(pct, 1))%").font(.zen(11)).foregroundStyle(Zen.ink3)
                            Text("\(negative ? "-" : "")\(KobanFormat.currency(amount, code: currency))")
                                .fontWeight(.medium)
                                .foregroundStyle(negative ? Zen.accent : Zen.ink)
                        }
                        .monospacedDigit()
                    }
                    .font(.zen(12))
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        if idx < rows.count - 1 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accSurfaceCard(padding: 20)
    }

    private func trajectoryCard(_ nw: NetWorthSummaryMetrics) -> some View {
        let maxAbs = nw.maxHistoryAbs
        let snapshots = store.state.netWorthSnapshots.sorted { $0.monthKey > $1.monthKey }
        let titleBlock = VStack(alignment: .leading, spacing: 2) {
            Text("12-Month Net Worth Trajectory").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
            Text("Combines recorded monthly snapshots with cumulative cashflow progression")
                .font(.zen(12)).foregroundStyle(Zen.ink2)
        }
        let legend = HStack(spacing: 12) {
            legendItem(Zen.positive, "Net Worth")
            legendItem(Zen.indigo, "Recorded Snapshot")
        }
        .font(.zen(11)).foregroundStyle(Zen.ink2)

        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) { titleBlock; Spacer(minLength: 8); legend }
                VStack(alignment: .leading, spacing: 8) { titleBlock; legend }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(nw.historySeries) { pt in
                    let isCurrent = pt.monthKey == monthKey
                    let color = pt.hasExplicitSnapshot ? Zen.indigo : (pt.netWorth >= 0 ? Zen.positive : Zen.accent)
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Color.clear
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(color)
                                .opacity(isCurrent ? 1 : 0.78)
                                .frame(maxWidth: 22)
                                .frame(height: 128 * pt.barHeightPct(maxAbs: maxAbs) / 100)
                        }
                        .frame(height: 128)
                        Text(pt.monthLabel)
                            .font(.zen(10, isCurrent ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? Zen.ink : Zen.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(pt.monthLabel) (\(pt.monthKey))\nNet Worth: \(KobanFormat.currency(pt.netWorth, code: currency))\nLiquid: \(KobanFormat.currency(pt.liquidAssets, code: currency))\nRetirement: \(KobanFormat.currency(pt.retirementAssets, code: currency))")
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 4)
            .frame(height: 176, alignment: .bottom)
            .accBottomHairline()

            if !snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECORDED MONTHLY BALANCE SHEET SNAPSHOTS (\(snapshots.count))")
                        .font(.zen(11, .medium)).tracking(0.55).foregroundStyle(Zen.ink3)
                    let list = VStack(spacing: 4) {
                        ForEach(snapshots) { snap in snapshotRow(snap) }
                    }
                    .padding(.trailing, 4)
                    if snapshots.count > 3 {
                        ScrollView { list }.frame(height: 112)
                    } else {
                        list
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accSurfaceCard(padding: 20)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func snapshotRow(_ snap: NetWorthSnapshot) -> some View {
        HStack {
            HStack(spacing: 8) {
                Text(snap.monthKey).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Zen.ink)
                Text("Liquid: \(KobanFormat.currency(snap.liquidAssets, code: currency)) · Retirement: \(KobanFormat.currency(snap.retirementAssets, code: currency))")
                    .font(.zen(11)).foregroundStyle(Zen.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text(KobanFormat.currency(snap.netWorth, code: currency))
                    .font(.zen(12, .semibold)).foregroundStyle(Zen.positive)
                AccHoverIcon(icon: "trash", size: 12, help: "Remove snapshot") {
                    store.deleteNetWorthSnapshot(snap.id)
                }
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

// MARK: - Account card

private struct AccountCard: View {
    let item: AccountComputedItem
    let currency: String
    let isEditing: Bool
    let onStartEdit: () -> Void
    let onCommit: (Double?) -> Void
    let onCancel: () -> Void
    let onToggleAuto: () -> Void
    let onToggleNw: () -> Void
    let onInspect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var balanceHover = false

    private var account: FinancialAccount { item.account }
    private var isLiability: Bool { account.classification == .liability }

    private var classIcon: String {
        switch account.classification {
        case .liquid: return "building.columns"
        case .retirement: return "shield"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .fixedAsset: return "house"
        case .liability: return "creditcard"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                topRow
                balance.padding(.top, 4)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(hovering ? Zen.ink3.opacity(0.6) : Zen.line, lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hexString: account.color))
                    .frame(width: 32, height: 32)
                    .overlay { ZIcon(classIcon, size: 16, weight: .regular).foregroundStyle(.white) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.zen(14, .medium)).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.tail)
                    if account.institution?.isEmpty == false || account.accountNumberMasked?.isEmpty == false {
                        HStack(spacing: 6) {
                            if let inst = account.institution, !inst.isEmpty {
                                HStack(spacing: 4) {
                                    ZIcon("building.2", size: 12)
                                    Text(inst).lineLimit(1)
                                }
                            }
                            if let masked = account.accountNumberMasked, !masked.isEmpty {
                                Text("· \(masked)").font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            }
                        }
                        .font(.zen(11))
                        .foregroundStyle(Zen.ink3)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(account.typeBadgeLabel)
                    .font(.zen(10, .medium)).foregroundStyle(Zen.ink2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                Text(account.mode == .freelancer ? "BIZ" : "HOME")
                    .font(.zen(10, .medium))
                    .foregroundStyle(account.mode == .freelancer ? Zen.indigo : Zen.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(account.mode == .freelancer ? Zen.indigo.opacity(0.15) : Zen.raised,
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .fixedSize()
        }
    }

    private var balance: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isLiability ? "CURRENT DEBT BALANCE" : "CURRENT ACCOUNT BALANCE")
                .font(.zen(10)).tracking(0.5).foregroundStyle(Zen.ink3)
            if isEditing {
                BalanceEditor(initial: item.liveBalance, onCommit: onCommit, onCancel: onCancel)
                    .padding(.top, 2)
            } else {
                Button(action: onStartEdit) {
                    Text("\(isLiability && item.liveBalance > 0 ? "-" : "")\(KobanFormat.currency(abs(item.liveBalance), code: currency))")
                        .font(.zen(20, .semibold))
                        .monospacedDigit()
                        .underline(balanceHover)
                        .foregroundStyle(isLiability ? Zen.accent : (item.liveBalance >= 0 ? Zen.ink : Zen.accent))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .onHover { balanceHover = $0 }
                .help("Click to update or reconcile balance")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                AutoTrackPill(isAuto: account.autoTrackTransactions, action: onToggleAuto)
                if item.txCount > 0 {
                    TxCountButton(count: item.txCount, delta: item.txNetDelta, action: onInspect)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                AccCheckbox(isOn: account.includeInNetWorth, label: "NW", fontSize: 11, color: Zen.ink3,
                            hoverColor: Zen.ink2, gap: 4, toggle: onToggleNw)
                    .help("Include this account in Net Worth calculation")
                AccHoverIcon(icon: "trash", size: 14, padding: 4, hoverBackground: Zen.raised, help: "Delete Account",
                             action: onDelete)
            }
        }
        .font(.zen(11))
        .padding(.top, 10)
        .accTopHairline()
    }
}

private struct AutoTrackPill: View {
    let isAuto: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZIcon("arrow.clockwise", size: 10, weight: .regular)
                Text(isAuto ? "Auto-Tx" : "Manual").font(.zen(11))
            }
            .foregroundStyle(isAuto ? Zen.positive : (hovering ? Zen.ink2 : Zen.ink3))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(isAuto ? Zen.positive.opacity(0.1) : Zen.app, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isAuto ? Zen.positive.opacity(0.3) : Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isAuto ? "Balance auto-updates from linked transactions (click to switch to manual valuation)"
                     : "Manual valuation mode (click to auto-track from transactions)")
    }
}

private struct TxCountButton: View {
    let count: Int
    let delta: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZIcon("receipt", size: 12).foregroundStyle(Zen.ink3)
                Text("\(count) tx (\(delta >= 0 ? "+" : "")\(KobanFormat.number(delta)))")
                    .font(.zen(11)).monospacedDigit()
                    .foregroundStyle(hovering ? Zen.ink : Zen.ink2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("View transactions for this account")
    }
}

/// Inline balance input (autoFocus, Enter/blur commits, Escape cancels).
private struct BalanceEditor: View {
    let initial: Double
    let onCommit: (Double?) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.zen(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(Zen.ink)
                .padding(.horizontal, 10)
                .frame(width: 160, height: 32)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.ink, lineWidth: 1))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
            Button(action: commit) {
                ZIcon("checkmark", size: 14, weight: .regular)
            }
            .buttonStyle(.zen(.ink, height: 32, padding: 10))
        }
        .onAppear {
            text = AccountsJS.string(initial)
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        onCommit(AccountsJS.parseLooseAmount(text))
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}

/// Icon button with hover tint (+ optional hover background), e.g. `text-ink-3 hover:text-accent`.
struct AccHoverIcon: View {
    let icon: String
    var size: CGFloat = 14
    var padding: CGFloat = 0
    var tint: Color = Zen.ink3
    var hoverTint: Color = Zen.accent
    var hoverBackground: Color? = nil
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon(icon, size: size, weight: .regular)
                .foregroundStyle(hovering ? hoverTint : tint)
                .padding(padding)
                .background(hovering ? (hoverBackground ?? .clear) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
