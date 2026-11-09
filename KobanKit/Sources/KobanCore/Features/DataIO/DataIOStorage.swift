import Foundation

/// Ports of the file-level Tauri commands in src-tauri/src/lib.rs used by the Backups view:
/// list_backups, restore_backup_file, copy_db_file, move_database_location,
/// reset_database_location, get_db_info.
enum DataIOStorage {
    struct StorageError: Error, LocalizedError, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// list_backups: every .db / .sqlite file in the folder, newest first; [] when the folder is missing.
    static func listBackups(in dir: String) -> [BackupEntry] {
        var isDir: ObjCBool = false
        guard !dir.isEmpty, FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return [] }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { u -> BackupEntry? in
            let name = u.lastPathComponent
            guard name.hasSuffix(".db") || name.hasSuffix(".sqlite"),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return BackupEntry(name: name, url: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// restore_backup_file (preview part): decrypts a .db / .sqlite backup with the given
    /// passphrase (falling back to `sessionPassphrase`, like the Rust session key), or parses a
    /// plain .json snapshot (UTF-8 BOM tolerated).
    static func readBackup(at url: URL, passphrase: String?, sessionPassphrase: String?) throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: url.path) else { throw StorageError("Backup file does not exist.") }
        let ext = url.pathExtension.lowercased()
        if ext == "db" || ext == "sqlite" {
            let secret = (passphrase?.isEmpty == false) ? passphrase : sessionPassphrase
            let vault: KobanVault
            do {
                vault = try KobanVault(url: url, passphrase: secret)
            } catch {
                throw StorageError("Failed to open backup SQLite database: \(error)")
            }
            guard let state = try vault.load() else {
                throw StorageError("No encrypted ledger data found in backup database.")
            }
            return state
        }
        var data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        do {
            return try JSONDecoder().decode(LedgerState.self, from: data)
        } catch {
            throw StorageError("The file is not a valid Koban JSON backup: \(error.localizedDescription)")
        }
    }

    /// copy_db_file
    static func copyDatabase(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        do {
            if source.standardizedFileURL == target.standardizedFileURL { return }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        } catch {
            throw StorageError("Failed to export encrypted SQLite DB: \(error.localizedDescription)")
        }
    }

    /// Where move_database_location puts the file: a path ending in .db is used as is,
    /// anything else is treated as a folder that receives koban.db.
    static func targetDatabaseURL(forFolder folder: String) throws -> URL {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StorageError("Target folder path cannot be empty.") }
        let input = URL(fileURLWithPath: trimmed)
        return input.pathExtension == "db" ? input : input.appendingPathComponent("koban.db")
    }

    /// KOBAN_DB_PATH (developer override) pins the database; the location pointer must not be
    /// rewritten then, since it lives in the real Application Support folder and would be ignored.
    static var locationOverrideActive: Bool {
        !(ProcessInfo.processInfo.environment["KOBAN_DB_PATH"] ?? "").isEmpty
    }

    static let overrideMessage = "The database location is pinned by the KOBAN_DB_PATH environment variable (developer override) and can't be changed in this session."

    /// -wal / -shm plus the per-device WebDAV sync state (`<db>.webdav-sync.json`), which must travel with the DB.
    private static func copySidecars(from current: URL, to target: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm", WebDav.syncStateSuffix] {
            let cur = URL(fileURLWithPath: current.path + suffix)
            let tgt = URL(fileURLWithPath: target.path + suffix)
            // A stale sidecar at the destination belongs to the file that was just replaced.
            try? fm.removeItem(at: tgt)
            guard fm.fileExists(atPath: cur.path) else { continue }
            try? fm.copyItem(at: cur, to: tgt)
        }
    }

    /// move_database_location: copies the active DB (plus -wal/-shm) into the folder and points
    /// Koban at it via db_location.txt. Returns the new database URL.
    @discardableResult
    static func moveDatabase(toFolder folder: String, current: URL = KobanPaths.activeDatabaseURL) throws -> URL {
        let fm = FileManager.default
        let target = try targetDatabaseURL(forFolder: folder)
        if locationOverrideActive { throw StorageError(overrideMessage) }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw StorageError("Failed to create destination folder: \(error.localizedDescription)")
        }
        if current.standardizedFileURL == target.standardizedFileURL { return target }

        if fm.fileExists(atPath: current.path) {
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: current, to: target)
            } catch {
                throw StorageError("Failed to copy active SQLite database: \(error.localizedDescription)")
            }
            copySidecars(from: current, to: target)
        } else {
            do { _ = try KobanVault(url: target) } catch {
                throw StorageError("Failed to create new SQLite database: \(error)")
            }
        }
        do {
            try KobanPaths.useDatabase(at: target)
        } catch {
            throw StorageError("Failed to save location pointer: \(error.localizedDescription)")
        }
        return target
    }

    /// reset_database_location: copies a custom-location DB back to the default path and clears the pointer.
    static func resetDatabaseLocation(current: URL = KobanPaths.activeDatabaseURL) throws {
        if locationOverrideActive { throw StorageError(overrideMessage) }
        let fm = FileManager.default
        let def = KobanPaths.defaultDatabaseURL
        if current.standardizedFileURL != def.standardizedFileURL, fm.fileExists(atPath: current.path) {
            try? fm.createDirectory(at: def.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: def)
            try? fm.copyItem(at: current, to: def)
            copySidecars(from: current, to: def)
        }
        KobanPaths.resetToDefaultLocation()
    }

    /// get_db_info for a database that is not open in this session.
    static func info(forDatabaseAt url: URL) -> DbInfo {
        if let vault = try? KobanVault(url: url) {
            return vault.info(isCustomLocation: KobanPaths.isCustomLocation)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return DbInfo(dbPath: url.path, dbSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                      lastModified: attrs?[.modificationDate] as? Date, cipher: "AES-256-GCM",
                      encryptedRecords: 0, hasCustomPassphrase: false, isCustomLocation: KobanPaths.isCustomLocation)
    }

    // MARK: - Formatting (BackupsExportView.tsx helpers)

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }

    /// `new Date(secs * 1000).toLocaleString()`
    static func formatTime(_ date: Date?) -> String {
        guard let date, date > Date(timeIntervalSince1970: 0) else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
