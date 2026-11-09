import Foundation
import Observation
import SwiftUI

// OWNER: Onboarding — hook used by the TopBar sparkles button, the sidebar "Re-run Setup"
// and the app menu command. Port of the setup handlers in src/App.tsx.
extension LedgerStore {
    static let setupWizardModalId = "setup-wizard"

    /// Re-runs the 4-step wizard over the open ledger (setShowSetupModal(true)).
    func openSetupWizard(step: Int = 1) {
        guard isReady else { return }
        openMenu = nil
        presentSetupWizard(model: nil, step: step)
    }

    fileprivate func presentSetupWizard(model: SetupWizardModel?, step: Int) {
        present(Self.setupWizardModalId, dismissOnBackdrop: false) {
            SetupWizardView(isFirstRun: false, initialStep: step, existingModel: model)
                .environment(self)
        }
    }

    /// The ledger the wizard starts from. On a first run without a stored ledger this is
    /// createInitialLedgerState('both', 'CHF', '', false), like App.tsx's initial state.
    var setupBaseState: LedgerState {
        if phase == .ready || state.settings.setupCompleted == false { return state }
        return KobanTemplates.initialLedgerState(setupMode: .both, currency: "CHF", backupDir: "", setupCompleted: false)
    }

    /// AuthConfig of the active database (AuthCenter), reloaded so a first run sees this vault's config.
    func loadSetupAuthConfig() -> AuthConfig {
        AuthCenter.shared.refresh(store: self, force: true)
        return AuthCenter.shared.config
    }

    /// handleCompleteSetup in App.tsx.
    func completeSetup(_ opts: SetupOptions, auth: AuthConfig) {
        let wasFirstRun = phase != .ready
        let next = OnboardingSetup.apply(opts, to: setupBaseState)
        flushPendingSave()
        state = next
        phase = .ready
        applyAppearance()
        saveNow()
        // onUpdateAuthConfig → persists vault_meta.auth_config and refreshes AuthCenter in memory.
        updateAuthConfig(auth)
        if wasFirstRun { finishFirstRunActivation() }

        if let pass = opts.vaultPassphrase, !pass.isEmpty {
            // updateVaultPassphrase(): re-encrypts and keeps the Touch ID Keychain secret in sync.
            applyVaultPassphrase(pass)
        }

        dismissModal()
        notify(OnboardingSetup.completionMessage(skippedAccounts: opts.skipAccountsSetup))
    }

    /// The post-load hooks that openVault runs for a stored ledger (language, personalization,
    /// auto-lock monitor). No lock: Windows doesn't lock right after finishing setup.
    fileprivate func finishFirstRunActivation() {
        // didLaunchCheck = true makes shouldLockAfterLoad skip the launch lock decision.
        AuthCenter.shared.didLaunchCheck = true
        _ = shouldLockAfterLoad()
    }

    // MARK: - Import from the wizard (onOpenImportModal)

    /// "Import Existing Data…" in the wizard header. On Windows the Import modal opens on top of the
    /// wizard: committing an import replaces the ledger (setupCompleted: true) and closes the wizard,
    /// cancelling returns to the wizard where it was.
    func openImportFromSetupWizard(model: SetupWizardModel) {
        if model.isFirstRun && phase == .needsSetup && state.settings.setupCompleted {
            // No stored ledger yet: import into App.tsx's initial ledger, as Windows does.
            state = setupBaseState
        }
        let before = state
        let wizardModalBefore = modal?.id == Self.setupWizardModalId
        openImport()
        guard let importId = modal?.id, importId != Self.setupWizardModalId else {
            if wizardModalBefore && modal == nil { presentSetupWizard(model: model, step: model.step) }
            return
        }
        SetupImportWatcher.watch(store: self, importModalId: importId, before: before, model: model,
                                 reopenWizard: wizardModalBefore)
    }

    /// Called when the import modal opened from the wizard has closed.
    fileprivate func setupImportFinished(before: LedgerState, model: SetupWizardModel, reopenWizard: Bool) {
        let committed = state != before || (model.isFirstRun && phase != .needsSetup)
        if committed {
            if phase == .needsSetup {
                // handleCommitImport: proposedState has setupCompleted: true → leave setup.
                state.settings.setupCompleted = true
                phase = .ready
                applyAppearance()
                saveNow()
                finishFirstRunActivation()
            } else if phase == .ready {
                if !state.settings.setupCompleted { update { $0.settings.setupCompleted = true } }
                saveNow()
            }
            if modal?.id == Self.setupWizardModalId { dismissModal() }
        } else if reopenWizard, modal == nil, isReady {
            presentSetupWizard(model: model, step: model.step)
        }
    }
}

/// Watches the store's modal slot (without a mounted view) until the Import modal closes.
@MainActor
enum SetupImportWatcher {
    static func watch(store: LedgerStore, importModalId: String, before: LedgerState,
                      model: SetupWizardModel, reopenWizard: Bool) {
        withObservationTracking {
            _ = store.modal?.id
        } onChange: {
            Task { @MainActor in
                if store.modal?.id == importModalId {
                    watch(store: store, importModalId: importModalId, before: before, model: model,
                          reopenWizard: reopenWizard)
                } else {
                    store.setupImportFinished(before: before, model: model, reopenWizard: reopenWizard)
                }
            }
        }
    }
}
