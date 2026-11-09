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
                    Text("Savings Goals, Sinking Funds & Tax Reserves")
                        .font(.zen(20)).foregroundStyle(Zen.ink)
                    Text("Track progress toward emergency funds, equipment replacements, and freelancer tax set-asides.")
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
            AccLabeledField("Goal / Reserve Name") {
                AccTextField(placeholder: "e.g. Emergency Fund, Tax Provision", text: $name, height: 32,
                             background: Zen.raised, onSubmit: submit)
            }
            .accFlex(grow: 2, basis: 200, minWidth: 180)

            AccLabeledField("Target (\(currency))") {
                AccTextField(placeholder: "10000", text: $targetAmount, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            AccLabeledField("Saved So Far") {
                AccTextField(placeholder: "0", text: $currentAmount, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            AccLabeledField("Monthly Plan") {
                AccTextField(placeholder: "250", text: $monthlyContribution, height: 32, background: Zen.raised,
                             trailing: true, monospacedDigits: true, onSubmit: submit)
            }
            .accFlex(grow: 1, basis: 110, minWidth: 100)

            if workspace == .combined {
                AccLabeledField("Workspace") {
                    AccSelect(options: [(LedgerMode.home, "Home"), (.freelancer, "Freelancer")],
                              selection: Binding(get: { mode ?? .home }, set: { mode = $0 }),
                              height: 32, background: Zen.raised)
                }
                .accFlex(grow: 1, basis: 115, minWidth: 105)
            }

            AccLabeledField("Target Date") {
                AccDateField(text: $targetDate)
            }
            .accFlex(grow: 1, basis: 140, minWidth: 135)

            Button(action: submit) {
                HStack(spacing: 6) {
                    ZIcon("plus", size: 14)
                    Text("Add Goal").fontWeight(.medium)
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
                        Text(goal.name).font(.zen(14, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                        Text("\(goal.mode.rawValue) · Target Date: \((goal.targetDate ?? "").isEmpty ? "Flexible" : goal.targetDate!)".uppercased())
                            .font(.zen(11)).tracking(0.55).foregroundStyle(Zen.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                AccHoverIcon(icon: "trash", size: 14, padding: 6, hoverBackground: Zen.raised, help: "Delete goal",
                             action: onDelete)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(KobanFormat.currency(goal.currentAmount, code: currency))
                        .font(.zen(16, .semibold)).monospacedDigit().foregroundStyle(Zen.ink)
                    Spacer(minLength: 8)
                    Text("of \(KobanFormat.currency(goal.targetAmount, code: currency)) (\(AccountsJS.fixed(progress.pct, 1))%)")
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
                    Text("Balance:").font(.zen(11)).foregroundStyle(Zen.ink3)
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
        if p.remaining == 0 { return "Goal reached!" }
        if let months = p.monthsToGoal, months != 0 {
            return "~\(months) mo left at \(KobanFormat.currency(goal.monthlyContribution, code: currency))/mo"
        }
        return "\(KobanFormat.currency(p.remaining, code: currency)) remaining"
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
