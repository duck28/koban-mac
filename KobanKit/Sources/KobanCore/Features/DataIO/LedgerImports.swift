import Foundation

// Port of the import half of src/utils/exportImport.ts plus the preview/confirm data model
// of src/components/ImportDataModal.tsx.

enum ImportKind: String, CaseIterable, Sendable {
    case budgetSheet = "budget_sheet"
    case transactions
    case databaseBackup = "database_backup"
}

struct BudgetImportPreviewRow: Hashable, Identifiable, Sendable {
    var categoryId: String
    var groupName: String
    var categoryName: String
    var kind: CategoryKind
    var isNewCategory: Bool
    var previousBudget: Double
    var previousActual: Double
    var budget: Double
    var actual: Double
    var id: String { categoryId }
}

struct TransactionImportPreviewRow: Hashable, Identifiable, Sendable {
    var id: String
    var date: String
    var monthKey: String
    var type: TransactionType
    var categoryName: String
    var description: String
    var amount: Double
    var client: String?
    var taxRate: Double?
}

struct ImportPreviewData: Sendable {
    var kind: ImportKind
    var targetMode: LedgerMode
    var fileName: String
    var sheetName: String?
    var proposedState: LedgerState
    var importedCount: Int
    var budgetRows: [BudgetImportPreviewRow]?
    var transactionRows: [TransactionImportPreviewRow]?
    var backupPath: String?

    /// handleConfirmPreview in ImportDataModal.tsx: drops the rows the user unticked.
    /// Excluded transactions are removed; excluded budget rows revert to their previous
    /// values and excluded *new* categories are not created.
    func applyingExclusions(_ excluded: Set<String>, monthKey: String) -> ImportPreviewData {
        guard !excluded.isEmpty else { return self }
        var out = self
        switch kind {
        case .transactions:
            out.importedCount = (transactionRows ?? []).filter { !excluded.contains($0.id) }.count
            out.proposedState.transactions.removeAll { excluded.contains($0.id) }
        case .budgetSheet:
            let rows = budgetRows ?? []
            out.importedCount = rows.filter { !excluded.contains($0.categoryId) }.count
            let newExcluded = Set(rows.filter { $0.isNewCategory && excluded.contains($0.categoryId) }.map(\.categoryId))
            out.proposedState.categories.removeAll { newExcluded.contains($0.id) }
            out.proposedState.monthlyBudgets = proposedState.monthlyBudgets.map { mb in
                guard mb.monthKey == monthKey, excluded.contains(mb.categoryId),
                      let row = rows.first(where: { $0.categoryId == mb.categoryId }) else { return mb }
                var copy = mb
                copy.budget = row.previousBudget
                copy.directActual = row.previousActual
                return copy
            }
        case .databaseBackup:
            break
        }
        return out
    }

    /// `(categories + transactions + accounts).length` for backup previews.
    static func backupRecordCount(_ s: LedgerState) -> Int {
        s.categories.count + s.transactions.count + s.accounts.count
    }
}

enum LedgerImports {
    struct BudgetImportResult {
        var state: LedgerState
        var importedCategories: Int
        var sheetName: String
        var previewRows: [BudgetImportPreviewRow]
    }

    struct TransactionImportResult {
        var state: LedgerState
        var importedTransactions: Int
        var sheetName: String
        var previewRows: [TransactionImportPreviewRow]
    }

    /// Non-zero numeric activity of a sheet (ignores the `42` placeholder of the
    /// "Personal Monthly Budget" template).
    static func activityScore(_ rows: [[SheetCell]]) -> Double {
        var score = 0.0
        for r in rows {
            for cell in r {
                let n: Double?
                switch cell {
                case .number(let v): n = v
                case .string(let s): n = DataIOJS.parseStripped(s)
                }
                if let n, !n.isNaN, abs(n) > 0, abs(n) != 42 { score += abs(n) }
            }
        }
        return score
    }

    private static func cell(_ row: [SheetCell], _ i: Int) -> String {
        i >= 0 && i < row.count ? row[i].text : ""
    }

    private static func guessKind(_ name: String) -> CategoryKind {
        let u = name.uppercased()
        if u.contains("INCOME") || u.contains("REVENUE") { return .income }
        if u.contains("SAVING") { return .savings }
        return .expense
    }

