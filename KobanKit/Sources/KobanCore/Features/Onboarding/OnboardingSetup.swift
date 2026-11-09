import Foundation

// Platform-independent logic of the setup wizard:
//  - SetupOptions + OnboardingSetup.apply  = handleCompleteSetup in src/App.tsx (state part)
//  - OnboardingDrafts                      = the account-draft helpers in OnboardingModal.tsx
//  - OnboardingSetup.finishAuth            = the AuthConfig edit done by handleFinish

/// Everything the wizard hands to `onCompleteSetup` (OnboardingModal.tsx props).
struct SetupOptions: Sendable {
    var setupMode: ProfileSetupMode
    var currency: String
    var backupDir: String
    var autoBackup: Bool
    var defaultVatRate: Double
    var taxReserveRate: Double
    var applyCategorySelection: Bool
    var selectedHomeIds: Set<String>
    var selectedFreelancerIds: Set<String>
    var recurringCategoryIds: Set<String>
    var customItemsByGroup: [String: [String]]
    /// nil when the accounts step was skipped.
    var accounts: [FinancialAccount]?
    var skipAccountsSetup: Bool
    /// Trimmed custom vault passphrase; nil = leave the vault key unchanged.
    var vaultPassphrase: String?
    var confirmBeforeMonthCopy: Bool
    var monthCopyScope: MonthCopyScope
    var autoPromptCopyOnEmptyMonth: Bool
}

enum OnboardingSetup {
    /// handleCompleteSetup: either rebuilds the ledger from the chosen catalog selection
    /// (first run, or re-run with "Apply category changes"), or merges the new mode,
    /// recurring flags, accounts and preferences into the existing ledger.
    static func apply(_ opts: SetupOptions, to state: LedgerState,
                      now: Date = Date(), calendar: Calendar = .current) -> LedgerState {
        let chosenAccounts = opts.skipAccountsSetup ? state.accounts : (opts.accounts ?? state.accounts)

        if opts.applyCategorySelection {
            var fresh = KobanTemplates.initialLedgerState(
                setupMode: opts.setupMode,
                currency: opts.currency,
                backupDir: opts.backupDir,
                setupCompleted: true,
                selectedHomeIds: opts.selectedHomeIds,
                selectedFreelancerIds: opts.selectedFreelancerIds,
                customItemsByGroup: opts.customItemsByGroup,
                initialAccounts: chosenAccounts,
                initialNetWorthSnapshots: state.netWorthSnapshots,
                recurringIds: opts.recurringCategoryIds,
                now: now, calendar: calendar)
            fresh.settings.autoBackup = opts.autoBackup
            fresh.settings.defaultVatRate = opts.defaultVatRate
            fresh.settings.taxReserveRate = opts.taxReserveRate
            fresh.settings.confirmBeforeMonthCopy = opts.confirmBeforeMonthCopy
            fresh.settings.monthCopyScope = opts.monthCopyScope
            fresh.settings.autoPromptCopyOnEmptyMonth = opts.autoPromptCopyOnEmptyMonth
            return fresh
        }

        let nextWorkspace: ActiveWorkspace
        switch opts.setupMode {
        case .freelancer: nextWorkspace = .freelancer
        case .home: nextWorkspace = .home
        case .both: nextWorkspace = state.settings.activeWorkspace
        }

        var next = state
        next.categories = state.categories.map { cat in
            var c = cat
            c.isRecurring = opts.recurringCategoryIds.contains(cat.id)
            return c
        }
        // new Map(rules.map(r => [r.categoryId, r])): the last rule per category wins.
        var existingRecByCat: [String: RecurringRule] = [:]
        for rule in state.recurringRules { existingRecByCat[rule.categoryId] = rule }

        var nextRules: [RecurringRule] = []
        for cat in next.categories where cat.isRecurring == true {
            if var existing = existingRecByCat[cat.id] {
                existing.active = true
                nextRules.append(existing)
            } else {
                nextRules.append(RecurringRule(
                    id: "rec-init-\(cat.id)",
                    mode: cat.mode,
                    type: cat.kind == .income ? .income : .expense,
                    categoryId: cat.id,
                    accountId: nil,
                    description: cat.name,
                    amount: cat.defaultBudget,
                    frequency: .monthly,
                    dayOfMonth: cat.kind == .income ? 25 : 1,
                    client: nil,
                    taxRate: cat.taxRate ?? 0,
                    deductiblePct: cat.deductiblePct ?? 100,
                    active: true))
            }
        }
        next.recurringRules = nextRules
        next.accounts = chosenAccounts
        next.settings.setupCompleted = true
        next.settings.setupMode = opts.setupMode
        next.settings.activeWorkspace = nextWorkspace
        next.settings.currency = opts.currency
        next.settings.backupDir = opts.backupDir
        next.settings.autoBackup = opts.autoBackup
        next.settings.defaultVatRate = opts.defaultVatRate
        next.settings.taxReserveRate = opts.taxReserveRate
        next.settings.confirmBeforeMonthCopy = opts.confirmBeforeMonthCopy
        next.settings.monthCopyScope = opts.monthCopyScope
        next.settings.autoPromptCopyOnEmptyMonth = opts.autoPromptCopyOnEmptyMonth
        return next
    }

