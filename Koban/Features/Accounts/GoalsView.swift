import SwiftUI

/// Port of src/components/SavingsGoalsView.tsx — savings goals, sinking funds & tax reserves.
struct GoalsView: View {
    @Environment(LedgerStore.self) private var store

    @State private var name = ""
    @State private var targetAmount = ""
    @State private var currentAmount = ""
    @State private var monthlyContribution = ""
    @State private var targetDate = "2027-12-31"
    @State private var mode: LedgerMode?
    @State private var scrollWidth: CGFloat = 1100

    private var workspace: ActiveWorkspace { store.state.settings.activeWorkspace }
    private var currency: String { store.state.settings.currency }
    private var visibleGoals: [SavingsGoal] { store.state.savingsGoals.filter { workspace.includes($0.mode) } }
    private var bp: AccBreakpoints { AccBreakpoints(viewport: scrollWidth + (store.isSidebarOpen ? 256 : 0)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("goals.title"))
                        .font(.zen(20)).foregroundStyle(Zen.ink)
                    Text(L10n.t("goals.subtitle"))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                }

                addGoalForm

                AccGrid(columns: bp.md ? 2 : 1, hSpacing: 20, vSpacing: 20) {
                    ForEach(visibleGoals) { goal in
                        GoalCard(goal: goal, currency: currency,
                                 onUpdateAmount: { store.updateGoalAmount(goal.id, currentAmount: $0) },
                                 onDelete: { store.deleteGoal(goal.id) })
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1152)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scrollWidth = $0 }
        .onAppear {
            if mode == nil { mode = workspace == .freelancer ? .freelancer : .home }
        }
    }

    private var addGoalForm: some View {
        AccFlexWrap(spacing: 12) {
            AccLabeledField(L10n.t("goals.nameLabel")) {
                AccTextField(placeholder: L10n.t("goals.namePlaceholder"), text: $name, height: 32,
                             background: Zen.raised, onSubmit: submit)
            }
            .accFlex(grow: 2, basis: 200, minWidth: 180)

            AccLabeledField(L10n.tf("goals.targetLabel", ["currency": currency])) {
                AccTextField(placeholder: "10000", text: $targetAmount, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            AccLabeledField(L10n.t("goals.savedSoFarLabel")) {
                AccTextField(placeholder: "0", text: $currentAmount, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            AccLabeledField(L10n.t("goals.monthlyPlanLabel")) {
                AccTextField(placeholder: "250", text: $monthlyContribution, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            if workspace == .combined {
                AccLabeledField(L10n.t("sidebar.workspace")) {
                    AccSelect(options: [(LedgerMode.home, L10n.t("workspace.home")), (.freelancer, L10n.t("workspace.freelancer"))],
                              selection: Binding(get: { mode ?? .home }, set: { mode = $0 }),
                              height: 32, background: Zen.raised)
                }
                .accFlex(grow: 1, basis: 115, minWidth: 105)
            }

            AccLabeledField(L10n.t("goals.targetDateLabel")) {
                AccDateField(text: $targetDate)
            }
            .accFlex(grow: 1, basis: 140, minWidth: 135)

            Button(action: submit) {
                HStack(spacing: 6) {
                    ZIcon("plus", size: 14)
                    Text(L10n.t("goals.addGoalBtn")).fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 16))
        }
        .accSurfaceCard(padding: 16)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // `required` on name and target: the browser blocks submit while they are empty.
        guard !trimmed.isEmpty, !targetAmount.isEmpty else { return }
        let goalMode: LedgerMode = workspace == .combined ? (mode ?? .home) : (workspace == .freelancer ? .freelancer : .home)
        let target = AccountsJS.parseFloat(targetAmount.replacingOccurrences(of: ",", with: ".")).flatMap { $0 == 0 ? nil : $0 } ?? 1000
        let saved = AccountsJS.parseFloat(currentAmount.replacingOccurrences(of: ",", with: ".")) ?? 0
        let monthly = AccountsJS.parseFloat(monthlyContribution.replacingOccurrences(of: ",", with: ".")) ?? 0
        store.addGoal(NewGoalInput(
            mode: goalMode,
            name: trimmed,
            targetAmount: target,
            currentAmount: saved,
            monthlyContribution: monthly,
            targetDate: targetDate,
            color: ZenGroupPalette.colors[visibleGoals.count % ZenGroupPalette.colors.count]
        ))
        name = ""
        targetAmount = ""
        currentAmount = ""
        monthlyContribution = ""
    }
}

private struct GoalCard: View {
    let goal: SavingsGoal
    let currency: String
    let onUpdateAmount: (Double) -> Void
    let onDelete: () -> Void

    var body: some View {
        let progress = goal.progress
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hexString: goal.color))
                        .frame(width: 32, height: 32)
                        .overlay { ZIcon("target", size: 16, weight: .regular).foregroundStyle(.white) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.goalName(goal)).font(.zen(14, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                        Text("\(L10n.t(goal.mode == .home ? "workspace.home" : "workspace.freelancer")) · \(L10n.t("goals.targetDateLabel")): \((goal.targetDate ?? "").isEmpty ? L10n.t("goals.flexibleDate") : goal.targetDate!)".uppercased())
                            .font(.zen(11)).tracking(0.55).foregroundStyle(Zen.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                AccHoverIcon(icon: "trash", size: 14, padding: 6, hoverBackground: Zen.raised, help: L10n.t("common.delete"),
                             action: onDelete)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(KobanFormat.currency(goal.currentAmount, code: currency))
                        .font(.zen(16, .semibold)).monospacedDigit().foregroundStyle(Zen.ink)
                    Spacer(minLength: 8)
                    Text(L10n.tf("goals.ofTarget", ["target": KobanFormat.currency(goal.targetAmount, code: currency), "pct": AccountsJS.fixed(progress.pct, 1)]))
                        .font(.zen(12)).monospacedDigit().foregroundStyle(Zen.ink2)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Zen.raised)
                        Capsule().fill(Color(hexString: goal.color))
                            .frame(width: geo.size.width * progress.pct / 100)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                Text(statusText(progress)).font(.zen(12)).foregroundStyle(Zen.ink3).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if goal.monthlyContribution > 0 && progress.remaining > 0 {
                        ContributionButton(amount: goal.monthlyContribution) {
                            onUpdateAmount(goal.currentAmount + goal.monthlyContribution)
                        }
                    }
                    Text(L10n.t("goals.balanceLabel")).font(.zen(11)).foregroundStyle(Zen.ink3)
                    GoalBalanceField(value: goal.currentAmount, onChange: onUpdateAmount)
                }
                .fixedSize()
            }
            .padding(.top, 8)
            .accTopHairline(Zen.line.opacity(0.6))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accSurfaceCard(padding: 20)
        .clipped()
    }

    private func statusText(_ p: GoalProgress) -> String {
        if p.remaining == 0 { return L10n.t("goals.goalReached") }
        if let months = p.monthsToGoal, months != 0 {
            return L10n.tf("goals.monthsLeftAt", ["months": months, "amount": KobanFormat.currency(goal.monthlyContribution, code: currency)])
        }
        return L10n.tf("goals.remaining", ["amount": KobanFormat.currency(p.remaining, code: currency)])
    }
}

private struct ContributionButton: View {
    let amount: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("+\(AccountsJS.string(amount))")
                .font(.zen(11)).monospacedDigit()
                .foregroundStyle(hovering ? Zen.ink : Zen.ink2)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(hovering ? Zen.line.opacity(0.5) : Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add one monthly contribution to current balance")
    }
}

/// `<input type="number" value={goal.currentAmount}>` — updates the goal on every keystroke.
private struct GoalBalanceField: View {
    let value: Double
    let onChange: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.zen(12))
            .monospacedDigit()
            .foregroundStyle(Zen.ink)
            .padding(.horizontal, 8)
            .frame(width: 96, height: 28)
            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
            .focused($focused)
            .onAppear { text = AccountsJS.string(value) }
            .onChange(of: value) { _, newValue in
                if !focused || (AccountsJS.parseFloat(text) ?? 0) != newValue { text = AccountsJS.string(newValue) }
            }
            .onChange(of: text) { _, newText in
                guard focused else { return }
                let parsed = AccountsJS.parseFloat(newText.replacingOccurrences(of: ",", with: ".")) ?? 0
                if parsed != value { onChange(parsed) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = AccountsJS.string(value) }
            }
            .onSubmit { focused = false }
    }
}
