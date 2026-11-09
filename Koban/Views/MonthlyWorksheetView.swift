import SwiftUI

/// Port of src/components/MonthlyWorksheetView.tsx — the 2-column Budget / Actual worksheet.
struct MonthlyWorksheetView: View {
    @Environment(LedgerStore.self) private var store
    @State private var hideZeroRows: Bool?
    @State private var showNewGroupForm = false
    @State private var contentWidth: CGFloat = 1000
    @State private var pendingDelete: DeleteTarget?
    @State private var editFocus = EditFocus()
    /// Group whose inline "add category" form is open.
    @State private var addingGroupId: String?

    enum DeleteTarget: Identifiable {
        case category(id: String, name: String)
        case group(id: String, name: String)
        var id: String {
            switch self {
            case .category(let id, _), .group(let id, _): return id
            }
        }
    }

    var body: some View {
        let state = store.state
        let settings = state.settings
        let workspace = settings.activeWorkspace
        let summary = store.monthSummary(monthKey: state.activeMonthKey, workspace: workspace)
        let hideZero = hideZeroRows ?? (settings.defaultHideZeroRows ?? false)
        let prevKey = adjacentKey(-1), nextKey = adjacentKey(1)
        let monthEmpty = summary.incomeBudget == 0 && summary.incomeActual == 0
            && summary.totalOutflowBudget == 0 && summary.totalOutflowActual == 0
        let showBanner = monthEmpty && (settings.autoPromptCopyOnEmptyMonth ?? true)
            && store.monthHasData(monthKey: prevKey, workspace: workspace)
        let twoColumns = contentWidth >= 720
        let leftGroups = summary.groups.filter { $0.group.column == 0 }
        let rightGroups = summary.groups.filter { $0.group.column != 0 }
        // Tab order like the Windows DOM: left column, then right; name → budget → actual per row.
        let _ = editFocus.order = (leftGroups + rightGroups).flatMap { gs in
            gs.rows.filter { !(hideZero && $0.budget == 0 && $0.actual == 0 && $0.txCount == 0) }
                .flatMap { ["\($0.category.id)#name", "\($0.category.id)#budget", "\($0.category.id)#actual"] }
        }

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header + toolbar
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace == .home ? "Personal Monthly Budget"
                             : workspace == .freelancer ? "Freelancer Business Budget & P&L"
                             : "Combined Home & Freelancer Worksheet")
                            .font(.zen(20))
                            .foregroundStyle(Zen.ink)
                        Text("Click any Budget or Actual figure to edit directly inline, or log itemized transactions.")
                            .font(.zen(12))
                            .foregroundStyle(Zen.ink2)
                    }

                    FlowLayout(spacing: 8) {
                        Button { hideZeroRows = !hideZero } label: {
                            HStack(spacing: 6) {
                                ZIcon(hideZero ? "eye" : "eye.slash", size: 14)
                                    .foregroundStyle(hideZero ? Zen.accent : Zen.ink2)
                                Text(hideZero ? "Showing Active Only" : "Hide Zero Rows")
                                    .fontWeight(hideZero ? .medium : .regular)
                            }
                        }
                        .buttonStyle(.zen(.outline, active: hideZero))
                        .overlay {
                            if hideZero { RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.ink, lineWidth: 1) }
                        }
                        .help("Hide or show categories with 0.00 Budget and 0.00 Actual")

                        Button { requestCopy(.prevToCurrent) } label: {
                            HStack(spacing: 6) {
                                ZIcon("doc.on.doc", size: 14).foregroundStyle(Zen.indigo)
                                Text("Copy \(prevKey) → Here")
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help("Copy values from previous month (\(prevKey)) into this month (\(summary.monthKey))")

                        Button { requestCopy(.currentToNext) } label: {
                            HStack(spacing: 6) {
                                ZIcon("arrow.right", size: 14).foregroundStyle(Zen.positive)
                                Text("Copy into Next Month (\(nextKey))")
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help("Copy this month's values (\(summary.monthKey)) into next month (\(nextKey))")

                        Button { requestCopy(.allMonths) } label: {
                            HStack(spacing: 6) {
                                ZIcon("doc.on.doc", size: 14).foregroundStyle(Zen.positive)
                                Text("Apply to All 12 Months")
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help("Copy this month's planned Budget amounts across all 12 months of the year")

                        Button { showNewGroupForm.toggle() } label: {
                            HStack(spacing: 6) {
                                ZIcon("folder.badge.plus", size: 14)
                                Text("New Category Group")
                            }
                        }
                        .buttonStyle(.zenInk)
                    }
                }

                if showBanner {
                    CarryOverBanner(monthKey: summary.monthKey, prevKey: prevKey) { requestCopy(.prevToCurrent) }
                }

                if showNewGroupForm {
                    NewGroupForm(workspace: workspace) { showNewGroupForm = false }
                }

                if workspace != .home {
                    FreelancerStrip(summary: summary, currency: settings.currency, columns: twoColumns ? 4 : 2)
                }

                let left = leftGroups
                let right = rightGroups
                let summaryBox = BudgetSummaryBox(summary: summary)

                // Lazy per row: group cards are split into header / row / footer items so only the
                // rows on screen are built (each item draws its slice of the card outline).
                if twoColumns {
                    HStack(alignment: .top, spacing: 24) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(left.enumerated()), id: \.element.id) { idx, gs in
                                groupItems(gs, first: idx == 0, hideZero: hideZero, workspace: workspace)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        LazyVStack(spacing: 0) {
                            summaryBox
                            ForEach(right) { groupItems($0, first: false, hideZero: hideZero, workspace: workspace) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(left.enumerated()), id: \.element.id) { idx, gs in
                            groupItems(gs, first: idx == 0, hideZero: hideZero, workspace: workspace)
                        }
                        summaryBox.padding(.top, left.isEmpty ? 0 : 20)
                        ForEach(right) { groupItems($0, first: false, hideZero: hideZero, workspace: workspace) }
                    }
                }

                if summary.groups.isEmpty {
                    Text("No category groups yet. Use “New Category Group” to start your worksheet.")
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(24)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 - 48 }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            // Tabbing into a row that is off-screen scrolls it into view.
            editFocus.onMove = { cellID in
                let rowID = String(cellID.prefix(while: { $0 != "#" }))
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rowID) }
            }
        }
        }
        .environment(editFocus)
        .alert(item: $pendingDelete) { target in
            switch target {
            case .category(let id, let name):
                return Alert(title: Text("Delete category “\(name)”?"),
                             message: Text("Its monthly values and transactions are deleted too."),
                             primaryButton: .destructive(Text("Delete")) { store.deleteCategory(id) },
                             secondaryButton: .cancel())
            case .group(let id, let name):
                return Alert(title: Text("Delete the “\(name)” group?"),
                             message: Text("All categories inside it, their monthly values and transactions are deleted too."),
                             primaryButton: .destructive(Text("Delete")) { store.deleteGroup(id) },
                             secondaryButton: .cancel())
            }
        }
    }

    @ViewBuilder
    private func groupItems(_ gs: GroupComputedSummary, first: Bool, hideZero: Bool,
                            workspace: ActiveWorkspace) -> some View {
        let rows = gs.rows.filter { !(hideZero && $0.budget == 0 && $0.actual == 0 && $0.txCount == 0) }
        // Tax badges only from the Windows `xl` breakpoint (1280 px window) up.
        let showTax = contentWidth >= 976
        let adding = addingGroupId == gs.group.id
        GroupHeader(gs: gs, showMode: workspace == .combined,
                    onAdd: { addingGroupId = adding ? nil : gs.group.id },
                    onDelete: { requestDelete(.group(id: gs.group.id, name: gs.group.name)) })
            .cardPiece(top: true)
            .padding(.top, first ? 0 : 20)
        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
            CategoryRow(row: row, isLast: idx == rows.count - 1, showTaxBadge: showTax) {
                requestDelete(.category(id: row.category.id, name: row.category.name))
            }
            .cardPiece()
        }
        if adding {
            AddCategoryForm(gs: gs) { addingGroupId = nil }.cardPiece()
        }
        GroupFooter(gs: gs).cardPiece(bottom: true)
    }

    private func requestDelete(_ target: DeleteTarget) {
        if store.state.settings.confirmBeforeDelete == false {
            switch target {
            case .category(let id, _): store.deleteCategory(id)
            case .group(let id, _): store.deleteGroup(id)
            }
        } else {
            pendingDelete = target
        }
    }

    private func adjacentKey(_ delta: Int) -> String {
        var copy = store.state
        copy.shiftActiveMonth(by: delta)
        return copy.activeMonthKey
    }

    private func requestCopy(_ mode: LedgerStore.CopyRequest.Mode) {
        let s = store.state.settings
        let current = store.state.activeMonthKey
        let request = LedgerStore.CopyRequest(
            mode: mode,
            source: mode == .prevToCurrent ? adjacentKey(-1) : current,
            target: mode == .prevToCurrent ? current
                : mode == .currentToNext ? adjacentKey(1) : "All 12 Months (\(s.activeYear))",
            scope: s.monthCopyScope ?? .budgetsAndActuals,
            overwriteExisting: s.monthCopyOverwriteExisting ?? true,
            navigateToTarget: mode == .currentToNext
        )
        if s.confirmBeforeMonthCopy == false {
            store.performCopy(request)
        } else {
            store.copyRequest = request
        }
    }
}

