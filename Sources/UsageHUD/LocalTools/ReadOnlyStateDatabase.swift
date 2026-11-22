import Foundation
import SQLite3

/// Read-only access to the `state.vscdb` SQLite store that VS Code-based
/// editors (Cursor, Windsurf, Devin Desktop) keep their settings in. The
/// database is never written: it is opened with `mode=ro`, or as immutable when
/// the editor holds its journal locked.
enum ReadOnlyStateDatabase {
    static func withConnection<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        // Prefer a normal read-only open, which respects the editor's WAL; fall
        // back to an immutable open if the journal is locked.
        for uri in ["file:\(path)?mode=ro", "file:\(path)?immutable=1"] {
            var database: OpaquePointer?
            guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
                if database != nil { sqlite3_close(database) }
                continue
            }
            defer { sqlite3_close(database) }
            // Editors write this database constantly; wait briefly for their
            // lock instead of mistaking a busy database for an empty one.
            sqlite3_busy_timeout(database, 200)
            return try body(database)
        }
        throw LocalToolUsageError.invalidResponse
    }

    /// Text of a column that may be stored as TEXT or as a BLOB holding UTF-8
    /// or UTF-16LE text, which is how VS Code-based editors save JSON values.
    static func text(of statement: OpaquePointer, column: Int32) -> String? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, column).map { String(cString: $0) }
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
            let data = Data(bytes: bytes, count: count)
            // UTF-16LE text has a zero byte after every ASCII character.
            if data.count >= 2, data.count.isMultiple(of: 2), data[data.startIndex + 1] == 0 {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }
}
