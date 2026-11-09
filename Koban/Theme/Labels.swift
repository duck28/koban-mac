import Foundation

// UI labels (English, from src/i18n/locales/en.ts).
// Localized through L10n (Features/Settings, generated from src/i18n/locales).

extension ViewTab {
    var title: String {
        switch self {
        case .worksheet: return L10n.t("nav.monthly")
        case .yearlyPlanner: return L10n.t("nav.yearly")
        case .transactions: return L10n.t("nav.transactions")
        case .accounts: return L10n.t("nav.accounts")
        case .reports: return L10n.t("nav.reports")
        case .categories: return L10n.t("nav.categories")
        case .recurring: return L10n.t("nav.recurring")
        case .goals: return L10n.t("nav.savings")
        case .backups: return L10n.t("nav.backups")
        case .settings: return L10n.t("nav.settings")
        }
    }

    /// SF Symbols closest to the lucide icons in Sidebar.tsx.
    var systemImage: String {
        switch self {
        case .worksheet: return "square.grid.2x2"             // LayoutGrid
        case .yearlyPlanner: return "calendar"                // CalendarRange
        case .transactions: return "list.bullet.rectangle.portrait" // ReceiptText
        case .accounts: return "building.columns"             // Landmark
        case .reports: return "chart.pie"                     // PieChart
        case .categories: return "folder"                     // FolderKanban
        case .recurring: return "repeat"                      // Repeat
        case .goals: return "target"                          // Target
        case .backups: return "externaldrive"                 // DatabaseBackup
        case .settings: return "slider.horizontal.3"          // SlidersHorizontal
        }
    }

    /// The <h1> of each Windows view.
    var pageTitle: String {
        switch self {
        case .worksheet: return "Personal Monthly Budget"
        case .yearlyPlanner: return "Yearly Budget & Account Forecast Planner"
        case .transactions: return "Transactions & Multi-Account Ledger"
        case .accounts: return "Accounts & Comprehensive Net Worth Tracker"
        case .reports: return "Financial Reports, Breakdowns & Charts"
        case .categories: return "Categories & Structure"
        case .recurring: return "Recurring Income, Subscriptions & Fixed Costs"
        case .goals: return "Savings Goals, Sinking Funds & Tax Reserves"
        case .backups: return "Encrypted Database, Backups & Data Import / Export"
        case .settings: return "Settings & Behavior"
        }
    }

    /// The React component this view is being ported from.
    var windowsSource: String {
        switch self {
        case .worksheet: return "MonthlyWorksheetView.tsx"
        case .yearlyPlanner: return "YearlyBudgetPlannerView.tsx"
        case .transactions: return "TransactionsView.tsx"
        case .accounts: return "AccountsNetWorthView.tsx"
        case .reports: return "ReportsChartsView.tsx"
        case .categories: return "CategoriesStudioView.tsx"
        case .recurring: return "RecurringView.tsx"
        case .goals: return "SavingsGoalsView.tsx"
        case .backups: return "BackupsExportView.tsx"
        case .settings: return "SettingsView.tsx"
        }
    }
}

extension ActiveWorkspace {
    var title: String {
        switch self {
        case .home: return L10n.t("workspace.home")
        case .freelancer: return L10n.t("workspace.freelancer")
        case .combined: return L10n.t("workspace.combined")
        }
    }

    var help: String {
        switch self {
        case .home: return L10n.t("workspace.home.tip")
        case .freelancer: return L10n.t("workspace.freelancer.tip")
        case .combined: return L10n.t("workspace.combined.tip")
        }
    }
}

extension ProfileSetupMode {
    var title: String {
        switch self {
        case .home: return "Home Budget"
        case .freelancer: return "Freelancer / Business"
        case .both: return "Both"
        }
    }
}
