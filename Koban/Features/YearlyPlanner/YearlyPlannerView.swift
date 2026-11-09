import SwiftUI

/// Port of src/components/YearlyBudgetPlannerView.tsx — Yearly Budget & Account Forecast Planner.
struct YearlyPlannerView: View {
    @Environment(LedgerStore.self) private var store

    enum KindFilter: String, CaseIterable { case all, income, expense, savings }

    @State private var planningYear: Int?
    @State private var filterKind: KindFilter = .all
    @State private var hideUnplannedRows = false
    @State private var contentWidth: CGFloat = 1000
    /// Click-to-edit Mo / Year cells with Tab navigation (see EditFocus).
    @State private var editFocus = EditFocus()

    // Quick-add form (initialised once on appear, like React's useState initialisers).
    @State private var didInitForm = false
    @State private var quickLabel = ""
    @State private var quickGroupId = ""
    @State private var quickAmount = ""
    @State private var quickSchedule: YearlyPlanSchedule = .annualLump
    @State private var quickAccountId = ""
    @State private var quickDestAccountId = ""

    init() {}

    // MARK: Derived data

    private var state: LedgerState { store.state }
    private var workspace: ActiveWorkspace { state.settings.activeWorkspace }
    private var currency: String { state.settings.currency }
    private var year: Int { planningYear ?? state.settings.activeYear + 1 }

    private func cur(_ v: Double) -> String { KobanFormat.currency(v, code: currency) }

    private var visibleAccounts: [AccountComputedItem] {
        state.accounts.filter { workspace.includes($0.mode) }.map { $0.liveBalance(transactions: state.transactions) }
    }

    private func defaultLiquidAccountId(_ accounts: [AccountComputedItem]) -> String {
        accounts.first { $0.account.type == .checking || $0.account.type == .businessBank }?.account.id
            ?? accounts.first { $0.account.classification == .liquid }?.account.id ?? ""
    }

    private func defaultInvestmentAccountId(_ accounts: [AccountComputedItem]) -> String {
        accounts.first { $0.account.classification == .investment || $0.account.classification == .retirement }?
            .account.id ?? ""
    }

    private var yearPlanItems: [YearlyPlanItem] {
        (state.yearlyPlanItems ?? []).filter { $0.year == year && workspace.includes($0.mode) }
    }

    // MARK: Body

