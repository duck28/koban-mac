import SwiftUI

// Native macOS SwiftUI counterpart of BankImportReview.tsx & ImportRulesModal.tsx.

private func bankTodayIso() -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

// MARK: - Bank Import Review (Column Mapper + Staging Inbox)

struct BankImportReviewView: View {
    enum FilterKind: String, CaseIterable, Identifiable {
        case all = "All"
        case needsReview = "Needs Review"
        case auto = "Auto-Matched"
        case duplicates = "Duplicates"
        case transfers = "Transfers"
        var id: String { rawValue }
    }

    @Environment(LedgerStore.self) private var store

    let initialParseResult: BankStatementParseResult
    let targetMode: LedgerMode
    let accountId: String?
    let watchedFileURL: URL?
    let isBusy: Bool
    let onBackToSource: () -> Void
    let onCancel: () -> Void
    let onComplete: (
        _ stagedRows: [StagedBankTransaction],
        _ savedProfile: BankImportProfile?,
        _ savedRules: [ImportRule],
        _ archiveWatchedFile: Bool
    ) -> Void

    @State private var currentParseResult: BankStatementParseResult
    @State private var selectedBankId: String
    @State private var activeProfile: BankImportProfile?
    @State private var pendingSavedProfile: BankImportProfile?
    @State private var stagedRows: [StagedBankTransaction] = []
    @State private var rulesSnapshot: [ImportRule] = []
    @State private var showMapper: Bool
    @State private var filter: FilterKind = .all
    @State private var searchText = ""
    @State private var bulkCategoryId = ""
    @State private var archiveWatchedFile: Bool
    @State private var bannerInfo: String? = nil

    // Inline + Rule creator state
    @State private var editingRuleRowId: String? = nil
    @State private var draftPattern = ""
    @State private var draftField: ImportRuleMatchField = .any
    @State private var draftType: ImportRuleMatchType = .contains
    @State private var draftDirection: ImportRuleDirection = .any
    @State private var draftCategoryId = ""
    @State private var draftPayee = ""
    @State private var draftAccountOnly = false

    @State private var didInit = false

    init(
        parseResult: BankStatementParseResult,
        targetMode: LedgerMode,
        accountId: String?,
        watchedFileURL: URL?,
        isBusy: Bool,
        onBackToSource: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (
            _ stagedRows: [StagedBankTransaction],
            _ savedProfile: BankImportProfile?,
            _ savedRules: [ImportRule],
            _ archiveWatchedFile: Bool
        ) -> Void
    ) {
        self.initialParseResult = parseResult
        self.targetMode = targetMode
        self.accountId = accountId
        self.watchedFileURL = watchedFileURL
        self.isBusy = isBusy
        self.onBackToSource = onBackToSource
        self.onCancel = onCancel
        self.onComplete = onComplete

        _currentParseResult = State(initialValue: parseResult)
        _selectedBankId = State(initialValue: parseResult.selectedProfileId ?? "auto")
        _activeProfile = State(initialValue: parseResult.activeMapping ?? parseResult.matchedProfile)
        _showMapper = State(initialValue: parseResult.needsMappingReview && parseResult.rawRows != nil)
        _archiveWatchedFile = State(initialValue: watchedFileURL != nil)
    }

    private var currency: String {
        currentParseResult.detectedCurrency ?? store.state.settings.currency
    }

