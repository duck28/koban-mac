import SwiftUI

/// Port of src/components/RecurringView.tsx — recurring income, subscriptions & fixed costs.
struct RecurringView: View {
    @Environment(LedgerStore.self) private var store

    @State private var categoryId = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var dayOfMonth = "1"
    @State private var amountInvalid = false
    @FocusState private var amountFocused: Bool

    static let frequencyOptions: [(RecurrenceFrequency, String)] =
        [(.monthly, "Monthly"), (.quarterly, "Quarterly"), (.yearly, "Yearly")]

    var body: some View {
        let state = store.state
        let workspace = state.settings.activeWorkspace
        let monthKey = state.activeMonthKey
        let currency = state.settings.currency
        let visibleRules = state.recurringRules.filter { workspace.includes($0.mode) }
        let active = visibleRules.filter(\.active)
        let outflow = active.filter { $0.type == .expense }.reduce(0) { $0 + $1.monthlyEquivalent }
        let income = active.filter { $0.type == .income }.reduce(0) { $0 + $1.monthlyEquivalent }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(monthKey: monthKey)
                addForm(state: state, workspace: workspace, currency: currency)
                summary(outflow: outflow, income: income, activeCount: active.count,
                        total: visibleRules.count, currency: currency)
                rulesList(visibleRules, state: state, currency: currency)
            }
            .padding(24)
            .frame(maxWidth: 1152)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: ensureValidCategory)
        .onChange(of: workspace) { _, _ in ensureValidCategory() }
    }

    // MARK: Header

    private func header(monthKey: String) -> some View {
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("Recurring Income, Subscriptions & Fixed Costs")
                .font(.zen(20))
                .foregroundStyle(Zen.ink)
            Text("Automate fixed monthly wages, mortgage/rent, health insurance, SaaS subscriptions, and client retainers.")
                .font(.zen(12))
                .foregroundStyle(Zen.ink2)
        }
        let post = Button { store.applyRecurringToMonth() } label: {
            HStack(spacing: 8) {
                ZIcon("play", size: 14)
                Text("Post Active Recurring Items to \(monthKey)").fontWeight(.medium)
            }
        }
        .buttonStyle(.zen(.ink, height: 36, padding: 16))
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 12)
                post
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                post
            }
        }
    }

    // MARK: Add form

    private func addForm(state: LedgerState, workspace: ActiveWorkspace, currency: String) -> some View {
        let groups: [TxOptionGroup<String>] = state.groups
            .filter { workspace.includes($0.mode) }
            .map { grp in
                TxOptionGroup(label: grp.name,
                              options: state.categories
                                .filter { $0.groupId == grp.id && workspace.includes($0.mode) }
                                .map { ($0.id, $0.name) })
            }

        let category = TxField(label: "Category") {
            TxSelect(groups: groups, selection: $categoryId)
        }
        let desc = TxField(label: "Description / Subscription Name") {
            TextField("", text: $description, prompt: txPrompt("e.g. Wages, Mortgage/Rent, Health Insurance"))
                .txInput()
                .onSubmit(submit)
        }
        let amountField = TxField(label: "Amount (\(currency))") {
            TextField("", text: $amount, prompt: txPrompt("0.00"))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .txInput(invalid: amountInvalid)
                .focused($amountFocused)
                .onSubmit(submit)
                .onChange(of: amount) { _, _ in amountInvalid = false }
        }
        let freq = TxField(label: "Frequency") {
            TxSelect(options: Self.frequencyOptions, selection: $frequency)
        }
        let day = TxField(label: "Day (1–28)") {
            TextField("", text: $dayOfMonth)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .txInput(padding: 8)
                .help("Day of month")
                .onSubmit(submit)
        }
        .frame(width: 80)
        let add = Button(action: submit) {
            HStack(spacing: 6) {
                ZIcon("plus", size: 14)
                Text("Add Rule").fontWeight(.medium)
            }
        }
        .buttonStyle(.zen(.ink, padding: 16))
        .fixedSize()

        // flex-wrap with flex-[2_1_190px] / flex-[1_1_115px] items: one line when it fits.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                category.frame(minWidth: 170).layoutPriority(2)
                desc.frame(minWidth: 170).layoutPriority(2)
                amountField.frame(minWidth: 105, maxWidth: 160)
                freq.frame(minWidth: 105, maxWidth: 160)
                day
                add
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) { category; desc }
                HStack(alignment: .bottom, spacing: 12) { amountField; freq; day; add }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: Summary banner

    private func summary(outflow: Double, income: Double, activeCount: Int, total: Int,
                         currency: String) -> some View {
        HStack(spacing: 12) {
            FlowLayout(spacing: 16) {
                HStack(spacing: 8) {
                    ZIcon("repeat", size: 16).foregroundStyle(Zen.indigo)
                    (Text("Fixed Monthly Outflow: ").foregroundStyle(Zen.ink2)
                     + Text("\(KobanFormat.currency(outflow, code: currency))/mo")
                        .fontWeight(.bold).foregroundStyle(Zen.ink))
                        .monospacedDigit()
                }
                if income > 0 {
                    HStack(spacing: 6) {
                        Text("·").foregroundStyle(Zen.ink2)
                        (Text("Recurring Income: ").foregroundStyle(Zen.ink2)
                         + Text("+\(KobanFormat.currency(income, code: currency))/mo")
                            .fontWeight(.bold).foregroundStyle(Zen.positive))
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 12)
            Text("\(activeCount) active of \(total) recurring items")
                .foregroundStyle(Zen.ink3)
                .monospacedDigit()
                .fixedSize()
        }
        .font(.zen(12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: Rules list

    private func rulesList(_ rules: [RecurringRule], state: LedgerState, currency: String) -> some View {
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grpMap = Dictionary(state.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(spacing: 0) {
            if rules.isEmpty {
                Text("No recurring rules configured yet. Add one above or toggle the recurring icon on categories during setup.")
                    .font(.zen(12))
                    .foregroundStyle(Zen.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            } else {
                ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                    if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                    let cat = catMap[rule.categoryId]
                    RecurringRuleRow(rule: rule, category: cat, group: cat.flatMap { grpMap[$0.groupId] },
                                     currency: currency)
                }
            }
        }
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: Behaviour

    private func ensureValidCategory() {
        let ws = store.state.settings.activeWorkspace
        let avail = store.state.categories.filter { ws.includes($0.mode) }
        if let first = avail.first, !avail.contains(where: { $0.id == categoryId }) {
            categoryId = first.id
        }
    }

    private func submit() {
        guard let rule = store.state.buildRecurringRule(categoryId: categoryId, description: description,
                                                        amount: amount, frequency: frequency,
                                                        dayOfMonth: dayOfMonth) else {
            // <input required>: an empty / invalid amount blocks the submit.
            if JSNumber.parseFloat(amount) == nil || (JSNumber.parseFloat(amount) ?? 0) < 0 {
                amountInvalid = true
                amountFocused = true
            }
            return
        }
        store.addRecurringRule(rule)
        description = ""
        amount = ""
    }
}

private struct RecurringRuleRow: View {
    @Environment(LedgerStore.self) private var store
    let rule: RecurringRule
    let category: CategoryItem?
    let group: CategoryGroup?
    let currency: String
    @State private var hovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                info
                Spacer(minLength: 12)
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                info
                controls
            }
        }
        .font(.zen(12))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Zen.raised.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }

    private var info: some View {
        HStack(spacing: 12) {
            Button { store.toggleRecurringRule(rule.id) } label: {
                ZIcon("checkmark.circle", size: 16, weight: .regular)
                    .foregroundStyle(rule.active ? Zen.positive : Zen.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.active ? "Active — click to pause" : "Paused — click to activate")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(rule.description)
                        .font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.tail)
                    Text(rule.type == .income ? "Income" : "Fixed / Recurring")
                        .font(.zen(10, .medium))
                        .foregroundStyle(rule.type == .income ? Zen.positive : Zen.ink2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(rule.type == .income ? Zen.positive.opacity(0.15) : Zen.raised,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                }
                Text("\(group?.name ?? "Category") · \(category?.name ?? rule.description)")
                    .font(.zen(11)).foregroundStyle(Zen.ink3).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            TxSelect(options: RecurringView.frequencyOptions,
                     selection: Binding(get: { rule.frequency },
                                        set: { store.updateRecurringRule(rule.id, patch: .init(frequency: $0)) }),
                     height: 28, radius: 4, fontSize: 11, textColor: Zen.ink2, fullWidth: false)
                .help("Recurring frequency")

            HStack(spacing: 4) {
                Text("Day").font(.zen(11)).foregroundStyle(Zen.ink3)
                RuleNumberField(value: Double(rule.dayOfMonth), fontSize: 11, weight: .regular, color: Zen.ink,
                                alignment: .center, width: 48, placeholder: "") { text in
                    store.updateRecurringRule(rule.id, patch: .init(dayOfMonth: RecurringRule.clampDay(text)))
                }
                .help("Day of month")
            }

            HStack(spacing: 4) {
                Text(currency).font(.zen(11)).foregroundStyle(Zen.ink3)
                RuleNumberField(value: rule.amount, fontSize: 12, weight: .semibold,
                                color: rule.type == .income ? Zen.positive : Zen.ink,
                                alignment: .trailing, width: 96, placeholder: "0.00") { text in
                    store.updateRecurringRule(rule.id, patch: .init(amount: JSNumber.parseFloat(text) ?? 0))
                }
                .help("Recurring amount (syncs with monthly budget)")
            }

            DeleteRuleButton { store.deleteRecurringRule(rule.id) }
        }
        .fixedSize()
    }
}

/// `<input type="number">` bound to a rule field: updates on every keystroke like the React
/// onChange handler, and shows the stored (clamped) value again once it loses focus.
private struct RuleNumberField: View {
    let value: Double
    var fontSize: CGFloat
    var weight: Font.Weight
    var color: Color
    var alignment: TextAlignment
    var width: CGFloat
    var placeholder: String
    let onEdit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: txPrompt(placeholder))
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .font(.zen(fontSize, weight))
            .textFieldStyle(.plain)
            .foregroundStyle(color)
            .padding(.horizontal, alignment == .center ? 6 : 8)
            .frame(width: width, height: 28)
            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
            .focused($focused)
            .onAppear { text = JSNumber.string(value) }
            .onChange(of: value) { _, new in if !focused { text = JSNumber.string(new) } }
            .onChange(of: text) { _, new in
                if focused && new != JSNumber.string(value) { onEdit(new) }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { text = JSNumber.string(value) } }
            .onSubmit { focused = false }
    }
}

/// p-1.5 rounded-lg text-ink-3 hover:text-accent hover:bg-raised
private struct DeleteRuleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon("trash", size: 14, weight: .regular)
                .foregroundStyle(hovering ? Zen.accent : Zen.ink3)
                .padding(6)
                .background(hovering ? Zen.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Delete recurring rule")
    }
}
