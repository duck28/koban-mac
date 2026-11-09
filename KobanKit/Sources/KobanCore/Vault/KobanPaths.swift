import Foundation

/// Where Koban for macOS keeps its data. Mirrors koban_app_dir / get_active_db_path in lib.rs,
/// with `~/Library/Application Support/Koban` in place of `%LOCALAPPDATA%\Koban`.
enum KobanPaths {
    static var appDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Koban", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var defaultDatabaseURL: URL { appDirectory.appendingPathComponent("koban.db") }

    /// Text file holding a custom database path (same mechanism as on Windows).
    static var pointerURL: URL { appDirectory.appendingPathComponent("db_location.txt") }

    static var activeDatabaseURL: URL {
        // Developer override (tests, screenshots, demo data) that leaves the real vault untouched.
        if let override = ProcessInfo.processInfo.environment["KOBAN_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let raw = try? String(contentsOf: pointerURL, encoding: .utf8) else { return defaultDatabaseURL }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDatabaseURL }

        var isDir: ObjCBool = false
        let candidate = URL(fileURLWithPath: trimmed)
        if (FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) && isDir.boolValue) || trimmed.hasSuffix("/") {
            return candidate.appendingPathComponent("koban.db")
        }
        return candidate
    }

    static var isCustomLocation: Bool {
        activeDatabaseURL.standardizedFileURL != defaultDatabaseURL.standardizedFileURL
    }

    /// Points Koban at an existing database file (e.g. a koban.db copied from Windows or in a synced folder).
    static func useDatabase(at url: URL) throws {
        try url.path.write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    static func resetToDefaultLocation() {
        try? FileManager.default.removeItem(at: pointerURL)
    }
}