    private var categoryMap: [String: CategoryItem] {
        Dictionary(store.state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var availableCategories: [CategoryItem] {
        store.state.categories
            .filter { $0.mode == .home || $0.mode == .freelancer }
            .sorted {
                if $0.mode != $1.mode { return $0.mode == targetMode }
                return $0.name < $1.name
            }
    }

    private var includedCount: Int { stagedRows.filter(\.included).count }
    private var dupCount: Int { stagedRows.filter { $0.duplicateStatus != .none }.count }
    private var transferCount: Int { stagedRows.filter(\.isTransferCandidate).count }
    private var needsReviewCount: Int {
        stagedRows.filter { $0.included && ($0.confidence == .needsReview || $0.categoryId == nil) }.count
    }
    private var uncategorizedIncludedCount: Int {
        stagedRows.filter { $0.included && $0.categoryId == nil }.count
    }
    private var autoMatchedCount: Int {
        stagedRows.filter { $0.categoryId != nil && $0.confidence != .needsReview }.count
    }

    private var visibleRows: [StagedBankTransaction] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return stagedRows.filter { row in
            switch filter {
            case .needsReview:
                if !(row.included && (row.confidence == .needsReview || row.categoryId == nil)) { return false }
            case .auto:
                if !(row.categoryId != nil && row.confidence != .needsReview) { return false }
            case .duplicates:
                if row.duplicateStatus == .none { return false }
            case .transfers:
                if !row.isTransferCandidate { return false }
            case .all:
                break
            }
            if !q.isEmpty {
                let hay = "\(row.description) \(row.rawDescription) \(row.date) \(row.invoiceRef ?? "")".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showMapper, let rows = currentParseResult.rawRows {
                BankColumnMapperView(
                    fileName: currentParseResult.fileName,
                    rawRows: rows,
                    initialHeaderRow: currentParseResult.headerRowIndex ?? 0,
                    initialProfile: activeProfile,
                    accountId: accountId,
                    targetMode: targetMode,
                    fallbackCurrency: currency,
                    onBack: onBackToSource,
                    onCancel: onCancel,
                    onContinue: { newHeaderIdx, newMapping, newRawTxs, profileToSave in
                        var updated = currentParseResult
                        updated.headerRowIndex = newHeaderIdx
                        updated.headers = newHeaderIdx < rows.count ? BankImport.makeUniqueHeaders(rows[newHeaderIdx]) : []
                        updated.activeMapping = newMapping
                        updated.matchedProfile = newMapping
                        updated.rawTransactions = newRawTxs
                        updated.warnings = []
                        updated.needsMappingReview = false
                        currentParseResult = updated
                        activeProfile = newMapping
                        pendingSavedProfile = profileToSave
                        restage(rawTransactions: newRawTxs, rules: rulesSnapshot)
                        showMapper = false
                    }
                )
                .id(activeProfile?.id ?? selectedBankId)
            } else {
                reviewInboxBody
            }
        }
        .onAppear {
            if !didInit {
                didInit = true
                let rules = store.state.importRules ?? []
                rulesSnapshot = rules
                restage(rawTransactions: currentParseResult.rawTransactions, rules: rules)
            }
        }
    }

    private func restage(rawTransactions: [RawBankTransaction], rules: [ImportRule]) {
        stagedRows = BankImport.stageBankTransactions(
            rawTransactions: rawTransactions,
            state: store.state,
            targetMode: targetMode,
            accountId: accountId,
            rulesOverride: rules
        )
    }

    private func switchBankPreset(_ bankId: String) {
        selectedBankId = bankId
        let reparsed = BankImport.reparseWithProfile(
            currentParseResult,
            selectedProfileId: bankId,
            savedProfiles: store.state.importProfiles ?? [],
            accountId: accountId,
            fallbackCurrency: currency
        )
        currentParseResult = reparsed
        activeProfile = reparsed.activeMapping ?? reparsed.matchedProfile
        restage(rawTransactions: reparsed.rawTransactions, rules: rulesSnapshot)
        if bankId == "custom" || reparsed.needsMappingReview {
            showMapper = true
        }
    }

    private var formatBadgeLabel: String {
        switch currentParseResult.format {
        case .camt053: return "ISO 20022 CAMT"
        case .ofx: return "OFX / QFX"
        case .csv: return "CSV"
        case .spreadsheet: return "Excel"
        }
    }

    @ViewBuilder
    private var reviewInboxBody: some View {
        // Header context & Edit Mapping trigger
        HStack(spacing: 10) {
            ZIcon("sparkles", size: 15).foregroundStyle(Zen.indigo)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    DataIOPill(text: formatBadgeLabel, foreground: Zen.indigo, background: Zen.indigo.opacity(0.12), border: Zen.indigo.opacity(0.25))
                    if let prof = activeProfile, !prof.name.isEmpty {
                        DataIOPill(text: prof.name, foreground: Zen.ink2, background: Zen.surface, border: Zen.line)
                    }
                    if let iban = currentParseResult.detectedAccountIban {
                        DataIOPill(text: iban, foreground: Zen.ink2, background: Zen.surface, border: Zen.line)
                    }
                }
                Text("\(currentParseResult.rawTransactions.count) statement entry(ies) parsed from \(currentParseResult.fileName)")
                    .font(.zen(11)).foregroundStyle(Zen.ink2)
            }
            Spacer()
            if currentParseResult.rawRows != nil {
                Picker("", selection: Binding(
                    get: { selectedBankId },
                    set: { switchBankPreset($0) }
                )) {
                    Text("Auto-detect (recommended)").tag("auto")
                    let saved = store.state.importProfiles ?? []
                    if !saved.isEmpty {
                        Section("Saved Profiles") {
                            ForEach(saved) { prof in
                                Text(prof.name).tag(prof.id)
                            }
                        }
                    }
                    Section("Supported Banks") {
                        ForEach(BankImport.builtinProfiles) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    Text("Custom / Map Columns Manually…").tag("custom")
                }
                .labelsHidden()
                .frame(width: 210)

                Button {
                    showMapper = true
                } label: {
                    HStack(spacing: 5) {
                        ZIcon("tablecells", size: 12)
                        Text("Edit Columns")
                    }
                }
                .buttonStyle(DataIORaisedButtonStyle(height: 28, padding: 10, fontSize: 11))
            }
        }
        .padding(12)
        .background(Zen.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.indigo.opacity(0.22), lineWidth: 1))

        if !currentParseResult.warnings.isEmpty {
            DataIOBanner(kind: .warning, text: currentParseResult.warnings.joined(separator: " "))
        }

        if let bannerInfo {
            DataIOBanner(kind: .success, text: bannerInfo)
        }

        // Summary KPI row
        HStack(spacing: 10) {
            kpiCard("Selected", "\(includedCount) / \(stagedRows.count)", accent: Zen.ink)
            kpiCard("Auto-Matched", "\(autoMatchedCount)", accent: Zen.positive)
            kpiCard("Needs Review", "\(needsReviewCount)", accent: needsReviewCount > 0 ? DataIOColors.amber600 : Zen.ink3)
            kpiCard("Duplicates · Transfers", "\(dupCount) · \(transferCount)", accent: dupCount > 0 ? Zen.accent : Zen.ink2)
        }

        // Filter & bulk toolbar
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(FilterKind.allCases) { kind in
                    filterPill(kind)
                }
            }
            Spacer()
            DataIOTextField(placeholder: "Filter payee or text…", text: $searchText, icon: "magnifyingglass", height: 28)
                .frame(width: 190)