    /// importBudgetSheetFromBuffer: merges groups, categories, budgets and actuals from a
    /// 2-column Monthly Budget sheet or a flat category table into `targetMode` / `monthKey`.
    static func importBudgetSheet(_ wb: WorkbookData, currentState: LedgerState,
                                  targetMode: LedgerMode, monthKey: String,
                                  now: Int64 = DataIOJS.nowMillis()) -> BudgetImportResult {
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthPart = monthKey.split(separator: "-").dropFirst().first.map(String.init) ?? "1"
        let monthNum = Int(monthPart) ?? 1
        let targetMonthIdx = max(0, min(11, (monthNum == 0 ? 1 : monthNum) - 1))
        let targetMonthShort = monthNames[targetMonthIdx]

        guard let first = wb.sheets.first else {
            return BudgetImportResult(state: currentState, importedCategories: 0, sheetName: "", previewRows: [])
        }
        var chosen = first
        if let monthMatched = wb.sheets.first(where: { $0.name.lowercased().hasPrefix(targetMonthShort) }),
           activityScore(monthMatched.rows) > 0 {
            chosen = monthMatched
        }
        var aoa = chosen.rows
        var chosenName = chosen.name

        if activityScore(aoa) == 0 && wb.sheets.count > 1 {
            for s in wb.sheets where activityScore(s.rows) > 0 {
                chosenName = s.name
                aoa = s.rows
                break
            }
        }

        // Stacked "Personal Monthly Budget" blocks (e.g. 12 months in one CSV).
        var blockStarts: [Int] = []
        for (r, row) in aoa.enumerated() {
            let c0 = cell(row, 0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let c1 = cell(row, 1).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let c2 = cell(row, 2).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if c0 == "INCOME" && c1 == "budget" && c2 == "actual" { blockStarts.append(r) }
        }
        if blockStarts.count > 1 {
            var blocks: [[[SheetCell]]] = []
            for (i, start) in blockStarts.enumerated() {
                let end = i + 1 < blockStarts.count ? blockStarts[i + 1] : aoa.count
                blocks.append(Array(aoa[start..<end]))
            }
            let nonZero = blocks.filter { activityScore($0) > 0 }
            aoa = nonZero.isEmpty ? blocks[0] : nonZero.flatMap { $0 }
        }

        var nextGroups = currentState.groups
        var nextCategories = currentState.categories
        var nextBudgets = currentState.monthlyBudgets
        var previewOrder: [String] = []
        var previewMap: [String: BudgetImportPreviewRow] = [:]
        func setPreview(_ row: BudgetImportPreviewRow) {
            if previewMap[row.categoryId] == nil { previewOrder.append(row.categoryId) }
            previewMap[row.categoryId] = row
        }
        var importedCount = 0
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let headerRow = (aoa.first ?? []).map { trim($0.text).lowercased() }
        let grpCol = headerRow.firstIndex { $0 == "group" || $0 == "category group" } ?? -1
        let catCol = headerRow.firstIndex { $0 == "category" || $0 == "item" || $0 == "subcategory" } ?? -1
        let budCol = headerRow.firstIndex { $0.contains("budget") || $0 == "planned" } ?? -1
        let actCol = headerRow.firstIndex { $0.contains("actual") || $0 == "spent" } ?? -1

        func modeGroupCount() -> Int { nextGroups.filter { $0.mode == targetMode }.count }

        if catCol >= 0 && (budCol >= 0 || actCol >= 0) {
            // ---- Flat category table ----
            for r in aoa.indices.dropFirst() {
                let row = aoa[r]
                let catName = trim(cell(row, catCol))
                if catName.isEmpty { continue }
                let grpRaw = grpCol >= 0 ? trim(cell(row, grpCol)) : ""
                let grpName = grpRaw.isEmpty ? "GENERAL" : grpRaw
                let budgetVal = budCol >= 0 ? DataIOJS.orZero(DataIOJS.parseStripped(cell(row, budCol))) : 0
                let actualVal = actCol >= 0 ? DataIOJS.orZero(DataIOJS.parseStripped(cell(row, actCol))) : 0

                var grp: CategoryGroup
                if let g = nextGroups.first(where: { $0.mode == targetMode && $0.name.lowercased() == grpName.lowercased() }) {
                    grp = g
                } else {
                    let kind = guessKind(grpName)
                    grp = CategoryGroup(id: "grp-imp-\(now)-\(r)", mode: targetMode, name: grpName.uppercased(),
                                        kind: kind, color: kind == .income ? "#3f704d" : "#3f6e8c",
                                        column: 0, order: modeGroupCount())
                    nextGroups.append(grp)
                }

                let catIdx = nextCategories.firstIndex { $0.groupId == grp.id && $0.name.lowercased() == catName.lowercased() }
                let isNew = catIdx == nil
                let cat: CategoryItem
                if let catIdx {
                    if budgetVal > 0 { nextCategories[catIdx].defaultBudget = budgetVal }
                    cat = nextCategories[catIdx]
                } else {
                    cat = CategoryItem(id: "cat-imp-\(now)-\(r)", groupId: grp.id, mode: targetMode, name: catName,
                                       kind: grp.kind, defaultBudget: budgetVal, taxRate: 0,
                                       deductiblePct: targetMode == .freelancer ? 100 : 0,
                                       order: nextCategories.filter { $0.groupId == grp.id }.count)
                    nextCategories.append(cat)
                }

                let mbIdx = nextBudgets.firstIndex { $0.monthKey == monthKey && $0.categoryId == cat.id }
                let prevBud = mbIdx.map { nextBudgets[$0].budget } ?? 0
                let prevAct = mbIdx.map { nextBudgets[$0].directActual ?? 0 } ?? 0
                var finalBudget = budgetVal
                var finalActual = actualVal
                if let mbIdx {
                    let existing = nextBudgets[mbIdx]
                    finalBudget = budgetVal != 0 || existing.budget == 0 ? budgetVal : existing.budget
                    finalActual = actualVal != 0 || (existing.directActual ?? 0) == 0 ? actualVal : (existing.directActual ?? 0)
                    nextBudgets[mbIdx].budget = finalBudget
                    nextBudgets[mbIdx].directActual = finalActual
                } else {
                    nextBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: cat.id, budget: budgetVal, directActual: actualVal))
                }

                setPreview(BudgetImportPreviewRow(categoryId: cat.id, groupName: grp.name, categoryName: cat.name,
                                                  kind: grp.kind, isNewCategory: isNew, previousBudget: prevBud,
                                                  previousActual: prevAct, budget: finalBudget, actual: finalActual))
                importedCount += 1
            }

            var state = currentState
            state.groups = nextGroups
            state.categories = nextCategories
            state.monthlyBudgets = nextBudgets
            return BudgetImportResult(state: state, importedCategories: importedCount, sheetName: chosenName,
                                      previewRows: previewOrder.compactMap { previewMap[$0] })
        }

