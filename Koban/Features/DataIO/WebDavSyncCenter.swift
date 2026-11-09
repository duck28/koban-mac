import AppKit
import Foundation
import Observation
import SwiftUI

// OWNER: Data I/O — WebDAV backup / primary storage (WEBDAV-SPEC.md §4–§5).
// The engine lives in KobanCore (WebDav.check / push / pull + the `<db>.webdav-sync.json` state);
// this file schedules it: startup, debounced push after saves, every 5 minutes, on app focus,
// one operation at a time, plus the conflict dialog and the pause state.

/// Live WebDAV sync state shown by WebDavSyncCard (extensions can't add stored properties to LedgerStore).
@MainActor
@Observable
final class WebDavSyncCenter {
    static let shared = WebDavSyncCenter()

    enum Status: Equatable {
        case none
        case syncing
        case synced(Date)
        case offline
        case paused
        case error(String)
    }

    struct ConflictInfo: Equatable {
        var firstLink: Bool
        var remoteLastModified: String?
        var localSavedAt: Date?
    }

    static let conflictModalId = "dataio.webdav-conflict"
    static let connectModalId = "dataio.webdav-connect"
    static let offlineMessage = "Offline — working from the local cache. Changes will sync when the server is reachable."
    static let pausedMessage = "Sync paused — the cloud vault and this device both changed."

    var status: Status = .none
    /// Last result message of an automatic operation (in memory).
    private(set) var lastMessage: String?
    private(set) var isPaused = false
    private(set) var isConflictOpen = false
    /// The conflict the dialog shows (also kept while paused for "Resolve…").
    private(set) var conflict: ConflictInfo?
    var isBusy: Bool { running }

    @ObservationIgnored private weak var store: LedgerStore?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var queued: Op?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private var presentWhenFree = false
    /// Settings to apply once the vault downloaded by "Open Vault from WebDAV…" is loaded (it may need its passphrase first).
    @ObservationIgnored var pendingConnect: WebDavConfig?
    /// Debug snapshots with a demo config: no network.
    @ObservationIgnored private var debugFrozen = false

    enum Op: Int, Comparable {
        case pushIfDirty = 0
        case syncNow = 1
        static func < (a: Op, b: Op) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: - Configuration

    /// The config when automatic sync applies: enabled, complete credentials, ledger loaded.
    static func activeConfig(_ store: LedgerStore) -> WebDavConfig? {
        guard store.phase == .ready, let w = store.state.settings.webdav, w.enabled,
              !w.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !w.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(w.password ?? "").isEmpty else { return nil }
        return w
    }

    static func primaryConfig(_ store: LedgerStore) -> WebDavConfig? {
        guard let w = activeConfig(store), w.effectiveMode == .primary else { return nil }
        return w
    }

    private var canAutoSync: Bool { !isPaused && !isConflictOpen }

    // MARK: - Lifecycle

