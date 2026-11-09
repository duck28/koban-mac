import Foundation

struct BackupEntry: Identifiable, Hashable, Sendable {
    var name: String
    var url: URL
    var size: Int64
    var modified: Date

    var id: URL { url }
}

/// Port of perform_backup_to_dir / list_backups in lib.rs. Backups are plain file copies
/// of the (already encrypted) database, so they stay encrypted at rest and remain
/// restorable on either platform.
enum BackupManager {
    /// Copies the DB to `koban-latest.db` plus a daily (`koban-daily-<day>.db`) or timestamped
    /// (`koban-backup-<secs>.db`) snapshot, then prunes snapshots beyond `maxBackups`.
    @discardableResult
    static func backup(database: URL, to directory: URL, timestamped: Bool, maxBackups: Int) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let latest = directory.appendingPathComponent("koban-latest.db")
        try replaceCopy(from: database, to: latest)

        let secs = Int(Date().timeIntervalSince1970)
        let snapshotName = timestamped ? "koban-backup-\(secs).db" : "koban-daily-\(secs / 86_400).db"
        let snapshot = directory.appendingPathComponent(snapshotName)
        if timestamped || !fm.fileExists(atPath: snapshot.path) {
            try? replaceCopy(from: database, to: snapshot)
        }

        if maxBackups > 0 {
            for old in try snapshots(in: directory).dropFirst(maxBackups) {
                try? fm.removeItem(at: old.url)
            }
        }
        return timestamped ? snapshot : latest
    }

    /// All `.db` files in the backup folder, newest first.
    static func list(in directory: URL) throws -> [BackupEntry] {
        try entries(in: directory) { $0.hasSuffix(".db") }
    }

    private static func snapshots(in directory: URL) throws -> [BackupEntry] {
        try entries(in: directory) { name in
            (name.hasPrefix("koban-backup-") || name.hasPrefix("koban-daily-")) && name.hasSuffix(".db")
        }
    }

    private static func entries(in directory: URL, where include: (String) -> Bool) throws -> [BackupEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return urls.compactMap { url -> BackupEntry? in
            guard include(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return BackupEntry(
                name: url.lastPathComponent,
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    private static func replaceCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
