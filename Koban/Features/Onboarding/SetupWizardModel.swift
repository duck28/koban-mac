import AppKit
import LocalAuthentication
import Observation
import SwiftUI

/// All useState hooks of OnboardingModal.tsx plus its handlers.
@MainActor
@Observable
final class SetupWizardModel {
    let isFirstRun: Bool
    /// currentSettings.setupCompleted
    let setupCompleted: Bool
    /// Whether the active database already uses an unlocked Vault v2 configuration.
    let alreadyConfiguredV2: Bool
    var step: Int

    // Step 1: Profile & Currency
    var setupMode: ProfileSetupMode
    var currency: String
    var defaultVatRate: Double
    var taxReserveRate: Double

    // Step 2: Categories & Recurring Flags
    var categoryTab: LedgerMode
    var selectedHomeIds = KobanTemplates.defaultCheckedIds(KobanTemplates.homeCatalog)
    var selectedFreelancerIds = KobanTemplates.defaultCheckedIds(KobanTemplates.freelancerCatalog)
    var recurringCategoryIds = KobanTemplates.defaultRecurringIds()
    var customItemsByGroup: [String: [String]] = [:]
    var customInputByGroup: [String: String] = [:]
    var applyCategorySelection: Bool

    // Step 3: Liquid Assets, Bank Accounts & Retirement
    var skipAccountsSetup = false
    var draftAccounts: [FinancialAccount]

    // Step 4: Vault Format v2 Encryption, Key File & Quick Unlock
    var backupDir: String
    var autoBackup: Bool
    var vaultPassphrase = ""
    var vaultPassphraseConfirm = ""
    var keyfileURL: URL?
    var rememberKeyfile = false
    var createRecoveryKey = true
    var userDisplayName: String
    var enrollTouchID: Bool
    var autoLockMinutes: Int
    var lockOnMinimize: Bool
    var keyfileStatusMsg: String?
    var confirmBeforeMonthCopy: Bool
    var monthCopyScope: MonthCopyScope
    var autoPromptCopyOnEmptyMonth: Bool

    init(base: LedgerState, vaultStatus: VaultStatus?, isFirstRun: Bool, initialStep: Int = 1) {
        let s = base.settings
        self.isFirstRun = isFirstRun
        self.alreadyConfiguredV2 = (vaultStatus?.exists == true && vaultStatus?.formatVersion == 2 && vaultStatus?.unlocked == true)
        setupCompleted = !isFirstRun && s.setupCompleted
        step = min(max(initialStep, 1), 4)
        setupMode = s.setupMode
        currency = s.currency.isEmpty ? "CHF" : s.currency
        defaultVatRate = s.defaultVatRate
        taxReserveRate = s.taxReserveRate
        categoryTab = s.setupMode == .freelancer ? .freelancer : .home
        applyCategorySelection = !setupCompleted
        draftAccounts = base.accounts.isEmpty
            ? KobanTemplates.defaultOnboardingAccounts(setupMode: s.setupMode) : base.accounts
        backupDir = s.backupDir
        autoBackup = s.backupDir.isEmpty ? true : s.autoBackup
        userDisplayName = (s.ownerDisplayName ?? "").isEmpty ? "Koban Owner" : s.ownerDisplayName!
        enrollTouchID = TouchIDKeychain.anyAuthAvailable && (vaultStatus?.deviceSlotEnrolled ?? true)
        autoLockMinutes = vaultStatus?.authSettings.autoLockMinutes ?? 15
        lockOnMinimize = vaultStatus?.authSettings.lockOnMinimize ?? false
        confirmBeforeMonthCopy = s.confirmBeforeMonthCopy ?? true
        monthCopyScope = s.monthCopyScope ?? .budgetsAndActuals
        autoPromptCopyOnEmptyMonth = s.autoPromptCopyOnEmptyMonth ?? true
    }

    // MARK: Step 1

    func handleModeChange(_ mode: ProfileSetupMode) {
        setupMode = mode
        if mode == .freelancer { categoryTab = .freelancer }
        if mode == .home { categoryTab = .home }
        if !draftAccounts.contains(where: { $0.startingBalance != 0 }) {
            draftAccounts = KobanTemplates.defaultOnboardingAccounts(setupMode: mode)
        }
    }

    // MARK: Step 2

    func selectedIds(_ mode: LedgerMode) -> Set<String> {
        mode == .home ? selectedHomeIds : selectedFreelancerIds
    }

    private func updateSelection(_ mode: LedgerMode, _ update: (inout Set<String>) -> Void) {
        if mode == .home { update(&selectedHomeIds) } else { update(&selectedFreelancerIds) }
    }

    func toggleCategory(_ mode: LedgerMode, _ id: String) {
        updateSelection(mode) { set in
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
        }
    }

