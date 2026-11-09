import SwiftUI

// The four step bodies of OnboardingModal.tsx.

/// h2 + description used at the top of each step.
private struct StepHeading<Trailing: View>: View {
    let title: String
    let subtitle: String
    var badge: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.zen(16, .medium)).foregroundStyle(Zen.ink)
                    if let badge {
                        Text(badge).font(.zen(10)).foregroundStyle(Zen.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                    }
                }
                Text(subtitle).font(.zen(12)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension StepHeading where Trailing == EmptyView {
    init(title: String, subtitle: String, badge: String? = nil) {
        self.init(title: title, subtitle: subtitle, badge: badge) { EmptyView() }
    }
}

/// p-4 rounded-xl bg-app border border-line
private extension View {
    func onbBox(padding: CGFloat = 16, radius: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Zen.app, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.zen(11)).foregroundStyle(Zen.ink2).padding(.bottom, 4)
    }
}

// MARK: - Step 1: Profile & Currency

struct SetupStepProfile: View {
    @Bindable var model: SetupWizardModel

    private struct ModeCard {
        let id: ProfileSetupMode
        let title: String
        let subtitle: String
        let icon: String
        let tint: Color
    }

    private var modeCards: [ModeCard] {
        [
            ModeCard(id: .home, title: "Home Budget",
                     subtitle: "Personal & household monthly budget, daily living, subscriptions, obligations, and savings.",
                     icon: "house", tint: Zen.accent),
            ModeCard(id: .freelancer, title: "Freelancer / Business",
                     subtitle: "Client revenue, tax-deductible business expenses, VAT reconciliation, and tax reserves.",
                     icon: "briefcase", tint: Zen.indigo),
            ModeCard(id: .both, title: "Both (Home + Freelancer)",
                     subtitle: "Dedicated Home and Freelancer workspaces with instant top-bar switching and combined cashflow.",
                     icon: "square.3.layers.3d", tint: Zen.positive),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose Your Ledger Profile").font(.zen(16, .medium)).foregroundStyle(Zen.ink)
                Text("Select how you intend to use Koban. You can switch workspaces or enable both at any time.")
                    .font(.zen(12)).foregroundStyle(Zen.ink2)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(modeCards, id: \.id) { card in modeCard(card) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Currency & Tax Defaults").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        FieldLabel("Primary Currency")
                        OnbSelect(options: [("CHF", "CHF — Swiss Franc"), ("EUR", "EUR (€) — Euro"),
                                            ("USD", "USD ($) — US Dollar"), ("GBP", "GBP (£) — British Pound"),
                                            ("JPY", "JPY (¥) — Japanese Yen")]
                                  + (["CHF", "EUR", "USD", "GBP", "JPY"].contains(model.currency)
                                     ? [] : [(model.currency, model.currency)]),
                                  selection: $model.currency, fullWidth: true)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        FieldLabel("Default Freelancer VAT %")
                        OnbNumberField(value: $model.defaultVatRate)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        FieldLabel("Tax Reserve Set-Aside %")
                        OnbNumberField(value: $model.taxReserveRate)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .onbBox()
        }
    }

    private func modeCard(_ card: ModeCard) -> some View {
        let selected = model.setupMode == card.id
        return Button { model.handleModeChange(card.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZIcon(card.icon, size: 20).foregroundStyle(card.tint)
                    Spacer()
                    if selected {
                        Circle().fill(Zen.ink).frame(width: 20, height: 20)
                            .overlay(ZIcon("checkmark", size: 12, weight: .semibold).foregroundStyle(Zen.onInk))
                    }
                }
                .frame(height: 20)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    Text(card.subtitle).font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(HoverFill(base: selected ? Zen.raised : Zen.app.opacity(0.6),
                                hover: selected ? Zen.raised : Zen.raised.opacity(0.6), radius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Zen.ink : Zen.line, lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Background that changes on hover (hover:bg-…).
private struct HoverFill: ViewModifier {
    let base: Color
    let hover: Color
    var radius: CGFloat = 8
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? hover : base, in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

// MARK: - Step 2: Categories

struct SetupStepCategories: View {
    @Bindable var model: SetupWizardModel
    let listMaxHeight: CGFloat

    private var activeCatalog: [CatalogGroupDef] {
        model.categoryTab == .home ? KobanTemplates.homeCatalog : KobanTemplates.freelancerCatalog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(title: "Select & Customize Your Categories",
                        subtitle: "Core categories are pre-checked. Uncheck any you don't need, check additional categories, or add custom ones.") {
                HStack(spacing: 8) {
                    if model.setupMode == .both {
                        HStack(spacing: 0) {
                            tabButton(.home, "Home (\(model.selectedHomeIds.count))")
                            tabButton(.freelancer, "Freelancer (\(model.selectedFreelancerIds.count))")
                        }
                        .padding(2)
                        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                    }
                    if model.setupCompleted {
                        OnbCheckbox(isOn: $model.applyCategorySelection, label: "Apply category changes")
                    }
                }
                .fixedSize()
            }

            recurringLegend

            CappedScroll(maxHeight: max(200, listMaxHeight)) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    let groups = activeCatalog
                    ForEach(Array(stride(from: 0, to: groups.count, by: 2)), id: \.self) { i in
                        GridRow {
                            GroupCard(model: model, group: groups[i])
                            if i + 1 < groups.count {
                                GroupCard(model: model, group: groups[i + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }

    private func tabButton(_ tab: LedgerMode, _ label: String) -> some View {
        let active = model.categoryTab == tab
        return Button { model.categoryTab = tab } label: {
            Text(label)
                .font(.zen(12, active ? .medium : .regular))
                .foregroundStyle(active ? Zen.ink : Zen.ink2)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(active ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 0.5, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var legendText: Text {
        let b: (String) -> Text = { Text($0).fontWeight(.semibold) }
        var t: Text = Text("Fixed items like ") + b("Wages")
        t = t + Text(", ") + b("Mortgage/Rent")
        t = t + Text(", ") + b("Health Insurance")
        t = t + Text(" & ") + b("Subscriptions")
        t = t + Text(" are set as ") + b("Recurring")
        t = t + Text(" automatically. Click the ")
        let icon: Text = Text(Image(systemName: "repeat")).foregroundColor(Zen.indigo)
        let iconLabel: Text = Text(" recurring icon").foregroundColor(Zen.indigo).fontWeight(.medium)
        return t + icon + iconLabel + Text(" on any category to toggle it on or off.")
    }

    private var recurringLegend: some View {
        HStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Zen.indigo).frame(width: 20, height: 20)
                    .overlay(ZIcon("repeat", size: 12, weight: .regular).foregroundStyle(.white))
                legendText
                    .font(.zen(12)).foregroundStyle(Zen.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Reset Recurring Defaults") { model.resetRecurringDefaults() }
                .buttonStyle(LinkLikeButtonStyle(color: Zen.indigo))
                .help("Restore default recurring flags")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Zen.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.indigo.opacity(0.25), lineWidth: 1))
    }
}

/// text-[11px] font-medium hover:underline
private struct LinkLikeButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration, color: color)
    }
    private struct LinkLabel: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.zen(11, .medium)).foregroundStyle(color).underline(hovering)
                .fixedSize().onHover { hovering = $0 }
        }
    }
}

/// One catalog group card with chips, recurring toggles and the custom-category input.
private struct GroupCard: View {
    @Bindable var model: SetupWizardModel
    let group: CatalogGroupDef

    var body: some View {
        let selected = model.selectedIds(group.mode)
        let customList = model.customItemsByGroup[group.id] ?? []
        let checkedCount = group.items.filter { selected.contains($0.id) }.count + customList.count

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hexString: group.color)).frame(width: 8, height: 8)
                        Text(group.name.uppercased()).font(.zen(11, .semibold)).tracking(0.55)
                            .foregroundStyle(Zen.ink).lineLimit(1)
                        Text("(\(checkedCount))").font(.zen(10)).monospacedDigit().foregroundStyle(Zen.ink3)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        TinyTextButton(label: "All") { model.setGroupSelection(group, .all) }
                        Text("·")
                        TinyTextButton(icon: "arrow.counterclockwise", help: "Reset to default selection") {
                            model.setGroupSelection(group, .default)
                        }
                        Text("·")
                        TinyTextButton(label: "None") { model.setGroupSelection(group, .none) }
                    }
                    .font(.zen(10))
                    .foregroundStyle(Zen.ink3)
                    .fixedSize()
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line.opacity(0.7)).frame(height: 1) }

                FlowLayout(spacing: 6) {
                    ForEach(group.items) { item in
                        CategoryChip(name: item.name, isChecked: selected.contains(item.id),
                                     isRecurring: model.recurringCategoryIds.contains(item.id),
                                     onToggle: { model.toggleCategory(group.mode, item.id) },
                                     onToggleRecurring: { model.toggleRecurringCategory(group.mode, item.id) })
                    }
                    ForEach(Array(customList.enumerated()), id: \.offset) { idx, name in
                        let key = "custom:\(group.id):\(name)"
                        CustomChip(name: name, isRecurring: model.recurringCategoryIds.contains(key),
                                   onToggleRecurring: { model.toggleRecurringCategory(group.mode, key) },
                                   onRemove: { model.handleRemoveCustomCategory(group.id, idx) })
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                OnbTextField(text: Binding(get: { model.customInputByGroup[group.id] ?? "" },
                                           set: { model.customInputByGroup[group.id] = $0 }),
                             placeholder: "+ Add custom to \(group.name.lowercased())…",
                             height: 24, fontSize: 11, radius: 4, horizontalPadding: 8,
                             onSubmit: { model.handleAddCustomCategory(group.id) })
                if !(model.customInputByGroup[group.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add") { model.handleAddCustomCategory(group.id) }
                        .buttonStyle(.zen(.ink, height: 24, radius: 4, padding: 8, fontSize: 10))
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }
}

private struct TinyTextButton: View {
    var label: String?
    var icon: String?
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let label { Text(label) } else if let icon { ZIcon(icon, size: 10, weight: .regular) }
            }
            .foregroundStyle(hovering ? Zen.ink : Zen.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// h-6 chip: [✓/+ name][⟳]
private struct CategoryChip: View {
    let name: String
    let isChecked: Bool
    let isRecurring: Bool
    let onToggle: () -> Void
    let onToggleRecurring: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    ZIcon(isChecked ? "checkmark" : "plus", size: 12, weight: .regular)
                        .foregroundStyle(isChecked ? Zen.positive : Zen.ink3)
                    Text(name)
                }
                .padding(.leading, 8).padding(.trailing, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RecurringToggle(isOn: isRecurring,
                            help: isRecurring
                                ? "\(name): Set as recurring monthly item (click to disable recurring)"
                                : "\(name): One-off / variable item (click to set as recurring monthly)",
                            action: onToggleRecurring)
        }
        .font(.zen(11, isChecked ? .medium : .regular))
        .foregroundStyle(isChecked ? Zen.ink : (hovering ? Zen.ink2 : Zen.ink3))
        .frame(height: 24)
        .background(isChecked ? Zen.surface : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isChecked ? Zen.ink.opacity(0.7) : (hovering ? Zen.ink3 : Zen.line), lineWidth: 1))
        .shadow(color: .black.opacity(isChecked ? 0.05 : 0), radius: 0.5, y: 0.5)
        .onHover { hovering = $0 }
        .fixedSize()
    }
}

/// Custom category chip: [✓ name][⟳][×]
private struct CustomChip: View {
    let name: String
    let isRecurring: Bool
    let onToggleRecurring: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ZIcon("checkmark", size: 12, weight: .regular).foregroundStyle(Zen.accent)
                Text(name)
            }
            .padding(.leading, 8).padding(.trailing, 6)
            RecurringToggle(isOn: isRecurring,
                            help: isRecurring ? "\(name): Recurring monthly item (click to disable)"
                                              : "\(name): Click to mark as recurring monthly item",
                            action: onToggleRecurring)
            RemoveToggle(action: onRemove)
        }
        .font(.zen(11, .medium))
        .foregroundStyle(Zen.ink)
        .frame(height: 24)
        .background(Zen.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Zen.accent.opacity(0.7), lineWidth: 1))
        .fixedSize()
    }
}