        // ---- 2-column Monthly Budget worksheet layout ----
        var updatedCatIds = Set<String>()

        func parseSide(colOffset: Int, columnIdx: Int) {
            var activeGroup: CategoryGroup?
            for (r, row) in aoa.enumerated() {
                let col0 = trim(cell(row, colOffset))
                let col1 = trim(cell(row, colOffset + 1))
                let col2 = trim(cell(row, colOffset + 2))
                if col0.isEmpty { continue }

                if col1.lowercased() == "budget" && col2.lowercased() == "actual" {
                    if col0.uppercased() == "BUDGET SUMMARY" { activeGroup = nil; continue }
                    if let g = nextGroups.first(where: { $0.mode == targetMode && $0.name.lowercased() == col0.lowercased() }) {
                        activeGroup = g
                    } else {
                        let kind = guessKind(col0)
                        let g = CategoryGroup(id: "grp-imp-\(now)-\(r)-\(colOffset)", mode: targetMode, name: col0,
                                              kind: kind, color: kind == .income ? "#3f704d" : "#3f6e8c",
                                              column: columnIdx, order: modeGroupCount())
                        nextGroups.append(g)
                        activeGroup = g
                    }
                    continue
                }

                let lower = col0.lowercased()
                if lower.hasPrefix("total ") || col0.uppercased() == "NET" || lower.hasPrefix("personal monthly budget")
                    || lower.hasPrefix("http") || col0 == "[42]" {
                    activeGroup = nil
                    continue
                }

                guard let group = activeGroup else { continue }
                let budgetNum = DataIOJS.orZero(DataIOJS.parseStripped(col1))
                let actualNum = DataIOJS.orZero(DataIOJS.parseStripped(col2))

                let catIdx = nextCategories.firstIndex { $0.groupId == group.id && $0.name.lowercased() == lower }
                let isNew = catIdx == nil
                let cat: CategoryItem
                if let catIdx {
                    if budgetNum > 0 { nextCategories[catIdx].defaultBudget = budgetNum }
                    cat = nextCategories[catIdx]
                } else {
                    cat = CategoryItem(id: "cat-imp-\(now)-\(r)-\(colOffset)", groupId: group.id, mode: targetMode,
                                       name: col0, kind: group.kind, defaultBudget: budgetNum, taxRate: 0,
                                       deductiblePct: targetMode == .freelancer ? 100 : 0,
                                       order: nextCategories.filter { $0.groupId == group.id }.count)
                    nextCategories.append(cat)
                }

                let mbIdx = nextBudgets.firstIndex { $0.monthKey == monthKey && $0.categoryId == cat.id }
                let origMb = currentState.monthlyBudgets.first { $0.monthKey == monthKey && $0.categoryId == cat.id }
                var finalBudget = budgetNum
                var finalActual = actualNum
                if let mbIdx {
                    let prev = nextBudgets[mbIdx]
                    // Duplicate rows (e.g. two "Other" lines) must not zero out a value set earlier in this pass.
                    let already = updatedCatIds.contains(cat.id)
                    finalBudget = already && budgetNum == 0 && prev.budget != 0 ? prev.budget : budgetNum
                    finalActual = already && actualNum == 0 && (prev.directActual ?? 0) != 0 ? (prev.directActual ?? 0) : actualNum
                    nextBudgets[mbIdx].budget = finalBudget
                    nextBudgets[mbIdx].directActual = finalActual
                } else {
                    nextBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: cat.id, budget: budgetNum, directActual: actualNum))
                }

