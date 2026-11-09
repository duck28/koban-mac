import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite C API (no third-party dependency).
final class SQLiteConnection {
    enum Value {
        case text(String)
        case int(Int64)
        case null
    }

    struct SQLiteError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    private var handle: OpaquePointer?
    let path: String

    /// Tells SQLite to copy bound strings (equivalent of the C macro SQLITE_TRANSIENT).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let err = SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            handle = nil
            throw err
        }
        sqlite3_busy_timeout(handle, 3_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Executes one or more SQL statements without parameters.
    func execute(_ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let message = errPtr.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errPtr)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Runs a single statement with bound parameters (INSERT / UPDATE / DELETE).
    func run(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(code: rc, message: lastErrorMessage)
        }
    }

    /// Returns all rows as arrays of optional strings (column values read as text).
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String?]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: lastErrorMessage) }
            let columns = sqlite3_column_count(stmt)
            var row: [String?] = []
            row.reserveCapacity(Int(columns))
            for i in 0..<columns {
                if let text = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalarString(_ sql: String, _ params: [Value] = []) throws -> String? {
        try query(sql, params).first?.first ?? nil
    }

    func scalarInt(_ sql: String, _ params: [Value] = []) throws -> Int {
        Int(try scalarString(sql, params) ?? "0") ?? 0
    }

    /// Runs `body` inside BEGIN IMMEDIATE / COMMIT, rolling back on error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Private

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: lastErrorMessage)
        }
        for (offset, value) in params.enumerated() {
            let idx = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
