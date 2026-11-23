import Foundation

// Swift mirror of src/types/index.ts.
// Property names match the JSON keys written by the Windows (Tauri/React) build,
// so Codable synthesis maps them 1:1. Optional TS fields (`foo?: T`) are Swift optionals.
//
// NOTE: fields unknown to this file are dropped on re-save. When the Windows build adds a
// field to LedgerState, add it here too, or the macOS build will strip it from shared vaults.

struct FinancialAccount: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var institution: String?
    var accountNumberMasked: String?
    var mode: LedgerMode
    var type: AccountType
    /// Used when `type == .custom` (e.g. "Precious Metals", "Pillar 3a").
    var customTypeLabel: String?
    var classification: AccountLiquidityClass
    /// Opening / baseline balance.
    var startingBalance: Double
    /// Current manual balance or market valuation.
    var currentBalance: Double
    /// If true, live balance = startingBalance + linked income - linked expenses.
    var autoTrackTransactions: Bool
    var includeInNetWorth: Bool
    /// Expected annual return / interest rate in percent.
    var expectedAnnualReturnPct: Double?
    var color: String
    var notes: String?
    /// YYYY-MM-DD
    var updatedAt: String
}

struct NetWorthSnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// YYYY-MM
    var monthKey: String
    /// YYYY-MM-DD
    var recordedAt: String
    var liquidAssets: Double
    var retirementAssets: Double
    var investmentAssets: Double
    var fixedAssets: Double
    var totalAssets: Double
    var totalLiabilities: Double
    var netWorth: Double
    var note: String?
}

struct CategoryGroup: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var mode: LedgerMode
    var name: String
    var kind: CategoryKind
    var color: String
    /// 0 = left column, 1 = right column
    var column: Int
    var order: Int
}

struct CategoryItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var groupId: String
    var mode: LedgerMode
    var name: String
    var kind: CategoryKind
    var defaultBudget: Double
    var isRecurring: Bool?
    /// Default VAT / sales tax % for freelancer items (e.g. 8.1, 19, 0).
    var taxRate: Double?
    /// Tax-deductible % for freelancer expenses (e.g. 100, 50, 0).
    var deductiblePct: Double?
    var order: Int
    /// Fixed cost (anchor toggle): the month's Actual automatically equals its Budget unless an
    /// Actual is typed or transactions are logged. Independent of `isRecurring`.
    var isFixedCost: Bool? = nil
    /// Savings categories: account the money moves into. Savings transactions then count as a
    /// transfer (out of their source account, into this one), so net worth does not drop.
    var targetAccountId: String? = nil
}

struct MonthlyBudgetEntry: Codable, Hashable, Sendable {
    /// "YYYY-MM"
    var monthKey: String
    var categoryId: String
    var budget: Double
    /// Direct Actual override from the Monthly Worksheet.
    /// When nil, Actual = sum of transactions for that category & month.
    var directActual: Double?
    /// True when the user typed this month's Budget for a category whose budget is otherwise
    /// derived from a scheduled recurring rule (bi-weekly / bi-monthly / quarterly / yearly).
    var budgetManual: Bool? = nil
}

struct TransactionItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// YYYY-MM-DD
    var date: String
    /// YYYY-MM
    var monthKey: String
    var mode: LedgerMode
    var type: TransactionType
    var categoryId: String
    var accountId: String?
    var description: String
    var amount: Double
    // Freelancer / business fields
    var client: String?
    var invoiceRef: String?
    var taxRate: Double?
    var deductiblePct: Double?
    var paymentMethod: String?
    var status: TransactionStatus?
    var notes: String?
    var recurringId: String?
    var externalId: String? = nil
    var importFingerprint: String? = nil
    var rawDescription: String? = nil
    var transferPeerId: String? = nil
}

enum BankDateFormat: String, Codable, CaseIterable, Sendable {
    case auto
    case iso = "YYYY-MM-DD"
    case chDot = "DD.MM.YYYY"
    case euSlash = "DD/MM/YYYY"
    case usSlash = "MM/DD/YYYY"
    case compact = "YYYYMMDD"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BankDateFormat(rawValue: raw) ?? .auto
    }
}

enum BankAmountMode: String, Codable, CaseIterable, Sendable {
    case signed
    case splitDebitCredit = "split_debit_credit"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BankAmountMode(rawValue: raw) ?? .signed
    }
}