private struct RecurringToggle: View {
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon("repeat", size: 10, weight: .regular)
                .foregroundStyle(isOn || hovering ? Zen.indigo : Zen.ink3.opacity(0.5))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(isOn ? Zen.indigo.opacity(hovering ? 0.25 : 0.15) : (hovering ? Zen.indigo.opacity(0.1) : .clear))
                .overlay(alignment: .leading) {
                    Rectangle().fill(isOn ? Zen.indigo.opacity(0.3) : Zen.line.opacity(0.6)).frame(width: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct RemoveToggle: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon("xmark", size: 10, weight: .regular)
                .foregroundStyle(hovering ? Zen.accent : Zen.ink3)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) { Rectangle().fill(Zen.line.opacity(0.6)).frame(width: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove custom category")
    }
}

// MARK: - Step 3: Accounts & Net Worth

struct SetupStepAccounts: View {
    @Bindable var model: SetupWizardModel

    private static let liquidTypes: [(AccountType, String)] = [
        (.checking, "Checking"), (.savings, "Savings"), (.businessBank, "Business Bank"),
        (.taxReserve, "Tax Reserve"), (.cash, "Cash / Wallet"), (.custom, "Custom"),
    ]
    private static let wealthTypes: [(AccountType, String)] = [
        (.retirement, "Retirement / Pension"), (.brokerage, "Brokerage / ETFs"), (.crypto, "Crypto"),
        (.realEstate, "Real Estate"), (.creditCard, "Credit Card (Debt)"), (.loan, "Loan / Mortgage (Debt)"),
        (.custom, "Custom Type…"),
    ]
    private static let classOptions: [(AccountLiquidityClass, String)] = [
        (.retirement, "Retirement"), (.investment, "Investment"), (.fixedAsset, "Fixed Asset"),
        (.liquid, "Liquid"), (.liability, "Liability"),
    ]

    var body: some View {
        let totals = model.totals
        let currency = model.currency
        VStack(alignment: .leading, spacing: 16) {
            StepHeading(title: "Liquid Assets, Retirement & Custom Accounts",
                        subtitle: "Configure your bank accounts, retirement funds (Pillar 2 / 3a / IRA), or custom accounts — or skip this step for setup later.",
                        badge: "Optional") {
                HStack(spacing: 6) {
                    Text("Est. Net Worth:").foregroundStyle(Zen.ink3)
                    Text(KobanFormat.currency(totals.netWorth, code: currency)).fontWeight(.semibold)
                        .foregroundStyle(totals.netWorth >= 0 ? Zen.positive : Zen.accent)
                }
                .font(.zen(12)).monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                .fixedSize()
            }

            HStack(alignment: .top, spacing: 16) {
                column(icon: "building.columns", iconTint: Zen.positive, title: "Liquid Assets & Bank Accounts",
                       total: totals.liquid, totalColor: Zen.positive,
                       accounts: model.draftAccounts.filter { $0.classification == .liquid }, liquid: true) {
                    addButton("Add Another Bank / Liquid Account") { model.addDraftAccount(.liquid) }
                }
                column(icon: "shield", iconTint: Color(hexString: "#8a6fb0"), title: "Retirement, Investments & Custom",
                       total: totals.wealthAndOther, totalColor: Zen.ink,
                       accounts: model.draftAccounts.filter { $0.classification != .liquid }, liquid: false) {
                    HStack(spacing: 8) {
                        addButton("Add Retirement / ETF") { model.addDraftAccount(.retirement) }
                        addButton("Add Custom Account") { model.addDraftAccount(.custom) }
                    }
                }
            }
        }
    }

    private func column<Footer: View>(icon: String, iconTint: Color, title: String, total: Double, totalColor: Color,
                                      accounts: [FinancialAccount], liquid: Bool,
                                      @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    ZIcon(icon, size: 16).foregroundStyle(iconTint)
                    Text(title).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                }
                Spacer()
                Text(KobanFormat.currency(total, code: model.currency))
                    .font(.zen(12, .medium)).monospacedDigit().foregroundStyle(totalColor)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line.opacity(0.7)).frame(height: 1) }