    func toggleRecurringCategory(_ mode: LedgerMode, _ id: String) {
        let wasRecurring = recurringCategoryIds.contains(id)
        if wasRecurring { recurringCategoryIds.remove(id) } else { recurringCategoryIds.insert(id) }
        // Toggling recurring ON for an unselected standard category also selects it.
        if !id.hasPrefix("custom:") && !wasRecurring && !selectedIds(mode).contains(id) {
            updateSelection(mode) { $0.insert(id) }
        }
    }

    enum GroupAction { case all, `default`, none }

    func setGroupSelection(_ group: CatalogGroupDef, _ action: GroupAction) {
        updateSelection(group.mode) { set in
            for item in group.items {
                switch action {
                case .all: set.insert(item.id)
                case .none: set.remove(item.id)
                case .default:
                    if item.defaultChecked { set.insert(item.id) } else { set.remove(item.id) }
                }
            }
        }
    }

    func resetRecurringDefaults() {
        recurringCategoryIds = KobanTemplates.defaultRecurringIds()
    }

    func handleAddCustomCategory(_ groupId: String) {
        let val = (customInputByGroup[groupId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return }
        customItemsByGroup[groupId, default: []].append(val)
        customInputByGroup[groupId] = ""
    }

    func handleRemoveCustomCategory(_ groupId: String, _ idx: Int) {
        guard var list = customItemsByGroup[groupId], list.indices.contains(idx) else { return }
        list.remove(at: idx)
        customItemsByGroup[groupId] = list
    }

    // MARK: Step 3

    func updateDraftAccount(_ id: String, _ mutate: (inout FinancialAccount) -> Void) {
        guard let idx = draftAccounts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&draftAccounts[idx])
    }

    func changeDraftType(_ id: String, to type: AccountType) {
        guard let idx = draftAccounts.firstIndex(where: { $0.id == id }) else { return }
        draftAccounts[idx] = OnboardingDrafts.changingType(draftAccounts[idx], to: type)
    }

    func setDraftBalance(_ id: String, _ value: Double) {
        updateDraftAccount(id) {
            $0.startingBalance = value
            $0.currentBalance = value
        }
    }

    func addDraftAccount(_ preset: OnboardingDrafts.PresetClass) {
        draftAccounts.append(OnboardingDrafts.newAccount(preset, setupMode: setupMode))
    }

    func removeDraftAccount(_ id: String) {
        draftAccounts.removeAll { $0.id == id }
    }

    var totals: OnboardingDrafts.Totals { OnboardingDrafts.totals(draftAccounts) }

    // MARK: Step 4

    var requiresCustomPassphrase: Bool { !hasCustomPassphrase }

    var requiresCustomPassphrase: Bool { !alreadyConfiguredV2 }

    var minPassphraseLen: Int {
        keyfileURL != nil ? VaultCrypto.minCompositePassphraseLength : VaultCrypto.minPassphraseLength
    }

    var passphraseError: String? {
        let hasInput = !vaultPassphrase.isEmpty || !vaultPassphraseConfirm.isEmpty
        if alreadyConfiguredV2 && !hasInput {
            return nil
        }
        if vaultPassphrase.count < minPassphraseLen {
            return "Master Password must be at least \(minPassphraseLen) characters."
        }
        if vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines) != vaultPassphrase {
            return "Master Password cannot start or end with spaces."
        }
        if vaultPassphrase != vaultPassphraseConfirm {
            return L10n.t("onboarding.s4.errMismatch")
        }
        return nil
    }

    var isPassphraseValid: Bool { passphraseError == nil }

    func handleChooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Automatic Database Backup Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupDir = url.path
        autoBackup = true
    }

    /// handleFinish.
    func finish(store: LedgerStore) {
        guard isPassphraseValid else { return }
        let owner = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.completeSetup(SetupOptions(
            setupMode: setupMode,
            currency: currency,
            backupDir: backupDir,
            autoBackup: autoBackup,
            defaultVatRate: defaultVatRate,
            taxReserveRate: taxReserveRate,
            applyCategorySelection: applyCategorySelection,
            selectedHomeIds: selectedHomeIds,
            selectedFreelancerIds: selectedFreelancerIds,
            recurringCategoryIds: recurringCategoryIds,
            customItemsByGroup: customItemsByGroup,
            accounts: skipAccountsSetup ? nil : draftAccounts,
            skipAccountsSetup: skipAccountsSetup,
            ownerDisplayName: owner.isEmpty ? "Koban Owner" : owner,
            vaultPassphrase: vaultPassphrase.isEmpty ? nil : vaultPassphrase,
            keyfileURL: keyfileURL,
            rememberKeyfile: rememberKeyfile,
            createRecoveryKey: createRecoveryKey,
            enrollTouchID: enrollTouchID,
            autoLockMinutes: autoLockMinutes,
            lockOnMinimize: lockOnMinimize,
            confirmBeforeMonthCopy: confirmBeforeMonthCopy,
            monthCopyScope: monthCopyScope,
            autoPromptCopyOnEmptyMonth: autoPromptCopyOnEmptyMonth
        ))
    }
}