    /// Timer (every 5 minutes) + app focus. Installed once; both only act in primary mode.
    func install(store: LedgerStore) {
        self.store = store
        guard timer == nil else { return }
        let t = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in WebDavSyncCenter.shared.automaticSync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WebDavSyncCenter.shared.automaticSync() }
        }
    }

    /// Periodic / focus trigger.
    func automaticSync() {
        guard let store, Self.primaryConfig(store) != nil, canAutoSync else { return }
        enqueue(.syncNow)
    }

    /// After every successful local save (primary mode): debounce 2 s, then push(force: false).
    func scheduleDebouncedPush() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let store = self.store,
                  Self.primaryConfig(store) != nil, self.canAutoSync else { return }
            self.enqueue(.pushIfDirty)
        }
    }

    /// "Sync now" (card) — also lifts a pause; a remaining conflict reopens the dialog.
    func syncNowManually() {
        isPaused = false
        enqueue(.syncNow, manual: true)
    }

    /// Mode switched in the card. Leaving primary clears the pause; entering it syncs right away.
    func modeChanged(to mode: WebDavMode) {
        if mode == .backup {
            isPaused = false
            conflict = nil
            if case .paused = status { status = .none }
            if case .offline = status { status = .none }
        } else {
            enqueue(.syncNow)
        }
    }

    // MARK: - Serial runner

    /// Never two sync operations at once; at most one follow-up is queued (the stronger one wins).
    func enqueue(_ op: Op, manual: Bool = false) {
        guard let store, Self.primaryConfig(store) != nil, !debugFrozen else { return }
        guard manual || canAutoSync else { return }
        if running {
            queued = max(queued ?? op, op)
            return
        }
        running = true
        Task { @MainActor in
            var next: Op? = op
            while let current = next {
                await run(current)
                next = queued
                queued = nil
                if next != nil, !canAutoSync || Self.primaryConfig(store) == nil { next = nil }
            }
            running = false
        }
    }

    /// Waits for the running operation, then runs `work` exclusively (conflict resolutions, manual push/pull).
    func exclusive<T>(_ work: () async throws -> T) async rethrows -> T {
        while running { try? await Task.sleep(for: .milliseconds(100)) }
        running = true
        defer {
            running = false
            // Follow-ups requested meanwhile (e.g. by the reload after a pull) are covered by this operation.
            queued = nil
        }
        return try await work()
    }

    private func run(_ op: Op) async {
        guard let store, let c = Self.primaryConfig(store) else { return }
        let db = store.activeDatabaseFile
        if op == .pushIfDirty {
            let target = WebDav.targetURL(c)
            if let s = WebDav.loadSyncState(for: db, target: target) {
                if !WebDav.isLocalDirty(db, state: s) { return }
                await push(store, c, force: false, initialized: false)
                return
            }
            // No sync state: never overwrite blindly — check first (may be a first-link conflict).
        }
        store.flushPendingSave()
        setStatus(.syncing)
        let r = await WebDav.check(localDatabase: db, config: c)
        await handle(r, store: store, config: c)
    }

    private func handle(_ r: WebDavCheckResult, store: LedgerStore, config c: WebDavConfig, recheck: Bool = true) async {
        let db = store.activeDatabaseFile
        switch r.status {
        case .inSync:
            let s = WebDav.loadSyncState(for: db, target: WebDav.targetURL(c))
            setStatus(.synced(s.map { Date(timeIntervalSince1970: Double($0.syncedAt)) } ?? Date()))
        case .remoteMissing:
            await push(store, c, force: true, initialized: true)
        case .localAhead:
            await push(store, c, force: false, initialized: false)
        case .remoteAhead:
            // Flush a pending local save first; if that dirties the local file it's a conflict.
            store.flushPendingSave()
            if recheck, WebDav.isLocalDirty(db, state: WebDav.loadSyncState(for: db, target: WebDav.targetURL(c))) {
                let again = await WebDav.check(localDatabase: db, config: c)
                await handle(again, store: store, config: c, recheck: false)
                return
            }
            do {
                try await pullAndReload(store, c)
                store.notify("Loaded the latest vault from WebDAV.")
            } catch {
                fail(error)
            }
        case .conflict:
            presentConflict(ConflictInfo(firstLink: r.firstLink, remoteLastModified: r.remoteLastModified,
                                         localSavedAt: store.lastSavedAt ?? Self.fileDate(db)))
        case .offline:
            setStatus(.offline)
        case .error:
            setStatus(.error(r.message))
        }
    }

    private func push(_ store: LedgerStore, _ c: WebDavConfig, force: Bool, initialized: Bool) async {
        setStatus(.syncing)
        do {
            let res = try await WebDav.push(localDatabase: store.activeDatabaseFile, url: c.url, username: c.username,
                                            password: c.password ?? "", filename: c.remoteFileName, force: force)
            setStatus(.synced(Date(timeIntervalSince1970: res.timestamp)), message: res.message)
            if initialized { store.notify("Cloud vault initialized on WebDAV.") }
        } catch let e as WebDavError where e.isConflict {
            // Show the dialog with what the server reports now.
            let r = await WebDav.check(localDatabase: store.activeDatabaseFile, config: c)
            if r.status == .conflict {
                presentConflict(ConflictInfo(firstLink: r.firstLink, remoteLastModified: r.remoteLastModified,
                                             localSavedAt: store.lastSavedAt))
            } else if r.status == .offline {
                setStatus(.offline)
            } else {
                presentConflict(ConflictInfo(firstLink: false, remoteLastModified: r.remoteLastModified,
                                             localSavedAt: store.lastSavedAt))
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        if let e = error as? WebDavError, e.isOffline { setStatus(.offline); return }
        setStatus(.error(DataIOMessages.text(error)))
    }

    /// Pull + reload like the manual Pull, keeping this device's WebDAV settings in memory
    /// (not saved, so devices with different credentials don't keep re-uploading each other's settings).
    private func pullAndReload(_ store: LedgerStore, _ c: WebDavConfig) async throws {
        setStatus(.syncing)
        let (data, result) = try await WebDav.download(url: c.url, username: c.username, password: c.password ?? "",
                                                       filename: c.remoteFileName)
        let keep = store.state.settings.webdav ?? c
        try store.installWebDavDownload(data, result: result)
        if store.phase == .ready {
            store.state.settings.webdav = keep
        }
        setStatus(.synced(Date(timeIntervalSince1970: result.timestamp)), message: result.message)
    }

    // MARK: - Status

    /// Live status of automatic sync. Kept in memory only — writing it into `settings.webdav.lastSync*`
    /// would change the ledger, save, push and loop. (Manual card actions still record lastSync* like today.)
    func setStatus(_ s: Status, message: String? = nil) {
        status = s
        if let message { lastMessage = message }
    }

    static func fileDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Conflict dialog (§5)

    func presentConflict(_ info: ConflictInfo) {
        conflict = info
        isConflictOpen = true
        setStatus(.paused)
        showDialogIfPossible()
    }

    /// "Resolve…" while paused.
    func reopenConflict() {
        guard let conflict else { syncNowManually(); return }
        presentConflict(conflict)
    }

    /// The dialog waits while the app is locked or another modal (wizard, import …) is open.
    private func showDialogIfPossible() {
        guard let store, isConflictOpen, let info = conflict else { return }
        let free = store.phase == .ready && !store.isAppLocked
            && (store.modal == nil || store.modal?.id == Self.conflictModalId)
        if free {
            presentWhenFree = false
            store.present(Self.conflictModalId, dismissOnBackdrop: false) {
                WebDavConflictModal(info: info).environment(store)
            }
            return
        }
        guard !presentWhenFree else { return }
        presentWhenFree = true
        watchUntilFree(store)
    }

    private func watchUntilFree(_ store: LedgerStore) {
        withObservationTracking {
            _ = store.isAppLocked
            _ = store.modal?.id
            _ = store.phase
        } onChange: {
            Task { @MainActor in
                let center = WebDavSyncCenter.shared
                guard center.presentWhenFree else { return }
                center.presentWhenFree = false
                center.showDialogIfPossible()
            }
        }
    }

    enum Resolution { case useCloud, keepLocal, decideLater, cancelFirstLink }

    func resolve(_ choice: Resolution) async {
        guard let store else { return }
        let c = Self.activeConfig(store) ?? store.state.settings.webdav
        switch choice {
        case .decideLater:
            isConflictOpen = false
            isPaused = true
            setStatus(.paused)
            store.dismissModal()
            return
        case .cancelFirstLink:
            isConflictOpen = false
            isPaused = false
            conflict = nil
            store.dismissModal()
            store.applySettingsChange { $0.webdav?.mode = .backup }
            status = .none
            return
        case .useCloud, .keepLocal:
            break
        }
        guard let c else { return }
        await exclusive {
            do {
                if choice == .useCloud {
                    store.flushPendingSave()
                    try await pullAndReload(store, c)
                    store.notify("Loaded the latest vault from WebDAV.")
                } else {
                    store.flushPendingSave()
                    let db = store.activeDatabaseFile
                    let copy = try await WebDav.saveRemoteConflictCopy(next: db, url: c.url, username: c.username,
                                                                       password: c.password ?? "", filename: c.remoteFileName)
                    let res = try await WebDav.push(localDatabase: db, url: c.url, username: c.username,
                                                    password: c.password ?? "", filename: c.remoteFileName, force: true)
                    setStatus(.synced(Date(timeIntervalSince1970: res.timestamp)), message: res.message)
                    store.notify(copy == nil ? "Uploaded this device's vault to WebDAV."
                                             : "Uploaded this device's vault to WebDAV. The previous cloud copy was kept as \(copy!.lastPathComponent).",
                                 filePath: copy?.path)
                }
                isConflictOpen = false
                isPaused = false
                conflict = nil
                if store.modal?.id == Self.conflictModalId { store.dismissModal() }
            } catch {
                isConflictOpen = false
                isPaused = true
                if store.modal?.id == Self.conflictModalId { store.dismissModal() }
                fail(error)
                if case .offline = status {} else { store.notify("WebDAV sync failed: \(DataIOMessages.text(error))") }
            }
        }
    }

    /// Manual Push / Pull in the card succeeded: the device is in sync again.
    func manualSyncSucceeded(_ res: WebDavSyncResult) {
        isPaused = false
        isConflictOpen = false
        conflict = nil
        status = .synced(Date(timeIntervalSince1970: res.timestamp))
    }

    // MARK: - New device (§6 "Open Vault from WebDAV…")

    /// Downloads the vault into the active local DB path, writes the sync state and reloads.
    /// The WebDAV settings are applied (and saved) once the ledger is loaded — after the
    /// passphrase screen for a custom-passphrase vault.
    func connectNewDevice(_ store: LedgerStore, config: WebDavConfig) async throws {
        self.store = store
        let (data, result) = try await WebDav.download(url: config.url, username: config.username,
                                                       password: config.password ?? "", filename: config.remoteFileName)
        pendingConnect = config
        do {
            // Reloading runs webDavAfterLoad, which applies pendingConnect once the ledger is open.
            try store.installWebDavDownload(data, result: result)
        } catch {
            pendingConnect = nil
            throw error
        }
        // Still pending only while the vault waits for its passphrase; any other outcome drops it.
        if case .locked = store.phase { return }
        pendingConnect = nil
    }

    /// Called by LedgerStore.webDavAfterLoad: finish a pending "Open Vault from WebDAV…".
    func applyPendingConnect(_ store: LedgerStore) {
        guard let entered = pendingConnect, store.phase == .ready else { return }
        pendingConnect = nil
        var next = store.state.settings.webdav ?? entered
        next.enabled = true
        next.mode = .primary
        next.url = entered.url
        next.username = entered.username
        next.password = entered.password
        next.remoteFileName = entered.remoteFileName
        next.lastSyncAt = WebDav.nowSecs()
        next.lastSyncStatus = .success
        next.lastSyncMessage = "Vault downloaded from WebDAV."
        store.state.settings.webdav = next
        store.saveNow()
        store.notify("Opened your vault from WebDAV. This device now uses it as primary storage.")
    }
}

#if DEBUG
extension WebDavSyncCenter {
    /// KOBAN_SNAPSHOT_ACTION=webdav-* demo states (in-memory demo config; nothing is saved or sent).
    func debugDemo(_ name: String, store: LedgerStore) {
        self.store = store
        debugFrozen = true
        let now = Date()
        var demo = store.state.settings.webdav ?? WebDavConfig(enabled: true, url: "", username: "", password: nil)
        demo.enabled = true
        if demo.url.isEmpty { demo.url = "https://cloud.example.com/remote.php/dav/files/me/Koban/" }
        if demo.username.isEmpty { demo.username = "me" }
        if (demo.password ?? "").isEmpty { demo.password = "app-token" }
        demo.mode = name == "webdav-demo-backup" ? .backup : .primary
        demo.lastSyncAt = now.timeIntervalSince1970 - 180
        demo.lastSyncStatus = .success
        store.state.settings.webdav = demo
        let remote = "Sun, 08 Nov 2026 21:14:05 GMT"
        switch name {
        case "webdav-demo-primary": status = .synced(now.addingTimeInterval(-180))
        case "webdav-demo-offline": status = .offline
        case "webdav-demo-syncing": status = .syncing
        case "webdav-demo-error": status = .error(WebDav.authFailedMessage)
        case "webdav-demo-paused":
            conflict = ConflictInfo(firstLink: false, remoteLastModified: remote, localSavedAt: now.addingTimeInterval(-600))
            isPaused = true
            status = .paused
        case "webdav-conflict":
            presentConflict(ConflictInfo(firstLink: false, remoteLastModified: remote, localSavedAt: now.addingTimeInterval(-600)))
        case "webdav-conflict-first":
            presentConflict(ConflictInfo(firstLink: true, remoteLastModified: remote, localSavedAt: now.addingTimeInterval(-600)))
        default: break
        }
    }
}
#endif

// MARK: - LedgerStore hooks

extension LedgerStore {
    /// The local DB file the open vault uses.
    var activeDatabaseFile: URL { vault?.url ?? databaseURL }

    /// Called right after a ledger is loaded from the local DB (LedgerStore.openVault): finishes a
    /// pending "Open Vault from WebDAV…" and, in primary mode, runs sync-now (startup sync, §4.1).
    func webDavAfterLoad() {
        let center = WebDavSyncCenter.shared
        center.install(store: self)
        center.applyPendingConnect(self)
        center.automaticSync()
    }

    /// Closes the vault, installs a downloaded DB file (keeping koban-pre-webdav-sync-<secs>.db and
    /// writing the sync state) and reloads the ledger. The app lock stays as it was.
    func installWebDavDownload(_ data: Data, result: WebDavSyncResult) throws {
        flushPendingSave()
        let pass = vault?.passphrase
        let local = activeDatabaseFile
        let wasLocked = isAppLocked
        vault = nil
        do {
            try WebDav.installDownloadedDatabase(data, at: local, result: result)
        } catch {
            reopenVault(passphrase: pass)
            throw error
        }
        reopenVault(passphrase: pass)
        if wasLocked, phase == .ready { isAppLocked = true }
    }

    /// First-run "Open Vault from WebDAV…" form.
    func presentWebDavConnect() {
        present(WebDavSyncCenter.connectModalId, dismissOnBackdrop: false) {
            WebDavConnectModal().environment(self)
        }
    }
}
