import SwiftUI

/// Port of src/components/ImportDataModal.tsx — step 1 (source, workspace / passphrase,
/// preview toggle) and step 2 (preview with row selection, then confirm).
struct ImportDataModal: View {
    @Environment(LedgerStore.self) private var store
    @State private var importKind: ImportKind = .budgetSheet
    @State private var targetMode: LedgerMode
    @State private var passphrase = ""
    @State private var isBusy = false
    @State private var previewData: ImportPreviewData?
    @State private var excluded = Set<String>()
    @State private var hideZeroPreviewRows = false

    init(initialPreview: ImportPreviewData?, defaultMode: LedgerMode? = nil) {
        _previewData = State(initialValue: initialPreview)
        _targetMode = State(initialValue: initialPreview?.targetMode ?? defaultMode ?? .home)
        _didSetDefaultMode = State(initialValue: initialPreview != nil || defaultMode != nil)
    }

    @State private var didSetDefaultMode: Bool

    private var monthKey: String { store.state.activeMonthKey }
    private var currency: String { store.state.settings.currency }
    private var confirmAndPreview: Bool { store.state.settings.confirmAndPreviewBeforeImport ?? true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let preview = previewData {
                previewStep(preview)
            } else {
                sourceStep
            }
        }
        .frame(width: previewData == nil ? 576 : 896)
        .background(Zen.surface)
        .onAppear {
            if !didSetDefaultMode {
                targetMode = store.importDefaultMode
                didSetDefaultMode = true
            }
        }
    }

    private func closeAll() {
        previewData = nil
        excluded = []
        store.dismissModal()
    }

    // MARK: Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                ZIcon(previewData == nil ? "square.and.arrow.up" : "eye", size: 16)
                    .foregroundStyle(previewData == nil ? Zen.accent : Zen.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(previewData == nil ? L10n.t("import.title") : L10n.t("import.preview.title"))
                            .font(.zen(16, .medium)).foregroundStyle(Zen.ink)
                        DataIOPill(text: previewData == nil ? L10n.t("import.step1") : L10n.t("import.step2"),
                                   foreground: Zen.ink2, background: Zen.raised, border: Zen.line)
                    }
                    Text(previewData.map { L10n.tf("import.subReview", ["file": $0.fileName]) }
                         ?? L10n.t("import.subSelect"))
                        .font(.zen(12)).foregroundStyle(Zen.ink2).lineLimit(1)
                }
            }
            Spacer()
            Button(action: closeAll) { ZIcon("xmark", size: 16) }
                .buttonStyle(.zen(.icon, height: 28, radius: 8, padding: 6))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Zen.app.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    // MARK: Step 1

    private struct SourceCard: Identifiable {
        let id: ImportKind
        let title: String
        let subtitle: String
        let formats: String
        let icon: String
        let accent: Color
    }

    private var cards: [SourceCard] {
        [
            SourceCard(id: .budgetSheet, title: L10n.t("import.budgetSheet"),
                       subtitle: L10n.t("import.budgetSheetDesc"),
                       formats: ".xlsx, .xls, .csv", icon: "tablecells", accent: Zen.positive),
            SourceCard(id: .transactions, title: L10n.t("import.transactions"),
                       subtitle: L10n.t("import.transactionsDesc"),
                       formats: ".csv, .xlsx, .xls", icon: "list.bullet.rectangle.portrait", accent: Zen.indigo),
            SourceCard(id: .databaseBackup, title: L10n.t("import.backup"),
                       subtitle: L10n.t("import.backupDesc"),
                       formats: ".db, .sqlite, .json", icon: "cylinder.split.1x2", accent: Zen.accent),
        ]
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("import.step1Heading").uppercased()).font(.zen(12, .medium)).tracking(1.4).foregroundStyle(Zen.ink3)
                VStack(spacing: 8) {
                    ForEach(cards) { sourceCard($0) }
                }
            }

            if importKind != .databaseBackup {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.tf("import.targetWorkspace", ["month": monthKey])).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text(L10n.t("import.targetWorkspaceDesc")).font(.zen(11)).foregroundStyle(Zen.ink3)
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        segment(L10n.t("onboarding.home"), .home)
                        segment(L10n.t("workspace.freelancer"), .freelancer)
                    }
                    .padding(2)
                    .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                }
                .padding(14)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ZIcon("lock", size: 14).foregroundStyle(Zen.positive)
                        Text(L10n.t("import.optionalPassphrase")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    }
                    Text(L10n.t("import.optionalPassphraseDesc"))
                        .font(.zen(11)).foregroundStyle(Zen.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    DataIOTextField(placeholder: L10n.t("import.optionalPassphrasePlaceholder"), text: $passphrase, secure: true,
                                    height: 32, background: Zen.surface, trailingPadding: 10)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
            }

            // 3. Preview & confirmation behaviour
            Button {
                let next = !confirmAndPreview
                store.applySettingsChange { $0.confirmAndPreviewBeforeImport = next }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        ZIcon("eye", size: 16).foregroundStyle(Zen.indigo).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("import.previewToggleTitle"))
                                .font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                            Text(L10n.t("import.previewToggleDesc"))
                                .font(.zen(11)).foregroundStyle(Zen.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    DataIOCheckSquare(isOn: confirmAndPreview).padding(.top, 2)
                }
                .multilineTextAlignment(.leading)
                .padding(12)
                .background(Zen.app.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Spacer()
                Button(L10n.t("common.cancel"), action: closeAll)
                    .buttonStyle(.zen(.ghost, height: 36, padding: 16))
                Button(action: selectFile) {
                    HStack(spacing: 8) {
                        ZIcon(confirmAndPreview ? "eye" : "square.and.arrow.up", size: 14)
                        Text(isBusy ? L10n.t("import.readingFile")
                             : confirmAndPreview ? L10n.t("import.selectFile") : L10n.t("import.selectImmediate"))
                    }
                }
                .buttonStyle(DataIOInkButtonStyle(height: 36, padding: 20))
                .disabled(isBusy)
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
        }
        .padding(24)
    }

    private func sourceCard(_ c: SourceCard) -> some View {
        let selected = importKind == c.id
        return Button { importKind = c.id } label: {
            HStack(alignment: .top, spacing: 12) {
                ZIcon(c.icon, size: 16).foregroundStyle(c.accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.title).font(.zen(13, .medium)).foregroundStyle(Zen.ink)
                        Spacer()
                        Text(c.formats).font(.zen(10)).monospacedDigit().foregroundStyle(Zen.ink3)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                    }
                    Text(c.subtitle).font(.zen(11)).foregroundStyle(Zen.ink2).lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if selected {
                    Circle().fill(Zen.ink).frame(width: 16, height: 16)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Zen.onInk))
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Zen.raised : Zen.app.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Zen.ink : Zen.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func segment(_ label: String, _ mode: LedgerMode) -> some View {
        let active = targetMode == mode
        return Button { targetMode = mode } label: {
            Text(label)
                .font(.zen(12, active ? .medium : .regular))
                .foregroundStyle(active ? Zen.ink : Zen.ink2)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(active ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: active ? .black.opacity(0.05) : .clear, radius: 0.5, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectFile() {
        isBusy = true
        defer { isBusy = false }
        let pass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prepared = store.prepareImport(kind: importKind, targetMode: targetMode,
                                                 passphrase: pass.isEmpty ? nil : pass) else { return }
        if confirmAndPreview {
            excluded = []
            previewData = prepared
        } else {
            store.commitImport(prepared)
            previewData = nil
        }
    }

    // MARK: Step 2

    private struct BudgetMetrics {
        var incomeBudget = 0.0, incomeActual = 0.0, outflowBudget = 0.0, outflowActual = 0.0
        var newCount = 0, nonZeroCount = 0, selectedCount = 0
        var netBudget: Double { incomeBudget - outflowBudget }
        var netActual: Double { incomeActual - outflowActual }
    }

    private func budgetMetrics(_ p: ImportPreviewData) -> BudgetMetrics {
        var m = BudgetMetrics()
        for r in p.budgetRows ?? [] {
            if abs(r.budget) > 0.001 || abs(r.actual) > 0.001 { m.nonZeroCount += 1 }
            if excluded.contains(r.categoryId) { continue }
            m.selectedCount += 1
            if r.isNewCategory { m.newCount += 1 }
            if r.kind == .income {
                m.incomeBudget += r.budget; m.incomeActual += r.actual
            } else {
                m.outflowBudget += r.budget; m.outflowActual += r.actual
            }
        }
        return m
    }

    private struct TxMetrics {
        var incomeTotal = 0.0, expenseTotal = 0.0, incomeCount = 0, expenseCount = 0, selectedCount = 0
        var netTotal: Double { incomeTotal - expenseTotal }
    }

    private func txMetrics(_ p: ImportPreviewData) -> TxMetrics {
        var m = TxMetrics()
        for r in p.transactionRows ?? [] where !excluded.contains(r.id) {
            m.selectedCount += 1
            if r.type == .income { m.incomeTotal += r.amount; m.incomeCount += 1 } else { m.expenseTotal += r.amount; m.expenseCount += 1 }
        }
        return m
    }

    private func toggle(_ id: String) {
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
    }

    private func previewStep(_ p: ImportPreviewData) -> some View {
        let bm = budgetMetrics(p)
        let tm = txMetrics(p)
        return VStack(alignment: .leading, spacing: 16) {
            contextBanner(p, bm)

            switch p.kind {
            case .budgetSheet: budgetPreview(p, bm)
            case .transactions: transactionPreview(p, tm)
            case .databaseBackup: backupPreview(p)
            }

            HStack(spacing: 12) {
                Button {
                    previewData = nil
                    excluded = []
                } label: {
                    HStack(spacing: 6) { ZIcon("arrow.left", size: 14); Text(L10n.t("import.chooseOther")) }
                }
                .buttonStyle(DataIORaisedButtonStyle(height: 36, padding: 14, background: Zen.surface))
                .disabled(isBusy)

                Spacer()

                Button(L10n.t("import.cancel"), action: closeAll)
                    .buttonStyle(.zen(.ghost, height: 36, padding: 16))
                    .disabled(isBusy)
                Button { confirm(p, budgetSelected: bm.selectedCount, txSelected: tm.selectedCount) } label: {
                    HStack(spacing: 8) {
                        ZIcon("checkmark.circle", size: 16)
                        Text(isBusy ? L10n.t("import.completing") : "\(L10n.t("import.confirm")) (\(confirmCountLabel(p, bm, tm)))")
                    }
                }
                .buttonStyle(DataIOInkButtonStyle(height: 36, padding: 20))
                .disabled(isBusy)
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
        }
        .padding(24)
    }

    private func confirmCountLabel(_ p: ImportPreviewData, _ bm: BudgetMetrics, _ tm: TxMetrics) -> String {
        switch p.kind {
        case .transactions: return "\(tm.selectedCount)"
        case .budgetSheet: return "\(bm.selectedCount)"
        case .databaseBackup: return "\(p.importedCount)"
        }
    }

    private func confirm(_ p: ImportPreviewData, budgetSelected: Int, txSelected: Int) {
        isBusy = true
        defer { isBusy = false }
        let filtered = p.applyingExclusions(excluded, monthKey: monthKey)
        store.commitImport(filtered)
        previewData = nil
        excluded = []
    }

    private func contextBanner(_ p: ImportPreviewData, _ bm: BudgetMetrics) -> some View {
        var line = Text(p.fileName).fontWeight(.semibold).foregroundColor(Zen.ink)
        if let sheet = p.sheetName, !sheet.isEmpty {
            line = line + Text(" • ").foregroundColor(Zen.ink2) + Text(sheet).fontWeight(.bold).foregroundColor(Zen.ink)
        }
        if p.kind != .databaseBackup {
            let modeLabel = p.targetMode == .home ? L10n.t("workspace.home") : L10n.t("workspace.freelancer")
            line = line + Text(" • ").foregroundColor(Zen.ink2)
                + Text(modeLabel).fontWeight(.bold).foregroundColor(Zen.ink)
                + Text(" (\(monthKey))").foregroundColor(Zen.ink2)
        }
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZIcon("sparkles", size: 16).foregroundStyle(Zen.indigo)
                line.font(.zen(12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if p.kind == .budgetSheet {
                DataIOCheckbox(isOn: $hideZeroPreviewRows, spacing: 6) {
                    Text(L10n.tf("import.showNonZeroOnly", ["active": bm.nonZeroCount, "total": p.budgetRows?.count ?? 0]))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                }
                .fixedSize()
            }
        }
        .padding(14)
        .background(Zen.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.indigo.opacity(0.25), lineWidth: 1))
    }

    private func stat(_ title: String, _ value: String, color: Color = Zen.ink, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.zen(10)).tracking(0.6).foregroundStyle(Zen.ink3).lineLimit(1)
            Text(value).font(.zen(14, .semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1)
            if let sub { Text(sub).font(.zen(11)).monospacedDigit().foregroundStyle(Zen.ink2).lineLimit(1) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func statRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) { content() }.fixedSize(horizontal: false, vertical: true)
    }

    private func money(_ v: Double) -> String { KobanFormat.currency(v, code: currency) }

    // Budget sheet preview

    @ViewBuilder
    private func budgetPreview(_ p: ImportPreviewData, _ bm: BudgetMetrics) -> some View {
        statRow {
            stat(L10n.t("import.categoriesParsed"), L10n.tf("import.rowsCount", ["count": p.budgetRows?.count ?? 0]),
                 sub: L10n.tf("import.newActiveCounts", ["new": bm.newCount, "active": bm.nonZeroCount]))
            stat(L10n.t("import.incomeBudgetActual"), money(bm.incomeBudget), color: Zen.positive,
                 sub: "\(L10n.t("finance.actual")): \(money(bm.incomeActual))")
            stat(L10n.t("import.outflowsBudgetActual"), money(bm.outflowBudget),
                 sub: "\(L10n.t("finance.actual")): \(money(bm.outflowActual))")
            stat(L10n.t("import.netCashflowPreview"), money(bm.netActual), color: bm.netActual >= 0 ? Zen.positive : DataIOColors.negative,
                 sub: L10n.tf("reports.plannedNet", ["amount": money(bm.netBudget)]))
        }

        let rows = (p.budgetRows ?? []).filter { !hideZeroPreviewRows || abs($0.budget) > 0.001 || abs($0.actual) > 0.001 }
        previewTable(header: {
            th("✓", width: 32, align: .center)
            th(L10n.t("import.colGroup"), width: 180)
            th(L10n.t("finance.category"), width: nil)
            th(L10n.t("import.colAction"), width: 72)
            th("\(L10n.t("finance.budget")) (\(currency))", width: 150, align: .trailing)
            th("\(L10n.t("finance.actual")) (\(currency))", width: 150, align: .trailing)
        }, rows: rows) { row in
            BudgetPreviewRowView(row: row, included: !excluded.contains(row.categoryId)) { toggle(row.categoryId) }
        }
    }

    // Transactions preview

    @ViewBuilder
    private func transactionPreview(_ p: ImportPreviewData, _ tm: TxMetrics) -> some View {
        statRow {
            stat(L10n.t("import.entriesToImport"), L10n.tf("import.txCountLabel", ["count": p.transactionRows?.count ?? 0]))
            stat("\(L10n.t("finance.income")) (\(tm.incomeCount))", money(tm.incomeTotal), color: Zen.positive)
            stat("\(L10n.t("finance.expenses")) (\(tm.expenseCount))", money(tm.expenseTotal))
            stat(L10n.t("import.netTxTotal"), money(tm.netTotal), color: tm.netTotal >= 0 ? Zen.positive : DataIOColors.negative)
        }
        previewTable(header: {
            th("✓", width: 32, align: .center)
            th(L10n.t("finance.date"), width: 96)
            th(L10n.t("import.colType"), width: 84)
            th(L10n.t("finance.category"), width: 180)
            th(L10n.t("finance.description"), width: nil)
            th("\(L10n.t("finance.amount")) (\(currency))", width: 140, align: .trailing)
        }, rows: p.transactionRows ?? []) { tx in
            TransactionPreviewRowView(tx: tx, included: !excluded.contains(tx.id)) { toggle(tx.id) }
        }
    }

    // Backup preview

    @ViewBuilder
    private func backupPreview(_ p: ImportPreviewData) -> some View {
        let s = p.proposedState
        HStack(alignment: .top, spacing: 10) {
            ZIcon("exclamationmark.triangle", size: 16).foregroundStyle(Zen.accent).padding(.top, 1)
            (Text(L10n.t("import.backupConfirmTitle")).fontWeight(.semibold)
             + Text(" " + L10n.tf("import.backupConfirmBody", ["file": p.fileName])))
                .font(.zen(12)).foregroundStyle(Zen.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Zen.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.accent.opacity(0.3), lineWidth: 1))

        statRow {
            stat(L10n.t("import.groupsCategories"), "\(s.groups.count) • \(s.categories.count)")
            stat(L10n.t("import.financialAccounts"), "\(s.accounts.count)")
            stat(L10n.t("import.transactionsRules"), "\(s.transactions.count) • \(s.recurringRules.count)")
            stat(L10n.t("import.backupCurrencyPeriod"), "\(s.settings.currency) • \(s.settings.activeYear)-\(String(format: "%02d", s.settings.activeMonth))",
                 color: Zen.positive)
        }

        if !s.accounts.isEmpty {
            VStack(spacing: 0) {
                Text(L10n.t("import.accountsIncluded").uppercased())
                    .font(.zen(10, .medium)).tracking(0.6).foregroundStyle(Zen.ink3)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Zen.raised)
                    .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(s.accounts.enumerated()), id: \.element.id) { idx, acc in
                            if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                            HStack {
                                (Text(L10n.accountName(acc)).fontWeight(.medium).foregroundColor(Zen.ink)
                                 + Text("  (\(L10n.accountClassLabel(acc.classification)))")
                                    .font(.zen(11)).foregroundColor(Zen.ink3))
                                Spacer()
                                let bal = acc.currentBalance != 0 ? acc.currentBalance : acc.startingBalance
                                Text(KobanFormat.currency(bal, code: s.settings.currency.isEmpty ? currency : s.settings.currency))
                                    .font(.zen(12, .semibold)).monospacedDigit().foregroundStyle(Zen.ink)
                            }
                            .font(.zen(12))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Zen.surface)
                        }
                    }
                }
                .frame(maxHeight: 192)
                .fixedSize(horizontal: false, vertical: s.accounts.count <= 5)
            }
            .background(Zen.app)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        }
    }

    // Table scaffolding (border border-line rounded-xl, max-h-72 scroll, sticky header)

    private func th(_ text: String, width: CGFloat?, align: Alignment = .leading) -> some View {
        Text(text.uppercased())
            .font(.zen(10)).tracking(0.6).foregroundStyle(Zen.ink3).lineLimit(1)
            .padding(.horizontal, width == 32 ? 10 : 12)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }

    private func previewTable<Row: Identifiable, Header: View, RowView: View>(
        @ViewBuilder header: () -> Header, rows: [Row], @ViewBuilder row: @escaping (Row) -> RowView
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { header() }
                .padding(.vertical, 8)
                .background(Zen.raised)
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                        if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                        row(r)
                    }
                }
            }
            .frame(height: min(288, CGFloat(max(rows.count, 1)) * 31))
        }
        .background(Zen.app)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }
}