            Picker("", selection: $bulkCategoryId) {
                Text("Bulk category…").tag("")
                ForEach(availableCategories) { cat in
                    Text("[\(cat.mode == .freelancer ? "Biz" : "Home")] \(L10n.categoryName(cat))").tag(cat.id)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Button("Apply") {
                applyBulkCategory()
            }
            .buttonStyle(DataIORaisedButtonStyle(height: 28, padding: 10, fontSize: 11))
            .disabled(bulkCategoryId.isEmpty)

            Button("Toggle Visible") {
                toggleVisibleRows()
            }
            .buttonStyle(DataIORaisedButtonStyle(height: 28, padding: 10, fontSize: 11))
        }

        // Staging Table
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("✓", width: 32, align: .center)
                tableHeader("Date", width: 92)
                tableHeader("Type", width: 58)
                tableHeader("Description / Merchant", width: nil)
                tableHeader("Category", width: 190)
                tableHeader("Status", width: 104)
                tableHeader("Amount", width: 96, align: .trailing)
                tableHeader("Rule", width: 64, align: .center)
            }
            .padding(.vertical, 8)
            .background(Zen.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            if visibleRows.isEmpty {
                VStack(spacing: 6) {
                    Text("No statement rows match the current filter.")
                        .font(.zen(12)).foregroundStyle(Zen.ink3)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .background(Zen.surface)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            if let idx = stagedRows.firstIndex(where: { $0.id == row.id }) {
                                if row.id != visibleRows.first?.id {
                                    Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1)
                                }
                                stagedRowView(index: idx)
                                if editingRuleRowId == row.id {
                                    inlineRuleDrawer(for: row)
                                }
                            }
                        }
                    }
                }
                .frame(height: 310)
                .background(Zen.surface)
            }
        }
        .background(Zen.app)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))

        if uncategorizedIncludedCount > 0 {
            HStack(spacing: 8) {
                ZIcon("exclamationmark.triangle", size: 14).foregroundStyle(DataIOColors.amber600)
                Text("\(uncategorizedIncludedCount) checked row(s) have no category selected yet and will fall back to a default category unless assigned above.")
                    .font(.zen(11)).foregroundStyle(DataIOColors.amber600)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DataIOColors.amber500.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DataIOColors.amber500.opacity(0.3), lineWidth: 1))
        }

        if watchedFileURL != nil {
            DataIOCheckbox(isOn: $archiveWatchedFile, spacing: 8) {
                Text("Move statement file into Imported/ subfolder after import")
                    .font(.zen(12)).foregroundStyle(Zen.ink2)
            }
        }

        HStack(spacing: 12) {
            Button(action: onBackToSource) {
                HStack(spacing: 6) {
                    ZIcon("arrow.left", size: 13)
                    Text("Choose Another File")
                }
            }
            .buttonStyle(DataIORaisedButtonStyle(height: 34, padding: 14, background: Zen.surface))
            .disabled(isBusy)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.zen(.ghost, height: 34, padding: 14))
                .disabled(isBusy)

            Button {
                onComplete(stagedRows, pendingSavedProfile, rulesSnapshot, archiveWatchedFile)
            } label: {
                HStack(spacing: 6) {
                    ZIcon("checkmark.circle", size: 15)
                    Text(isBusy ? "Importing…" : "Import \(includedCount) Transaction(s)")
                }
            }
            .buttonStyle(DataIOInkButtonStyle(height: 34, padding: 18))
            .disabled(isBusy || includedCount == 0)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private func kpiCard(_ title: String, _ value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.zen(10)).tracking(0.5).foregroundStyle(Zen.ink3)
            Text(value).font(.zen(13, .semibold)).monospacedDigit().foregroundStyle(accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func filterPill(_ kind: FilterKind) -> some View {
        let count: Int = {
            switch kind {
            case .all: return stagedRows.count
            case .needsReview: return needsReviewCount
            case .auto: return autoMatchedCount
            case .duplicates: return dupCount
            case .transfers: return transferCount
            }
        }()
        let active = filter == kind
        return Button {
            filter = kind
        } label: {
            Text("\(kind.rawValue) (\(count))")
                .font(.zen(11, active ? .medium : .regular))
                .foregroundStyle(active ? Zen.onInk : Zen.ink2)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(active ? Zen.ink : Zen.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tableHeader(_ text: String, width: CGFloat?, align: Alignment = .leading) -> some View {
        Text(text.uppercased())
            .font(.zen(10, .medium)).tracking(0.5).foregroundStyle(Zen.ink3).lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }

    private func stagedRowView(index idx: Int) -> some View {
        let row = stagedRows[idx]
        let isIncome = row.type == .income
        let uncategorized = row.included && row.categoryId == nil
        return HStack(spacing: 0) {
            Button {
                stagedRows[idx].included.toggle()
            } label: {
                DataIOCheckSquare(isOn: row.included)
            }
            .buttonStyle(.plain)
            .frame(width: 32)

            Text(row.date)
                .font(.zen(11)).monospacedDigit().foregroundStyle(Zen.ink2)
                .padding(.horizontal, 8)
                .frame(width: 92, alignment: .leading)

            Button {
                stagedRows[idx].type = isIncome ? .expense : .income
                stagedRows[idx].categoryId = nil
                stagedRows[idx].confidence = .needsReview
            } label: {
                Text(isIncome ? "IN" : "OUT")
                    .font(.zen(10, .semibold))
                    .foregroundStyle(isIncome ? Zen.positive : Zen.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((isIncome ? Zen.positive : Zen.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .frame(width: 58, alignment: .leading)
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 1) {
                TextField("", text: Binding(
                    get: { stagedRows[idx].description },
                    set: { stagedRows[idx].description = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.zen(12, .medium))
                .foregroundStyle(Zen.ink)
                if !row.rawDescription.isEmpty && row.rawDescription != row.description {
                    Text(row.rawDescription)
                        .font(.zen(10))
                        .foregroundStyle(Zen.ink3)
                        .lineLimit(1)
                }
                if let dupLabel = row.duplicateOfLabel {
                    Text("Dup: \(dupLabel)")
                        .font(.zen(10))
                        .foregroundStyle(Zen.accent)
                        .lineLimit(1)
                } else if let xferHint = row.transferHint {
                    Text(xferHint)
                        .font(.zen(10))
                        .foregroundStyle(Zen.indigo)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { stagedRows[idx].categoryId ?? "" },
                set: { newCatId in
                    if newCatId.isEmpty {
                        stagedRows[idx].categoryId = nil
                        stagedRows[idx].confidence = .needsReview
                    } else if let cat = categoryMap[newCatId] {
                        stagedRows[idx].categoryId = cat.id
                        stagedRows[idx].mode = cat.mode
                        stagedRows[idx].confidence = .rule
                        stagedRows[idx].matchReason = "Manual selection"
                    }
                }
            )) {
                Text("Select category…").tag("")
                ForEach(availableCategories.filter {
                    isIncome ? $0.kind == .income : $0.kind != .income
                }) { cat in
                    Text("[\(cat.mode == .freelancer ? "Biz" : "Home")] \(L10n.categoryName(cat))").tag(cat.id)
                }
            }
            .labelsHidden()
            .padding(2)
            .background(uncategorized ? DataIOColors.amber500.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if uncategorized {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(DataIOColors.amber500.opacity(0.6), lineWidth: 1)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 190)

            rowStatusBadge(row)
                .padding(.horizontal, 6)
                .frame(width: 104, alignment: .leading)

            Text("\(isIncome ? "+" : "-")\(KobanFormat.number(row.amount))")
                .font(.zen(12, .semibold)).monospacedDigit()
                .foregroundStyle(isIncome ? Zen.positive : Zen.ink)
                .padding(.horizontal, 8)
                .frame(width: 96, alignment: .trailing)

            Button {
                openRuleEditor(for: row)
            } label: {
                Text(editingRuleRowId == row.id ? "Close" : "+ Rule")
                    .font(.zen(10, .medium))
                    .foregroundStyle(Zen.indigo)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Zen.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .frame(width: 64)
        }
        .padding(.vertical, 6)
        .background(!row.included ? Zen.app.opacity(0.6) : Zen.surface)
        .opacity(row.included ? 1 : 0.5)
    }

    @ViewBuilder
    private func rowStatusBadge(_ row: StagedBankTransaction) -> some View {
        if row.duplicateStatus == .exactDuplicate {
            DataIOPill(text: "Duplicate", foreground: Zen.accent, background: Zen.accent.opacity(0.12))
        } else if row.duplicateStatus == .possibleDuplicate {
            DataIOPill(text: "Possible Dup", foreground: DataIOColors.amber600, background: DataIOColors.amber500.opacity(0.12))
        } else if row.isTransferCandidate {
            DataIOPill(text: "Transfer?", foreground: Zen.indigo, background: Zen.indigo.opacity(0.12))
        } else {
            switch row.confidence {
            case .rule:
                DataIOPill(text: "Rule", foreground: Zen.positive, background: Zen.positive.opacity(0.12))
            case .history:
                DataIOPill(text: "History", foreground: Zen.positive, background: Zen.positive.opacity(0.12))
            case .keyword:
                DataIOPill(text: "Auto", foreground: Zen.indigo, background: Zen.indigo.opacity(0.12))
            case .needsReview:
                DataIOPill(text: "Review", foreground: DataIOColors.amber600, background: DataIOColors.amber500.opacity(0.12))
            }
        }
    }

    private func openRuleEditor(for row: StagedBankTransaction) {
        if editingRuleRowId == row.id {
            editingRuleRowId = nil
            return
        }
        editingRuleRowId = row.id
        draftPattern = BankImport.suggestRulePattern(rawPayee: row.raw.rawPayee, rawDescription: row.raw.rawDescription)
        draftField = row.raw.rawPayee.isEmpty ? .any : .payee
        draftType = .contains
        draftDirection = row.type == .income ? .income : .expense
        draftCategoryId = row.categoryId ?? availableCategories.first(where: {
            row.type == .income ? $0.kind == .income : $0.kind != .income
        })?.id ?? ""
        draftPayee = row.description
        draftAccountOnly = false
    }

    private func inlineRuleDrawer(for row: StagedBankTransaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZIcon("tag", size: 12).foregroundStyle(Zen.indigo)
                Text("Create Auto-Categorization Rule").font(.zen(11, .semibold)).foregroundStyle(Zen.ink)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Pattern", size: 10)
                    DataIOTextField(placeholder: "e.g. migros", text: $draftPattern, height: 28, background: Zen.surface)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Field", size: 10)
                    Picker("", selection: $draftField) {
                        Text("Any text").tag(ImportRuleMatchField.any)
                        Text("Payee").tag(ImportRuleMatchField.payee)
                        Text("Description").tag(ImportRuleMatchField.description)
                        Text("IBAN").tag(ImportRuleMatchField.iban)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Match", size: 10)
                    Picker("", selection: $draftType) {
                        Text("Contains").tag(ImportRuleMatchType.contains)
                        Text("Starts with").tag(ImportRuleMatchType.startsWith)
                        Text("Exact").tag(ImportRuleMatchType.exact)
                        Text("Regex").tag(ImportRuleMatchType.regex)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Category", size: 10)
                    Picker("", selection: $draftCategoryId) {
                        ForEach(availableCategories) { cat in
                            Text("[\(cat.mode == .freelancer ? "Biz" : "Home")] \(L10n.categoryName(cat))").tag(cat.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Clean Payee", size: 10)
                    DataIOTextField(placeholder: "Optional", text: $draftPayee, height: 28, background: Zen.surface)
                }
            }
            HStack {
                if accountId != nil {
                    DataIOCheckbox(isOn: $draftAccountOnly, spacing: 6) {
                        Text("This account only").font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                }
                Spacer()
                Button("Cancel") { editingRuleRowId = nil }
                    .buttonStyle(DataIORaisedButtonStyle(height: 26, padding: 10, fontSize: 11))
                Button("Save Rule & Re-apply") { saveInlineRule(sourceRow: row) }
                    .buttonStyle(DataIOInkButtonStyle(height: 26, padding: 12, fontSize: 11))
                    .disabled(draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftCategoryId.isEmpty)
            }
        }
        .padding(12)
        .background(Zen.indigo.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(Zen.indigo.opacity(0.2)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.indigo.opacity(0.2)).frame(height: 1) }
    }

    private func saveInlineRule(sourceRow: StagedBankTransaction) {
        let pat = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty, !draftCategoryId.isEmpty else { return }
        let today = bankTodayIso()
        let cat = categoryMap[draftCategoryId]
        let cleanPayee = draftPayee.trimmingCharacters(in: .whitespacesAndNewlines)

        let newRule = ImportRule(
            id: "imprule-\(DataIOJS.nowMillis())",
            name: cleanPayee.isEmpty ? pat : cleanPayee,
            enabled: true,
            priority: 1,
            accountId: draftAccountOnly ? accountId : nil,
            direction: draftDirection,
            matchField: draftField,
            matchType: draftType,
            pattern: pat,
            minAmount: nil,
            maxAmount: nil,
            setCategoryId: draftCategoryId,
            setMode: cat?.mode,
            setPayee: cleanPayee.isEmpty ? nil : cleanPayee,
            setClient: nil,
            setTaxRate: nil,
            setDeductiblePct: nil,
            markAsTransfer: nil,
            createdAt: today,
            updatedAt: today
        )

        var nextRules = [newRule] + rulesSnapshot
        nextRules = nextRules.enumerated().map { idx, r in
            var copy = r
            copy.priority = idx + 1
            return copy
        }
        rulesSnapshot = nextRules

        let reEvaluated = BankImport.stageBankTransactions(
            rawTransactions: currentParseResult.rawTransactions,
            state: store.state,
            targetMode: targetMode,
            accountId: accountId,
            rulesOverride: nextRules
        )

        var matchedCount = 0
        let existingIncludedMap = Dictionary(stagedRows.map { ($0.id, $0.included) }, uniquingKeysWith: { a, _ in a })
        stagedRows = zip(stagedRows, reEvaluated).map { current, fresh in
            if fresh.matchedRuleId == newRule.id {
                matchedCount += 1
                var updated = fresh
                updated.included = existingIncludedMap[current.id] ?? fresh.included
                return updated
            }
            if current.id == sourceRow.id {
                var updated = current
                updated.categoryId = draftCategoryId
                updated.mode = cat?.mode ?? current.mode
                if !cleanPayee.isEmpty { updated.description = cleanPayee }
                updated.confidence = .rule
                updated.matchedRuleId = newRule.id
                return updated
            }
            return current
        }

        editingRuleRowId = nil
        bannerInfo = "Rule \"\(newRule.name)\" saved and matched \(max(matchedCount, 1)) statement row(s)."
    }

    private func applyBulkCategory() {
        guard let cat = categoryMap[bulkCategoryId] else { return }
        let visIds = Set(visibleRows.map(\.id))
        for i in stagedRows.indices where stagedRows[i].included && visIds.contains(stagedRows[i].id) {
            stagedRows[i].categoryId = cat.id
            stagedRows[i].mode = cat.mode
            stagedRows[i].confidence = .rule
            stagedRows[i].matchReason = "Bulk assigned"
        }
    }

    private func toggleVisibleRows() {
        let visIds = Set(visibleRows.map(\.id))
        let anyIncluded = visibleRows.contains(\.included)
        for i in stagedRows.indices where visIds.contains(stagedRows[i].id) {
            stagedRows[i].included = !anyIncluded
        }
    }
}

// MARK: - CSV / Excel Column Mapper

struct BankColumnMapperView: View {
    let fileName: String
    let rawRows: [[String]]
    let initialHeaderRow: Int
    let initialProfile: BankImportProfile?
    let accountId: String?
    let targetMode: LedgerMode
    let fallbackCurrency: String
    let onBack: () -> Void
    let onCancel: () -> Void
    let onContinue: (
        _ headerRowIndex: Int,
        _ profile: BankImportProfile,
        _ rawTransactions: [RawBankTransaction],
        _ profileToSave: BankImportProfile?
    ) -> Void

    @State private var headerRowIndex: Int
    @State private var dateColumn: String
    @State private var dateFormat: BankDateFormat
    @State private var amountMode: BankAmountMode
    @State private var amountColumn: String
    @State private var debitColumn: String
    @State private var creditColumn: String
    @State private var decimalSep: BankDecimalSeparator
    @State private var invertSign: Bool
    @State private var payeeColumn: String
    @State private var descriptionColumn: String
    @State private var referenceColumn: String
    @State private var currencyColumn: String
    @State private var saveAsProfile: Bool = true
    @State private var profileName: String

    init(
        fileName: String,
        rawRows: [[String]],
        initialHeaderRow: Int,
        initialProfile: BankImportProfile?,
        accountId: String?,
        targetMode: LedgerMode,
        fallbackCurrency: String,
        onBack: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (
            _ headerRowIndex: Int,
            _ profile: BankImportProfile,
            _ rawTransactions: [RawBankTransaction],
            _ profileToSave: BankImportProfile?
        ) -> Void
    ) {
        self.fileName = fileName
        self.rawRows = rawRows
        self.initialHeaderRow = initialHeaderRow
        self.initialProfile = initialProfile
        self.accountId = accountId
        self.targetMode = targetMode
        self.fallbackCurrency = fallbackCurrency
        self.onBack = onBack
        self.onCancel = onCancel
        self.onContinue = onContinue

        let safeRow = min(max(0, initialHeaderRow), max(0, rawRows.count - 1))
        let hdrs = safeRow < rawRows.count ? BankImport.makeUniqueHeaders(rawRows[safeRow]) : []
        _headerRowIndex = State(initialValue: safeRow)
        _dateColumn = State(initialValue: initialProfile?.dateColumn ?? hdrs.first ?? "")
        _dateFormat = State(initialValue: initialProfile?.dateFormat ?? .auto)
        _amountMode = State(initialValue: initialProfile?.amountMode ?? .signed)
        _amountColumn = State(initialValue: initialProfile?.amountColumn ?? "")
        _debitColumn = State(initialValue: initialProfile?.debitColumn ?? "")
        _creditColumn = State(initialValue: initialProfile?.creditColumn ?? "")
        _decimalSep = State(initialValue: initialProfile?.decimalSeparator ?? .auto)
        _invertSign = State(initialValue: initialProfile?.invertSign ?? false)
        _payeeColumn = State(initialValue: initialProfile?.payeeColumn ?? "")
        _descriptionColumn = State(initialValue: initialProfile?.descriptionColumns.first ?? "")
        _referenceColumn = State(initialValue: initialProfile?.referenceColumn ?? "")
        _currencyColumn = State(initialValue: initialProfile?.currencyColumn ?? "")
        _profileName = State(initialValue: {
            if let existing = initialProfile?.name, !existing.isEmpty, existing != "Auto-Detected CSV" {
                return existing
            }
            return (fileName as NSString).deletingPathExtension
        }())
    }

    private var headers: [String] {
        guard headerRowIndex >= 0, headerRowIndex < rawRows.count else { return [] }
        return BankImport.makeUniqueHeaders(rawRows[headerRowIndex])
    }

    private func buildProfile() -> BankImportProfile {
        let descCols = [descriptionColumn].filter { !$0.isEmpty }
        let today = bankTodayIso()
        let isCustomSaved = initialProfile?.id.hasPrefix("profile-") == true
        return BankImportProfile(
            id: isCustomSaved ? initialProfile!.id : "profile-\(DataIOJS.nowMillis())",
            name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Custom Bank CSV"
                : profileName.trimmingCharacters(in: .whitespacesAndNewlines),
            accountId: accountId,
            defaultMode: targetMode,
            headerFingerprint: Array(headers.prefix(8)),
            delimiter: initialProfile?.delimiter,
            dateColumn: dateColumn,
            dateFormat: dateFormat,
            amountMode: amountMode,
            amountColumn: amountMode == .signed && !amountColumn.isEmpty ? amountColumn : nil,
            debitColumn: amountMode == .splitDebitCredit && !debitColumn.isEmpty ? debitColumn : nil,
            creditColumn: amountMode == .splitDebitCredit && !creditColumn.isEmpty ? creditColumn : nil,
            invertSign: invertSign,
            decimalSeparator: decimalSep,
            descriptionColumns: descCols,
            payeeColumn: payeeColumn.isEmpty ? nil : payeeColumn,
            referenceColumn: referenceColumn.isEmpty ? nil : referenceColumn,
            currencyColumn: currencyColumn.isEmpty ? nil : currencyColumn,
            skipRows: headerRowIndex,
            updatedAt: today
        )
    }

    private var previewExtraction: [RawBankTransaction] {
        BankImport.extractRawTransactions(
            matrix: rawRows,
            headerRowIndex: headerRowIndex,
            profile: buildProfile(),
            fallbackCurrency: fallbackCurrency
        ).rawTransactions
    }

    var body: some View {
        let extracted = previewExtraction
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Map Statement Columns — \(fileName)")
                        .font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    Text("Match your bank's column layout once and optionally save it for future exports.")
                        .font(.zen(11)).foregroundStyle(Zen.ink2)
                }
                Spacer()
                DataIOPill(
                    text: "\(extracted.count) transactions detected",
                    foreground: extracted.isEmpty ? DataIOColors.amber600 : Zen.positive,
                    background: (extracted.isEmpty ? DataIOColors.amber500 : Zen.positive).opacity(0.12)
                )
            }

            // Header row selector & preview slice
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("HEADER ROW").font(.zen(10, .semibold)).tracking(0.6).foregroundStyle(Zen.ink3)
                    Stepper("Row \(headerRowIndex + 1)", value: $headerRowIndex, in: 0...max(0, min(rawRows.count - 1, 39)))
                        .font(.zen(12)).fixedSize()
                    Spacer()
                }
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 3) {
                        let start = max(0, headerRowIndex - 1)
                        let end = min(rawRows.count, headerRowIndex + 4)
                        ForEach(start..<end, id: \.self) { r in
                            let isHdr = r == headerRowIndex
                            HStack(spacing: 6) {
                                Text("R\(r + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(isHdr ? Zen.onInk : Zen.ink3)
                                    .frame(width: 28, alignment: .trailing)
                                ForEach(Array(rawRows[r].prefix(8).enumerated()), id: \.offset) { _, cell in
                                    Text(cell.isEmpty ? "—" : cell)
                                        .font(.zen(11, isHdr ? .medium : .regular))
                                        .foregroundStyle(isHdr ? Zen.onInk : Zen.ink2)
                                        .lineLimit(1)
                                        .frame(width: 110, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isHdr ? Zen.ink : Zen.app, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
                .background(Zen.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }

            // Column Mapping Grid
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    mapperPicker("Date column", selection: $dateColumn)
                    VStack(alignment: .leading, spacing: 3) {
                        DataIOFieldLabel("Date format")
                        Picker("", selection: $dateFormat) {
                            Text("Auto detect").tag(BankDateFormat.auto)
                            Text("YYYY-MM-DD").tag(BankDateFormat.iso)
                            Text("DD.MM.YYYY (CH/DE)").tag(BankDateFormat.chDot)
                            Text("DD/MM/YYYY").tag(BankDateFormat.euSlash)
                            Text("MM/DD/YYYY (US)").tag(BankDateFormat.usSlash)
                            Text("YYYYMMDD").tag(BankDateFormat.compact)
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        DataIOFieldLabel("Decimal format")
                        Picker("", selection: $decimalSep) {
                            Text("Auto detect").tag(BankDecimalSeparator.auto)
                            Text("Dot (1'234.50)").tag(BankDecimalSeparator.dot)
                            Text("Comma (1.234,50)").tag(BankDecimalSeparator.comma)
                        }
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        DataIOFieldLabel("Amount layout")
                        Picker("", selection: $amountMode) {
                            Text("Single signed (+/-) column").tag(BankAmountMode.signed)
                            Text("Split Debit / Credit columns").tag(BankAmountMode.splitDebitCredit)
                        }
                        .labelsHidden()
                    }
                    if amountMode == .signed {
                        mapperPicker("Amount column", selection: $amountColumn)
                    } else {
                        mapperPicker("Debit (outflow) column", selection: $debitColumn)
                        mapperPicker("Credit (inflow) column", selection: $creditColumn)
                    }
                    DataIOCheckbox(isOn: $invertSign, spacing: 6) {
                        Text("Invert +/- signs (credit card CSV)")
                            .font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    mapperPicker("Description column", selection: $descriptionColumn)
                    mapperPicker("Payee / Counterparty", selection: $payeeColumn)
                    mapperPicker("Reference / ID (optional)", selection: $referenceColumn)
                    mapperPicker("Currency (optional)", selection: $currencyColumn)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Zen.app, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))

            HStack(spacing: 12) {
                DataIOCheckbox(isOn: $saveAsProfile, spacing: 8) {
                    Text("Save mapping as reusable Bank Profile")
                        .font(.zen(12)).foregroundStyle(Zen.ink)
                }
                if saveAsProfile {
                    DataIOTextField(placeholder: "Profile name (e.g. UBS Checking)", text: $profileName, height: 30, background: Zen.surface)
                        .frame(width: 240)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 5) { ZIcon("arrow.left", size: 13); Text("Back") }
                }
                .buttonStyle(DataIORaisedButtonStyle(height: 34, padding: 14, background: Zen.surface))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.zen(.ghost, height: 34, padding: 14))
                Button {
                    let prof = buildProfile()
                    onContinue(headerRowIndex, prof, extracted, saveAsProfile ? prof : nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("Review \(extracted.count) Transaction(s)")
                        ZIcon("arrow.right", size: 13)
                    }
                }
                .buttonStyle(DataIOInkButtonStyle(height: 34, padding: 18))
                .disabled(extracted.isEmpty)
            }
        }
        .onChange(of: headerRowIndex) { _, _ in
            let valid = Set(headers)
            if !valid.contains(dateColumn) { dateColumn = headers.first ?? "" }
            if !valid.contains(amountColumn) { amountColumn = "" }
            if !valid.contains(debitColumn) { debitColumn = "" }
            if !valid.contains(creditColumn) { creditColumn = "" }
            if !valid.contains(payeeColumn) { payeeColumn = "" }
            if !valid.contains(descriptionColumn) { descriptionColumn = "" }
            if !valid.contains(referenceColumn) { referenceColumn = "" }
            if !valid.contains(currencyColumn) { currencyColumn = "" }
        }
    }

    private func mapperPicker(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            DataIOFieldLabel(label)
            Picker("", selection: selection) {
                Text("— None —").tag("")
                ForEach(headers, id: \.self) { h in
                    Text(h).tag(h)
                }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Categorization Rules & Saved Bank Profiles Manager

struct ImportRulesManagerView: View {
    enum Tab: String, CaseIterable {
        case rules = "Categorization Rules"
        case profiles = "Saved Bank Profiles"
    }

    @Environment(LedgerStore.self) private var store

    @State private var tab: Tab = .rules
    @State private var rules: [ImportRule] = []
    @State private var profiles: [BankImportProfile] = []
    @State private var showAddForm = false

    @State private var newName = ""
    @State private var newPattern = ""
    @State private var newField: ImportRuleMatchField = .any
    @State private var newType: ImportRuleMatchType = .contains
    @State private var newDirection: ImportRuleDirection = .any
    @State private var newAccountId = ""
    @State private var newCategoryId = ""
    @State private var newPayee = ""

    @State private var didInit = false

    private var catMap: [String: CategoryItem] {
        Dictionary(store.state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var accMap: [String: FinancialAccount] {
        Dictionary(store.state.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 10) {
                    ZIcon("tag", size: 16).foregroundStyle(Zen.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bank Import Rules & Saved Profiles")
                            .font(.zen(16, .medium)).foregroundStyle(Zen.ink)
                        Text("Rules run locally during statement review and sync inside your encrypted vault.")
                            .font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                }
                Spacer()
                Button { store.dismissModal() } label: { ZIcon("xmark", size: 15) }
                    .buttonStyle(.zen(.icon, height: 28, radius: 8, padding: 6))
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(Zen.app.opacity(0.6))
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            // Tabs
            HStack(spacing: 8) {
                ForEach(Tab.allCases, id: \.self) { t in
                    let active = tab == t
                    let count = t == .rules ? rules.count : profiles.count
                    Button { tab = t } label: {
                        Text("\(t.rawValue) (\(count))")
                            .font(.zen(12, active ? .medium : .regular))
                            .foregroundStyle(active ? Zen.onInk : Zen.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(active ? Zen.ink : Zen.raised, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if tab == .rules {
                    Button {
                        showAddForm.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            ZIcon("plus", size: 12)
                            Text("Add Rule")
                        }
                    }
                    .buttonStyle(DataIORaisedButtonStyle(height: 30, padding: 12, fontSize: 11))
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 12) {
                if tab == .rules {
                    if showAddForm { addRuleForm }
                    rulesList
                } else {
                    profilesList
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            // Footer
            HStack {
                Spacer()
                Button("Close") { store.dismissModal() }
                    .buttonStyle(DataIOInkButtonStyle(height: 34, padding: 18))
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
        }
        .frame(width: 780)
        .background(Zen.surface)
        .onAppear {
            if !didInit {
                didInit = true
                rules = (store.state.importRules ?? []).sorted { $0.priority < $1.priority }
                profiles = store.state.importProfiles ?? []
                newCategoryId = store.state.categories.first?.id ?? ""
            }
        }
    }

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Rule name (optional)", size: 10)
                    DataIOTextField(placeholder: "e.g. Migros Groceries", text: $newName, height: 30, background: Zen.surface)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Pattern", size: 10)
                    DataIOTextField(placeholder: "e.g. migros", text: $newPattern, height: 30, background: Zen.surface)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Match field & type", size: 10)
                    HStack(spacing: 4) {
                        Picker("", selection: $newField) {
                            Text("Any").tag(ImportRuleMatchField.any)
                            Text("Payee").tag(ImportRuleMatchField.payee)
                            Text("Desc").tag(ImportRuleMatchField.description)
                            Text("IBAN").tag(ImportRuleMatchField.iban)
                        }
                        .labelsHidden()
                        Picker("", selection: $newType) {
                            Text("Contains").tag(ImportRuleMatchType.contains)
                            Text("Starts").tag(ImportRuleMatchType.startsWith)
                            Text("Exact").tag(ImportRuleMatchType.exact)
                            Text("Regex").tag(ImportRuleMatchType.regex)
                        }
                        .labelsHidden()
                    }
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Assign Category", size: 10)
                    Picker("", selection: $newCategoryId) {
                        ForEach(store.state.categories) { c in
                            Text("[\(c.mode == .freelancer ? "Biz" : "Home")] \(L10n.categoryName(c))").tag(c.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Direction", size: 10)
                    Picker("", selection: $newDirection) {
                        Text("Any").tag(ImportRuleDirection.any)
                        Text("Expense").tag(ImportRuleDirection.expense)
                        Text("Income").tag(ImportRuleDirection.income)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Account scope", size: 10)
                    Picker("", selection: $newAccountId) {
                        Text("All Accounts").tag("")
                        ForEach(store.state.accounts) { a in
                            Text(L10n.accountName(a)).tag(a.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 3) {
                    DataIOFieldLabel("Clean Payee", size: 10)
                    DataIOTextField(placeholder: "Optional", text: $newPayee, height: 30, background: Zen.surface)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddForm = false }
                    .buttonStyle(DataIORaisedButtonStyle(height: 28, padding: 12, fontSize: 11))
                Button("Save Rule") { addNewRule() }
                    .buttonStyle(DataIOInkButtonStyle(height: 28, padding: 14, fontSize: 11))
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newCategoryId.isEmpty)
            }
        }
        .padding(12)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
    }

    @ViewBuilder
    private var rulesList: some View {
        if rules.isEmpty {
            Text("No categorization rules saved yet. Click \"+ Rule\" during statement review or \"Add Rule\" above.")
                .font(.zen(12)).foregroundStyle(Zen.ink3)
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rules.indices, id: \.self) { idx in
                        if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                        let rule = rules[idx]
                        let catName = catMap[rule.setCategoryId].map { L10n.categoryName($0) } ?? rule.setCategoryId
                        let accName = rule.accountId.flatMap { accMap[$0] }.map { L10n.accountName($0) }
                        HStack(spacing: 10) {
                            DataIOCheckbox(isOn: Binding(
                                get: { rules[idx].enabled },
                                set: { v in
                                    rules[idx].enabled = v
                                    persist()
                                }
                            )) { EmptyView() }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(rule.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                                    DataIOPill(text: "\(rule.matchField.rawValue) · \(rule.matchType.rawValue)", foreground: Zen.ink2, background: Zen.raised)
                                    if let accName {
                                        DataIOPill(text: accName, foreground: Zen.indigo, background: Zen.indigo.opacity(0.1))
                                    }
                                }
                                Text("Pattern \"\(rule.pattern)\" → \(catName)")
                                    .font(.zen(11)).foregroundStyle(Zen.ink2)
                            }
                            Spacer()
                            Button { moveRule(idx, -1) } label: { ZIcon("arrow.up", size: 12) }
                                .buttonStyle(.zen(.icon, height: 24, radius: 6, padding: 4))
                                .disabled(idx == 0)
                            Button { moveRule(idx, 1) } label: { ZIcon("arrow.down", size: 12) }
                                .buttonStyle(.zen(.icon, height: 24, radius: 6, padding: 4))
                                .disabled(idx == rules.count - 1)
                            Button {
                                rules.remove(at: idx)
                                renumberRules()
                                persist()
                            } label: { ZIcon("trash", size: 12).foregroundStyle(Zen.accent) }
                                .buttonStyle(.zen(.icon, height: 24, radius: 6, padding: 4))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .opacity(rule.enabled ? 1 : 0.5)
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(Zen.app)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var profilesList: some View {
        if profiles.isEmpty {
            Text("No custom bank CSV profiles saved yet. Unknown bank CSV layouts can save a reusable profile on import.")
                .font(.zen(12)).foregroundStyle(Zen.ink3)
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(profiles.indices, id: \.self) { idx in
                        if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                        let p = profiles[idx]
                        HStack(spacing: 10) {
                            ZIcon("tablecells", size: 14).foregroundStyle(Zen.indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                                Text("Date: \(p.dateColumn) (\(p.dateFormat.rawValue)) · \(p.amountMode == .splitDebitCredit ? "Split Debit/Credit" : "Signed Amount") · Updated \(p.updatedAt)")
                                    .font(.zen(11)).foregroundStyle(Zen.ink2)
                            }
                            Spacer()
                            Button {
                                profiles.remove(at: idx)
                                persist()
                            } label: { ZIcon("trash", size: 12).foregroundStyle(Zen.accent) }
                                .buttonStyle(.zen(.icon, height: 24, radius: 6, padding: 4))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(Zen.app)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
        }
    }

    private func addNewRule() {
        let pat = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty, !newCategoryId.isEmpty else { return }
        let today = bankTodayIso()
        let cat = catMap[newCategoryId]
        let cleanPayee = newPayee.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = ImportRule(
            id: "imprule-\(DataIOJS.nowMillis())",
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (cleanPayee.isEmpty ? pat : cleanPayee)
                : newName.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true,
            priority: 1,
            accountId: newAccountId.isEmpty ? nil : newAccountId,
            direction: newDirection,
            matchField: newField,
            matchType: newType,
            pattern: pat,
            minAmount: nil,
            maxAmount: nil,
            setCategoryId: newCategoryId,
            setMode: cat?.mode,
            setPayee: cleanPayee.isEmpty ? nil : cleanPayee,
            setClient: nil,
            setTaxRate: nil,
            setDeductiblePct: nil,
            markAsTransfer: nil,
            createdAt: today,
            updatedAt: today
        )
        rules.insert(rule, at: 0)
        renumberRules()
        persist()
        newName = ""
        newPattern = ""
        newPayee = ""
        showAddForm = false
    }

    private func moveRule(_ idx: Int, _ delta: Int) {
        let target = idx + delta
        guard rules.indices.contains(idx), rules.indices.contains(target) else { return }
        rules.swapAt(idx, target)
        renumberRules()
        persist()
    }

    private func renumberRules() {
        rules = rules.enumerated().map { idx, r in
            var copy = r
            copy.priority = idx + 1
            return copy
        }
    }

    private func persist() {
        store.saveImportRulesAndProfiles(rules: rules, profiles: profiles)
    }
}