// MARK: - Grid metrics (grid-cols-[1fr_84px_84px_84px_48px] gap-1.5)

private enum Cols {
    static let value: CGFloat = 84
    static let actions: CGFloat = 48
    static let gap: CGFloat = 6
}

// MARK: - Group block

extension View {
    /// One slice of a rounded group card (see CardSlice): surface fill, outline, rounded ends.
    func cardPiece(top: Bool = false, bottom: Bool = false) -> some View {
        background(Zen.surface)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: top ? 12 : 0, bottomLeadingRadius: bottom ? 12 : 0,
                                              bottomTrailingRadius: bottom ? 12 : 0, topTrailingRadius: top ? 12 : 0))
            .overlay(CardSlice(top: top, bottom: bottom).stroke(Zen.line, lineWidth: 1))
    }
}

private struct GroupHeader: View {
    let gs: GroupComputedSummary
    let showMode: Bool
    let onAdd: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Cols.gap) {
            HStack(spacing: 8) {
                Circle().fill(Color(hexString: gs.group.color)).frame(width: 10, height: 10)
                Text(gs.group.name.uppercased())
                    .font(.zen(11, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Zen.ink)
                    .lineLimit(1)
                if showMode {
                    Text(gs.group.mode.rawValue.uppercased())
                        .font(.zen(9))
                        .foregroundStyle(Zen.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 0)
            }
            headerLabel("Budget")
            headerLabel("Actual")
            headerLabel("Diff.").padding(.trailing, 4)
            HStack(spacing: 2) {
                ZenMiniButton(icon: "plus", size: 14, tint: Zen.ink2, help: "Add category to this group", action: onAdd)
                ZenMiniButton(icon: "trash", size: 12, hoverTint: Zen.accent, help: "Delete entire group", action: onDelete)
            }
            .frame(width: Cols.actions, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .background(Zen.raised.opacity(0.7))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(.zen(11))
            .foregroundStyle(Zen.ink2)
            .frame(width: Cols.value, alignment: .trailing)
    }
}

/// Inline add-category form under a group's rows.
private struct AddCategoryForm: View {
    @Environment(LedgerStore.self) private var store
    let gs: GroupComputedSummary
    let onDone: () -> Void
    @State private var newName = ""
    @State private var newBudget = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $newName, prompt: Text("New category name…").foregroundStyle(Zen.ink3))
                .zenField(height: 28, background: Zen.surface)
                .onSubmit(create)
            TextField("", text: $newBudget, prompt: Text("Budget (0)").foregroundStyle(Zen.ink3))
                .multilineTextAlignment(.trailing)
                .zenAmount()
                .zenField(height: 28, background: Zen.surface)
                .frame(width: 96)
                .onSubmit(create)
            Button("Add", action: create).buttonStyle(.zen(.ink, height: 28, radius: 4, padding: 10))
            Button("Cancel", action: onDone).buttonStyle(.zen(.ghost, height: 28, radius: 4, padding: 8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Zen.app)
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.addCategory(groupId: gs.group.id, mode: gs.group.mode, kind: gs.group.kind,
                          name: name, budget: NumberParsing.parse(newBudget) ?? 0)
        newName = ""
        newBudget = ""
        onDone()
    }
}

private struct GroupFooter: View {
    let gs: GroupComputedSummary

    var body: some View {
        HStack(spacing: Cols.gap) {
            Text("Total \(gs.group.name)").foregroundStyle(Zen.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(KobanFormat.number(gs.totalBudget)).foregroundStyle(Zen.ink2)
                .padding(.horizontal, 6).frame(width: Cols.value, alignment: .trailing)
            Text(KobanFormat.number(gs.totalActual)).foregroundStyle(Zen.ink)
                .padding(.horizontal, 6).frame(width: Cols.value, alignment: .trailing)
            Text(signed(gs.totalDifference)).foregroundStyle(Zen.diff(gs.totalDifference))
                .padding(.trailing, 4).frame(width: Cols.value, alignment: .trailing)
            Color.clear.frame(width: Cols.actions, height: 1)
        }
        .font(.zen(12, .semibold))
        .zenAmount()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Zen.app.opacity(0.8))
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }
}

func signed(_ value: Double) -> String {
    (value > 0.004 ? "+" : "") + KobanFormat.number(value)
}

// MARK: - Category row

private struct CategoryRow: View {
    @Environment(LedgerStore.self) private var store
    let row: CategoryComputedRow
    let isLast: Bool
    let showTaxBadge: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let cat = row.category
        let recurring = cat.isRecurring ?? false

        HStack(spacing: Cols.gap) {
            // Name + recurring toggle + badges
            HStack(spacing: 6) {
                InlineTextField(value: cat.name, cellID: "\(cat.id)#name") { store.renameCategory(cat.id, to: $0) }
                    .help(cat.name)

                // Only built when visible (recurring, or row hovered): fewer views per row.
                if recurring || hovering {
                    Button { store.toggleCategoryRecurring(cat.id) } label: {
                        ZIcon("repeat", size: 12, weight: .regular)
                            .foregroundStyle(recurring ? Zen.indigo : Zen.ink3)
                            .padding(4)
                            .background(recurring ? Zen.indigo.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(recurring ? "Recurring monthly item (click to disable recurring)" : "Mark as recurring monthly item")
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }

                if row.txCount > 0 && row.directActual == nil {
                    Text("\(row.txCount)tx")
                        .font(.zen(10)).zenAmount()
                        .foregroundStyle(Zen.ink3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                        .help("\(row.txCount) logged transaction(s)")
                }
                if row.directActual != nil {
                    ZenMiniButton(icon: "arrow.counterclockwise", size: 12,
                                  help: "Manual actual override active — click to revert to transaction sum") {
                        store.setDirectActual(nil, categoryId: cat.id)
                    }
                }
                if showTaxBadge, cat.mode == .freelancer, let badge = taxBadge(cat) {
                    Text(badge)
                        .font(.zen(9)).zenAmount()
                        .foregroundStyle(Zen.indigo)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Zen.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            InlineNumberField(value: row.budget, color: Zen.ink2, cellID: "\(cat.id)#budget") {
                store.setBudget($0 ?? 0, categoryId: cat.id)
            }
            .frame(width: Cols.value)
            InlineNumberField(value: (row.actual * 100).rounded() / 100, color: Zen.ink, weight: .medium,
                              cellID: "\(cat.id)#actual") {
                store.setDirectActual($0 ?? 0, categoryId: cat.id)
            }
            .frame(width: Cols.value)

            Text(signed(row.difference))
                .font(.zen(12, .medium))
                .zenAmount()
                .foregroundStyle(Zen.diff(row.difference))
                .padding(.trailing, 4)
                .frame(width: Cols.value, alignment: .trailing)

            // Hover-only actions are built on hover instead of hidden with opacity (each button
            // carries its own hover tracking, which was a large part of the scroll cost).
            HStack(spacing: 4) {
                if hovering {
                    ZenMiniButton(icon: "receipt", size: 12, help: "Log transaction in this category") {
                        store.openQuickAdd(categoryId: cat.id)
                    }
                    ZenMiniButton(icon: "trash", size: 12, hoverTint: Zen.accent, help: "Delete category", action: onDelete)
                }
            }
            .frame(width: Cols.actions, height: 20, alignment: .trailing)
        }
        .font(.zen(12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(hovering ? Zen.raised.opacity(0.6) : .clear)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
        }
        .onHover { hovering = $0 }
        .id(cat.id)
    }

    private func taxBadge(_ cat: CategoryItem) -> String? {
        let vat = cat.taxRate ?? 0
        let ded = cat.deductiblePct ?? 100
        guard vat != 0 || ded < 100 else { return nil }
        var parts: [String] = []
        // Raw numbers like `${taxRate}%` in the Windows build (8.1, not 8.10).
        func raw(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        if vat != 0 { parts.append("\(raw(vat))% VAT") }
        if ded < 100 && ded > 0 { parts.append("\(raw(ded))% Ded.") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Inline editors (transparent until hovered / focused, like the Windows inputs)

enum NumberParsing {
    /// Accepts "1234.5", "1234,5", "1'234.50".
    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    /// Raw editable form: no grouping, up to 2 decimals, empty for 0 (placeholder "0").
    static func editable(_ value: Double) -> String {
        guard abs(value) >= 0.005 else { return "" }
        if abs(value - value.rounded()) < 0.005 { return String(Int(value.rounded())) }
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

/// Budget / Actual cell. Renders as Text and turns into a TextField only while being edited
/// (click, or Tab from the previous cell — see EditFocus); with no EditFocus in the environment
/// it is always a live field.
struct InlineNumberField: View {
    let value: Double
    var color: Color = Zen.ink
    var weight: Font.Weight = .regular
    /// Identifies the cell in the EditFocus tab order.
    var cellID: String? = nil
    /// Called on every edit (nil when emptied), like the Windows onChange handlers.
    let onChange: (Double?) -> Void

    @Environment(EditFocus.self) private var editFocus: EditFocus?

    var body: some View {
        if let editFocus, let cellID, editFocus.active != cellID {
            let shown = NumberParsing.editable(value)
            Text(shown.isEmpty ? "0" : shown)
                .font(.zen(12, weight))
                .zenAmount()
                .foregroundStyle(shown.isEmpty ? Zen.ink3 : color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture { editFocus.active = cellID }
        } else {
            NumberEditor(value: value, color: color, weight: weight, autoFocus: cellID != nil && editFocus != nil,
                         onChange: onChange) { if let cellID { editFocus?.end(cellID) } }
        }
    }
}

private struct NumberEditor: View {
    let value: Double
    let color: Color
    let weight: Font.Weight
    let autoFocus: Bool
    let onChange: (Double?) -> Void
    let onEnd: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("0").foregroundStyle(Zen.ink3))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.zen(12, weight))
            .zenAmount()
            .foregroundStyle(focused ? Zen.ink : color)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Zen.line : .clear, lineWidth: 1))
            .focused($focused)
            .onAppear {
                text = NumberParsing.editable(value)
                if autoFocus { focused = true }
            }
            .onChange(of: value) { _, newValue in
                if !focused { text = NumberParsing.editable(newValue) }
            }
            .onChange(of: text) { _, newText in
                guard focused else { return }
                let parsed = NumberParsing.parse(newText)
                if newText.isEmpty || parsed != nil { onChange(parsed) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    text = NumberParsing.editable(value)
                    onEnd()
                }
            }
            .onSubmit { focused = false }
            .onExitCommand { focused = false }
    }
}

/// Category name cell; same click-to-edit behaviour as InlineNumberField.
struct InlineTextField: View {
    let value: String
    var cellID: String? = nil
    let onChange: (String) -> Void

    @Environment(EditFocus.self) private var editFocus: EditFocus?

    var body: some View {
        if let editFocus, let cellID, editFocus.active != cellID {
            Text(value)
                .font(.zen(12))
                .foregroundStyle(Zen.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editFocus.active = cellID }
        } else {
            NameEditor(value: value, autoFocus: cellID != nil && editFocus != nil, onChange: onChange) {
                if let cellID { editFocus?.end(cellID) }
            }
        }
    }
}

private struct NameEditor: View {
    let value: String
    let autoFocus: Bool
    let onChange: (String) -> Void
    let onEnd: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.zen(12))
            .foregroundStyle(Zen.ink)
            .lineLimit(1)
            .padding(.horizontal, focused ? 6 : 0)
            // Unfocused, an ellipsized label sits on top (the field itself clips without "…").
            .opacity(focused ? 1 : 0)
            .overlay(alignment: .leading) {
                if !focused {
                    Text(text)
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }
            }
            .background(focused ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .onAppear {
                text = value
                if autoFocus { focused = true }
            }
            .onChange(of: value) { _, newValue in if !focused { text = newValue } }
            .onChange(of: text) { _, newText in if focused && newText != value { onChange(newText) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { onEnd() } }
            .onSubmit { focused = false }
            .onExitCommand { focused = false }
    }
}

// MARK: - Budget summary box

private struct BudgetSummaryBox: View {
    let summary: MonthSummaryMetrics
    private let col: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("BUDGET SUMMARY").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text("BUDGET").opacity(0.8).frame(width: col, alignment: .trailing)
                Text("ACTUAL").opacity(0.8).frame(width: col, alignment: .trailing)
                Text("DIFFERENCE").opacity(0.8).frame(width: col, alignment: .trailing)
            }
            .font(.zen(11))
            .tracking(0.9)
            .foregroundStyle(Zen.onInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Zen.ink)

            row("Total Income", summary.incomeBudget, summary.incomeActual, summary.incomeDifference, actualColor: Zen.positive)
            Rectangle().fill(Zen.line).frame(height: 1)
            row("Total Expenses", summary.totalOutflowBudget, summary.totalOutflowActual, summary.totalOutflowDifference, actualColor: Zen.ink)
            Rectangle().fill(Zen.line).frame(height: 1)

            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("NET").foregroundStyle(Zen.ink)
                    Text("\(String(format: "%.1f", summary.savingsRatePct))% retained")
                        .font(.zen(11))
                        .zenAmount()
                        .foregroundStyle(Zen.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Zen.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Zen.line, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(KobanFormat.number(summary.netBudget)).foregroundStyle(Zen.ink2).frame(width: col, alignment: .trailing)
                Text(KobanFormat.number(summary.netActual))
                    .foregroundStyle(summary.netActual >= 0 ? Zen.positive : Zen.accent)
                    .frame(width: col, alignment: .trailing)
                Text(signed(summary.netDifference))
                    .foregroundStyle(summary.netDifference >= 0 ? Zen.positive : Zen.accent)
                    .frame(width: col, alignment: .trailing)
            }
            .font(.zen(13, .semibold))
            .zenAmount()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Zen.raised.opacity(0.7))
        }
        .background(Zen.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.ink.opacity(0.8), lineWidth: 2))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

    private func row(_ label: String, _ budget: Double, _ actual: Double, _ diff: Double, actualColor: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.medium).foregroundStyle(Zen.ink).frame(maxWidth: .infinity, alignment: .leading)
            Text(KobanFormat.number(budget)).foregroundStyle(Zen.ink2).frame(width: col, alignment: .trailing)
            Text(KobanFormat.number(actual)).fontWeight(.semibold).foregroundStyle(actualColor).frame(width: col, alignment: .trailing)
            Text(signed(diff)).fontWeight(.medium).foregroundStyle(diff >= 0 ? Zen.positive : Zen.accent)
                .frame(width: col, alignment: .trailing)
        }
        .font(.zen(13))
        .zenAmount()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Freelancer tax strip

private struct FreelancerStrip: View {
    let summary: MonthSummaryMetrics
    let currency: String
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            card("Gross Revenue", summary.incomeActual, Zen.positive,
                 "VAT Collected: \(KobanFormat.currency(summary.vatCollected, code: currency))")
            card("Deductible Business Expenses", summary.deductibleExpensesActual, Zen.indigo,
                 "Input VAT Paid: \(KobanFormat.currency(summary.vatPaidOnExpenses, code: currency))")
            card("Net VAT / MWST Payable", summary.netVatPayable, Zen.ink, "Output VAT − Input Tax Credit")
            card("Est. Income Tax Set-Aside", summary.estimatedTaxReserve, Zen.warning, "Based on net operating profit")
        }
    }

    private func card(_ title: String, _ value: Double, _ color: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ZenEyebrow(title, tracking: 1)
            Text(KobanFormat.currency(value, code: currency))
                .font(.zen(16, .semibold)).zenAmount().foregroundStyle(color)
            Text(detail).font(.zen(11)).foregroundStyle(Zen.ink3)
        }
        .zenCard(padding: 14)
    }
}

// MARK: - Banner & new group form

private struct CarryOverBanner: View {
    let monthKey: String
    let prevKey: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZIcon("doc.on.doc").foregroundStyle(Zen.indigo)
            (Text(monthKey).bold() + Text(" has no budget or actual values yet, while previous month ")
                + Text(prevKey).bold() + Text(" has configured values. Would you like to copy last month's values into ")
                + Text(monthKey).bold() + Text("?"))
                .font(.zen(12))
                .foregroundStyle(Zen.ink)
            Spacer(minLength: 8)
            Button(action: action) {
                HStack(spacing: 6) {
                    ZIcon("doc.on.doc", size: 14)
                    Text("Copy \(prevKey) Values…").fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 14))
        }
        .padding(14)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.indigo.opacity(0.4), lineWidth: 1))
    }
}