    /// Toast shown by App.tsx after setup.
    static func completionMessage(skippedAccounts: Bool) -> String {
        skippedAccounts
            ? "Koban setup complete (Account setup skipped for later)."
            : "Koban setup, accounts, and encrypted vault configured."
    }
}

// MARK: - Account drafts (step 3)

enum OnboardingDrafts {
    enum PresetClass { case liquid, retirement, custom }

    /// addDraftAccount in OnboardingModal.tsx.
    static func newAccount(_ preset: PresetClass, setupMode: ProfileSetupMode, now: Date = Date()) -> FinancialAccount {
        let type: AccountType = preset == .liquid ? .checking : preset == .retirement ? .retirement : .custom
        let meta = KobanTemplates.accountType(type)
        let suffix = String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(3))
        return FinancialAccount(
            id: "acc-onb-\(Int(now.timeIntervalSince1970 * 1000))-\(suffix)",
            name: preset == .liquid ? "Secondary Bank Account"
                : preset == .retirement ? "Retirement / Investment Account" : "Custom Asset Account",
            institution: "",
            accountNumberMasked: nil,
            mode: setupMode == .freelancer ? .freelancer : .home,
            type: type,
            customTypeLabel: preset == .custom ? "Custom Account" : nil,
            classification: meta.defaultClass,
            startingBalance: 0,
            currentBalance: 0,
            autoTrackTransactions: meta.autoTrackDefault,
            includeInNetWorth: true,
            expectedAnnualReturnPct: nil,
            color: meta.defaultColor,
            notes: nil,
            updatedAt: KobanTemplates.today())
    }

    /// updateDraftAccount with a type change: classification / auto-track / color follow the type.
    static func changingType(_ account: FinancialAccount, to type: AccountType) -> FinancialAccount {
        var updated = account
        guard type != account.type else { return updated }
        updated.type = type
        let meta = KobanTemplates.accountType(type)
        updated.classification = meta.defaultClass
        updated.autoTrackTransactions = meta.autoTrackDefault
        updated.color = meta.defaultColor
        return updated
    }

    struct Totals: Equatable {
        var liquid: Double
        var retirement: Double
        var investmentFixed: Double
        var liability: Double
        var netWorth: Double { liquid + retirement + investmentFixed - liability }
        /// Right-hand column total (retirement + investments − debts).
        var wealthAndOther: Double { retirement + investmentFixed - liability }
    }

    /// Live preview totals for step 3.
    static func totals(_ accounts: [FinancialAccount]) -> Totals {
        func sum(_ classes: Set<AccountLiquidityClass>, abs useAbs: Bool = false) -> Double {
            accounts.filter { classes.contains($0.classification) }
                .reduce(0) { $0 + (useAbs ? Swift.abs($1.startingBalance) : $1.startingBalance) }
        }
        return Totals(liquid: sum([.liquid]), retirement: sum([.retirement]),
                      investmentFixed: sum([.investment, .fixedAsset]), liability: sum([.liability], abs: true))
    }
}

// MARK: - AuthConfig (handleFinish in OnboardingModal.tsx)

extension OnboardingSetup {
    /// handleFinish: login enabled when required, a passkey exists or a vault passphrase was set;
    /// the passphrase also becomes the master-passphrase verifier (PBKDF2, utils/auth.ts).
    static func finishAuth(_ config: AuthConfig, requireLoginOnStartup: Bool, userDisplayName: String,
                           vaultPassphrase: String?) -> AuthConfig {
        var next = config
        let pass = vaultPassphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        next.enabled = requireLoginOnStartup || !config.passkeys.isEmpty || !pass.isEmpty
        let name = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        next.userDisplayName = name.isEmpty ? "Koban Owner" : name
        if !pass.isEmpty {
            let verifier = AuthCrypto.hashPassphraseVerifier(pass)
            next.hasMasterPassphrase = true
            next.passphraseSaltB64 = verifier.saltB64
            next.passphraseVerifierHashB64 = verifier.hashB64
        }
        return next
    }
}
