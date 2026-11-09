import Foundation

/// Settings that belong to this Mac rather than the shared (synced) ledger.
///
/// `settings.backupDir` is stored inside the ledger, so with one vault shared by several devices a
/// folder chosen on Windows (`C:\…`) would show up here and vice versa. Each device keeps its own
/// folder in its preferences and overlays it on every ledger it loads (same key and rules as the
/// Windows build's `applyDeviceBackupDir` in src/utils/storage.ts).
@MainActor
enum DeviceSettings {
    static let backupDirKey = "koban_device_backup_dir_v1"

    /// Dev runs against a scratch vault (KOBAN_DB_PATH) keep the value in memory only, so they
    /// never change the real app's preference.
    private static var isolated: Bool { DataIOStorage.locationOverrideActive }
    private static var scratchBackupDir: String?

    /// This device's backup folder: nil = never set, "" = none.
    static var backupDir: String? {
        get { isolated ? scratchBackupDir : UserDefaults.standard.string(forKey: backupDirKey) }
        set {
            if isolated { scratchBackupDir = newValue; return }
            UserDefaults.standard.set(newValue, forKey: backupDirKey)
        }
    }

    /// Remembers the folder currently in the ledger as this device's choice.
    static func rememberBackupDir(_ dir: String) {
        if backupDir != dir { backupDir = dir }
    }

    /// Replaces the ledger's backup folder with this device's. On first use the ledger's folder is
    /// adopted when it is a valid path on this Mac (otherwise none).
    static func applyBackupDir(to state: LedgerState) -> LedgerState {
        let dir: String
        if let stored = backupDir {
            dir = stored
        } else {
            dir = state.settings.localBackupDir
            backupDir = dir
        }
        guard state.settings.backupDir != dir else { return state }
        var next = state
        next.settings.backupDir = dir
        return next
    }
}
