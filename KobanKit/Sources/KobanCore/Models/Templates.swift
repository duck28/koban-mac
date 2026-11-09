import Foundation

// Port of the functions in src/data/templates.ts. The catalog / metadata values are generated
// into TemplatesData.swift.

struct CatalogCategoryOption: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Pre-selected during setup; false = additional category the user can opt into.
    var defaultChecked: Bool
    /// Marked as a recurring monthly item during setup by default.
    var defaultRecurring: Bool
    var taxRate: Double?
    var deductiblePct: Double?
}

struct CatalogGroupDef: Hashable, Sendable, Identifiable {
    var id: String
    var mode: LedgerMode
    var name: String
    var kind: CategoryKind
    var color: String
    var column: Int
    var items: [CatalogCategoryOption]
}

struct AccountTypeMeta: Hashable, Sendable {
    var label: String
    var shortLabel: String
    var defaultClass: AccountLiquidityClass
    var defaultColor: String
    var autoTrackDefault: Bool
}

struct AccountClassMeta: Hashable, Sendable {
    var label: String
    var description: String
    var color: String
}

enum KobanTemplates {
    static func defaultCheckedIds(_ catalog: [CatalogGroupDef]) -> Set<String> {
        Set(catalog.flatMap(\.items).filter(\.defaultChecked).map(\.id))
    }

    static func defaultRecurringIds(_ catalogs: [[CatalogGroupDef]]? = nil) -> Set<String> {
        let all = catalogs ?? [homeCatalog, freelancerCatalog]
        return Set(all.flatMap { $0.flatMap(\.items) }.filter(\.defaultRecurring).map(\.id))
    }

    static func accountType(_ type: AccountType) -> AccountTypeMeta {
        accountTypes[type] ?? AccountTypeMeta(label: type.rawValue, shortLabel: type.rawValue,
                                              defaultClass: .liquid, defaultColor: "#7a746b", autoTrackDefault: false)
    }

    static func accountClass(_ cls: AccountLiquidityClass) -> AccountClassMeta {
        accountClasses[cls] ?? AccountClassMeta(label: cls.rawValue, description: "", color: "#7a746b")
    }

    struct ModeData {
        var groups: [CategoryGroup] = []
        var categories: [CategoryItem] = []
        var monthlyBudgets: [MonthlyBudgetEntry] = []
        var recurringRules: [RecurringRule] = []
    }

