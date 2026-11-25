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
    @State private var budgetW: CGFloat = 86
    @State private var actualW: CGFloat = 86
    @State private var diffW: CGFloat = 78
    @State private var leftPanePct: CGFloat = 50
    @State private var dragStartColWidth: CGFloat? = nil
    @State private var dragStartSplitPct: CGFloat? = nil
    @State private var resizingCol: ResizableWorksheetCol? = nil
    @State private var resizingSplit = false

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
        let sortBy = settings.worksheetSortBy ?? .manual
        let sortDir = settings.worksheetSortDir ?? .asc
        let prevKey = adjacentKey(-1), nextKey = adjacentKey(1)
        let monthEmpty = summary.incomeBudget == 0 && summary.incomeActual == 0
            && summary.totalOutflowBudget == 0 && summary.totalOutflowActual == 0
        let showBanner = monthEmpty && (settings.autoPromptCopyOnEmptyMonth ?? true)
            && store.monthHasData(monthKey: prevKey, workspace: workspace)
        let singleMinWidth = 170 + budgetW + actualW + diffW + Cols.actions + 40
        let twoColumns = contentWidth >= max(900, singleMinWidth * 2 + 12)
        let leftGroups = summary.groups.filter { $0.group.column == 0 }
        let rightGroups = summary.groups.filter { $0.group.column != 0 }
        let hasCustomWidths = budgetW != 86 || actualW != 86 || diffW != 78 || leftPanePct != 50
        let sortOptions: [(WorksheetSortField, String)] = [
            (.manual, L10n.t("worksheet.sortManual")),
            (.name, L10n.t("worksheet.sortName")),
            (.budget, L10n.t("worksheet.sortBudget")),
            (.actual, L10n.t("worksheet.sortActual")),
            (.diff, L10n.t("worksheet.sortDiff")),
        ]
        // Tab order matches displayed sort order: left column, then right; name → budget → actual per row.
        let _ = editFocus.order = (leftGroups + rightGroups).flatMap { gs in
            let visible = gs.rows.filter { !(hideZero && $0.budget == 0 && $0.actual == 0 && $0.txCount == 0) }
            let sorted = LedgerState.sortWorksheetRows(visible, by: sortBy, direction: sortDir) { L10n.categoryName($0) }
            return sorted.flatMap { ["\($0.category.id)#name", "\($0.category.id)#budget", "\($0.category.id)#actual"] }
        }

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header + toolbar
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace == .home ? L10n.t("worksheet.titleHome")
                             : workspace == .freelancer ? L10n.t("worksheet.titleFreelancer")
                             : L10n.t("worksheet.titleCombined"))
                            .font(.zen(20))
                            .foregroundStyle(Zen.ink)
                        Text(L10n.t("worksheet.subtitle"))
                            .font(.zen(12))
                            .foregroundStyle(Zen.ink2)
                    }

                    FlowLayout(spacing: 8) {
                        HStack(spacing: 4) {
                            Menu {
                                ForEach(sortOptions, id: \.0) { field, label in
                                    Button {
                                        let nextDir: WorksheetSortDirection = (field == .name || field == .manual) ? .asc : .desc
                                        store.setWorksheetSort(by: field, direction: nextDir)
                                    } label: {
                                        if sortBy == field {
                                            Label(label, systemImage: "checkmark")
                                        } else {
                                            Text(label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    ZIcon("arrow.up.arrow.down", size: 13).foregroundStyle(Zen.ink3)
                                    Text("\(L10n.t("worksheet.sortLabel")): \(sortOptions.first(where: { $0.0 == sortBy })?.1 ?? "")")
                                        .font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(1)
                                    ZIcon("chevron.down", size: 11).foregroundStyle(Zen.ink3)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)

                            if sortBy != .manual {
                                Button {
                                    store.setWorksheetSort(by: sortBy, direction: sortDir == .asc ? .desc : .asc)
                                } label: {
                                    ZIcon(sortDir == .asc ? "arrow.up" : "arrow.down", size: 13)
                                        .foregroundStyle(Zen.indigo)
                                }
                                .buttonStyle(.zen(.outline, padding: 8))
                            }
                        }

                        if hasCustomWidths {
                            Button { resetAllWidths() } label: {
                                HStack(spacing: 6) {
                                    ZIcon("arrow.counterclockwise", size: 13)
                                    Text(L10n.t("worksheet.resetWidthsBtn"))
                                }
                            }
                            .buttonStyle(.zenOutline)
                            .help(L10n.t("worksheet.resizeColTip"))
                        }

                        Button { hideZeroRows = !hideZero } label: {
                            HStack(spacing: 6) {
                                ZIcon(hideZero ? "eye" : "eye.slash", size: 14)
                                    .foregroundStyle(hideZero ? Zen.accent : Zen.ink2)
                                Text(hideZero ? L10n.t("worksheet.showingActive") : L10n.t("worksheet.hideZeroRows"))
                                    .fontWeight(hideZero ? .medium : .regular)
                            }
                        }
                        .buttonStyle(.zen(.outline, active: hideZero))
                        .overlay {
                            if hideZero { RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.ink, lineWidth: 1) }
                        }
                        .help(L10n.t("worksheet.hideZeroRowsTip"))

                        Button { requestCopy(.prevToCurrent) } label: {
                            HStack(spacing: 6) {
                                ZIcon("doc.on.doc", size: 14).foregroundStyle(Zen.indigo)
                                Text(L10n.tf("worksheet.copyPrevHere", ["prev": prevKey]))
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help(L10n.tf("worksheet.copyPrevHereTip", ["prev": prevKey, "curr": summary.monthKey]))

                        Button { requestCopy(.currentToNext) } label: {
                            HStack(spacing: 6) {
                                ZIcon("arrow.right", size: 14).foregroundStyle(Zen.positive)
                                Text(L10n.tf("worksheet.copyNextMonth", ["next": nextKey]))
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help(L10n.tf("worksheet.copyNextMonthTip", ["curr": summary.monthKey, "next": nextKey]))

                        Button { requestCopy(.allMonths) } label: {
                            HStack(spacing: 6) {
                                ZIcon("doc.on.doc", size: 14).foregroundStyle(Zen.positive)
                                Text(L10n.t("worksheet.applyAll12"))
                            }
                        }
                        .buttonStyle(.zenOutline)
                        .help(L10n.t("worksheet.applyAll12Tip"))

                        Button { showNewGroupForm.toggle() } label: {
                            HStack(spacing: 6) {
                                ZIcon("folder.badge.plus", size: 14)
                                Text(L10n.t("worksheet.newGroup"))
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
                let colMetrics = WorksheetColWidths(budget: budgetW, actual: actualW, diff: diffW)
                let summaryBox = BudgetSummaryBox(
                    summary: summary,
                    cols: colMetrics,
                    sortBy: sortBy,
                    sortDir: sortDir,
                    resizingCol: resizingCol,
                    onCycleSort: cycleSort,
                    onResizeCol: handleColResize,
                    onEndResizeCol: commitColWidths,
                    onResetColWidths: resetNumericWidths
                )

                // Lazy per row: group cards are split into header / row / footer items so only the
                // rows on screen are built (each item draws its slice of the card outline).
                if twoColumns {
                    let avail = max(400, contentWidth - 12)
                    let leftW = (avail * leftPanePct / 100).rounded()
                    let rightW = avail - leftW
                    HStack(alignment: .top, spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(left.enumerated()), id: \.element.id) { idx, gs in
                                groupItems(gs, first: idx == 0, hideZero: hideZero, workspace: workspace,
                                           sortBy: sortBy, sortDir: sortDir, cols: colMetrics)
                            }
                        }
                        .frame(width: leftW, alignment: .top)

                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 12)
                            .overlay {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(resizingSplit ? Zen.indigo : Zen.line.opacity(0.75))
                                    .frame(width: 2)
                                    .padding(.vertical, 8)
                            }
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                    .onChanged { val in
                                        let startPct = dragStartSplitPct ?? leftPanePct
                                        if dragStartSplitPct == nil {
                                            dragStartSplitPct = startPct
                                            resizingSplit = true
                                        }
                                        let startPx = (startPct / 100) * avail
                                        let next = ((startPx + val.translation.width) / avail * 100).rounded()
                                        leftPanePct = min(66, max(34, next))
                                    }
                                    .onEnded { _ in
                                        dragStartSplitPct = nil
                                        resizingSplit = false
                                        commitColWidths()
                                    }
                            )
                            .onTapGesture(count: 2) {
                                leftPanePct = 50
                                commitColWidths()
                            }
                            .help(L10n.t("worksheet.resizeSplitTip"))

                        LazyVStack(spacing: 0) {
                            summaryBox
                            ForEach(right) {
                                groupItems($0, first: false, hideZero: hideZero, workspace: workspace,
                                           sortBy: sortBy, sortDir: sortDir, cols: colMetrics)
                            }
                        }
                        .frame(width: rightW, alignment: .top)
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(left.enumerated()), id: \.element.id) { idx, gs in
                            groupItems(gs, first: idx == 0, hideZero: hideZero, workspace: workspace,
                                       sortBy: sortBy, sortDir: sortDir, cols: colMetrics)
                        }
                        summaryBox.padding(.top, left.isEmpty ? 0 : 20)
                        ForEach(right) {
                            groupItems($0, first: false, hideZero: hideZero, workspace: workspace,
                                       sortBy: sortBy, sortDir: sortDir, cols: colMetrics)
                        }
                    }
                }

                if summary.groups.isEmpty {
                    Text(L10n.t("worksheet.emptyGroups"))
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
            syncWidthsFromSettings(settings.worksheetColumnWidths)
            // Tabbing into a row that is off-screen scrolls it into view.
            editFocus.onMove = { cellID in
                let rowID = String(cellID.prefix(while: { $0 != "#" }))
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rowID) }
            }
        }
        .onChange(of: settings.worksheetColumnWidths) { _, newWidths in
            syncWidthsFromSettings(newWidths)
        }
        }
        .environment(editFocus)
        .alert(item: $pendingDelete) { target in
            switch target {
            case .category(let id, let name):
                return Alert(title: Text(L10n.tf("worksheet.deleteCatAlertTitle", ["name": L10n.categoryName(name)])),
                             message: Text(L10n.t("worksheet.deleteCatAlertMsg")),
                             primaryButton: .destructive(Text(L10n.t("common.delete"))) { store.deleteCategory(id) },
                             secondaryButton: .cancel(Text(L10n.t("common.cancel"))))
            case .group(let id, let name):
                return Alert(title: Text(L10n.tf("worksheet.deleteGrpAlertTitle", ["name": L10n.groupName(name)])),
                             message: Text(L10n.t("worksheet.deleteGrpAlertMsg")),
                             primaryButton: .destructive(Text(L10n.t("common.delete"))) { store.deleteGroup(id) },
                             secondaryButton: .cancel(Text(L10n.t("common.cancel"))))
            }
        }
    }

    @ViewBuilder
    private func groupItems(_ gs: GroupComputedSummary, first: Bool, hideZero: Bool,
                            workspace: ActiveWorkspace,
                            sortBy: WorksheetSortField, sortDir: WorksheetSortDirection,
                            cols: WorksheetColWidths) -> some View {
        let filtered = gs.rows.filter { !(hideZero && $0.budget == 0 && $0.actual == 0 && $0.txCount == 0) }
        let rows = LedgerState.sortWorksheetRows(filtered, by: sortBy, direction: sortDir) { L10n.categoryName($0) }
        let sortedRowIds = rows.map(\.category.id)
        // Tax badges only from the Windows `xl` breakpoint (1280 px window) up.
        let showTax = contentWidth >= 976
        let adding = addingGroupId == gs.group.id
        GroupHeader(gs: gs, showMode: workspace == .combined,
                    cols: cols, sortBy: sortBy, sortDir: sortDir, resizingCol: resizingCol,
                    sortedRowIds: sortedRowIds,
                    onCycleSort: cycleSort,
                    onResizeCol: handleColResize,
                    onEndResizeCol: commitColWidths,
                    onResetColWidths: resetNumericWidths,
                    onDropAtTop: { draggedId in
                        store.reorderCategories(draggedCategoryId: draggedId, targetGroupId: gs.group.id,
                                                targetCategoryId: sortedRowIds.first, position: .before,
                                                baseOrderIds: sortedRowIds)
                    },
                    onAdd: { addingGroupId = adding ? nil : gs.group.id },
                    onDelete: { requestDelete(.group(id: gs.group.id, name: gs.group.name)) })
            .cardPiece(top: true)
            .padding(.top, first ? 0 : 20)
        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
            CategoryRow(row: row, isLast: idx == rows.count - 1, showTaxBadge: showTax,
                        cols: cols, sortedRowIds: sortedRowIds) {
                requestDelete(.category(id: row.category.id, name: row.category.name))
            }
            .cardPiece()
        }
        if adding {
            AddCategoryForm(gs: gs) { addingGroupId = nil }.cardPiece()
        }
        GroupFooter(gs: gs, cols: cols) { draggedId in
            store.reorderCategories(draggedCategoryId: draggedId, targetGroupId: gs.group.id,
                                    targetCategoryId: nil, position: .after, baseOrderIds: sortedRowIds)
        }
        .cardPiece(bottom: true)
    }

    private func syncWidthsFromSettings(_ w: WorksheetColumnWidths?) {
        guard let w else { return }
        budgetW = CGFloat(w.budget)
        actualW = CGFloat(w.actual)
        diffW = CGFloat(w.diff)
        leftPanePct = CGFloat(w.leftPanePct ?? 50)
    }

    private func cycleSort(_ field: WorksheetSortField) {
        let sortBy = store.state.settings.worksheetSortBy ?? .manual
        let sortDir = store.state.settings.worksheetSortDir ?? .asc
        let defaultDir: WorksheetSortDirection = field == .name ? .asc : .desc
        if sortBy != field {
            store.setWorksheetSort(by: field, direction: defaultDir)
        } else if sortDir == defaultDir {
            store.setWorksheetSort(by: field, direction: defaultDir == .asc ? .desc : .asc)
        } else {
            store.setWorksheetSort(by: .manual, direction: .asc)
        }
    }

    private func handleColResize(_ col: ResizableWorksheetCol, dx: CGFloat) {
        let current: CGFloat = switch col {
        case .budget: budgetW
        case .actual: actualW
        case .diff: diffW
        }
        if dragStartColWidth == nil {
            dragStartColWidth = current
            resizingCol = col
        }
        let start = dragStartColWidth ?? current
        let minW: CGFloat = col == .diff ? 60 : 64
        let next = min(180, max(minW, (start - dx).rounded()))
        switch col {
        case .budget: budgetW = next
        case .actual: actualW = next
        case .diff: diffW = next
        }
    }

    private func commitColWidths() {
        dragStartColWidth = nil
        resizingCol = nil
        store.setWorksheetColumnWidths(WorksheetColumnWidths(
            budget: Double(budgetW),
            actual: Double(actualW),
            diff: Double(diffW),
            leftPanePct: Double(leftPanePct)
        ))
    }

    private func resetNumericWidths() {
        budgetW = 86
        actualW = 86
        diffW = 78
        commitColWidths()
    }

    private func resetAllWidths() {
        budgetW = 86
        actualW = 86
        diffW = 78
        leftPanePct = 50
        commitColWidths()
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
                : mode == .currentToNext ? adjacentKey(1) : L10n.tf("worksheet.copyModalAll12Target", ["year": String(s.activeYear)]),
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

// MARK: - Grid metrics & column resizing

private enum ResizableWorksheetCol {
    case budget, actual, diff
}

private struct WorksheetColWidths {
    var budget: CGFloat = 86
    var actual: CGFloat = 86
    var diff: CGFloat = 78
}

private enum Cols {
    static let actions: CGFloat = 52
    static let gap: CGFloat = 4
    /// Width & height of each row icon slot (recurring, fixed cost, reset), so icons line up.
    static let iconSlot: CGFloat = 20
}

private struct WorksheetColResizeHeader: View {
    let label: String
    let field: WorksheetSortField
    let col: ResizableWorksheetCol
    let width: CGFloat
    let sortBy: WorksheetSortField
    let sortDir: WorksheetSortDirection
    let resizing: Bool
    var textColor: Color = Zen.ink2
    var activeColor: Color = Zen.ink
    var arrowColor: Color = Zen.indigo
    var handleIdleColor: Color = Zen.line.opacity(0.75)
    var handleActiveColor: Color = Zen.indigo
    var helpText: String
    let onSort: () -> Void
    let onResize: (CGFloat) -> Void
    let onEndResize: () -> Void
    let onReset: () -> Void

    @State private var hoveringHandle = false

    var body: some View {
        let isActive = sortBy == field
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            Button(action: onSort) {
                HStack(spacing: 3) {
                    Text(label).lineLimit(1)
                    if isActive {
                        ZIcon(sortDir == .asc ? "arrow.up" : "arrow.down", size: 10, weight: .semibold)
                            .foregroundStyle(arrowColor)
                    }
                }
                .foregroundStyle(isActive ? activeColor : textColor)
                .fontWeight(isActive ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .help("\(L10n.t("worksheet.sortLabel")): \(label)")
        }
        .frame(width: width, alignment: .trailing)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 1)
                        .fill((resizing || hoveringHandle) ? handleActiveColor : handleIdleColor)
                        .frame(width: 2, height: 14)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering && !hoveringHandle {
                        NSCursor.resizeLeftRight.push()
                    } else if !hovering && hoveringHandle {
                        NSCursor.pop()
                    }
                    hoveringHandle = hovering
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { onResize($0.translation.width) }
                        .onEnded { _ in onEndResize() }
                )
                .onTapGesture(count: 2, perform: onReset)
                .help(helpText)
                .offset(x: -4)
        }
    }
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
    let cols: WorksheetColWidths
    let sortBy: WorksheetSortField
    let sortDir: WorksheetSortDirection
    let resizingCol: ResizableWorksheetCol?
    let sortedRowIds: [String]
    let onCycleSort: (WorksheetSortField) -> Void
    let onResizeCol: (ResizableWorksheetCol, CGFloat) -> Void
    let onEndResizeCol: () -> Void
    let onResetColWidths: () -> Void
    let onDropAtTop: (String) -> Void
    let onAdd: () -> Void
    let onDelete: () -> Void

    @State private var headerTargeted = false

    var body: some View {
        HStack(spacing: Cols.gap) {
            HStack(spacing: 6) {
                Circle().fill(Color(hexString: gs.group.color)).frame(width: 10, height: 10)
                Text(L10n.groupName(gs.group).uppercased())
                    .font(.zen(11, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Zen.ink)
                    .lineLimit(1)
                if showMode {
                    Text((gs.group.mode == .home ? L10n.t("workspace.home") : L10n.t("workspace.freelancer")).uppercased())
                        .font(.zen(9))
                        .foregroundStyle(Zen.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 0)
                Button { onCycleSort(.name) } label: {
                    HStack(spacing: 2) {
                        Text("A–Z").font(.zen(10))
                        if sortBy == .name {
                            ZIcon(sortDir == .asc ? "arrow.up" : "arrow.down", size: 9, weight: .semibold)
                                .foregroundStyle(Zen.indigo)
                        }
                    }
                    .foregroundStyle(sortBy == .name ? Zen.ink : Zen.ink3)
                    .fontWeight(sortBy == .name ? .semibold : .regular)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(sortBy == .name ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(sortBy == .name ? Zen.line : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("\(L10n.t("worksheet.sortLabel")): \(L10n.t("worksheet.sortName"))")
            }
            .padding(.trailing, 2)

            WorksheetColResizeHeader(
                label: L10n.t("finance.budget"),
                field: .budget,
                col: .budget,
                width: cols.budget,
                sortBy: sortBy,
                sortDir: sortDir,
                resizing: resizingCol == .budget,
                helpText: L10n.t("worksheet.resizeColTip"),
                onSort: { onCycleSort(.budget) },
                onResize: { onResizeCol(.budget, $0) },
                onEndResize: onEndResizeCol,
                onReset: onResetColWidths
            )
            .font(.zen(11))

            WorksheetColResizeHeader(
                label: L10n.t("finance.actual"),
                field: .actual,
                col: .actual,
                width: cols.actual,
                sortBy: sortBy,
                sortDir: sortDir,
                resizing: resizingCol == .actual,
                helpText: L10n.t("worksheet.resizeColTip"),
                onSort: { onCycleSort(.actual) },
                onResize: { onResizeCol(.actual, $0) },
                onEndResize: onEndResizeCol,
                onReset: onResetColWidths
            )
            .font(.zen(11))

            WorksheetColResizeHeader(
                label: L10n.t("worksheet.diffShort"),
                field: .diff,
                col: .diff,
                width: cols.diff,
                sortBy: sortBy,
                sortDir: sortDir,
                resizing: resizingCol == .diff,
                helpText: L10n.t("worksheet.resizeColTip"),
                onSort: { onCycleSort(.diff) },
                onResize: { onResizeCol(.diff, $0) },
                onEndResize: onEndResizeCol,
                onReset: onResetColWidths
            )
            .font(.zen(11))
            .padding(.trailing, 4)

            HStack(spacing: 2) {
                ZenMiniButton(icon: "plus", size: 14, tint: Zen.ink2, help: L10n.t("worksheet.addCategoryTip"), action: onAdd)
                ZenMiniButton(icon: "trash", size: 13, tint: Zen.ink2, hoverTint: Zen.accent, help: L10n.t("worksheet.deleteGroupTip"), action: onDelete)
            }
            .frame(width: Cols.actions, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .background(headerTargeted ? Zen.indigo.opacity(0.12) : Zen.raised.opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(headerTargeted ? Zen.indigo : Zen.line).frame(height: headerTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let draggedId = items.first else { return false }
            onDropAtTop(draggedId)
            return true
        } isTargeted: { headerTargeted = $0 }
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
            TextField("", text: $newName, prompt: Text(L10n.t("worksheet.newCategoryPlaceholder")).foregroundStyle(Zen.ink3))
                .zenField(height: 28, background: Zen.surface)
                .onSubmit(create)
            TextField("", text: $newBudget, prompt: Text(L10n.t("worksheet.budgetZeroPlaceholder")).foregroundStyle(Zen.ink3))
                .multilineTextAlignment(.trailing)
                .zenAmount()
                .zenField(height: 28, background: Zen.surface)
                .frame(width: 96)
                .onSubmit(create)
            Button(L10n.t("common.add"), action: create).buttonStyle(.zen(.ink, height: 28, radius: 4, padding: 10))
            Button(L10n.t("common.cancel"), action: onDone).buttonStyle(.zen(.ghost, height: 28, radius: 4, padding: 8))
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
    let cols: WorksheetColWidths
    let onDropAtEnd: (String) -> Void
    @State private var footerTargeted = false

    var body: some View {
        HStack(spacing: Cols.gap) {
            Text(L10n.tf("worksheet.totalGroup", ["group": L10n.groupName(gs.group)])).foregroundStyle(Zen.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(KobanFormat.number(gs.totalBudget)).foregroundStyle(Zen.ink2).lineLimit(1)
                .padding(.horizontal, 6).frame(width: cols.budget, alignment: .trailing)
            Text(KobanFormat.number(gs.totalActual)).foregroundStyle(Zen.ink).lineLimit(1)
                .padding(.horizontal, 6).frame(width: cols.actual, alignment: .trailing)
            Text(signed(gs.totalDifference)).foregroundStyle(Zen.diff(gs.totalDifference)).lineLimit(1)
                .padding(.trailing, 4).frame(width: cols.diff, alignment: .trailing)
            Color.clear.frame(width: Cols.actions, height: 1)
        }
        .font(.zen(12, .semibold))
        .zenAmount()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(footerTargeted ? Zen.indigo.opacity(0.12) : Zen.app.opacity(0.8))
        .overlay(alignment: .top) {
            Rectangle().fill(footerTargeted ? Zen.indigo : Zen.line).frame(height: footerTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let draggedId = items.first else { return false }
            onDropAtEnd(draggedId)
            return true
        } isTargeted: { footerTargeted = $0 }
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
    let cols: WorksheetColWidths
    let sortedRowIds: [String]
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let cat = row.category
        let recurring = cat.isRecurring ?? false
        let displayName = L10n.categoryName(cat)

        HStack(spacing: Cols.gap) {
            // Strictly single-line Name + badges + compact icons
            HStack(spacing: 4) {
                ZIcon("line.3.horizontal", size: 11, weight: .regular)
                    .foregroundStyle(Zen.ink3.opacity(hovering ? 0.9 : 0.45))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
                    .draggable(cat.id)
                    .help(L10n.t("worksheet.dragRowTip"))

                InlineTextField(value: displayName, cellID: "\(cat.id)#name") { store.renameCategory(cat.id, to: $0) }
                    .help(displayName)
                    .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)

                // Variable-width badges (truncate cleanly if narrow)
                HStack(spacing: 4) {
                    if row.group.kind == .savings {
                        let target = store.state.accounts.first { $0.id == cat.targetAccountId }
                        let eligibleAccounts = store.state.accounts.filter {
                            $0.id == cat.targetAccountId || ($0.mode == cat.mode && $0.classification != .liability)
                        }
                        Menu {
                            Button {
                                store.setCategoryTargetAccount(cat.id, targetAccountId: nil)
                            } label: {
                                if cat.targetAccountId == nil || cat.targetAccountId?.isEmpty == true {
                                    Label("?", systemImage: "checkmark")
                                } else {
                                    Text("?")
                                }
                            }
                            ForEach(eligibleAccounts) { acc in
                                Button {
                                    store.setCategoryTargetAccount(cat.id, targetAccountId: acc.id)
                                } label: {
                                    if cat.targetAccountId == acc.id {
                                        Label(L10n.accountName(acc), systemImage: "checkmark")
                                    } else {
                                        Text(L10n.accountName(acc))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                ZIcon("arrow.right", size: 10, weight: .regular)
                                Text(target.map { L10n.accountName($0) } ?? "?")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.zen(10))
                            .foregroundStyle(target == nil ? Zen.accent : Zen.indigo)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((target == nil ? Zen.accent : Zen.indigo).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: 112, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help(target.map { L10n.tf("worksheet.savingsTargetTip", ["account": L10n.accountName($0)]) }
                              ?? L10n.t("worksheet.savingsNoTargetTip"))
                    }
                    if row.budgetOverridesSchedule {
                        ZenMiniButton(icon: "calendar.badge.clock", size: 12, tint: Zen.indigo.opacity(0.8),
                                      hoverTint: Zen.indigo, help: L10n.t("worksheet.manualBudgetTip")) {
                            store.resetScheduledBudget(categoryId: cat.id)
                        }
                    } else if row.budgetFromSchedule {
                        ZIcon("calendar.badge.clock", size: 12, weight: .regular)
                            .foregroundStyle(Zen.indigo.opacity(0.8))
                            .padding(3)
                            .help(L10n.t("worksheet.scheduledBudgetTip"))
                    }
                    if row.txCount > 0 && row.directActual == nil {
                        Text(L10n.tf("worksheet.txCountSuffix", ["count": row.txCount]))
                            .font(.zen(10)).zenAmount()
                            .foregroundStyle(Zen.ink2)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .help(L10n.tf("worksheet.txCountTip", ["count": row.txCount]))
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

                // Compact icon slots: recurring · fixed cost · reset Actual (omit reset spacer when absent)
                HStack(spacing: 2) {
                    Button { store.toggleCategoryRecurring(cat.id) } label: {
                        ZIcon("repeat", size: 12, weight: .regular)
                            .foregroundStyle(recurring ? Zen.indigo : Zen.ink2.opacity(0.8))
                            .frame(width: Cols.iconSlot, height: Cols.iconSlot)
                            .background(recurring ? Zen.indigo.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(recurring ? Zen.indigo.opacity(0.35) : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t(recurring ? "worksheet.recurringDisableTip" : "worksheet.recurringEnableTip"))

                    if row.group.kind != .income {
                        let fixed = row.isFixedCost
                        Button { store.toggleCategoryFixed(cat.id) } label: {
                            AnchorIcon(size: 12)
                                .foregroundStyle(fixed ? Zen.indigo : Zen.ink2.opacity(0.8))
                                .frame(width: Cols.iconSlot, height: Cols.iconSlot)
                                .background(fixed ? Zen.indigo.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fixed ? Zen.indigo.opacity(0.35) : .clear, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t(fixed ? "worksheet.fixedCostTip" : "worksheet.fixedCostEnableTip"))
                    } else {
                        Color.clear.frame(width: Cols.iconSlot, height: Cols.iconSlot)
                    }

                    if row.directActual != nil {
                        ZenMiniButton(icon: "arrow.counterclockwise", size: 12, tint: Zen.ink2.opacity(0.85),
                                      help: L10n.t("worksheet.manualActualTip")) {
                            store.setDirectActual(nil, categoryId: cat.id)
                        }
                        .frame(width: Cols.iconSlot, height: Cols.iconSlot)
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            InlineNumberField(value: row.budget, color: Zen.ink2, cellID: "\(cat.id)#budget") {
                store.setBudget($0 ?? 0, categoryId: cat.id)
            }
            .frame(width: cols.budget)
            InlineNumberField(value: (row.actual * 100).rounded() / 100,
                              color: row.autoActual ? Zen.indigo : Zen.ink, weight: .medium,
                              italic: row.autoActual, cellID: "\(cat.id)#actual") {
                store.setDirectActual($0 ?? 0, categoryId: cat.id)
            }
            .frame(width: cols.actual)
            .help(row.autoActual ? L10n.t("worksheet.autoActualTip") : "")

            Text(signed(row.difference))
                .font(.zen(12, .medium))
                .zenAmount()
                .foregroundStyle(Zen.diff(row.difference))
                .lineLimit(1)
                .padding(.trailing, 4)
                .frame(width: cols.diff, alignment: .trailing)

            HStack(spacing: 4) {
                ZenMiniButton(icon: "receipt", size: 13, tint: hovering ? Zen.ink2 : Zen.ink2.opacity(0.8), help: L10n.t("worksheet.logTxTip")) {
                    store.openQuickAdd(categoryId: cat.id)
                }
                ZenMiniButton(icon: "trash", size: 13, tint: hovering ? Zen.ink2 : Zen.ink2.opacity(0.8), hoverTint: Zen.accent, help: L10n.t("worksheet.deleteCategoryTip"), action: onDelete)
            }
            .frame(width: Cols.actions, height: 20, alignment: .trailing)
        }
        .font(.zen(12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(dropTargeted ? Zen.indigo.opacity(0.14) : (hovering ? Zen.raised.opacity(0.6) : .clear))
        .overlay(alignment: .bottom) {
            if dropTargeted {
                Rectangle().fill(Zen.indigo).frame(height: 2)
            } else if !isLast {
                Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1)
            }
        }
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, location in
            guard let draggedId = items.first, draggedId != cat.id else { return false }
            let pos: ReorderPosition = location.y < 18 ? .before : .after
            store.reorderCategories(draggedCategoryId: draggedId,
                                    targetGroupId: row.group.id,
                                    targetCategoryId: cat.id,
                                    position: pos,
                                    baseOrderIds: sortedRowIds)
            return true
        } isTargeted: { dropTargeted = $0 }
        .id(cat.id)
    }

    private func taxBadge(_ cat: CategoryItem) -> String? {
        let vat = cat.taxRate ?? 0
        let ded = cat.deductiblePct ?? 100
        guard vat != 0 || ded < 100 else { return nil }
        var parts: [String] = []
        // Raw numbers like `${taxRate}%` in the Windows build (8.1, not 8.10).
        func raw(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        if vat != 0 { parts.append("\(raw(vat))% \(L10n.t("worksheet.vatShort"))") }
        if ded < 100 && ded > 0 { parts.append("\(raw(ded))% \(L10n.t("worksheet.dedShort"))") }
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
    /// Italic while not editing (auto-filled fixed-cost Actuals).
    var italic: Bool = false
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
                .italic(italic)
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
    let cols: WorksheetColWidths
    let sortBy: WorksheetSortField
    let sortDir: WorksheetSortDirection
    let resizingCol: ResizableWorksheetCol?
    let onCycleSort: (WorksheetSortField) -> Void
    let onResizeCol: (ResizableWorksheetCol, CGFloat) -> Void
    let onEndResizeCol: () -> Void
    let onResetColWidths: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Cols.gap) {
                Text(L10n.t("worksheet.budgetSummary").uppercased())
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WorksheetColResizeHeader(
                    label: L10n.t("finance.budget").uppercased(),
                    field: .budget,
                    col: .budget,
                    width: cols.budget,
                    sortBy: sortBy,
                    sortDir: sortDir,
                    resizing: resizingCol == .budget,
                    textColor: Zen.onInk.opacity(0.8),
                    activeColor: Zen.onInk,
                    arrowColor: Zen.onInk,
                    handleIdleColor: Zen.onInk.opacity(0.35),
                    handleActiveColor: Zen.onInk,
                    helpText: L10n.t("worksheet.resizeColTip"),
                    onSort: { onCycleSort(.budget) },
                    onResize: { onResizeCol(.budget, $0) },
                    onEndResize: onEndResizeCol,
                    onReset: onResetColWidths
                )
                WorksheetColResizeHeader(
                    label: L10n.t("finance.actual").uppercased(),
                    field: .actual,
                    col: .actual,
                    width: cols.actual,
                    sortBy: sortBy,
                    sortDir: sortDir,
                    resizing: resizingCol == .actual,
                    textColor: Zen.onInk.opacity(0.8),
                    activeColor: Zen.onInk,
                    arrowColor: Zen.onInk,
                    handleIdleColor: Zen.onInk.opacity(0.35),
                    handleActiveColor: Zen.onInk,
                    helpText: L10n.t("worksheet.resizeColTip"),
                    onSort: { onCycleSort(.actual) },
                    onResize: { onResizeCol(.actual, $0) },
                    onEndResize: onEndResizeCol,
                    onReset: onResetColWidths
                )
                WorksheetColResizeHeader(
                    label: L10n.t("worksheet.difference").uppercased(),
                    field: .diff,
                    col: .diff,
                    width: cols.diff,
                    sortBy: sortBy,
                    sortDir: sortDir,
                    resizing: resizingCol == .diff,
                    textColor: Zen.onInk.opacity(0.8),
                    activeColor: Zen.onInk,
                    arrowColor: Zen.onInk,
                    handleIdleColor: Zen.onInk.opacity(0.35),
                    handleActiveColor: Zen.onInk,
                    helpText: L10n.t("worksheet.resizeColTip"),
                    onSort: { onCycleSort(.diff) },
                    onResize: { onResizeCol(.diff, $0) },
                    onEndResize: onEndResizeCol,
                    onReset: onResetColWidths
                )
            }
            .font(.zen(11))
            .tracking(0.9)
            .foregroundStyle(Zen.onInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Zen.ink)

            row(L10n.t("sidebar.totalIncome"), summary.incomeBudget, summary.incomeActual, summary.incomeDifference, actualColor: Zen.positive)
            Rectangle().fill(Zen.line).frame(height: 1)
            row(L10n.t("sidebar.totalExpenses"), summary.totalOutflowBudget, summary.totalOutflowActual, summary.totalOutflowDifference, actualColor: Zen.ink)
            Rectangle().fill(Zen.line).frame(height: 1)

            HStack(spacing: Cols.gap) {
                HStack(spacing: 6) {
                    Text(L10n.t("finance.net").uppercased()).foregroundStyle(Zen.ink).lineLimit(1)
                    Text(L10n.tf("worksheet.retainedPct", ["pct": String(format: "%.1f", summary.savingsRatePct)]))
                        .font(.zen(11))
                        .zenAmount()
                        .foregroundStyle(Zen.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Zen.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Zen.line, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(KobanFormat.number(summary.netBudget)).foregroundStyle(Zen.ink2).lineLimit(1)
                    .frame(width: cols.budget, alignment: .trailing)
                Text(KobanFormat.number(summary.netActual))
                    .foregroundStyle(summary.netActual >= 0 ? Zen.positive : Zen.accent)
                    .lineLimit(1)
                    .frame(width: cols.actual, alignment: .trailing)
                Text(signed(summary.netDifference))
                    .foregroundStyle(summary.netDifference >= 0 ? Zen.positive : Zen.accent)
                    .lineLimit(1)
                    .frame(width: cols.diff, alignment: .trailing)
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
        HStack(spacing: Cols.gap) {
            Text(label).fontWeight(.medium).foregroundStyle(Zen.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(KobanFormat.number(budget)).foregroundStyle(Zen.ink2).lineLimit(1)
                .frame(width: cols.budget, alignment: .trailing)
            Text(KobanFormat.number(actual)).fontWeight(.semibold).foregroundStyle(actualColor).lineLimit(1)
                .frame(width: cols.actual, alignment: .trailing)
            Text(signed(diff)).fontWeight(.medium).foregroundStyle(diff >= 0 ? Zen.positive : Zen.accent).lineLimit(1)
                .frame(width: cols.diff, alignment: .trailing)
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
            card(L10n.t("worksheet.grossRevenue"), summary.incomeActual, Zen.positive,
                 L10n.tf("worksheet.vatCollected", ["amount": KobanFormat.currency(summary.vatCollected, code: currency)]))
            card(L10n.t("worksheet.deductibleExp"), summary.deductibleExpensesActual, Zen.indigo,
                 L10n.tf("worksheet.inputVatPaid", ["amount": KobanFormat.currency(summary.vatPaidOnExpenses, code: currency)]))
            card(L10n.t("worksheet.netVatPayable"), summary.netVatPayable, Zen.ink, L10n.t("worksheet.vatFormula"))
            card(L10n.t("worksheet.estTaxSetAside"), summary.estimatedTaxReserve, Zen.warning, L10n.t("worksheet.basedOnNetProfit"))
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
            Text(L10n.tf("worksheet.carryOverBefore", ["curr": monthKey, "prev": prevKey]))
                .font(.zen(12))
                .foregroundStyle(Zen.ink)
            Spacer(minLength: 8)
            Button(action: action) {
                HStack(spacing: 6) {
                    ZIcon("doc.on.doc", size: 14)
                    Text(L10n.tf("worksheet.copyPrevValuesBtn", ["prev": prevKey])).fontWeight(.medium)
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
            field(L10n.t("worksheet.groupNameLabel")) {
                TextField("", text: $name, prompt: Text(L10n.t("worksheet.groupNamePlaceholder")).foregroundStyle(Zen.ink3))
                    .zenField()
                    .frame(minWidth: 220, idealWidth: 280)
                    .focused($nameFocused)
                    .onSubmit(create)
            }
            if workspace == .combined {
                field(L10n.t("worksheet.ledgerModeLabel")) {
                    ZenSelect(options: [(LedgerMode.home, L10n.t("onboarding.home")), (.freelancer, L10n.t("workspace.freelancer"))], selection: $mode)
                }
            }
            field(L10n.t("worksheet.typeLabel")) {
                ZenSelect(options: [(CategoryKind.expense, L10n.t("worksheet.expenseGroupOpt")), (.income, L10n.t("worksheet.incomeGroupOpt")),
                                    (.savings, L10n.t("worksheet.savingsGroupOpt"))], selection: $kind)
            }
            field(L10n.t("worksheet.columnLabel")) {
                ZenSelect(options: [(0, L10n.t("worksheet.leftColumnOpt")), (1, L10n.t("worksheet.rightColumnOpt"))], selection: $column)
            }
            Button(L10n.t("worksheet.createGroupBtn"), action: create).buttonStyle(.zen(.ink, padding: 16)).fontWeight(.medium)
            Button(L10n.t("common.cancel"), action: onClose).buttonStyle(.zen(.ghost))
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
                        Text(L10n.t("worksheet.copyModalTitle")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    }
                    Spacer()
                    ZenMiniButton(icon: "xmark", size: 16) { store.copyRequest = nil }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Zen.app.opacity(0.6))
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tf("worksheet.copyModalPrompt", ["source": request.source, "target": request.target]))
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink)
                        .lineSpacing(3)

                    if request.mode != .allMonths {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("worksheet.copyModalScopeLabel")).font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                                ZenSelect(options: [(MonthCopyScope.budgetsAndActuals, L10n.t("onboarding.s4.copyScopeBoth")),
                                                    (.budgetsOnly, L10n.t("onboarding.s4.copyScopeBudgetsOnly"))],
                                          selection: $request.scope, background: Zen.surface)
                            }
                            ZenCheckbox(isOn: $request.overwriteExisting,
                                        label: L10n.tf("worksheet.copyModalOverwrite", ["target": request.target]))
                            if request.mode == .currentToNext {
                                ZenCheckbox(isOn: $request.navigateToTarget,
                                            label: L10n.tf("worksheet.copyModalSwitchMonth", ["target": request.target]))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
                    }

                    ZenCheckbox(isOn: $dontAskAgain,
                                label: L10n.t("worksheet.copyModalDontAsk"),
                                fontSize: 11, color: Zen.ink3)
                        .padding(.top, 4)
                }
                .padding(20)

                HStack(spacing: 10) {
                    Spacer()
                    Button(L10n.t("common.cancel")) { store.copyRequest = nil }
                        .buttonStyle(.zen(.outline, padding: 14))
                        .keyboardShortcut(.cancelAction)
                    Button {
                        store.performCopy(request, disableFutureConfirm: dontAskAgain)
                        store.copyRequest = nil
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("doc.on.doc", size: 14)
                            Text(L10n.t("worksheet.copyModalConfirmBtn")).fontWeight(.medium)
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