            CappedScroll(maxHeight: 224) {
                VStack(spacing: 8) {
                    ForEach(accounts) { acc in accountRow(acc, liquid: liquid) }
                }
                .padding(.trailing, 2)
            }

            footer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func accountRow(_ acc: FinancialAccount, liquid: Bool) -> some View {
        let id = acc.id
        let types = liquid ? Self.liquidTypes : Self.wealthTypes
        let typeOptions = types.contains(where: { $0.0 == acc.type })
            ? types : types + [(acc.type, KobanTemplates.accountType(acc.type).label)]
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                OnbTextField(text: Binding(get: { model.draftAccounts.first { $0.id == id }?.name ?? "" },
                                           set: { v in model.updateDraftAccount(id) { $0.name = v } }),
                             placeholder: liquid ? "Account name (e.g. Main Checking)" : "e.g. Pillar 3a, Pension, ETFs",
                             height: 28, fontSize: 12, background: Zen.app, radius: 4, horizontalPadding: 8)
                OnbSelect(options: typeOptions,
                          selection: Binding(get: { acc.type }, set: { model.changeDraftType(id, to: $0) }),
                          height: 28, fontSize: 11, textColor: Zen.ink2, background: Zen.app, radius: 4,
                          horizontalPadding: 6)
                ZenMiniButton(icon: "trash", size: 14, tint: Zen.ink3, hoverTint: Zen.accent, help: "Remove account") {
                    model.removeDraftAccount(id)
                }
            }
            HStack(spacing: 6) {
                if !liquid && acc.type == .custom {
                    OnbTextField(text: Binding(get: { model.draftAccounts.first { $0.id == id }?.customTypeLabel ?? "" },
                                               set: { v in model.updateDraftAccount(id) { $0.customTypeLabel = v } }),
                                 placeholder: "Custom type label…",
                                 height: 28, fontSize: 11, background: Zen.app, radius: 4, horizontalPadding: 8)
                    OnbSelect(options: Self.classOptions,
                              selection: Binding(get: { acc.classification },
                                                 set: { v in model.updateDraftAccount(id) { $0.classification = v } }),
                              height: 28, fontSize: 10, textColor: Zen.ink2, background: Zen.app, radius: 4,
                              horizontalPadding: 6)
                } else {
                    OnbTextField(text: Binding(get: { model.draftAccounts.first { $0.id == id }?.institution ?? "" },
                                               set: { v in model.updateDraftAccount(id) { $0.institution = v } }),
                                 placeholder: liquid ? "Bank / Institution (optional)" : "Provider / Foundation (optional)",
                                 height: 28, fontSize: 11, textColor: Zen.ink2, background: Zen.app, radius: 4,
                                 horizontalPadding: 8)
                }
                OnbNumberField(value: Binding(get: { model.draftAccounts.first { $0.id == id }?.startingBalance ?? 0 },
                                              set: { model.setDraftBalance(id, $0) }),
                               placeholder: "0.00 \(model.currency)", emptyForZero: true,
                               height: 28, fontSize: 12, background: Zen.app, radius: 4, horizontalPadding: 8,
                               alignment: .trailing)
                    .frame(width: 128)
            }
        }
        .padding(10)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZIcon("plus", size: 14)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(.outline, height: 32, radius: 8, padding: 8, fontSize: 12))
    }
}