enum BankDecimalSeparator: String, Codable, CaseIterable, Sendable {
    case auto
    case dot = "."
    case comma = ","

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BankDecimalSeparator(rawValue: raw) ?? .auto
    }
}

struct BankImportProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var accountId: String?
    var defaultMode: LedgerMode?
    var headerFingerprint: [String]
    var delimiter: String?
    var dateColumn: String
    var dateFormat: BankDateFormat
    var amountMode: BankAmountMode
    var amountColumn: String?
    var debitColumn: String?
    var creditColumn: String?
    var invertSign: Bool
    var decimalSeparator: BankDecimalSeparator
    var descriptionColumns: [String]
    var payeeColumn: String?
    var referenceColumn: String?
    var currencyColumn: String?
    var skipRows: Int?
    var updatedAt: String
}

enum ImportRuleDirection: String, Codable, CaseIterable, Sendable {
    case any, income, expense

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImportRuleDirection(rawValue: raw) ?? .any
    }
}

enum ImportRuleMatchField: String, Codable, CaseIterable, Sendable {
    case any, payee, description, iban

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImportRuleMatchField(rawValue: raw) ?? .any
    }
}

enum ImportRuleMatchType: String, Codable, CaseIterable, Sendable {
    case contains
    case startsWith = "starts_with"
    case exact
    case regex

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImportRuleMatchType(rawValue: raw) ?? .contains
    }
}

struct ImportRule: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
    var priority: Int
    var accountId: String?
    var direction: ImportRuleDirection?
    var matchField: ImportRuleMatchField
    var matchType: ImportRuleMatchType
    var pattern: String
    var minAmount: Double?
    var maxAmount: Double?
    var setCategoryId: String
    var setMode: LedgerMode?
    var setPayee: String?
    var setClient: String?
    var setTaxRate: Double?
    var setDeductiblePct: Double?
    var markAsTransfer: Bool?
    var createdAt: String
    var updatedAt: String
}

struct PendingImportFile: Identifiable, Hashable, Sendable {
    var name: String
    var url: URL
    var size: Int64
    var modified: Date
    var extensionName: String
    var id: String { url.path }
    var path: String { url.path }
}

struct RecurringRule: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var mode: LedgerMode
    var type: TransactionType
    var categoryId: String
    var accountId: String?
    var description: String
    var amount: Double
    var frequency: RecurrenceFrequency
    var dayOfMonth: Int
    var client: String?
    var taxRate: Double?
    var deductiblePct: Double?
    var active: Bool
    /// Bi-weekly only: date (YYYY-MM-DD) of the first occurrence; every further one is 14 days
    /// later. Picked as a start week + weekday. Absent on legacy rules ⇒ dayOfMonth & dayOfMonth±14.
    var startDate: String? = nil
    /// Bi-monthly / quarterly / yearly: first month (YYYY-MM) the item is due.
    var startMonth: String? = nil
}

struct SavingsGoal: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var mode: LedgerMode
    var name: String
    var targetAmount: Double
    var currentAmount: Double
    var monthlyContribution: Double
    var targetDate: String?
    var color: String
    var linkedCategoryId: String?
    var linkedAccountId: String?
}

struct WebDavConfig: Codable, Hashable, Sendable {
    var enabled: Bool
    var url: String
    var username: String
    var password: String?
    var remoteFileName: String?
    var autoSync: Bool?
    var lastSyncAt: Double?
    var lastSyncStatus: WebDavSyncStatus?
    var lastSyncMessage: String?
    /// Absent ⇒ backup (WEBDAV-SPEC §1).
    var mode: WebDavMode?

    var effectiveMode: WebDavMode { mode ?? .backup }
}

extension AppSettings {
    /// The backup folder if it is usable on this Mac. `backupDir` is synced inside the ledger, so a
    /// vault shared with Windows can carry a path like `C:\\Users\\…`; that is treated as "not set here".
    var localBackupDir: String {
        let dir = backupDir.trimmingCharacters(in: .whitespaces)
        return dir.hasPrefix("/") || dir.hasPrefix("~") ? (dir as NSString).expandingTildeInPath : ""
    }

    /// True when a backup folder is set but belongs to another platform (e.g. a Windows path).
    var backupDirIsForeign: Bool { !backupDir.trimmingCharacters(in: .whitespaces).isEmpty && localBackupDir.isEmpty }
}

