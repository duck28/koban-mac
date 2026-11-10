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
}

struct MonthlyBudgetEntry: Codable, Hashable, Sendable {
    /// "YYYY-MM"
    var monthKey: String
    var categoryId: String
    var budget: Double
    /// Direct Actual override from the Monthly Worksheet.
    /// When nil, Actual = sum of transactions for that category & month.
    var directActual: Double?
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
    var webdav: WebDavConfig?
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
}

// Lenient decoding: older vaults may lack newer collections (the Rust backend
// and the React app both treat missing arrays as empty).
// Declared in an extension so the memberwise initializer is kept.
extension LedgerState {
    enum CodingKeys: String, CodingKey {
        case version, settings, groups, categories, monthlyBudgets, transactions,
             recurringRules, savingsGoals, accounts, netWorthSnapshots, yearlyPlanItems
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
            confirmAndPreviewBeforeImport: true
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

enum MonthKey {
    static func format(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    static let shortMonthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