                setPreview(BudgetImportPreviewRow(categoryId: cat.id, groupName: group.name, categoryName: cat.name,
                                                  kind: group.kind, isNewCategory: isNew,
                                                  previousBudget: origMb?.budget ?? 0,
                                                  previousActual: origMb?.directActual ?? 0,
                                                  budget: finalBudget, actual: finalActual))
                updatedCatIds.insert(cat.id)
                importedCount += 1
            }
        }

        parseSide(colOffset: 0, columnIdx: 0)
        parseSide(colOffset: 5, columnIdx: 1)

        var state = currentState
        state.groups = nextGroups
        state.categories = nextCategories
        state.monthlyBudgets = nextBudgets
        return BudgetImportResult(state: state,
                                  importedCategories: updatedCatIds.isEmpty ? importedCount : updatedCatIds.count,
                                  sheetName: chosenName,
                                  previewRows: previewOrder.compactMap { previewMap[$0] })
    }

    /// `sheet_to_json(sheet, { defval: '' })`: first row = keys (empty → "__EMPTY", duplicates
    /// → "name_1"), blank rows skipped.
    static func objectRows(_ rows: [[SheetCell]]) -> (keys: [String], rows: [[String: SheetCell]]) {
        guard let header = rows.first else { return ([], []) }
        var keys: [String] = []
        var used: [String: Int] = [:]
        var emptyCount = 0
        for c in header {
            var k = c.text
            if k.isEmpty {
                k = emptyCount == 0 ? "__EMPTY" : "__EMPTY_\(emptyCount)"
                emptyCount += 1
            }
            if let n = used[k] {
                var candidate = "\(k)_\(n)"
                var m = n
                while used[candidate] != nil { m += 1; candidate = "\(k)_\(m)" }
                used[k] = m + 1
                used[candidate] = 1
                k = candidate
            } else {
                used[k] = 1
            }
            keys.append(k)
        }
        var out: [[String: SheetCell]] = []
        for row in rows.dropFirst() {
            if row.allSatisfy(\.isEmpty) { continue }
            var obj: [String: SheetCell] = [:]
            for (i, k) in keys.enumerated() { obj[k] = i < row.count ? row[i] : .empty }
            out.append(obj)
        }
        return (keys, out)
    }

    /// importTransactionsFromBuffer: transactions / bank statements with smart column matching.
    static func importTransactions(_ wb: WorkbookData, currentState: LedgerState,
                                   targetMode: LedgerMode, fallbackMonthKey: String,
                                   now: Int64 = DataIOJS.nowMillis()) -> TransactionImportResult {
        guard let sheet = wb.sheets.first(where: { $0.name.lowercased().contains("transaction") }) ?? wb.sheets.first else {
            return TransactionImportResult(state: currentState, importedTransactions: 0, sheetName: "", previewRows: [])
        }
        let (keys, rows) = objectRows(sheet.rows)
        if rows.isEmpty {
            return TransactionImportResult(state: currentState, importedTransactions: 0, sheetName: sheet.name, previewRows: [])
        }

        var nextTransactions = currentState.transactions
        let modeCats = currentState.categories.filter { $0.mode == targetMode }
        let defaultExpense = modeCats.first { $0.kind == .expense } ?? modeCats.first
        let defaultIncome = modeCats.first { $0.kind == .income } ?? modeCats.first
        var preview: [TransactionImportPreviewRow] = []
        var count = 0
        let lowerKeys = keys.map { ($0, $0.lowercased()) }

        for (i, r) in rows.enumerated() {
            func findVal(_ candidates: [String]) -> String {
                for cand in candidates {
                    if let k = lowerKeys.first(where: { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) == cand })?.0,
                       let v = r[k], !v.isEmpty {
                        return v.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                for cand in candidates {
                    if let k = lowerKeys.first(where: { $0.1.contains(cand) })?.0, let v = r[k], !v.isEmpty {
                        return v.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ""
            }

            let rawAmt = findVal(["amount", "total", "value", "sum", "betrag", "chf", "eur"])
            guard let rawNum = DataIOJS.parseStripped(rawAmt), !rawNum.isNaN, abs(rawNum) >= 0.001 else { continue }

            let rawDate = findVal(["date", "datum", "booking date", "valuta"])
            var isoDate = "\(fallbackMonthKey)-08"
            if rawDate.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                isoDate = String(rawDate.prefix(10))
            } else if rawDate.range(of: #"^\d{1,2}[./]\d{1,2}[./]\d{4}"#, options: .regularExpression) != nil {
                let parts = rawDate.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "/" }.map(String.init)
                let y = String(parts[2].prefix(4))
                let m = parts[1].count < 2 ? String(repeating: "0", count: 2 - parts[1].count) + parts[1] : parts[1]
                let d = parts[0].count < 2 ? String(repeating: "0", count: 2 - parts[0].count) + parts[0] : parts[0]
                isoDate = "\(y)-\(m)-\(d)"
            }
            let txMonthKey = String(isoDate.prefix(7))

            let descFound = findVal(["description", "payee", "text", "memo", "purpose", "merchant", "details"])
            let rawDesc = descFound.isEmpty ? "Imported Entry" : descFound
            let rawCatName = findVal(["category", "kategorie", "subcategory"])
            let rawType = findVal(["type", "kind", "direction"]).lowercased()
            let rawClient = findVal(["client", "customer", "project"])
            let rawInvoice = findVal(["invoiceref", "invoice", "reference", "ref"])
            let rawVat = DataIOJS.orZero(DataIOJS.parseFloat(findVal(["taxratepct", "vat", "tax", "mwst"])))
            let dedParsed = DataIOJS.orZero(DataIOJS.parseFloat(findVal(["deductiblepct", "deductible"])))
            let rawDed = dedParsed != 0 ? dedParsed : (targetMode == .freelancer ? 100 : 0)

            var matched: CategoryItem? = rawCatName.isEmpty ? nil : currentState.categories.first {
                $0.mode == targetMode && $0.name.lowercased() == rawCatName.lowercased()
            }
            let isIncome = rawType == "income" || matched?.kind == .income
                || (rawType.isEmpty && !(rawNum < 0) && rawDesc.lowercased().contains("invoice"))
            if matched == nil { matched = isIncome ? defaultIncome : defaultExpense }
            guard let cat = matched else { continue }

            let txType: TransactionType = cat.kind == .income || rawType == "income" ? .income : .expense
            let method = findVal(["paymentmethod", "account", "method"])
            let tx = TransactionItem(
                id: "tx-imp-\(now)-\(i)", date: isoDate, monthKey: txMonthKey, mode: targetMode, type: txType,
                categoryId: cat.id, accountId: nil, description: rawDesc, amount: abs(rawNum),
                client: rawClient.isEmpty ? nil : rawClient, invoiceRef: rawInvoice.isEmpty ? nil : rawInvoice,
                taxRate: rawVat, deductiblePct: rawDed, paymentMethod: method.isEmpty ? "Imported" : method,
                status: .cleared, notes: nil, recurringId: nil
            )
            nextTransactions.append(tx)
            preview.append(TransactionImportPreviewRow(id: tx.id, date: tx.date, monthKey: tx.monthKey, type: tx.type,
                                                       categoryName: cat.name, description: tx.description,
                                                       amount: tx.amount, client: tx.client, taxRate: tx.taxRate))
            count += 1
        }

        var state = currentState
        state.transactions = nextTransactions
        return TransactionImportResult(state: state, importedTransactions: count, sheetName: sheet.name, previewRows: preview)
    }
}