private struct NewGroupForm: View {
    @Environment(LedgerStore.self) private var store
    let workspace: ActiveWorkspace
    let onClose: () -> Void
    @State private var name = ""
    @State private var kind: CategoryKind = .expense
    @State private var column = 0
    @State private var mode: LedgerMode = .home
    @FocusState private var nameFocused: Bool

    var body: some View {
        FlowLayout(spacing: 12, alignment: .bottom) {
            field("Group Name") {
                TextField("", text: $name, prompt: Text("e.g. REAL ESTATE, SIDE PROJECT, PETS").foregroundStyle(Zen.ink3))
                    .zenField()
                    .frame(minWidth: 220, idealWidth: 280)
                    .focused($nameFocused)
                    .onSubmit(create)
            }
            if workspace == .combined {
                field("Ledger Mode") {
                    ZenSelect(options: [(LedgerMode.home, "Home Budget"), (.freelancer, "Freelancer")], selection: $mode)
                }
            }
            field("Type") {
                ZenSelect(options: [(CategoryKind.expense, "Expense Group"), (.income, "Income Group"),
                                    (.savings, "Savings / Reserve")], selection: $kind)
            }
            field("Worksheet Column") {
                ZenSelect(options: [(0, "Left Column"), (1, "Right Column")], selection: $column)
            }
            Button("Create Group", action: create).buttonStyle(.zen(.ink, padding: 16)).fontWeight(.medium)
            Button("Cancel", action: onClose).buttonStyle(.zen(.ghost))
        }
        .zenCard(padding: 16)
        .onAppear {
            mode = workspace == .freelancer ? .freelancer : .home
            nameFocused = true
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zen(11)).foregroundStyle(Zen.ink2)
            content()
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let m: LedgerMode = workspace == .combined ? mode : (workspace == .freelancer ? .freelancer : .home)
        store.addGroup(mode: m, name: trimmed.uppercased(), kind: kind, column: column)
        name = ""
        onClose()
    }
}