struct AppSettings: Codable, Hashable, Sendable {
    var setupCompleted: Bool
    var setupMode: ProfileSetupMode
    var activeWorkspace: ActiveWorkspace
    var currency: String
    var theme: ThemePreference
    var themePalette: ThemePalette?
    var density: UiDensity?
    var highContrastAmounts: Bool?
    var backupDir: String
    var autoBackup: Bool
    var maxBackups: Int
    /// Milliseconds since epoch (JS `Date.now()`).
    var lastBackupAt: Double?
    var lastBackupPath: String?
    var defaultVatRate: Double
    var taxReserveRate: Double
    var activeYear: Int
    /// 1...12
    var activeMonth: Int
    // Behavioral settings
    var confirmBeforeMonthCopy: Bool?
    var monthCopyScope: MonthCopyScope?
    var monthCopyOverwriteExisting: Bool?
    var autoPromptCopyOnEmptyMonth: Bool?
    var confirmBeforeDelete: Bool?
    var defaultHideZeroRows: Bool?
    var confirmAndPreviewBeforeImport: Bool?
    /// UI language code (e.g. "en", "de", "hu", "ja").
    var language: String?
    /// Automatically check GitHub Releases for app updates on startup.
    var autoCheckUpdates: Bool?
    var ownerDisplayName: String? = nil
    var webdav: WebDavConfig?
    /// Fixed-cost categories: Actual automatically equals Budget until transactions are logged
    /// or an Actual is typed. Absent ⇒ true.
    var autoFillFixedActuals: Bool? = nil
}

struct YearlyPlanItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var year: Int
    var mode: LedgerMode
    var categoryId: String
    var label: String
    var kind: CategoryKind
    /// Total planned amount for the full year.
    var annualAmount: Double
    var schedule: YearlyPlanSchedule
    var accountId: String?
    var destinationAccountId: String?
}

struct LedgerState: Codable, Hashable, Sendable {
    var version: Int
    var settings: AppSettings
    var groups: [CategoryGroup]
    var categories: [CategoryItem]
    var monthlyBudgets: [MonthlyBudgetEntry]
    var transactions: [TransactionItem]
    var recurringRules: [RecurringRule]
    var savingsGoals: [SavingsGoal]
    var accounts: [FinancialAccount]
    var netWorthSnapshots: [NetWorthSnapshot]
    var yearlyPlanItems: [YearlyPlanItem]?
    var importProfiles: [BankImportProfile]? = nil
    var importRules: [ImportRule]? = nil
}

// Lenient decoding: older vaults may lack newer collections (the Rust backend
// and the React app both treat missing arrays as empty).
// Declared in an extension so the memberwise initializer is kept.
extension LedgerState {
    enum CodingKeys: String, CodingKey {
        case version, settings, groups, categories, monthlyBudgets, transactions,
             recurringRules, savingsGoals, accounts, netWorthSnapshots, yearlyPlanItems,
             importProfiles, importRules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        var decodedSettings = try c.decode(AppSettings.self, forKey: .settings)
        // Out-of-range values from an imported/synced ledger are used as array indexes
        // (e.g. MonthNames.long[activeMonth - 1]) and would crash the app on every launch.
        decodedSettings.activeMonth = min(12, max(1, decodedSettings.activeMonth))
        decodedSettings.activeYear = min(9999, max(1900, decodedSettings.activeYear))
        settings = decodedSettings
        groups = try c.decodeIfPresent([CategoryGroup].self, forKey: .groups) ?? []
        categories = try c.decodeIfPresent([CategoryItem].self, forKey: .categories) ?? []
        monthlyBudgets = try c.decodeIfPresent([MonthlyBudgetEntry].self, forKey: .monthlyBudgets) ?? []
        transactions = try c.decodeIfPresent([TransactionItem].self, forKey: .transactions) ?? []
        recurringRules = try c.decodeIfPresent([RecurringRule].self, forKey: .recurringRules) ?? []
        savingsGoals = try c.decodeIfPresent([SavingsGoal].self, forKey: .savingsGoals) ?? []
        accounts = try c.decodeIfPresent([FinancialAccount].self, forKey: .accounts) ?? []
        netWorthSnapshots = try c.decodeIfPresent([NetWorthSnapshot].self, forKey: .netWorthSnapshots) ?? []
        yearlyPlanItems = try c.decodeIfPresent([YearlyPlanItem].self, forKey: .yearlyPlanItems)
        importProfiles = try c.decodeIfPresent([BankImportProfile].self, forKey: .importProfiles)
        importRules = try c.decodeIfPresent([ImportRule].self, forKey: .importRules)
    }
}

