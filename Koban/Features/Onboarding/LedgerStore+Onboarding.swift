import Foundation
import Observation
import SwiftUI

// OWNER: Onboarding — Vault Format v2 first-run setup & re-run setup wizard.
extension LedgerStore {
    static let setupWizardModalId = "setup-wizard"

    func openSetupWizard(step: Int = 1) {
        guard isUnlockedAndReady else { return }
        openMenu = nil
        presentSetupWizard(model: nil, step: step)
    }

    fileprivate func presentSetupWizard(model: SetupWizardModel?, step: Int) {
        present(Self.setupWizardModalId, dismissOnBackdrop: false) {
            SetupWizardView(isFirstRun: false, initialStep: step, existingModel: model)
                .environment(self)
        }
    }

    var setupBaseState: LedgerState {
        if phase == .ready || state.settings.setupCompleted == false { return state }
        return KobanTemplates.initialLedgerState(setupMode: .both, currency: "CHF", backupDir: "", setupCompleted: false)
    }

    func completeSetup(_ opts: SetupOptions) {
        let next = OnboardingSetup.apply(opts, to: setupBaseState)
        flushPendingSave()

        let v = vault ?? KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v

        do {
            let st = try v.status(
                deviceSlotEnrolled: { TouchIDKeychain.hasDEK(vaultID: $0) },
                isCustomLocation: KobanPaths.isCustomLocation
            )
            var recoveryKeyToShow: String? = nil

            if !st.exists || !st.hasLedgerState {
                guard let pass = opts.vaultPassphrase, !pass.isEmpty else {
                    notify("Master Password is required to create Vault Format v2.")
                    return
                }
                let created = try v.createV2(
                    passphrase: pass,
                    keyfileURL: opts.keyfileURL,
                    createRecoveryKey: opts.createRecoveryKey,
                    initialState: next
                )
                recoveryKeyToShow = created.recoveryKey
                if opts.rememberKeyfile, let kf = opts.keyfileURL, let vid = v.vaultIDB64 {
                    TouchIDKeychain.rememberKeyfileURL(kf, vaultID: vid)
                }
            } else if v.isUnlocked {
                state = next
                if let pass = opts.vaultPassphrase, !pass.isEmpty {
                    try v.changeCredentials(
                        newPassphrase: pass,
                        newKeyfileURL: opts.keyfileURL,
                        rekeyDEK: false,
                        currentState: next
                    )
                    if let vid = v.vaultIDB64 {
                        TouchIDKeychain.rememberKeyfileURL(opts.rememberKeyfile ? opts.keyfileURL : nil, vaultID: vid)
                    }
                } else {
                    try v.save(next, forceOverwrite: true)
                }
            }

            try? v.saveAuthSettings(
                VaultAuthSettings(
                    autoPromptDevice: true,
                    autoLockMinutes: opts.autoLockMinutes,
                    lockOnMinimize: opts.lockOnMinimize
                )
            )

            finishUnlock(loaded: DeviceSettings.applyBackupDir(to: next), greet: false)
            if let recoveryKeyToShow {
                AuthCenter.shared.pendingRecoveryKey = recoveryKeyToShow
            }
            if opts.enrollTouchID, TouchIDKeychain.anyAuthAvailable,
               let vid = v.vaultIDB64, !TouchIDKeychain.hasDEK(vaultID: vid) {
                Task { @MainActor in
                    try? await self.enrollTouchID()
                }
            }

            dismissModal()
            notify(OnboardingSetup.completionMessage(skippedAccounts: opts.skipAccountsSetup))
        } catch {
            notify("Vault setup failed: \(DataIOMessages.text(error))")
        }
    }

    // MARK: - Import from the wizard

    func openImportFromSetupWizard(model: SetupWizardModel) {
        if model.isFirstRun && phase == .needsSetup && state.settings.setupCompleted {
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

    fileprivate func setupImportFinished(before: LedgerState, model: SetupWizardModel, reopenWizard: Bool) {
        let committed = state != before || (model.isFirstRun && phase != .needsSetup)
        if committed {
            if phase == .ready {
                if !state.settings.setupCompleted { update { $0.settings.setupCompleted = true } }
                saveNow()
            }
            if modal?.id == Self.setupWizardModalId { dismissModal() }
        } else if reopenWizard, modal == nil, isUnlockedAndReady {
            presentSetupWizard(model: model, step: model.step)
        }
    }
}

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