// MARK: - Month copy confirmation (shown by MainView over the whole window)

struct MonthCopyModal: View {
    @Environment(LedgerStore.self) private var store
    @State var request: LedgerStore.CopyRequest
    @State private var dontAskAgain = false

    var body: some View {
        ZenModal(onDismiss: { store.copyRequest = nil }) {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        ZIcon("exclamationmark.triangle").foregroundStyle(Zen.accent)
                        Text("Confirm Copying Monthly Values").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    }
                    Spacer()
                    ZenMiniButton(icon: "xmark", size: 16) { store.copyRequest = nil }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Zen.app.opacity(0.6))
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

                VStack(alignment: .leading, spacing: 16) {
                    (Text("Are you sure you want to copy values from ") + Text(request.source).fontWeight(.semibold)
                        + Text(" into ") + Text(request.target).fontWeight(.semibold) + Text("?"))
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink)
                        .lineSpacing(3)

                    if request.mode != .allMonths {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Values to Copy").font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                                ZenSelect(options: [(MonthCopyScope.budgetsAndActuals, "Both Planned Budgets & Direct Actuals"),
                                                    (.budgetsOnly, "Planned Budgets Only (Leave Actuals at 0)")],
                                          selection: $request.scope, background: Zen.surface)
                            }
                            ZenCheckbox(isOn: $request.overwriteExisting,
                                        label: "Overwrite existing non-zero entries in \(request.target)")
                            if request.mode == .currentToNext {
                                ZenCheckbox(isOn: $request.navigateToTarget,
                                            label: "Switch active month to \(request.target) after copying")
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
                    }

                    ZenCheckbox(isOn: $dontAskAgain,
                                label: "Don't ask for confirmation again (can be changed in Settings)",
                                fontSize: 11, color: Zen.ink3)
                        .padding(.top, 4)
                }
                .padding(20)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { store.copyRequest = nil }
                        .buttonStyle(.zen(.outline, padding: 14))
                        .keyboardShortcut(.cancelAction)
                    Button {
                        store.performCopy(request, disableFutureConfirm: dontAskAgain)
                        store.copyRequest = nil
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("doc.on.doc", size: 14)
                            Text("Yes, Copy Values").fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.zen(.ink, padding: 16))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Zen.app.opacity(0.5))
                .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
            }
        }
    }
}

// MARK: - Flow layout (flex-wrap)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for idx in row.indices {
                let size = subviews[idx].sizeThatFits(.unspecified)
                let dy: CGFloat = alignment == .bottom ? row.height - size.height
                    : alignment == .top ? 0 : (row.height - size.height) / 2
                subviews[idx].place(at: CGPoint(x: x, y: y + dy), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for idx in subviews.indices {
            let size = subviews[idx].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(idx)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
