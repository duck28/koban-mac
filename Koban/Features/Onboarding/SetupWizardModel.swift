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

    // Step 4: Encrypted Backup, Login / Passkeys & Behavioral Preferences
    var backupDir: String
    var autoBackup: Bool
    var vaultPassphrase = ""
    var userDisplayName: String
    var requireLoginOnStartup: Bool
    var passkeyStatusMsg: String?
    var isEnrollingPasskey = false
    var confirmBeforeMonthCopy: Bool
    var monthCopyScope: MonthCopyScope
    var autoPromptCopyOnEmptyMonth: Bool

    var auth: AuthConfig

    init(base: LedgerState, auth: AuthConfig, isFirstRun: Bool, initialStep: Int = 1) {
        let s = base.settings
        self.isFirstRun = isFirstRun
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
        userDisplayName = auth.userDisplayName.isEmpty ? "Koban Owner" : auth.userDisplayName
        requireLoginOnStartup = auth.enabled
        confirmBeforeMonthCopy = s.confirmBeforeMonthCopy ?? true
        monthCopyScope = s.monthCopyScope ?? .budgetsAndActuals
        autoPromptCopyOnEmptyMonth = s.autoPromptCopyOnEmptyMonth ?? true
        self.auth = auth
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

    /// handleEnrollPasskeyInOnboarding — Windows Hello / WebAuthn → Touch ID via the Settings
    /// enrollment path (TouchIDKeychain + AuthCenter). The vault secret stored for Touch ID unlock is the
    /// passphrase typed here, else the vault's current custom passphrase.
    func handleEnrollPasskey(store: LedgerStore) {
        isEnrollingPasskey = true
        passkeyStatusMsg = nil
        let trimmedName = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = trimmedName.isEmpty ? "Koban Owner" : trimmedName
        let typed = vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = typed.isEmpty ? store.vault?.passphrase : typed
        Task { @MainActor in
            defer { isEnrollingPasskey = false }
            do {
                let cred = try await TouchIDKeychain.enroll(account: AuthCenter.shared.account,
                                                            label: TouchIDKeychain.methodName,
                                                            vaultSecret: secret, displayName: cleanName)
                var next = AuthCenter.shared.config
                next.enabled = true
                next.userDisplayName = cleanName
                next.passkeys.append(cred)
                auth = next
                requireLoginOnStartup = true
                store.updateAuthConfig(next)
                passkeyStatusMsg = "Enrolled \"\(cred.name)\" successfully."
            } catch let err as LAError where err.code == .userCancel || err.code == .appCancel || err.code == .systemCancel {
                passkeyStatusMsg = "Passkey registration canceled."
            } catch {
                passkeyStatusMsg = "Passkey prompt: \(error.localizedDescription)"
            }
        }
    }

    /// handleFinish.
    func finish(store: LedgerStore) {
        let pass = vaultPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAuth = OnboardingSetup.finishAuth(auth, requireLoginOnStartup: requireLoginOnStartup,
                                                  userDisplayName: userDisplayName, vaultPassphrase: pass)
        auth = nextAuth
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
            vaultPassphrase: pass.isEmpty ? nil : pass,
            confirmBeforeMonthCopy: confirmBeforeMonthCopy,
            monthCopyScope: monthCopyScope,
            autoPromptCopyOnEmptyMonth: autoPromptCopyOnEmptyMonth
        ), auth: nextAuth)
    }
}
