import Foundation
import SQLite3

/// Read-only SQLite access on a private copy of the database (including WAL/SHM),
/// so we never contend with the owning application.
final class SQLiteDB {
    private var db: OpaquePointer?
    private let tempDir: URL

    init(copyOf path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw ProviderError(.notConfigured, "Database not found: \((path as NSString).abbreviatingWithTildeInPath)")
        }
        tempDir = fm.temporaryDirectory.appendingPathComponent("usagebar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: tempDir.appendingPathComponent(name + suffix).path)
            }
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(tempDir.appendingPathComponent(name).path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw ProviderError(.parse, "Cannot open database (\(rc))")
        }
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: tempDir)
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