    /// Groups, categories, month entries and recurring rules for one catalog (buildModeDataFromCatalog).
    /// `recurringIds` nil = use the catalog's defaultRecurring flags. Custom items use the key
    /// `custom:<groupId>:<name>` in `recurringIds`.
    static func buildModeData(catalog: [CatalogGroupDef], selected: Set<String>,
                              customItemsByGroup: [String: [String]], monthKey: String,
                              recurringIds: Set<String>?) -> ModeData {
        var data = ModeData()
        let now = Int(Date().timeIntervalSince1970 * 1000)

        func rule(id: String, group: CatalogGroupDef, categoryId: String, name: String,
                  taxRate: Double, deductible: Double) -> RecurringRule {
            RecurringRule(id: id, mode: group.mode, type: group.kind == .income ? .income : .expense,
                          categoryId: categoryId, description: name, amount: 0, frequency: .monthly,
                          dayOfMonth: group.kind == .income ? 25 : 1, taxRate: taxRate,
                          deductiblePct: deductible, active: true)
        }

        for (gIdx, cg) in catalog.enumerated() {
            data.groups.append(CategoryGroup(id: cg.id, mode: cg.mode, name: cg.name, kind: cg.kind,
                                             color: cg.color, column: cg.column, order: gIdx))
            var order = 0
            for item in cg.items where selected.contains(item.id) {
                let isRec = recurringIds.map { $0.contains(item.id) } ?? item.defaultRecurring
                let tax = item.taxRate ?? 0
                let ded = item.deductiblePct ?? (cg.mode == .freelancer ? 100 : 0)
                data.categories.append(CategoryItem(id: item.id, groupId: cg.id, mode: cg.mode, name: item.name,
                                                    kind: cg.kind, defaultBudget: 0, isRecurring: isRec,
                                                    taxRate: tax, deductiblePct: ded, order: order))
                order += 1
                data.monthlyBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: item.id, budget: 0))
                if isRec {
                    data.recurringRules.append(rule(id: "rec-init-\(item.id)", group: cg, categoryId: item.id,
                                                    name: item.name, taxRate: tax, deductible: ded))
                }
            }
            for name in customItemsByGroup[cg.id] ?? [] {
                let isRec = recurringIds?.contains("custom:\(cg.id):\(name)") ?? false
                let id = "\(cg.id)-custom-\(order)-\(now)"
                let tax: Double = cg.mode == .freelancer ? 8.1 : 0
                let ded: Double = cg.mode == .freelancer ? 100 : 0
                data.categories.append(CategoryItem(id: id, groupId: cg.id, mode: cg.mode, name: name, kind: cg.kind,
                                                    defaultBudget: 0, isRecurring: isRec, taxRate: tax,
                                                    deductiblePct: ded, order: order))
                order += 1
                data.monthlyBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: id, budget: 0))
                if isRec {
                    data.recurringRules.append(rule(id: "rec-init-\(id)", group: cg, categoryId: id, name: name,
                                                    taxRate: tax, deductible: ded))
                }
            }
        }
        return data
    }

    static func defaultReturnRate(type: AccountType, classification: AccountLiquidityClass,
                                  expected: Double?) -> Double {
        if let expected { return expected }
        switch type {
        case .brokerage: return 7.5
        case .crypto: return 10
        case .retirement: return 5.5
        case .realEstate: return 3.5
        case .savings: return 1.5
        case .taxReserve: return 1
        default:
            switch classification {
            case .investment: return 7
            case .retirement: return 5.5
            case .fixedAsset: return 3
            default: return 0
            }
        }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func defaultOnboardingAccounts(setupMode: ProfileSetupMode = .both) -> [FinancialAccount] {
        let today = today()
        func acc(_ id: String, _ name: String, _ inst: String, _ mode: LedgerMode, _ type: AccountType,
                 _ cls: AccountLiquidityClass, auto: Bool, ret: Double, color: String) -> FinancialAccount {
            FinancialAccount(id: id, name: name, institution: inst, mode: mode, type: type, classification: cls,
                             startingBalance: 0, currentBalance: 0, autoTrackTransactions: auto,
                             includeInNetWorth: true, expectedAnnualReturnPct: ret, color: color, updatedAt: today)
        }
        var list: [FinancialAccount] = []
        if setupMode == .home || setupMode == .both {
            list += [
                acc("acc-home-checking-main", "Main Checking Account", "Primary Bank", .home, .checking, .liquid,
                    auto: true, ret: 0, color: "#3f704d"),
                acc("acc-home-savings-reserve", "Savings & Emergency Account", "Savings Bank", .home, .savings, .liquid,
                    auto: true, ret: 1.5, color: "#5b7f4a"),
                acc("acc-home-retirement-3a", "Private Retirement (Pillar 3a / IRA)", "Retirement Foundation", .home,
                    .retirement, .retirement, auto: false, ret: 5.5, color: "#8a6fb0"),
                acc("acc-home-retirement-pension", "Pension Fund (Pillar 2 / Occupational)", "Pension Fund", .home,
                    .retirement, .retirement, auto: false, ret: 4.5, color: "#8a6fb0"),
                acc("acc-home-brokerage", "Investment / ETF Portfolio", "Brokerage", .home, .brokerage, .investment,
                    auto: false, ret: 7.5, color: "#3f6e8c"),
            ]
        }
        if setupMode == .freelancer || setupMode == .both {
            list += [
                acc("acc-biz-checking", "Business Operating Bank Account", "Business Bank", .freelancer, .businessBank,
                    .liquid, auto: true, ret: 0, color: "#3f6e8c"),
                acc("acc-biz-tax-reserve", "Tax & VAT Reserve Sub-Account", "Business Bank", .freelancer, .taxReserve,
                    .liquid, auto: true, ret: 1, color: "#4c7a7b"),
            ]
        }
        return list
    }

    /// createInitialLedgerState: both catalogs (selected or default-checked items), default
    /// savings goals and onboarding accounts.
    static func initialLedgerState(setupMode: ProfileSetupMode = .both, currency: String = "CHF",
                                   backupDir: String = "", setupCompleted: Bool = false,
                                   selectedHomeIds: Set<String>? = nil, selectedFreelancerIds: Set<String>? = nil,
                                   customItemsByGroup: [String: [String]] = [:],
                                   initialAccounts: [FinancialAccount]? = nil,
                                   initialNetWorthSnapshots: [NetWorthSnapshot]? = nil,
                                   recurringIds: Set<String>? = nil,
                                   now: Date = Date(), calendar: Calendar = .current) -> LedgerState {
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let monthKey = MonthKey.format(year: year, month: month)

        let home = buildModeData(catalog: homeCatalog, selected: selectedHomeIds ?? defaultCheckedIds(homeCatalog),
                                 customItemsByGroup: customItemsByGroup, monthKey: monthKey, recurringIds: recurringIds)
        let free = buildModeData(catalog: freelancerCatalog,
                                 selected: selectedFreelancerIds ?? defaultCheckedIds(freelancerCatalog),
                                 customItemsByGroup: customItemsByGroup, monthKey: monthKey, recurringIds: recurringIds)

        var state = LedgerState.empty(setupMode: setupMode, currency: currency, now: now, calendar: calendar)
        state.settings.setupCompleted = setupCompleted
        state.settings.backupDir = backupDir
        state.settings.autoBackup = !backupDir.isEmpty
        state.groups = home.groups + free.groups
        state.categories = home.categories + free.categories
        state.monthlyBudgets = home.monthlyBudgets + free.monthlyBudgets
        state.recurringRules = home.recurringRules + free.recurringRules
        state.savingsGoals = [
            SavingsGoal(id: "goal-home-emergency", mode: .home, name: "Emergency Reserve", targetAmount: 15000,
                        currentAmount: 0, monthlyContribution: 500, targetDate: "\(year + 1)-12-31", color: "#3f704d"),
            SavingsGoal(id: "goal-biz-tax", mode: .freelancer, name: "Annual Tax & VAT Provision", targetAmount: 12000,
                        currentAmount: 0, monthlyContribution: 1000, targetDate: "\(year + 1)-03-31", color: "#3f6e8c"),
        ]
        state.accounts = initialAccounts ?? defaultOnboardingAccounts(setupMode: setupMode)
        state.netWorthSnapshots = initialNetWorthSnapshots ?? []
        return state
    }
}