// MARK: - Construction & mutation helpers

extension LedgerState {
    /// A fresh, empty ledger with the same settings defaults as
    /// `createInitialLedgerState` in src/data/templates.ts.
    ///
    /// The onboarding uses KobanTemplates.initialLedgerState (catalog-seeded) instead.
    static func empty(
        setupMode: ProfileSetupMode = .both,
        currency: String = "CHF",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LedgerState {
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let settings = AppSettings(
            setupCompleted: true,
            setupMode: setupMode,
            activeWorkspace: setupMode == .freelancer ? .freelancer : .home,
            currency: currency,
            theme: .system,
            themePalette: .zen,
            density: .comfortable,
            highContrastAmounts: false,
            backupDir: "",
            autoBackup: false,
            maxBackups: 20,
            defaultVatRate: 8.1,
            taxReserveRate: 25,
            activeYear: year,
            activeMonth: month,
            confirmBeforeMonthCopy: true,
            monthCopyScope: .budgetsAndActuals,
            monthCopyOverwriteExisting: true,
            autoPromptCopyOnEmptyMonth: true,
            confirmBeforeDelete: true,
            defaultHideZeroRows: false,
            confirmAndPreviewBeforeImport: true,
            autoCheckUpdates: true,
            autoFillFixedActuals: true
        )
        return LedgerState(
            version: 1,
            settings: settings,
            groups: [],
            categories: [],
            monthlyBudgets: [],
            transactions: [],
            recurringRules: [],
            savingsGoals: [],
            accounts: [],
            netWorthSnapshots: []
        )
    }

    var activeMonthKey: String {
        MonthKey.format(year: settings.activeYear, month: settings.activeMonth)
    }

    /// Moves the active month by `delta` months, rolling the year as needed.
    mutating func shiftActiveMonth(by delta: Int) {
        let zeroBased = settings.activeYear * 12 + (settings.activeMonth - 1) + delta
        settings.activeYear = zeroBased / 12
        settings.activeMonth = zeroBased % 12 + 1
    }

    /// Sets the planned budget of a category for one month (creating the entry if needed).
    /// Like handleUpdateBudget in App.tsx, it also becomes the category's default budget and
    /// updates linked recurring rules that still carried the old default (or 0).
    mutating func setBudget(_ amount: Double, categoryId: String, monthKey: String) {
        // Budgets driven by a scheduled recurring rule vary per month: a typed value only
        // overrides this month (budgetManual), like handleUpdateBudget on Windows.
        if recurringRules.contains(where: { $0.active && $0.categoryId == categoryId && $0.isScheduled }) {
            if let idx = monthlyBudgets.firstIndex(where: { $0.monthKey == monthKey && $0.categoryId == categoryId }) {
                monthlyBudgets[idx].budget = amount
                monthlyBudgets[idx].budgetManual = true
            } else {
                monthlyBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: categoryId, budget: amount,
                                                         directActual: nil, budgetManual: true))
            }
            return
        }
        let oldDefault = categories.first(where: { $0.id == categoryId })?.defaultBudget ?? 0
        if let idx = monthlyBudgets.firstIndex(where: { $0.monthKey == monthKey && $0.categoryId == categoryId }) {
            monthlyBudgets[idx].budget = amount
        } else {
            monthlyBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: categoryId, budget: amount))
        }
        if let cIdx = categories.firstIndex(where: { $0.id == categoryId }) {
            categories[cIdx].defaultBudget = amount
        }
        for i in recurringRules.indices where recurringRules[i].categoryId == categoryId
            && (recurringRules[i].amount == 0 || abs(recurringRules[i].amount - oldDefault) < 0.01) {
            recurringRules[i].amount = amount
        }
    }
}

extension LedgerState {
    /// Makes a scheduled category's budget follow the recurring schedule again this month.
    mutating func resetScheduledBudget(categoryId: String, monthKey: String) {
        for i in monthlyBudgets.indices
        where monthlyBudgets[i].monthKey == monthKey && monthlyBudgets[i].categoryId == categoryId {
            monthlyBudgets[i].budgetManual = false
        }
    }
}

enum MonthKey {
    static func format(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// Current calendar month as YYYY-MM (local time) — currentMonthKey() on Windows.
    static func current(_ now: Date = Date(), calendar: Calendar = .current) -> String {
        format(year: calendar.component(.year, from: now), month: calendar.component(.month, from: now))
    }

    static let shortMonthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
