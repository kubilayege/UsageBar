import Foundation
import SQLite3

/// Read-only SQLite access. Opens the database in place (a WAL reader never blocks the owning
/// application), and only falls back to a private copy (including WAL/SHM) when that fails.
/// Cursor's and OpenCode's databases run to hundreds of MB, so copying them on every read cost
/// far more disk I/O and energy than anything else UsageBar does.
final class SQLiteDB {
    private var db: OpaquePointer?
    private var tempDir: URL?

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError(.notConfigured, "Database not found: \((path as NSString).abbreviatingWithTildeInPath)")
        }
        if let handle = Self.open(path, flags: SQLITE_OPEN_READONLY) {
            db = handle
            return
        }
        try openCopy(of: path)
    }

    /// Returns a handle only once the schema is readable, so a locked or unreadable file falls back to a copy.
    private static func open(_ path: String, flags: Int32) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 500)
        guard sqlite3_exec(handle, "select count(*) from sqlite_master", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private func openCopy(of path: String) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("usagebar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let name = (path as NSString).lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: dir.appendingPathComponent(name + suffix).path)
            }
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dir.appendingPathComponent(name).path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw ProviderError(.parse, "Cannot open database (\(rc))")
        }
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func query(_ sql: String) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError(.parse, "SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = sqlite3_column_count(stmt)
            var row: [String?] = []
            for i in 0..<n {
                if let c = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: c))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalar(_ sql: String) throws -> String? {
        try query(sql).first?.first ?? nil
    }
}