// MARK: - Step 4: Vault & Preferences

struct SetupStepVault: View {
    @Environment(LedgerStore.self) private var store
    @Bindable var model: SetupWizardModel

    var body: some View {
        let passkeyCount = model.auth.passkeys.count
        VStack(alignment: .leading, spacing: 16) {
            StepHeading(title: "Passkey / Touch ID Login, Encrypted Vault & Preferences",
                        subtitle: "Configure Passkey / Touch ID login protection, automatic encrypted SQLite backups, and month-to-month workflow preferences.")

            // Login & Passkey / Touch ID Protection
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ZIcon("touchid", size: 16).foregroundStyle(Zen.indigo)
                        Text("Passkey & Touch ID Login Protection").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        if passkeyCount > 0 {
                            HStack(spacing: 4) {
                                ZIcon("checkmark.circle", size: 12, weight: .regular)
                                Text("\(passkeyCount) Passkey Enrolled")
                            }
                            .font(.zen(10, .medium)).foregroundStyle(Zen.positive)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Zen.positive.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Zen.positive.opacity(0.3), lineWidth: 1))
                        }
                    }
                    Spacer(minLength: 8)
                    OnbCheckbox(isOn: $model.requireLoginOnStartup, label: "Require Login on Startup")
                }

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        FieldLabel("Account Owner Name")
                        OnbTextField(text: $model.userDisplayName, placeholder: "e.g. Roland")
                    }
                    .frame(maxWidth: .infinity)
                    Button { model.handleEnrollPasskey(store: store) } label: {
                        HStack(spacing: 8) {
                            ZIcon("touchid", size: 14)
                            Text(passkeyCount > 0 ? "Add Another Passkey / Touch ID" : "Enroll Passkey / Touch ID")
                                .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.zen(.ink, height: 36, radius: 8, padding: 16, fontSize: 12))
                    .disabled(model.isEnrollingPasskey)
                }

                if let msg = model.passkeyStatusMsg {
                    Text(msg).font(.zen(11)).foregroundStyle(Zen.indigo)
                }
            }
            .onbBox()

            // Encrypted Vault & Backup Path
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        ZIcon("checkmark.shield", size: 16).foregroundStyle(Zen.positive)
                        Text("AES-256-GCM Encrypted Database & Automatic Backups")
                            .font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    }
                    Spacer(minLength: 8)
                    OnbCheckbox(isOn: $model.autoBackup, label: "Auto-backup on changes")
                }

                (Text("All records inside ") + Text("koban.db").font(.system(size: 11, design: .monospaced)).foregroundColor(Zen.ink)
                 + Text(" and your backup snapshots (")
                 + Text("koban-latest.db").font(.system(size: 11, design: .monospaced)).foregroundColor(Zen.ink)
                 + Text(") are encrypted at rest with authenticated ")
                 + Text("AES-256-GCM").fontWeight(.semibold) + Text("."))
                    .font(.zen(11)).foregroundStyle(Zen.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        OnbTextField(text: $model.backupDir,
                                     placeholder: "Backup Folder: e.g. /Users/\(NSUserName())/Backups/Koban")
                        Button { model.handleChooseBackupFolder() } label: {
                            HStack(spacing: 6) {
                                ZIcon("folder", size: 14)
                                Text("Browse…").foregroundStyle(Zen.ink)
                            }
                        }
                        .buttonStyle(.zen(.raised, height: 36, radius: 8, padding: 12, fontSize: 12))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1).allowsHitTesting(false))
                    }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(2)

                    HStack(spacing: 8) {
                        ZIcon("lock", size: 14).foregroundStyle(Zen.ink3)
                        SecureField("", text: $model.vaultPassphrase,
                                    prompt: Text("Optional custom vault passphrase").foregroundStyle(Zen.ink3))
                            .textFieldStyle(.plain)
                            .font(.zen(12))
                            .foregroundStyle(Zen.ink)
                    }
                    .padding(.leading, 10).padding(.trailing, 12)
                    .frame(height: 36)
                    .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                    .frame(width: 262)
                }
            }
            .onbBox()

            // Behavioral Options
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ZIcon("slider.horizontal.3", size: 16).foregroundStyle(Zen.indigo)
                    Text("Month-to-Month Copy & Behavioral Preferences").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                }

                HStack(alignment: .top, spacing: 12) {
                    preferenceCard(isOn: $model.confirmBeforeMonthCopy,
                                   title: "Ask confirmation before copying monthly values",
                                   detail: "Always ask if you are sure before copying last month's values into the next month.")
                    preferenceCard(isOn: $model.autoPromptCopyOnEmptyMonth,
                                   title: "Offer carry-over when switching to an empty month",
                                   detail: "Show a one-click banner when viewing a new month that has no values yet.")
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Default values to copy from previous month:").font(.zen(12)).foregroundStyle(Zen.ink2)
                    Spacer(minLength: 8)
                    OnbSelect(options: [(MonthCopyScope.budgetsAndActuals, "Both Planned Budgets & Direct Actuals"),
                                        (.budgetsOnly, "Planned Budgets Only (Reset Actuals to 0)")],
                              selection: $model.monthCopyScope, height: 32, horizontalPadding: 10)
                }
                .padding(.top, 4)
            }
            .onbBox()
        }
    }

    private func preferenceCard(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn.wrappedValue ? Zen.ink : Zen.surface)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn.wrappedValue ? Zen.ink : Zen.ink3, lineWidth: 1))
                    .overlay {
                        if isOn.wrappedValue {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Zen.onInk)
                        }
                    }
                    .frame(width: 13, height: 13)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    Text(detail).font(.zen(11)).foregroundStyle(Zen.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
