import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Shared, observable Data I/O state (extensions can't add stored properties to LedgerStore):
/// database info and the backup list shown by BackupsView / DbLocationCard, plus the
/// background WebDAV auto-sync bookkeeping.
@MainActor
@Observable
final class DataIOCenter {
    static let shared = DataIOCenter()

    var dbInfo: DbInfo?
    var backups: [BackupEntry] = []
    var isLoadingBackups = false

    @ObservationIgnored private var autoSyncRunning = false
    @ObservationIgnored private var autoSyncQueued = false

    /// refreshInfo() in BackupsExportView.tsx / DbLocationCard.tsx (get_db_info + list_backups).
    func refresh(_ store: LedgerStore) {
        isLoadingBackups = true
        dbInfo = store.vault?.info(isCustomLocation: KobanPaths.isCustomLocation)
            ?? DataIOStorage.info(forDatabaseAt: store.databaseURL)
        backups = DataIOStorage.listBackups(in: store.state.settings.localBackupDir)
        isLoadingBackups = false
    }

    /// Backup mode: background forced push after a save (saveLedgerToDb in storage.ts). Failures are only
    /// logged, like the Windows build's console.warn. Saves arriving mid-upload queue one more push.
    /// A successful push records the sync state (WEBDAV-SPEC §2).
    func autoPush(database: URL, config: WebDavConfig) {
        if autoSyncRunning { autoSyncQueued = true; return }
        autoSyncRunning = true
        Task { @MainActor in
            defer { autoSyncRunning = false }
            repeat {
                autoSyncQueued = false
                do {
                    let res = try await WebDav.push(localDatabase: database, url: config.url, username: config.username,
                                                    password: config.password ?? "", filename: config.remoteFileName,
                                                    force: true)
                    WebDavSyncCenter.shared.setStatus(.synced(Date(timeIntervalSince1970: res.timestamp)), message: res.message)
                } catch {
                    NSLog("Background WebDAV auto-sync failed: %@", DataIOMessages.text(error))
                }
            } while autoSyncQueued
        }
    }
}

enum DataIOMessages {
    /// `String(err)` for the Tauri error strings.
    static func text(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

/// NSOpenPanel / NSSavePanel replacements for pick_folder / pick_open_file / pick_save_file.
enum DataIOPanels {
    @MainActor
    static func save(defaultName: String, extensions: [String], title: String = "Export File") -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func open(extensions: [String], title: String = "Select File") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func folder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// reveal_in_explorer → Finder (selects files, opens folders).
    @MainActor
    static func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

// OWNER: Data I/O — hooks called by the TopBar, menus and LedgerStore.saveNow(), plus the
// backup / import / export handlers of App.tsx (~1402–1660).
extension LedgerStore {
    // MARK: - Hooks (signatures used by the shell)

    /// TopBar "Import" / ⌘I: opens the Import Data modal (ImportDataModal.tsx).
    func openImport() { presentImportModal(initialPreview: nil) }

    /// handleExportExcel
    func exportExcel() {
        let mk = state.activeMonthKey
        let ws = state.settings.activeWorkspace
        guard let url = DataIOPanels.save(defaultName: LedgerExports.excelFileName(workspace: ws, monthKey: mk),
                                          extensions: ["xlsx"]) else { return }
        do {
            try XLSXWriter.write(LedgerExports.workbook(state, monthKey: mk, workspace: ws), to: url)
            notify("Exported multi-sheet Excel workbook (.xlsx).", filePath: url.path)
        } catch {
            notify("Export error: \(DataIOMessages.text(error))")
        }
    }

    /// handleExportBudgetCsv
    func exportBudgetCSV() {
        let mk = state.activeMonthKey
        let ws = state.settings.activeWorkspace
        guard let url = DataIOPanels.save(defaultName: LedgerExports.budgetCSVFileName(workspace: ws, monthKey: mk),
                                          extensions: ["csv"]) else { return }
        do {
            try LedgerExports.monthlyBudgetCSV(state, monthKey: mk, workspace: ws).write(to: url, options: .atomic)
            notify("Exported Monthly Budget CSV (.csv).", filePath: url.path)
        } catch {
            notify("Export error: \(DataIOMessages.text(error))")
        }
    }

    /// handleExportTransactionsCsv
    func exportTransactionsCSV() {
        let ws = state.settings.activeWorkspace
        guard let url = DataIOPanels.save(defaultName: LedgerExports.transactionsCSVFileName(workspace: ws, year: state.settings.activeYear),
                                          extensions: ["csv"]) else { return }
        do {
            try LedgerExports.transactionsCSV(state, workspace: ws).write(to: url, options: .atomic)
            notify("Exported Transactions & Tax CSV (.csv).", filePath: url.path)
        } catch {
            notify("Export error: \(DataIOMessages.text(error))")
        }
    }

    /// Called after every successful encrypted save: WebDAV auto-sync (saveLedgerToDb in storage.ts).
    /// Backup mode: forced fire-and-forget push when autoSync is on. Primary mode: debounced (2 s)
    /// conditional push through WebDavSyncCenter (autoSync implied).
    func afterSave() {
        guard let w = WebDavSyncCenter.activeConfig(self) else { return }
        if w.effectiveMode == .primary {
            WebDavSyncCenter.shared.install(store: self)
            WebDavSyncCenter.shared.scheduleDebouncedPush()
        } else if w.autoSync == true {
            DataIOCenter.shared.autoPush(database: activeDatabaseFile, config: w)
        }
    }

    // MARK: - Import modal

    func presentImportModal(initialPreview: ImportPreviewData?) {
        present("dataio.import", dismissOnBackdrop: false) {
            ImportDataModal(initialPreview: initialPreview)
        }
    }

    /// The modal's default target (`activeWorkspace === 'freelancer' ? 'freelancer' : 'home'`).
    var importDefaultMode: LedgerMode { state.settings.activeWorkspace == .freelancer ? .freelancer : .home }

    /// handlePrepareImport: asks for a file and builds the preview (nil when cancelled or failed).
    func prepareImport(kind: ImportKind, targetMode: LedgerMode, passphrase: String?) -> ImportPreviewData? {
        do {
            if kind == .databaseBackup {
                guard let url = DataIOPanels.open(extensions: ["db", "sqlite", "json"]) else { return nil }
                let restored = try DataIOStorage.readBackup(at: url, passphrase: passphrase, sessionPassphrase: vault?.passphrase)
                return ImportPreviewData(kind: .databaseBackup, targetMode: targetMode, fileName: url.lastPathComponent,
                                         proposedState: restored, importedCount: ImportPreviewData.backupRecordCount(restored),
                                         backupPath: url.path)
            }
            guard let url = DataIOPanels.open(extensions: ["xlsx", "xls", "csv"]) else { return nil }
            let wb = try SpreadsheetReader.read(url: url)
            return buildImportPreview(kind: kind, workbook: wb, fileName: url.lastPathComponent, targetMode: targetMode)
        } catch {
            notify("Import error: \(DataIOMessages.text(error))")
            return nil
        }
    }

    /// Spreadsheet half of handlePrepareImport (budget sheet or transactions).
    func buildImportPreview(kind: ImportKind, workbook wb: WorkbookData, fileName: String, targetMode: LedgerMode) -> ImportPreviewData {
        let mk = state.activeMonthKey
        if kind == .budgetSheet {
            let res = LedgerImports.importBudgetSheet(wb, currentState: state, targetMode: targetMode, monthKey: mk)
            var proposed = res.state
            proposed.settings.setupCompleted = true
            return ImportPreviewData(kind: .budgetSheet, targetMode: targetMode, fileName: fileName, sheetName: res.sheetName,
                                     proposedState: proposed, importedCount: res.importedCategories, budgetRows: res.previewRows)
        }
        let res = LedgerImports.importTransactions(wb, currentState: state, targetMode: targetMode, fallbackMonthKey: mk)
        var proposed = res.state
        proposed.settings.setupCompleted = true
        return ImportPreviewData(kind: .transactions, targetMode: targetMode, fileName: fileName, sheetName: res.sheetName,
                                 proposedState: proposed, importedCount: res.importedTransactions, transactionRows: res.previewRows)
    }

    /// handleCommitImport
    func commitImport(_ preview: ImportPreviewData) {
        let mk = state.activeMonthKey
        update { $0 = preview.proposedState }
        dismissModal()
        switch preview.kind {
        case .databaseBackup:
            // A restored backup replaces the local vault: it no longer matches the last WebDAV sync.
            WebDav.deleteSyncState(for: activeDatabaseFile)
            applyAppearance()
            notify("Restored backup snapshot \"\(preview.fileName)\" (\(preview.importedCount) records).", filePath: preview.backupPath)
        case .budgetSheet:
            notify("Imported \(preview.importedCount) categories & budget rows from \"\(preview.fileName)\" into \(mk).")
        case .transactions:
            selectedTab = .transactions
            notify("Imported \(preview.importedCount) transaction(s) from \"\(preview.fileName)\" into \(preview.targetMode.rawValue) ledger.")
        }
    }

    // MARK: - Backups

    /// handleRestoreFromPath: previews (or directly restores) a backup snapshot.
    func restoreBackup(at path: String, passphrase: String? = nil) {
        do {
            let url = URL(fileURLWithPath: path)
            let restored = try DataIOStorage.readBackup(at: url, passphrase: passphrase, sessionPassphrase: vault?.passphrase)
            if state.settings.confirmAndPreviewBeforeImport ?? true {
                presentImportModal(initialPreview: ImportPreviewData(
                    kind: .databaseBackup, targetMode: importDefaultMode, fileName: url.lastPathComponent,
                    proposedState: restored, importedCount: ImportPreviewData.backupRecordCount(restored), backupPath: path))
                return
            }
            update { $0 = restored }
            WebDav.deleteSyncState(for: activeDatabaseFile)
            applyAppearance()
            notify("Encrypted database restored from backup snapshot.", filePath: path)
        } catch {
            notify("Restore failed: \(DataIOMessages.text(error))")
        }
    }

    /// handleExportSqliteCopy (copy_db_file).
    func exportDatabaseCopy(to url: URL) {
        flushPendingSave()
        do {
            try DataIOStorage.copyDatabase(from: vault?.url ?? databaseURL, to: url)
            notify("Exported encrypted SQLite database (.db).", filePath: url.path)
        } catch {
            notify(DataIOMessages.text(error))
        }
    }

    /// handleReloadLedgerState: re-reads the ledger from the active database.
    func reloadLedgerState() {
        let pass = vault?.passphrase
        reopenVault(passphrase: pass)
        if phase == .ready || phase == .needsSetup {
            notify("Ledger state reloaded from synchronized database.")
        }
    }

    // MARK: - Database location (move_database_location / reset_database_location)

    func moveDatabase(toFolder folder: String) throws {
        if DataIOStorage.locationOverrideActive { throw DataIOStorage.StorageError(DataIOStorage.overrideMessage) }
        flushPendingSave()
        let pass = vault?.passphrase
        let current = vault?.url ?? databaseURL
        vault = nil // close the SQLite handle before copying
        defer { reopenVault(passphrase: pass) }
        try DataIOStorage.moveDatabase(toFolder: folder, current: current)
    }

    func resetDatabaseLocation() throws {
        if DataIOStorage.locationOverrideActive { throw DataIOStorage.StorageError(DataIOStorage.overrideMessage) }
        flushPendingSave()
        let pass = vault?.passphrase
        let current = vault?.url ?? databaseURL
        vault = nil
        defer { reopenVault(passphrase: pass) }
        try DataIOStorage.resetDatabaseLocation(current: current)
    }

    // MARK: - WebDAV

    /// Manual Push. Backup mode always overwrites (force); primary mode is conditional and a
    /// WEBDAV_CONFLICT opens the conflict dialog.
    func webDavPush(_ c: WebDavConfig) async throws -> WebDavSyncResult {
        let center = WebDavSyncCenter.shared
        center.install(store: self)
        do {
            let res = try await center.exclusive {
                flushPendingSave()
                return try await WebDav.push(localDatabase: activeDatabaseFile, url: c.url, username: c.username,
                                             password: c.password ?? "", filename: c.remoteFileName,
                                             force: c.effectiveMode != .primary)
            }
            center.manualSyncSucceeded(res)
            return res
        } catch let e as WebDavError where e.isConflict {
            center.syncNowManually()
            throw e
        }
    }

    /// pull_from_webdav + onStateReloaded: downloads, swaps the database file, records the sync
    /// state and reloads the ledger.
    func webDavPull(_ c: WebDavConfig) async throws -> WebDavSyncResult {
        let center = WebDavSyncCenter.shared
        center.install(store: self)
        let result = try await center.exclusive {
            let (data, result) = try await WebDav.download(url: c.url, username: c.username, password: c.password ?? "",
                                                           filename: c.remoteFileName)
            try installWebDavDownload(data, result: result)
            return result
        }
        center.manualSyncSucceeded(result)
        if phase == .ready || phase == .needsSetup {
            notify("Ledger state reloaded from synchronized database.")
        }
        return result
    }
}
