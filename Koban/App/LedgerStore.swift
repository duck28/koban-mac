import AppKit
import SwiftUI
import Foundation
import Observation
import UniformTypeIdentifiers

/// App-wide state: owns the open vault and the decrypted ledger, and persists edits.
/// Equivalent of the state handling in src/App.tsx + src/utils/storage.ts.
@MainActor
@Observable
final class LedgerStore {
    enum Phase: Equatable {
        case loading
        /// Vault exists but needs the custom passphrase.
        case locked(message: String?)
        /// No ledger yet — show the welcome / setup screen.
        case needsSetup
        case ready
        case failed(String)
    }

    var phase: Phase = .loading
    var state: LedgerState = .empty() {
        didSet { calcCache.removeAll(keepingCapacity: true) }
    }

    /// Memoized calculations for the current `state` (see LedgerStore+Cache.swift). Several views
    /// (sidebar, worksheet, reports, accounts) need the same month summary / net-worth series on
    /// every render; recomputing them over all transactions each time made edits and tab switches slow.
    @ObservationIgnored var calcCache: [String: Any] = [:]
    var selectedTab: ViewTab = .worksheet

    // MARK: UI state (mirrors the useState hooks in App.tsx)

    enum TopMenu: Equatable { case month, export, language }
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var filePath: String?
    }

    var isSidebarOpen = true
    var openMenu: TopMenu?
    private(set) var toast: Toast?
    private(set) var isSaving = false
    /// Category to preselect when the Transactions view opens (quick log from the worksheet).
    var preselectedCategoryId: String?

    /// Pending month-copy confirmation (copyModalState in MonthlyWorksheetView.tsx).
    struct CopyRequest: Equatable {
        enum Mode { case prevToCurrent, currentToNext, allMonths }
        var mode: Mode
        var source: String
        var target: String
        var scope: MonthCopyScope
        var overwriteExisting: Bool
        var navigateToTarget: Bool
    }
    var copyRequest: CopyRequest?

    /// App-level lock screen over a loaded ledger (Windows login / passkey lock). The vault
    /// itself stays open; Settings/Auth decides when to set this (see LedgerStore+Auth.swift).
    var isAppLocked = false

    /// A window-wide modal (ZenModal content). Features present their dialogs through this so
    /// the dimmed backdrop covers the top bar and sidebar too.
    struct PresentedModal: Identifiable {
        let id: String
        let content: AnyView
        var dismissOnBackdrop: Bool
    }
    var modal: PresentedModal?

    func present<V: View>(_ id: String, dismissOnBackdrop: Bool = true, @ViewBuilder _ content: () -> V) {
        modal = PresentedModal(id: id, content: AnyView(content()), dismissOnBackdrop: dismissOnBackdrop)
    }

    func dismissModal() { modal = nil }
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    var lastSaveError: String?
    /// Auto-backup after a save failed (the save itself succeeded).
    var lastBackupError: String?
    var lastSavedAt: Date?

    /// True while a valid encrypted vault is protected (always true in Vault v2).
    var hasCustomPassphrase = true

    /// The open vault. Features (unlock, restore, DB location) use it directly.
    @ObservationIgnored var vault: KobanVault?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The ledger as last loaded from / written to the vault.
    @ObservationIgnored private var lastPersistedState: LedgerState?

    var isReady: Bool { phase == .ready }
    var isUnlockedAndReady: Bool { isReady && !isAppLocked && (vault?.isUnlocked ?? false) }
    var canLock: Bool { isUnlockedAndReady }
    var databaseURL: URL { KobanPaths.activeDatabaseURL }

    func wireVaultHooks(_ v: KobanVault) {
        v.onStripWebDavPassword = { TouchIDKeychain.stripAndStoreWebDavPassword(in: $0) }
        v.onInjectWebDavPassword = { TouchIDKeychain.injectLocalWebDavPassword(in: $0) }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard phase == .loading else { return }
        AutoLockMonitor.install(store: self)
        refreshVaultPhase()
    }

    /// Reads Vault v2 metadata read-only without decrypting or prompting for biometrics.
    func refreshVaultPhase() {
        do {
            let v = KobanVault(url: KobanPaths.activeDatabaseURL)
            wireVaultHooks(v)
            self.vault = v
            lastPersistedState = nil
            let st = try v.status(
                deviceSlotEnrolled: { TouchIDKeychain.hasDEK(vaultID: $0) },
                isCustomLocation: KobanPaths.isCustomLocation
            )
            hasCustomPassphrase = true
            AuthCenter.shared.refresh(store: self, force: true)
            if !st.exists || !st.hasLedgerState {
                phase = .needsSetup
            } else {
                phase = .locked(message: nil)
            }
        } catch {
            phase = .failed(DataIOMessages.text(error))
        }
    }

    func finishUnlock(loaded stored: LedgerState, greet: Bool = true) {
        let loaded = DeviceSettings.applyBackupDir(to: stored)
        state = loaded
        lastPersistedState = loaded
        applyAppearance()
        AuthCenter.shared.refresh(store: self, force: true)
        AuthCenter.shared.didLaunchCheck = true
        isAppLocked = false
        phase = loaded.settings.setupCompleted ? .ready : .needsSetup
        if phase == .ready {
            AutoLockMonitor.install(store: self)
            AutoLockMonitor.resetIdle()
            webDavAfterLoad()
            UpdateChecker.shared.checkOnLaunchIfEnabled(autoCheck: loaded.settings.autoCheckUpdates ?? true)
            DataIOCenter.shared.refreshImportWatchFolder()
            if greet {
                let owner = (loaded.settings.ownerDisplayName ?? "").isEmpty ? "Koban Owner" : loaded.settings.ownerDisplayName!
                notify("Signed in as \(owner).")
            }
        }
    }

    func lock() {
        flushPendingSave()
        pendingSave?.cancel()
        pendingSave = nil
        vault?.lock()
        state = .empty()
        lastPersistedState = nil
        isAppLocked = false
        phase = .locked(message: nil)
        AuthCenter.shared.refresh(store: self, force: true)
    }

    /// Re-opens the active DB cleanly; if `sessionDEK` still unlocks the replacement DB, stays unlocked.
    func reopenWithDEK(_ rawDEK: Data?) {
        let v = KobanVault(url: KobanPaths.activeDatabaseURL)
        wireVaultHooks(v)
        self.vault = v
        lastPersistedState = nil
        do {
            let st = try v.status(
                deviceSlotEnrolled: { TouchIDKeychain.hasDEK(vaultID: $0) },
                isCustomLocation: KobanPaths.isCustomLocation
            )
            if !st.exists || !st.hasLedgerState {
                AuthCenter.shared.refresh(store: self, force: true)
                phase = .needsSetup
                return
            }
            if let rawDEK, let loaded = try? v.unlockWithDEK(rawDEK) {
                finishUnlock(loaded: loaded, greet: false)
                return
            }
            state = .empty()
            phase = .locked(message: nil)
            AuthCenter.shared.refresh(store: self, force: true)
        } catch {
            phase = .failed(DataIOMessages.text(error))
        }
    }

    /// Switches to an existing koban.db (e.g. one shared via iCloud, Synology Drive, or copied from Windows).
    func openExistingDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Open Koban Database"
        panel.allowedContentTypes = ["db", "sqlite"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try KobanVault.detectFormatVersion(at: url)
            try KobanPaths.useDatabase(at: url)
            flushPendingSave()
            vault?.lock()
            vault = nil
            state = .empty()
            phase = .loading
            refreshVaultPhase()
        } catch {
            phase = .failed(DataIOMessages.text(error))
        }
    }

    // MARK: - Editing

    /// Applies a mutation and schedules a debounced encrypted save.
    func update(_ mutate: (inout LedgerState) -> Void) {
        mutate(&state)
        scheduleSave()
    }

    func shiftMonth(by delta: Int) {
        update { $0.shiftActiveMonth(by: delta) }
    }

    func setMonth(year: Int, month: Int) {
        update {
            $0.settings.activeYear = year
            $0.settings.activeMonth = month
        }
    }

    func setWorkspace(_ workspace: ActiveWorkspace) {
        update { $0.settings.activeWorkspace = workspace }
    }

    /// system → light → dark, like the TopBar theme button.
    func cycleTheme() {
        let order: [ThemePreference] = [.system, .light, .dark]
        let idx = order.firstIndex(of: state.settings.theme) ?? 0
        update { $0.settings.theme = order[(idx + 1) % order.count] }
        applyAppearance()
    }

    func setPalette(_ palette: ThemePalette) {
        update { $0.settings.themePalette = palette }
        applyAppearance()
    }

    /// Applies the stored theme (system / light / dark) and palette to the whole app.
    func applyAppearance() {
        Zen.palette = state.settings.themePalette ?? .zen
        applyPersonalization()
        L10n.setLanguage(state.settings.language)
        switch state.settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func toggleSidebar() { isSidebarOpen.toggle() }

    func toggleMenu(_ menu: TopMenu) {
        openMenu = openMenu == menu ? nil : menu
    }

    /// Bottom-right toast (showNotification in App.tsx); hides itself after a few seconds.
    func notify(_ message: String, filePath: String? = nil) {
        toast = Toast(message: message, filePath: filePath)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(filePath == nil ? 4 : 7))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Opens the Transactions view, optionally with a category preselected
    /// ("Add Entry" and the worksheet's quick-log button do the same on Windows).
    func openQuickAdd(categoryId: String? = nil) {
        preselectedCategoryId = categoryId
        selectedTab = .transactions
    }

    /// ⌘F: opens Transactions and focuses its search field.
    func openTransactionSearch() {
        selectedTab = .transactions
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kobanFocusTransactionSearch, object: nil)
        }
    }

    /// ⌘T: jumps to the current calendar month.
    func goToCurrentMonth(now: Date = Date(), calendar: Calendar = .current) {
        setMonth(year: calendar.component(.year, from: now), month: calendar.component(.month, from: now))
    }

    // MARK: - Worksheet actions (App.tsx handlers)

    func setBudget(_ amount: Double, categoryId: String) {
        let key = state.activeMonthKey
        update { $0.setBudget(amount, categoryId: categoryId, monthKey: key) }
    }

    /// Makes a scheduled category's budget follow the recurring schedule again this month.
    func resetScheduledBudget(categoryId: String) {
        let key = state.activeMonthKey
        update { $0.resetScheduledBudget(categoryId: categoryId, monthKey: key) }
    }

    func setDirectActual(_ amount: Double?, categoryId: String) {
        let key = state.activeMonthKey
        update { $0.setDirectActual(amount, categoryId: categoryId, monthKey: key) }
    }

    func renameCategory(_ id: String, to name: String) {
        update { $0.renameCategory(id, to: name) }
    }

    func toggleCategoryFixed(_ id: String) {
        update { $0.toggleCategoryFixed(id) }
    }

    func toggleCategoryRecurring(_ id: String) {
        let key = state.activeMonthKey
        let name = state.categories.first(where: { $0.id == id })?.name ?? ""
        var result: Bool?
        update { result = $0.toggleCategoryRecurring(id, monthKey: key) }
        if let result {
            notify(result ? "Marked \"\(name)\" as a recurring monthly item."
                          : "Removed \"\(name)\" from recurring items.")
        }
    }

    func deleteCategory(_ id: String) { update { $0.deleteCategory(id) } }
    func deleteGroup(_ id: String) { update { $0.deleteGroup(id) } }

    func addCategory(groupId: String, mode: LedgerMode, kind: CategoryKind, name: String, budget: Double) {
        let key = state.activeMonthKey
        update { $0.addCategory(groupId: groupId, mode: mode, kind: kind, name: name, budget: budget, monthKey: key) }
    }

    func addGroup(mode: LedgerMode, name: String, kind: CategoryKind, column: Int) {
        update { $0.addGroup(mode: mode, name: name, kind: kind, column: column) }
        notify("Created group \"\(name)\".")
    }

    func applyBudgetsToAllMonths() {
        let key = state.activeMonthKey
        update { $0.applyBudgetsToAllMonths(from: key) }
        notify("Copied \(key) planned budgets across all 12 months of \(state.settings.activeYear).")
    }

    func copyMonthValues(from source: String, to target: String, scope: MonthCopyScope,
                         overwriteExisting: Bool, navigateToTarget: Bool, disableFutureConfirm: Bool) {
        var count = 0
        update {
            count = $0.copyMonthValues(from: source, to: target, scope: scope, overwriteExisting: overwriteExisting,
                                       navigateToTarget: navigateToTarget, disableFutureConfirm: disableFutureConfirm)
        }
        notify("Copied \(scope == .budgetsAndActuals ? "budgets & actuals" : "planned budgets") (\(count) categories) from \(source) → \(target).")
    }

    func performCopy(_ request: CopyRequest, disableFutureConfirm: Bool = false) {
        if request.mode == .allMonths {
            applyBudgetsToAllMonths()
            if disableFutureConfirm { update { $0.settings.confirmBeforeMonthCopy = false } }
        } else {
            copyMonthValues(from: request.source, to: request.target, scope: request.scope,
                            overwriteExisting: request.overwriteExisting,
                            navigateToTarget: request.navigateToTarget,
                            disableFutureConfirm: disableFutureConfirm)
        }
    }

    // MARK: - Backups

    /// Ctrl+S / the TopBar check button: writes a timestamped encrypted snapshot.
    /// Without a backup folder, asks for one first (like the Windows build's folder picker).
    func manualBackup() {
        flushPendingSave()
        var dir = state.settings.localBackupDir
        if dir.isEmpty {
            let panel = NSOpenPanel()
            panel.title = "Choose Backup Folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dir = url.path
            update { $0.settings.backupDir = dir }
            saveNow()
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try BackupManager.backup(
                database: KobanPaths.activeDatabaseURL,
                to: URL(fileURLWithPath: dir, isDirectory: true),
                timestamped: true,
                maxBackups: state.settings.maxBackups > 0 ? state.settings.maxBackups : 20
            )
            update {
                $0.settings.lastBackupAt = Date().timeIntervalSince1970 * 1000
                $0.settings.lastBackupPath = url.path
            }
            notify("Encrypted backup saved.", filePath: url.path)
        } catch {
            notify("Backup failed: \(error.localizedDescription)")
        }
    }

    func revealBackupFolder() {
        let dir = state.settings.localBackupDir
        guard !dir.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    /// Encrypts and writes the ledger atomically; merges automatically if cloud sync modified the DB on disk.
    func saveNow(forceOverwrite: Bool = false) {
        pendingSave = nil
        guard phase == .ready, let vault, vault.isUnlocked else { return }
        if !forceOverwrite, let last = lastPersistedState, last == state { return }
        DeviceSettings.rememberBackupDir(state.settings.backupDir)
        do {
            try vault.save(state, forceOverwrite: forceOverwrite)
            lastPersistedState = state
            lastSavedAt = Date()
            lastSaveError = nil
        } catch VaultError.externalDatabaseModified {
            do {
                let check = try vault.checkExternalChange()
                if let extState = check.externalState {
                    let (merged, summary) = LedgerMerge.merge(local: state, remote: extState, preferLocal: true)
                    let normalized = DeviceSettings.applyBackupDir(to: merged)
                    state = normalized
                    try vault.save(normalized, forceOverwrite: true)
                    lastPersistedState = normalized
                    lastSavedAt = Date()
                    lastSaveError = nil
                    if summary.totalChanges > 0 {
                        notify("Database changed on disk — merged external updates before saving.")
                    }
                } else {
                    lastSaveError = VaultError.externalDatabaseModified.description
                    return
                }
            } catch {
                lastSaveError = DataIOMessages.text(error)
                return
            }
        } catch {
            lastSaveError = DataIOMessages.text(error)
            return
        }

        // A failed backup must not mark the save as failed or skip WebDAV sync (afterSave).
        let settings = state.settings
        if settings.autoBackup, !settings.localBackupDir.isEmpty {
            do {
                try BackupManager.backup(
                    database: vault.url,
                    to: URL(fileURLWithPath: settings.localBackupDir, isDirectory: true),
                    timestamped: false,
                    maxBackups: settings.maxBackups > 0 ? settings.maxBackups : 20
                )
                lastBackupError = nil
            } catch {
                lastBackupError = "Auto-backup failed: \(error.localizedDescription)"
            }
        } else {
            lastBackupError = nil
        }
        afterSave()
    }

    func checkExternalDatabaseChange() {
        guard phase == .ready, !isAppLocked, let vault, vault.isUnlocked else { return }
        do {
            let check = try vault.checkExternalChange()
            guard check.changed else { return }
            if let extState = check.externalState {
                let (merged, summary) = LedgerMerge.merge(local: state, remote: extState, preferLocal: true)
                let normalized = DeviceSettings.applyBackupDir(to: merged)
                state = normalized
                if summary.totalChanges > 0 {
                    try vault.save(normalized, forceOverwrite: true)
                    notify("Synced external database updates (\(summary.totalChanges) change(s)).")
                }
                lastPersistedState = normalized
            } else if check.error != nil {
                lockVault()
                notify("External database changed with updated credentials — please unlock.")
            }
        } catch {
            NSLog("External database check skipped: %@", error.localizedDescription)
        }
    }

    func mergeRemoteWebDavState(_ remoteState: LedgerState) throws {
        guard let vault, vault.isUnlocked else { throw VaultError.vaultLocked }
        let (merged, _) = LedgerMerge.merge(local: state, remote: remoteState, preferLocal: true)
        let normalized = DeviceSettings.applyBackupDir(to: merged)
        state = normalized
        try vault.save(normalized, forceOverwrite: true)
        lastPersistedState = normalized
        lastSavedAt = Date()
    }
}