    var body: some View {
        let accounts = visibleAccounts
        let items = yearPlanItems
        let projections = YearlyPlanner.projections(accounts: accounts, items: items)
        let totals = YearlyPlanner.totals(items: items, projections: projections)
        let planByCategory = Dictionary(items.map { ($0.categoryId, $0) }, uniquingKeysWith: { _, last in last })
        let lg = contentWidth >= 720
        let md = contentWidth >= 470

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(items: items)
                kpiStrip(totals: totals, accountCount: accounts.count, lg: lg)
                standingSection(projections: projections, totals: totals, columns: lg ? 3 : (md ? 2 : 1))
                quickAddSection(accounts: accounts).id("yp-quick")
                categoryTable(accounts: accounts, planByCategory: planByCategory).id("yp-table")
            }
            .padding(24)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 - 48 }
        }
        .scrollContentBackground(.hidden)
        .environment(editFocus)
        .onAppear {
            initFormIfNeeded()
            editFocus.onMove = { cellID in
                let rowID = String(cellID.prefix(while: { $0 != "#" }))
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rowID) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            switch note.userInfo?["name"] as? String {
            case "yearly_seed": seedFromCurrentBudget()
            case "yearly_preset_etf": applyPreset(.etf)
            case "yearly_preset_retirement": applyPreset(.retirement)
            case "yearly_filter_savings": filterKind = .savings
            case "yearly_hide_unplanned": hideUnplannedRows = true
            default: break
            }
            if let scroll = ProcessInfo.processInfo.environment["KOBAN_SNAPSHOT_YP_SCROLL"], !scroll.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    proxy.scrollTo(scroll, anchor: .top)
                }
            }
        }
        }
    }

    // MARK: Header & year picker

    @ViewBuilder
    private func header(items: [YearlyPlanItem]) -> some View {
        let titleBlock = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text("Yearly Budget & Account Forecast Planner")
                    .font(.zen(20)).foregroundStyle(Zen.ink).tracking(-0.3)
                Text(verbatim: "Planning \(year)")
                    .font(.zen(12, .semibold)).monospacedDigit()
                    .foregroundStyle(Zen.indigo)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Zen.indigo.opacity(0.15), in: Capsule())
            }
            Text("Pre-plan next year's income, major expenses (e.g. tuition fees), and investment allocations mapped directly to your accounts.")
                .font(.zen(12)).foregroundStyle(Zen.ink2)
        }

        let controls = FlowLayout(spacing: 8) {
            yearSelector
            Button(action: seedFromCurrentBudget) {
                HStack(spacing: 6) {
                    ZIcon("sparkles", size: 14).foregroundStyle(Zen.indigo)
                    Text("Seed from Current Monthly × 12")
                }
            }
            .buttonStyle(.zenOutline)
            .help("Pre-fill yearly amounts from your current monthly budget × 12 and active recurring items")

            Button {
                store.applyYearlyPlanToMonthlyBudgets(year: year, items: items)
            } label: {
                HStack(spacing: 6) {
                    ZIcon("checkmark.rectangle.stack", size: 14)
                    Text(verbatim: "Apply Plan to \(year) Monthly Worksheets").fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 14))
            .help("Write planned monthly amounts into all 12 monthly worksheets of \(String(year))")
        }

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                titleBlock.fixedSize()
                Spacer(minLength: 0)
                controls.fixedSize()
            }
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                controls
            }
        }
    }

    private var yearSelector: some View {
        let active = state.settings.activeYear
        return HStack(spacing: 4) {
            ForEach([active, active + 1, active + 2, active + 3], id: \.self) { yr in
                YPYearPill(title: "\(yr)\(yr == active + 1 ? " (Next Yr)" : "")", active: year == yr) {
                    planningYear = yr
                }
            }
        }
        .padding(4)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: KPI strip

    private struct KPI: Identifiable {
        let id: Int
        let title: String
        let value: String
        let valueColor: Color
        let footnote: String
        let footColor: Color
    }

    @ViewBuilder
    private func kpiStrip(totals t: YearlyPlanTotals, accountCount: Int, lg: Bool) -> some View {
        let y = String(year)
        let kpis = [
            KPI(id: 0, title: "Current Account Standing", value: cur(t.currentNetWorthStanding), valueColor: Zen.ink,
                footnote: "Across \(accountCount) active account(s)", footColor: Zen.ink2),
            KPI(id: 1, title: "\(y) Planned Income", value: "+" + cur(t.plannedIncome), valueColor: Zen.positive,
                footnote: "\(cur(t.plannedIncome / 12)) / month avg", footColor: Zen.ink2),
            KPI(id: 2, title: "\(y) Planned Outflows", value: "-" + cur(t.plannedExpenses), valueColor: Zen.accent,
                footnote: "\(cur(t.plannedExpenses / 12)) / month avg", footColor: Zen.ink2),
            KPI(id: 3, title: "Planned Investments & Est. Yield", value: "+" + cur(t.plannedSavingsAndInvestments),
                valueColor: Zen.indigo,
                footnote: "+\(cur(t.estimatedInvestmentGrowth)) est. return in \(y)", footColor: Zen.positive),
            KPI(id: 4, title: "Est. End of \(y) Standing", value: cur(t.projectedYearEndNetWorth),
                valueColor: t.projectedYearEndNetWorth >= t.currentNetWorthStanding ? Zen.positive : Zen.accent,
                footnote: "5-Yr Est.: \(cur(t.projectedFiveYearNetWorth))", footColor: Zen.ink2),
        ]
        YPGrid(items: kpis, columns: lg ? 5 : 2, spacing: 12) { kpi in
            VStack(alignment: .leading, spacing: 0) {
                Text(kpi.title.uppercased())
                    .font(.zen(11)).tracking(0.6).foregroundStyle(Zen.ink3)
                Text(kpi.value)
                    .font(.zen(18, .semibold)).monospacedDigit().foregroundStyle(kpi.valueColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.top, 4)
                Text(kpi.footnote)
                    .font(.zen(11)).monospacedDigit().foregroundStyle(kpi.footColor)
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        }
    }

    // MARK: Section 1 — account standing & projections

    @ViewBuilder
    private func standingSection(projections: [YearlyAccountProjection], totals: YearlyPlanTotals, columns: Int) -> some View {
        let y = String(year)
        let titleBlock = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ZIcon("building.columns", size: 16).foregroundStyle(Zen.indigo)
                Text("Current Standing of All Accounts & \(y) End-of-Year Estimates")
                    .font(.zen(14, .semibold)).foregroundStyle(Zen.ink)
            }
            Text("Shows each account's current balance, planned inflows/outflows assigned to it, expected annual return %, and projected end-of-\(y) standing.")
                .font(.zen(12)).foregroundStyle(Zen.ink2)
        }
        let unallocated = totals.unallocatedCashflow
        let pill = HStack(spacing: 6) {
            Text("Unallocated Annual Cashflow:").foregroundStyle(Zen.ink3)
            Text((unallocated >= 0 ? "+" : "") + cur(unallocated))
                .fontWeight(.semibold)
                .foregroundStyle(unallocated >= 0 ? Zen.positive : Zen.accent)
        }
        .font(.zen(12)).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    titleBlock.fixedSize()
                    Spacer(minLength: 0)
                    if unallocated != 0 { pill.fixedSize() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleBlock
                    if unallocated != 0 { pill.fixedSize() }
                }
            }

            YPGrid(items: projections, columns: columns, spacing: 14) { proj in
                YPAccountCard(proj: proj, year: year, currency: currency) { pct in
                    store.setYearlyPlannerReturnRate(accountId: proj.account.id, returnPct: pct)
                }
            }
        }
        .zenCard(padding: 20)
    }

    // MARK: Section 2 — quick add

    enum Preset { case tuition, etf, retirement }

    private func initFormIfNeeded() {
        guard !didInitForm else { return }
        didInitForm = true
        let accounts = visibleAccounts
        quickGroupId = state.groups.first { $0.id == "home-grp-obligations" }?.id
            ?? state.groups.first { $0.kind == .expense }?.id
            ?? state.groups.first?.id ?? ""
        quickAccountId = defaultLiquidAccountId(accounts)
        quickDestAccountId = defaultInvestmentAccountId(accounts)
    }

    private func applyPreset(_ preset: Preset) {
        let accounts = visibleAccounts
        let liquid = defaultLiquidAccountId(accounts)
        switch preset {
        case .tuition:
            if let g = state.groups.first(where: { $0.id == "home-grp-obligations" })
                ?? state.groups.first(where: { $0.kind == .expense }) { quickGroupId = g.id }
            quickLabel = "Tuition Fees"
            quickSchedule = .annualLump
            quickAmount = "11000"
            quickAccountId = liquid
        case .etf:
            if let g = state.groups.first(where: { $0.id == "home-grp-savings" })
                ?? state.groups.first(where: { $0.kind == .savings }) { quickGroupId = g.id }
            quickLabel = "Global ETF Portfolio Allocation"
            quickSchedule = .monthly
            quickAmount = "1000"
            quickAccountId = liquid
            quickDestAccountId = defaultInvestmentAccountId(accounts)
        case .retirement:
            if let g = state.groups.first(where: { $0.id == "home-grp-savings" })
                ?? state.groups.first(where: { $0.kind == .savings }) { quickGroupId = g.id }
            quickLabel = "Pillar 3a / IRA Retirement Contribution"
            quickSchedule = .annualLump
            quickAmount = "7056"
            quickAccountId = liquid
            if let ret = accounts.first(where: { $0.account.classification == .retirement }) {
                quickDestAccountId = ret.account.id
            }
        }
    }

    private func submitQuickAdd() {
        let label = quickLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let raw = NumberParsing.parse(quickAmount), raw > 0 else { return }
        guard let grp = state.groups.first(where: { $0.id == quickGroupId })
                ?? state.groups.first(where: { workspace.includes($0.mode) })
                ?? state.groups.first else { return }
        let annual = quickSchedule == .monthly ? raw * 12 : raw
        store.addCategoryAndPlanItem(YearlyPlanNewItemRequest(
            year: year, groupId: grp.id, mode: grp.mode, kind: grp.kind, label: label,
            annualAmount: annual, schedule: quickSchedule,
            accountId: quickAccountId.isEmpty ? nil : quickAccountId,
            destinationAccountId: grp.kind == .savings && !quickDestAccountId.isEmpty ? quickDestAccountId : nil))
        quickLabel = ""
        quickAmount = ""
    }

    @ViewBuilder
    private func quickAddSection(accounts: [AccountComputedItem]) -> some View {
        let y = String(year)
        let selectedGroup = state.groups.first { $0.id == quickGroupId }
        let titleBlock = VStack(alignment: .leading, spacing: 2) {
            Text("Plan a Specific \(y) Expense, Tuition Fee, or Investment Allocation".uppercased())
                .font(.zen(12, .semibold)).tracking(0.6).foregroundStyle(Zen.ink)
            Text("Add a planned yearly item (like $11,000 in tuition fees) and pick which account it corresponds to.")
                .font(.zen(11)).foregroundStyle(Zen.ink2)
        }
        let presets = HStack(spacing: 6) {
            Text("Quick Fill:").font(.zen(11)).foregroundStyle(Zen.ink3)
            presetButton("graduationcap", tint: Zen.accent, "Tuition Fees (11,000)") { applyPreset(.tuition) }
            presetButton("chart.line.uptrend.xyaxis", tint: Zen.indigo, "ETF Investment (1,000/mo)") { applyPreset(.etf) }
            presetButton("shield", tint: Zen.positive, "Retirement 3a / IRA (7,056)") { applyPreset(.retirement) }
        }

        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    titleBlock.fixedSize()
                    Spacer(minLength: 0)
                    presets.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleBlock
                    FlowLayout(spacing: 6) { presets }
                }
            }

            YPFlexWrap(spacing: 12, alignment: .bottom) {
                formField("Planned Item / Category Name") {
                    TextField("", text: $quickLabel,
                              prompt: Text("e.g. Tuition Fees, ETF Allocation, Roof Repair").foregroundStyle(Zen.ink3))
                        .zenField(fontSize: 12)
                        .onSubmit(submitQuickAdd)
                }
                .ypFlex(grow: 2, basis: 190)

                formField("Budget Group") {
                    YPSelect(options: state.groups.filter { workspace.includes($0.mode) }
                                .map { ($0.id, "\($0.name) (\($0.kind.rawValue))") },
                             selection: quickGroupId, fullWidth: true) { quickGroupId = $0 }
                }
                .ypFlex(grow: 1, basis: 160)

                formField("Schedule") {
                    YPSelect(options: [(YearlyPlanSchedule.annualLump.rawValue, "Annual Total (\(y))"),
                                       (YearlyPlanSchedule.monthly.rawValue, "Monthly × 12")],
                             selection: quickSchedule.rawValue, fullWidth: true) {
                        quickSchedule = YearlyPlanSchedule(rawValue: $0) ?? .annualLump
                    }
                }
                .ypFlex(grow: 1, basis: 125)

                formField(quickSchedule == .monthly ? "Monthly (\(currency))" : "Annual (\(currency))") {
                    TextField("", text: $quickAmount, prompt: Text("11000").foregroundStyle(Zen.ink3))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .zenField(fontSize: 12)
                        .onSubmit(submitQuickAdd)
                }
                .ypFlex(grow: 1, basis: 115)

                formField(selectedGroup?.kind == .income ? "Deposit Into Account"
                          : selectedGroup?.kind == .savings ? "Source Bank Account (From)"
                          : "Corresponds to Account (Paid From)") {
                    YPSelect(options: [("", "Unassigned Account")]
                                + accounts.map { ($0.account.id, "\($0.account.name) (\(cur($0.liveBalance)))") },
                             selection: quickAccountId, fullWidth: true) { quickAccountId = $0 }
                }
                .ypFlex(grow: 2, basis: 200)

                if selectedGroup?.kind == .savings {
                    formField("Destination Investment / Savings Account (To)", labelColor: Zen.indigo, labelWeight: .medium) {
                        YPSelect(options: [("", "Select destination account…")]
                                    + accounts.map {
                                        ($0.account.id, "\($0.account.name) (\(YearlyPlanner.jsNumber(YearlyPlanner.returnRate($0.account)))% p.a.)")
                                    },
                                 selection: quickDestAccountId, border: Zen.indigo.opacity(0.4), fullWidth: true) {
                            quickDestAccountId = $0
                        }
                    }
                    .ypFlex(grow: 2, basis: 200)
                }

                Button(action: submitQuickAdd) {
                    HStack(spacing: 6) {
                        ZIcon("plus", size: 14)
                        Text(verbatim: "Add to \(year) Plan").fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, padding: 16))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .zenCard(padding: 16)
    }

    private func presetButton(_ icon: String, tint: Color, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZIcon(icon, size: 12).foregroundStyle(tint)
                Text(title)
            }
        }
        .buttonStyle(YPPresetStyle())
    }

    private func formField<Content: View>(_ label: String, labelColor: Color = Zen.ink2,
                                          labelWeight: Font.Weight = .regular,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zen(11, labelWeight)).foregroundStyle(labelColor).lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Section 3 — category table

    @ViewBuilder
    private func categoryTable(accounts: [AccountComputedItem], planByCategory: [String: YearlyPlanItem]) -> some View {
        let groups = state.groups
            .filter { workspace.includes($0.mode) }
            .filter { filterKind == .all || $0.kind.rawValue == filterKind.rawValue }
            .sorted { $0.order < $1.order }
        let categories = state.categories.filter { workspace.includes($0.mode) }
        // Tab order: rows top to bottom, Mo → Year within a row (same filtering as the table).
        let _ = editFocus.order = groups.flatMap { grp in
            categories.filter { $0.groupId == grp.id }.sorted { $0.order < $1.order }
                .filter { !hideUnplannedRows || (planByCategory[$0.id]?.annualAmount ?? 0) > 0 }
                .flatMap { ["\($0.id)#mo", "\($0.id)#yr"] }
        }
        let filters: [(KindFilter, String)] = [(.all, "All Categories"), (.income, "Income"),
                                               (.expense, "Expenses & Obligations"),
                                               (.savings, "Savings & Investments")]
        let tabs = HStack(spacing: 6) {
            ForEach(filters, id: \.0) { k, label in
                Button { filterKind = k } label: {
                    Text(label).fontWeight(filterKind == k ? .medium : .regular)
                }
                .buttonStyle(.zen(filterKind == k ? .ink : .outline, height: 28, padding: 12))
            }
        }
        let checkbox = ZenCheckbox(isOn: $hideUnplannedRows,
                                   label: "Show only categories with planned \(String(year)) amounts")

        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tabs.fixedSize()
                    Spacer(minLength: 0)
                    checkbox.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6) { tabs }
                    checkbox
                }
            }

            // Lazy per row: the group cards are flattened into header + row items so only the rows
            // on screen (each with its menus and number fields) are built. Each item draws its own
            // slice of the card outline.
            let sections: [(CategoryGroup, [CategoryItem])] = groups.compactMap { grp in
                let grpCategories = categories.filter { $0.groupId == grp.id }.sorted { $0.order < $1.order }
                let rows = hideUnplannedRows
                    ? grpCategories.filter { (planByCategory[$0.id]?.annualAmount ?? 0) > 0 }
                    : grpCategories
                return rows.isEmpty ? nil : (grp, rows)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.0.id) { sIdx, section in
                    let (grp, rows) = section
                    groupHeader(grp, rows: rows, planByCategory: planByCategory)
                        .background(Zen.raised.opacity(0.7))
                        .background(Zen.surface)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                        .overlay(CardSlice(top: true, bottom: false).stroke(Zen.line, lineWidth: 1))
                        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
                        .padding(.top, sIdx == 0 ? 0 : 16)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, cat in
                        let last = idx == rows.count - 1
                        YPCategoryRow(cat: cat, plan: planByCategory[cat.id], year: year, currency: currency,
                                      accounts: accounts,
                                      onUpdate: { patch in updateCategoryPlan(cat, accounts: accounts, planByCategory: planByCategory, patch) },
                                      onDelete: { store.deleteYearlyPlanItem(id: planByCategory[cat.id]?.id ?? "yp-\(year)-\(cat.id)") })
                            .background(Zen.surface)
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: last ? 12 : 0,
                                                              bottomTrailingRadius: last ? 12 : 0))
                            .overlay(alignment: .top) {
                                if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1).padding(.horizontal, 1) }
                            }
                            .overlay(CardSlice(top: false, bottom: last).stroke(Zen.line, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func groupHeader(_ grp: CategoryGroup, rows: [CategoryItem],
                             planByCategory: [String: YearlyPlanItem]) -> some View {
        let total = rows.reduce(0) { $0 + (planByCategory[$1.id]?.annualAmount ?? 0) }
        return HStack(spacing: 8) {
            Circle().fill(Color(hexString: grp.color)).frame(width: 10, height: 10)
            Text(grp.name.uppercased()).font(.zen(12, .semibold)).tracking(0.6).foregroundStyle(Zen.ink)
            Text(grp.kind.rawValue.uppercased())
                .font(.zen(10)).foregroundStyle(Zen.ink3)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
            Spacer(minLength: 8)
            HStack(spacing: 16) {
                (Text("Monthly Avg: ").foregroundStyle(Zen.ink2)
                 + Text(cur(total / 12)).fontWeight(.bold).foregroundStyle(Zen.ink))
                (Text(verbatim: "\(year) Total: ").foregroundStyle(Zen.ink2)
                 + Text(cur(total)).fontWeight(.bold).foregroundStyle(Zen.ink))
            }
            .font(.zen(12)).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func updateCategoryPlan(_ cat: CategoryItem, accounts: [AccountComputedItem],
                                    planByCategory: [String: YearlyPlanItem], _ patch: (inout YearlyPlanItem) -> Void) {
        let liquid = defaultLiquidAccountId(accounts)
        let investment = defaultInvestmentAccountId(accounts)
        var item = planByCategory[cat.id] ?? YearlyPlanItem(
            id: "yp-\(year)-\(cat.id)", year: year, mode: cat.mode, categoryId: cat.id, label: cat.name,
            kind: cat.kind, annualAmount: 0, schedule: cat.isRecurring == true ? .monthly : .annualLump,
            accountId: liquid.isEmpty ? nil : liquid,
            destinationAccountId: cat.kind == .savings && !investment.isEmpty ? investment : nil)
        patch(&item)
        store.upsertYearlyPlanItem(item)
    }

    // MARK: Seed

    private func seedFromCurrentBudget() {
        store.bulkSetYearlyPlan(year: year, items: YearlyPlanner.seedItems(state: state, year: year))
    }
}

// MARK: - Account card

private struct YPAccountCard: View {
    let proj: YearlyAccountProjection
    let year: Int
    let currency: String
    let onRateChange: (Double) -> Void

    private func cur(_ v: Double) -> String { KobanFormat.currency(v, code: currency) }

    var body: some View {
        let acc = proj.account
        let meta = KobanTemplates.accountType(acc.type)
        let typeLabel = (acc.customTypeLabel?.isEmpty == false ? acc.customTypeLabel! : meta.shortLabel)
            + ((acc.institution?.isEmpty == false) ? " · \(acc.institution!)" : "")

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hexString: acc.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(acc.name).font(.zen(12, .semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                            Text(typeLabel).font(.zen(10)).foregroundStyle(Zen.ink3).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !proj.isLiability {
                        HStack(spacing: 4) {
                            ZIcon("chart.line.uptrend.xyaxis", size: 12, weight: .regular).foregroundStyle(Zen.positive)
                            YPNumberField(value: proj.returnRatePct,
                                          display: { YearlyPlanner.jsNumber($0) },
                                          placeholder: "", width: 36, height: 16, fontSize: 11, weight: .medium,
                                          textColor: Zen.ink, chrome: false, onChange: onRateChange)
                            Text("% p.a.").font(.zen(10)).foregroundStyle(Zen.ink3)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Zen.line, lineWidth: 1))
                        .fixedSize()
                        .help("Expected annual investment return or interest yield %")
                    }
                }

                VStack(spacing: 4) {
                    line("Current Standing:", cur(proj.currentStanding), size: 12, labelColor: Zen.ink2,
                         valueColor: Zen.ink)
                    if proj.plannedInflows > 0 {
                        line("Planned Inflows / Contributions:", "+" + cur(proj.plannedInflows), valueColor: Zen.positive)
                    }
                    if proj.plannedOutflows > 0 {
                        line("Planned Outflows / Expenses:", "-" + cur(proj.plannedOutflows), valueColor: Zen.accent)
                    }
                    if proj.estimatedReturn > 0 {
                        line("Est. \(String(year)) Growth (\(YearlyPlanner.jsNumber(proj.returnRatePct))%):",
                             "+" + cur(proj.estimatedReturn), valueColor: Zen.indigo)
                    }
                }
                .padding(.top, 4)
                .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }

                if !proj.linkedItems.isEmpty {
                    YPFlexWrap(spacing: 4) {
                        ForEach(Array(proj.linkedItems.prefix(4).enumerated()), id: \.offset) { _, li in
                            let isIn = li.direction == .inflow
                            Text("\(li.label): \(isIn ? "+" : "-")\(KobanFormat.number(li.amount))")
                                .font(.zen(10)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(isIn ? Zen.positive : Zen.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((isIn ? Zen.positive : Zen.accent).opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        if proj.linkedItems.count > 4 {
                            Text("+\(proj.linkedItems.count - 4) more")
                                .font(.zen(10)).foregroundStyle(Zen.ink3)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "EST. DEC 31, \(year)").font(.zen(10)).tracking(0.5).foregroundStyle(Zen.ink3)
                    Text(cur(proj.projectedEndBalance))
                        .font(.zen(14, .semibold)).monospacedDigit()
                        .foregroundStyle(proj.isShortfall ? Zen.accent
                                         : proj.projectedEndBalance > proj.currentStanding ? Zen.positive : Zen.ink)
                }
                Spacer(minLength: 0)
                if proj.isShortfall {
                    HStack(spacing: 4) {
                        ZIcon("exclamationmark.triangle", size: 12, weight: .regular)
                        Text("Shortfall").font(.zen(10, .medium))
                    }
                    .foregroundStyle(Zen.accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Zen.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                } else if proj.isInvestmentOrRetirement && proj.fiveYearEstimate > proj.projectedEndBalance {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("5-Yr Compounded").font(.zen(10)).foregroundStyle(Zen.ink3)
                        Text(cur(proj.fiveYearEstimate)).font(.zen(12, .medium)).monospacedDigit()
                            .foregroundStyle(Zen.indigo)
                    }
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.7)).frame(height: 1) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(proj.isShortfall ? Zen.accent.opacity(0.05) : Zen.app.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(proj.isShortfall ? Zen.accent.opacity(0.6) : Zen.line, lineWidth: 1))
    }

    private func line(_ label: String, _ value: String, size: CGFloat = 11, labelColor: Color = Zen.ink3,
                      valueColor: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(labelColor).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).monospacedDigit().foregroundStyle(valueColor).lineLimit(1)
        }
        .font(.zen(size))
    }
}

// MARK: - Category row

private struct YPCategoryRow: View {
    let cat: CategoryItem
    let plan: YearlyPlanItem?
    let year: Int
    let currency: String
    let accounts: [AccountComputedItem]
    let onUpdate: ((inout YearlyPlanItem) -> Void) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let annual = plan?.annualAmount ?? 0
        let monthly = annual / 12
        let schedule = plan?.schedule ?? (cat.isRecurring == true ? .monthly : .annualLump)
        let linkedId = plan?.accountId ?? ""
        let destId = plan?.destinationAccountId ?? ""
        let lookupId = destId.isEmpty ? linkedId : destId
        let destAcc = accounts.first { $0.account.id == lookupId }?.account
        let destRate = destAcc.map(YearlyPlanner.returnRate) ?? 0
        let growth = YearlyPlanner.allocationGrowth(kind: cat.kind, annualAmount: annual, rate: destRate)

        let left = leftBlock(annual: annual, destAcc: destAcc, destRate: destRate, growth: growth)
        let right = controls(annual: annual, monthly: monthly, schedule: schedule, linkedId: linkedId, destId: destId)

        // flex-wrap: left is `min-w-[180px] flex-1`, controls `shrink-0` — controls drop below
        // only when the row can't fit 180 px + controls. Decided in one layout pass (no @State).
        YPRowLayout {
            left
            FlowLayout(spacing: 10) { right }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hovering ? Zen.raised.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func leftBlock(annual: Double, destAcc: FinancialAccount?, destRate: Double,
                           growth: (yr1Gain: Double, yr5Value: Double)) -> some View {
        let name = HStack(spacing: 8) {
            Text(cat.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
            if cat.isRecurring == true {
                Text("Recurring").font(.zen(10)).foregroundStyle(Zen.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Zen.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        if cat.kind == .savings && annual > 0 && destAcc != nil {
            let cur = { (v: Double) in KobanFormat.currency(v, code: currency) }
            let badge = HStack(alignment: .top, spacing: 4) {
                ZIcon("chart.line.uptrend.xyaxis", size: 12, weight: .regular)
                Text("Est. +\(cur(growth.yr1Gain)) yield in \(String(year)) · 5-Yr Value: \(cur(growth.yr5Value)) (\(YearlyPlanner.jsNumber(destRate))% p.a.)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.zen(10, .medium)).monospacedDigit()
            .foregroundStyle(Zen.positive)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Zen.positive.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { name; badge.fixedSize() }
                VStack(alignment: .leading, spacing: 6) { name; badge }
            }
        } else {
            name
        }
    }

    @ViewBuilder
    private func controls(annual: Double, monthly: Double, schedule: YearlyPlanSchedule,
                          linkedId: String, destId: String) -> some View {
        YPSelect(options: [(YearlyPlanSchedule.monthly.rawValue, "Monthly × 12"),
                           (YearlyPlanSchedule.annualLump.rawValue, "Annual Total")],
                 selection: schedule.rawValue, height: 28, fontSize: 11, radius: 4, textColor: Zen.ink2,
                 help: "Planning schedule") { v in
            onUpdate { $0.schedule = YearlyPlanSchedule(rawValue: v) ?? .monthly }
        }

        HStack(spacing: 4) {
            Text("Mo:").font(.zen(10)).foregroundStyle(Zen.ink3)
            YPNumberField(value: monthly, width: 80, help: "Planned monthly equivalent", cellID: "\(cat.id)#mo") { m in
                onUpdate { $0.annualAmount = m * 12; $0.schedule = .monthly }
            }
        }

        HStack(spacing: 4) {
            Text("Year (\(currency)):").font(.zen(10, .medium)).foregroundStyle(Zen.ink3)
            YPNumberField(value: annual, width: 96, weight: .semibold, textColor: Zen.ink,
                          background: Zen.surface, focusBorder: Zen.ink,
                          help: "Total planned amount for \(String(year))", cellID: "\(cat.id)#yr") { v in
                onUpdate { $0.annualAmount = v }
            }
        }

        YPSelect(options: [("", cat.kind == .income ? "Deposit Account…"
                                : cat.kind == .savings ? "From Account…" : "Corresponds to Account…")]
                    + accounts.map { ($0.account.id, "\($0.account.name) (\(KobanFormat.number($0.liveBalance)))") },
                 selection: linkedId, height: 28, fontSize: 11, radius: 4, maxWidth: 190,
                 help: cat.kind == .income ? "Account where this planned income is deposited"
                    : cat.kind == .savings ? "Source bank account funding this contribution"
                    : "Account this planned expense corresponds to") { v in
            onUpdate { $0.accountId = v.isEmpty ? nil : v }
        }

        if cat.kind == .savings {
            HStack(spacing: 4) {
                ZIcon("arrow.right", size: 12, weight: .regular).foregroundStyle(Zen.indigo)
                YPSelect(options: [("", "Into Investment / Savings…")]
                            + accounts.map {
                                ($0.account.id, "\($0.account.name) (\(YearlyPlanner.jsNumber(YearlyPlanner.returnRate($0.account)))% p.a.)")
                            },
                         selection: destId, height: 28, fontSize: 11, radius: 4,
                         background: Zen.indigo.opacity(0.1), border: Zen.indigo.opacity(0.3), maxWidth: 190,
                         help: "Destination investment, retirement, or savings account where the money goes") { v in
                    onUpdate { $0.destinationAccountId = v.isEmpty ? nil : v }
                }
            }
        }

        if annual > 0 {
            ZenMiniButton(icon: "trash", size: 14, tint: Zen.ink3, hoverTint: Zen.accent,
                          help: "Clear planned amount", action: onDelete)
        }
    }
}

/// Left block (min 180 pt, flexible) beside the controls when they fit, else controls below it.
private struct YPRowLayout: Layout {
    let gap: CGFloat = 12
    let minLeft: CGFloat = 180

    private func sideBySide(_ width: CGFloat, _ controls: CGSize) -> Bool {
        width >= minLeft + gap + controls.width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 800
        let controls = subviews[1].sizeThatFits(.unspecified)
        if sideBySide(width, controls) {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: width - gap - controls.width, height: nil))
            return CGSize(width: width, height: max(left.height, controls.height))
        }
        let left = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let wrapped = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: left.height + gap + wrapped.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let controls = subviews[1].sizeThatFits(.unspecified)
        if sideBySide(bounds.width, controls) {
            let leftWidth = bounds.width - gap - controls.width
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: leftWidth, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - left.height / 2),
                              proposal: ProposedViewSize(width: leftWidth, height: left.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - controls.width, y: bounds.midY - controls.height / 2),
                              proposal: ProposedViewSize(controls))
        } else {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: left.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + left.height + gap),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// One slice of a rounded card outline: the side lines, plus the rounded top / bottom edge when
/// this slice starts / ends the card (lets a card's rows live in a LazyVStack).
struct CardSlice: Shape {
    let top: Bool
    let bottom: Bool
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var p = Path()
        if top {
            p.move(to: CGPoint(x: r.minX, y: bottom ? r.maxY - radius : rect.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: bottom ? r.maxY - radius : rect.maxY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: bottom ? r.maxY - radius : rect.maxY))
        }
        if bottom {
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX, y: top ? r.minY + radius : rect.minY))
        } else if !top {
            p.move(to: CGPoint(x: r.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: r.minX, y: rect.maxY))
        }
        return p
    }
}

// MARK: - Button styles

/// Year selector pill: px-3 py-1 rounded-lg, active bg-ink text-on-ink, else text-ink-2 hover:text-ink.
private struct YPYearPill: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.zen(12, active ? .medium : .regular)).monospacedDigit()
                .foregroundStyle(active ? Zen.onInk : (hovering ? Zen.ink : Zen.ink2))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(active ? Zen.ink : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// h-6 px-2 rounded-md bg-raised border border-line text-ink-2 hover:text-ink text-[11px]
private struct YPPresetStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PresetBody(configuration: configuration) }
    private struct PresetBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.zen(11))
                .foregroundStyle(hovering ? Zen.ink : Zen.ink2)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Zen.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Zen.line, lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
