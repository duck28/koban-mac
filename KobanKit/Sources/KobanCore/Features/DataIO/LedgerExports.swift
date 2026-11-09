import Foundation

// Port of the export half of src/utils/exportImport.ts.

enum LedgerExports {
    private static func f2(_ v: Double) -> SheetCell { .number(DataIOJS.fixed2(v)) }

    /// Stable newest-first sort (`b.date.localeCompare(a.date)`).
    static func sortedTransactions(_ state: LedgerState, workspace: ActiveWorkspace) -> [TransactionItem] {
        state.transactions
            .filter { workspace.includes($0.mode) }
            .enumerated()
            .sorted { a, b in
                let cmp = b.element.date.compare(a.element.date)
                return cmp == .orderedSame ? a.offset < b.offset : cmp == .orderedAscending
            }
            .map(\.element)
    }

    /// buildMonthlyBudgetMatrix: the 2-column side-by-side Monthly Budget matrix.
    static func monthlyBudgetMatrix(_ state: LedgerState, monthKey: String, workspace: ActiveWorkspace) -> [[SheetCell]] {
        let summary = state.monthSummary(monthKey: monthKey, workspace: workspace)
        let leftGroups = summary.groups.filter { $0.group.column == 0 }
        let rightGroups = summary.groups.filter { $0.group.column == 1 }

        func block(_ gs: GroupComputedSummary) -> [[SheetCell]] {
            var out: [[SheetCell]] = [[.string(gs.group.name), "Budget", "Actual", "Difference"]]
            for r in gs.rows {
                out.append([.string(r.category.name), f2(r.budget), f2(r.actual), f2(r.difference)])
            }
            out.append([.string("Total \(gs.group.name)"), f2(gs.totalBudget), f2(gs.totalActual), f2(gs.totalDifference)])
            out.append(["", "", "", ""])
            return out
        }

        var left: [[SheetCell]] = []
        for g in leftGroups { left += block(g) }

        var right: [[SheetCell]] = [
            ["BUDGET SUMMARY", "Budget", "Actual", "Difference"],
            ["Total Income", f2(summary.incomeBudget), f2(summary.incomeActual), f2(summary.incomeDifference)],
            ["Total Expenses", f2(summary.totalOutflowBudget), f2(summary.totalOutflowActual), f2(summary.totalOutflowDifference)],
            ["NET", f2(summary.netBudget), f2(summary.netActual), f2(summary.netDifference)],
            ["", "", "", ""],
        ]
        for g in rightGroups { right += block(g) }

        let title: String
        switch workspace {
        case .freelancer: title = "Freelancer & Business"
        case .combined: title = "Combined Home & Business"
        case .home: title = "Personal Monthly"
        }
        var matrix: [[SheetCell]] = [
            [.string("Koban — \(title) Budget (\(monthKey))"), "", "", "", "", .string("Currency: \(state.settings.currency)"), "", "", ""],
            ["", "", "", "", "", "", "", "", ""],
        ]
        let blank: [SheetCell] = ["", "", "", ""]
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : blank
            let r = i < right.count ? right[i] : blank
            matrix.append([l[0], l[1], l[2], l[3], "", r[0], r[1], r[2], r[3]])
        }
        return matrix
    }

    /// exportExcelWorkbook: the five-sheet workbook.
    static func workbook(_ state: LedgerState, monthKey: String, workspace: ActiveWorkspace) -> WorkbookData {
        var sheets: [SheetData] = []

        // 1. 2-Column Monthly Budget Sheet
        sheets.append(SheetData(name: "Budget \(monthKey)",
                                rows: monthlyBudgetMatrix(state, monthKey: monthKey, workspace: workspace),
                                columnWidths: [30, 13, 13, 13, 4, 30, 13, 13, 13]))

        // 2. Flat Category Breakdown Sheet
        let summary = state.monthSummary(monthKey: monthKey, workspace: workspace)
        var flat: [[SheetCell]] = [[
            "Mode", "Group", "Category", "Kind", "Budget", "Actual", "Difference",
            "Transactions Count", "Tax / VAT %", "Deductible %", "Deductible Amount",
        ]]
        for gs in summary.groups {
            for r in gs.rows {
                flat.append([
                    .string(r.category.mode.rawValue), .string(gs.group.name), .string(r.category.name),
                    .string(gs.group.kind.rawValue), f2(r.budget), f2(r.actual), f2(r.difference),
                    .number(Double(r.txCount)), .number(r.category.taxRate ?? 0), .number(r.category.deductiblePct ?? 0),
                    f2(r.deductibleActual),
                ])
            }
        }
        sheets.append(SheetData(name: "Category Breakdown", rows: flat,
                                columnWidths: [12, 24, 28, 10, 12, 12, 12, 16, 12, 14, 16]))

        // 3. 12-Month Annual Cashflow Sheet
        let year = state.settings.activeYear
        var annual: [[SheetCell]] = [[
            "Month", "Month Key", "Income (Budget)", "Income (Actual)", "Total Outflow (Budget)",
            "Total Outflow (Actual)", "NET (Budget)", "NET (Actual)",
        ]]
        for pt in state.annualSeries(year: year, workspace: workspace) {
            annual.append([
                .string(pt.monthLabel), .string(pt.monthKey), f2(pt.incomeBudget), f2(pt.incomeActual),
                f2(pt.outflowBudget), f2(pt.outflowActual), f2(pt.netBudget), f2(pt.netActual),
            ])
        }
        sheets.append(SheetData(name: "Annual \(year)", rows: annual, columnWidths: [10, 12, 16, 16, 20, 20, 15, 15]))

        // 4. Transactions Ledger Sheet
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grpMap = Dictionary(state.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var txRows: [[SheetCell]] = [[
            "Date", "Month", "Mode", "Type", "Group", "Category", "Description", "Amount",
            "Client / Project", "Invoice / Ref", "VAT %", "Deductible %", "Payment Method", "Status",
        ]]
        for tx in sortedTransactions(state, workspace: workspace) {
            let cat = catMap[tx.categoryId]
            let grp = cat.flatMap { grpMap[$0.groupId] }
            txRows.append([
                .string(tx.date), .string(tx.monthKey), .string(tx.mode.rawValue), .string(tx.type.rawValue),
                .string(grp?.name ?? ""), .string(cat?.name ?? ""), .string(tx.description), f2(tx.amount),
                .string(tx.client ?? ""), .string(tx.invoiceRef ?? ""), .number(tx.taxRate ?? 0),
                .number(tx.deductiblePct ?? 0), .string(tx.paymentMethod ?? ""),
                .string((tx.status ?? .cleared).rawValue),
            ])
        }
        sheets.append(SheetData(name: "Transactions", rows: txRows,
                                columnWidths: [12, 10, 12, 10, 22, 26, 28, 12, 22, 16, 10, 12, 16, 12]))

        // 5. Accounts & Net Worth Sheet
        let nw = state.netWorthMetrics(workspace: workspace, monthlyOutflowReference: summary.totalOutflowActual)
        let cur = SheetCell.string(state.settings.currency)
        var nwRows: [[SheetCell]] = [
            ["NET WORTH SUMMARY", "Amount", "Currency"],
            ["Liquid Assets (Bank & Cash)", f2(nw.liquidAssets), cur],
            ["Retirement & Pension Accounts", f2(nw.retirementAssets), cur],
            ["Investments & Market Portfolio", f2(nw.investmentAssets), cur],
            ["Fixed & Real Estate Assets", f2(nw.fixedAssets), cur],
            ["Total Assets", f2(nw.totalAssets), cur],
            ["Total Liabilities & Debt", f2(nw.totalLiabilities), cur],
            ["TOTAL NET WORTH", f2(nw.netWorth), cur],
            [],
            [
                "Account Name", "Institution", "Mode", "Type", "Classification", "Opening Balance",
                "Live Balance", "Auto-Track Transactions", "Included in Net Worth",
            ],
        ]
        for item in nw.accounts {
            let a = item.account
            let typeLabel = (a.customTypeLabel?.isEmpty == false) ? a.customTypeLabel! : a.type.rawValue
            nwRows.append([
                .string(a.name), .string(a.institution ?? ""), .string(a.mode.rawValue), .string(typeLabel),
                .string(a.classification.rawValue), f2(a.startingBalance), f2(item.liveBalance),
                .string(a.autoTrackTransactions ? "Yes" : "No"), .string(a.includeInNetWorth ? "Yes" : "No"),
            ])
        }
        sheets.append(SheetData(name: "Accounts & Net Worth", rows: nwRows,
                                columnWidths: [28, 22, 12, 22, 16, 16, 16, 22, 20]))

        return WorkbookData(sheets: sheets)
    }

    /// exportTransactionsCsv rows ("Transactions & Tax CSV").
    static func transactionsCSVRows(_ state: LedgerState, workspace: ActiveWorkspace) -> [[SheetCell]] {
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let grpMap = Dictionary(state.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [[SheetCell]] = [[
            "Date", "Month", "Mode", "Type", "Group", "Category", "Description", "Amount", "Currency",
            "Client", "InvoiceRef", "TaxRatePct", "DeductiblePct", "DeductibleAmount", "PaymentMethod", "Status",
        ]]
        for tx in sortedTransactions(state, workspace: workspace) {
            let cat = catMap[tx.categoryId]
            let grp = cat.flatMap { grpMap[$0.groupId] }
            let dedPct = tx.deductiblePct ?? 0
            let dedAmt = tx.type == .expense ? tx.amount * (dedPct / 100) : 0
            rows.append([
                .string(tx.date), .string(tx.monthKey), .string(tx.mode.rawValue), .string(tx.type.rawValue),
                .string(grp?.name ?? ""), .string(cat?.name ?? ""), .string(tx.description), f2(tx.amount),
                .string(state.settings.currency), .string(tx.client ?? ""), .string(tx.invoiceRef ?? ""),
                .number(tx.taxRate ?? 0), .number(dedPct), f2(dedAmt), .string(tx.paymentMethod ?? ""),
                .string((tx.status ?? .cleared).rawValue),
            ])
        }
        return rows
    }

    static func monthlyBudgetCSV(_ state: LedgerState, monthKey: String, workspace: ActiveWorkspace) -> Data {
        SheetCSV.dataWithBOM(SheetCSV.write(monthlyBudgetMatrix(state, monthKey: monthKey, workspace: workspace)))
    }

    static func transactionsCSV(_ state: LedgerState, workspace: ActiveWorkspace) -> Data {
        SheetCSV.dataWithBOM(SheetCSV.write(transactionsCSVRows(state, workspace: workspace)))
    }

    // Default file names used by the save dialogs.
    static func excelFileName(workspace: ActiveWorkspace, monthKey: String) -> String {
        "Koban-\(workspace.rawValue)-\(monthKey).xlsx"
    }
    static func budgetCSVFileName(workspace: ActiveWorkspace, monthKey: String) -> String {
        "Koban-BudgetSheet-\(workspace.rawValue)-\(monthKey).csv"
    }
    static func transactionsCSVFileName(workspace: ActiveWorkspace, year: Int) -> String {
        "Koban-Transactions-\(workspace.rawValue)-\(year).csv"
    }
}