private struct BudgetPreviewRowView: View {
    let row: BudgetImportPreviewRow
    let included: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let hasValue = abs(row.budget) > 0.001 || abs(row.actual) > 0.001
        let bg: Color = !included ? Zen.app : hasValue ? (hovering ? Zen.raised.opacity(0.5) : Zen.surface)
            : (hovering ? Zen.raised.opacity(0.3) : .clear)
        HStack(spacing: 0) {
            Button(action: toggle) { DataIOCheckSquare(isOn: included) }
                .buttonStyle(.plain)
                .frame(width: 32)
            Text(L10n.groupName(row.groupName)).font(.zen(11, .medium)).foregroundStyle(Zen.ink2).lineLimit(1)
                .padding(.horizontal, 12).frame(width: 180, alignment: .leading)
            Text(L10n.categoryName(row.categoryName, id: row.categoryId)).font(.zen(12, .medium)).foregroundStyle(hasValue ? Zen.ink : Zen.ink3).lineLimit(1)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if row.isNewCategory {
                    Text(L10n.t("import.badgeNew")).font(.zen(10, .medium)).foregroundStyle(Zen.positive)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Zen.positive.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(L10n.t("import.badgeUpdate")).font(.zen(10)).foregroundStyle(Zen.ink2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10).frame(width: 72, alignment: .leading)
            amount(previous: row.previousBudget, value: row.budget, strong: Zen.ink)
                .padding(.horizontal, 12).frame(width: 150, alignment: .trailing)
            amount(previous: row.previousActual, value: row.actual, strong: Zen.positive)
                .padding(.horizontal, 12).frame(width: 150, alignment: .trailing)
        }
        .font(.zen(12))
        .frame(height: 30)
        .background(bg)
        .opacity(included ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }

    private func amount(previous: Double, value: Double, strong: Color) -> some View {
        HStack(spacing: 6) {
            if previous != value && previous > 0 {
                Text(KobanFormat.number(previous)).font(.zen(10)).strikethrough().foregroundStyle(Zen.ink3)
            }
            Text(KobanFormat.number(value))
                .font(.zen(12, value > 0 ? .semibold : .regular))
                .foregroundStyle(value > 0 ? strong : Zen.ink3)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

private struct TransactionPreviewRowView: View {
    let tx: TransactionImportPreviewRow
    let included: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let income = tx.type == .income
        HStack(spacing: 0) {
            Button(action: toggle) { DataIOCheckSquare(isOn: included) }
                .buttonStyle(.plain)
                .frame(width: 32)
            Text(tx.date).monospacedDigit().foregroundStyle(Zen.ink2)
                .padding(.horizontal, 12).frame(width: 96, alignment: .leading)
            Text(L10n.t(income ? "tx.filterIncome" : "tx.filterExpense").uppercased()).font(.zen(10, .medium))
                .foregroundStyle(income ? Zen.positive : Zen.ink2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(income ? Zen.positive.opacity(0.12) : Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 10).frame(width: 84, alignment: .leading)
            Text(L10n.categoryName(tx.categoryName)).foregroundStyle(Zen.ink2).lineLimit(1)
                .padding(.horizontal, 12).frame(width: 180, alignment: .leading)
            (Text(tx.description).fontWeight(.medium).foregroundColor(Zen.ink)
             + (tx.client.map { Text("  (\($0))").font(.zen(11)).foregroundColor(Zen.ink3) } ?? Text("")))
                .lineLimit(1)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(income ? "+" : "-")\(KobanFormat.number(tx.amount))")
                .font(.zen(12, .semibold)).monospacedDigit()
                .foregroundStyle(income ? Zen.positive : Zen.ink)
                .padding(.horizontal, 12).frame(width: 140, alignment: .trailing)
        }
        .font(.zen(12))
        .frame(height: 30)
        .background(!included ? Zen.app : (hovering ? Zen.raised.opacity(0.5) : Zen.surface))
        .opacity(included ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }
}
