import AppKit
import Foundation
import Observation

/// Holds live Vault Format v2 status, one-time Recovery Key presentation state,
/// and inactivity / minimize / external-sync monitors on macOS.
@MainActor
@Observable
final class AuthCenter {
    static let shared = AuthCenter()

    private(set) var vaultStatus: VaultStatus?
    var pendingRecoveryKey: String?

    var authSettings: VaultAuthSettings {
        vaultStatus?.authSettings ?? .default
    }

    var hasTouchIDEnrolled: Bool {
        vaultStatus?.deviceSlotEnrolled ?? false
    }

    var rememberedKeyfileURL: URL? {
        guard let vid = vaultStatus?.vaultID else { return nil }
        return TouchIDKeychain.rememberedKeyfileURL(vaultID: vid)
    }

    @ObservationIgnored var didLaunchCheck = false

    func refresh(store: LedgerStore, force: Bool = false) {
        let url = KobanPaths.activeDatabaseURL
        if !force, let st = vaultStatus, st.dbPath == url.path,
           st.unlocked == (store.vault?.isUnlocked ?? false) {
            return
        }
        let vault = (store.vault?.url.standardizedFileURL == url.standardizedFileURL)
            ? store.vault
            : KobanVault(url: url)
        do {
            vaultStatus = try vault?.status(
                deviceSlotEnrolled: { vid in TouchIDKeychain.hasDEK(vaultID: vid) },
                isCustomLocation: KobanPaths.isCustomLocation
            )
        } catch {
            vaultStatus = nil
        }
    }

    func updateAuthSettings(_ settings: VaultAuthSettings, store: LedgerStore) {
        let url = KobanPaths.activeDatabaseURL
        let vault = (store.vault?.url.standardizedFileURL == url.standardizedFileURL)
            ? (store.vault ?? KobanVault(url: url))
            : KobanVault(url: url)
        do {
            try vault.saveAuthSettings(settings)
            refresh(store: store, force: true)
        } catch {
            store.notify("Could not save lock settings: \(error.localizedDescription)")
        }
    }
}

/// Monitors user inactivity, window minimize/hide (`lockOnMinimize`), and external cloud-folder
/// modifications (`checkExternalDatabaseChange`) on macOS.
@MainActor
enum AutoLockMonitor {
    private static var eventMonitor: Any?
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var lastActivity = Date()
    private static var lastExternalCheck = Date.distantPast
    private static weak var store: LedgerStore?

    static func install(store: LedgerStore) {
        self.store = store
        guard eventMonitor == nil else { return }
        lastActivity = Date()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            lastActivity = Date()
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in handleMinimizeIfEnabled() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in handleMinimizeIfEnabled() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in triggerExternalCheckIfReady() }
        })
    }

    static func resetIdle() { lastActivity = Date() }

    private static func handleMinimizeIfEnabled() {
        guard let store, store.isUnlockedAndReady else { return }
        if AuthCenter.shared.authSettings.lockOnMinimize {
            store.lockVault()
        }
    }

    private static func triggerExternalCheckIfReady() {
        guard let store, store.isUnlockedAndReady else { return }
        guard Date().timeIntervalSince(lastExternalCheck) >= 3 else { return }
        lastExternalCheck = Date()
        store.checkExternalDatabaseChange()
    }

    private static func tick() {
        guard let store, store.isReady, !store.isAppLocked else {
            lastActivity = Date()
            return
        }
        let minutes = AuthCenter.shared.authSettings.autoLockMinutes
        if minutes > 0, Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 {
            store.lockVault()
            return
        }
        if Date().timeIntervalSince(lastExternalCheck) >= 30 {
            triggerExternalCheckIfReady()
        }
    }
}
