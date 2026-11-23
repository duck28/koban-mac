import Foundation

// Raw values mirror the string unions in src/types/index.ts exactly,
// so the JSON stored in koban.db is interchangeable with the Windows build.

enum ProfileSetupMode: String, Codable, CaseIterable, Sendable {
    case home, freelancer, both
}

enum LedgerMode: String, Codable, CaseIterable, Sendable {
    case home, freelancer
}

enum ActiveWorkspace: String, Codable, CaseIterable, Sendable {
    case home, freelancer, combined

    func includes(_ mode: LedgerMode) -> Bool {
        switch self {
        case .combined: return true
        case .home: return mode == .home
        case .freelancer: return mode == .freelancer
        }
    }
}

enum ViewTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case worksheet
    case yearlyPlanner = "yearly_planner"
    case transactions
    case accounts
    case reports
    case categories
    case recurring
    case goals
    case backups
    case settings

    var id: String { rawValue }
}

enum MonthCopyScope: String, Codable, Sendable {
    case budgetsOnly = "budgets_only"
    case budgetsAndActuals = "budgets_and_actuals"
}

enum AccountType: String, Codable, CaseIterable, Sendable {
    case checking, savings, cash
    case businessBank = "business_bank"
    case taxReserve = "tax_reserve"
    case retirement, brokerage, crypto
    case realEstate = "real_estate"
    case creditCard = "credit_card"
    case loan, custom
}

enum AccountLiquidityClass: String, Codable, CaseIterable, Sendable {
    case liquid, retirement, investment
    case fixedAsset = "fixed_asset"
    case liability
}

enum CategoryKind: String, Codable, CaseIterable, Sendable {
    case income, expense, savings
}

enum TransactionType: String, Codable, CaseIterable, Sendable {
    case income, expense
}

enum TransactionStatus: String, Codable, CaseIterable, Sendable {
    case cleared, pending, invoiced
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Sendable {
    case biweekly, monthly, bimonthly, quarterly, yearly

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecurrenceFrequency(rawValue: raw) ?? .monthly
    }
}

enum ThemePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

enum ThemePalette: String, Codable, CaseIterable, Sendable {
    case zen = "default"
    case monochrome, slate, forest
}

enum UiDensity: String, Codable, CaseIterable, Sendable {
    case comfortable, compact
}

enum WebDavSyncStatus: String, Codable, Sendable {
    case idle, success, error

    /// Tolerates values written by other builds (unknown ⇒ idle) so a shared ledger always decodes.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WebDavSyncStatus(rawValue: raw) ?? .idle
    }
}

/// WebDAV storage mode (WEBDAV-SPEC §1): a backup copy, or the primary (master) copy shared by devices.
enum WebDavMode: String, Codable, Sendable {
    case backup, primary

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WebDavMode(rawValue: raw) ?? .backup
    }
}

enum YearlyPlanSchedule: String, Codable, CaseIterable, Sendable {
    case biweekly
    case monthly
    case bimonthly
    case quarterly
    case annualLump = "annual_lump"

    // Lenient: an unknown value from a newer build must not make the whole vault unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = YearlyPlanSchedule(rawValue: raw) ?? .monthly
    }

    /// Payments per year (annual = per-payment amount × this) — planPeriodsPerYear on Windows.
    var periodsPerYear: Double {
        switch self {
        case .biweekly: return 26
        case .monthly: return 12
        case .bimonthly: return 6
        case .quarterly: return 4
        case .annualLump: return 1
        }
    }

    /// The schedule matching a recurring rule's frequency (planScheduleForFrequency).
    init(frequency: RecurrenceFrequency) {
        switch frequency {
        case .biweekly: self = .biweekly
        case .monthly: self = .monthly
        case .bimonthly: self = .bimonthly
        case .quarterly: self = .quarterly
        case .yearly: self = .annualLump
        }
    }
}
