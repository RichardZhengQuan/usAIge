import Foundation
import SQLite3

/// Session activity for Cursor. Cursor keeps every agent conversation in its
/// global state database: `composerHeaders` lists them with a last-updated
/// time and whether one is blocked on the person, and `composerData:<id>`
/// carries the live status. The provider opens that database read-only and
/// looks only at recently touched conversations, reading status fields and
/// never message text.
actor CursorAgentProvider: CodexAgentProviding {
    static let recentWindow: TimeInterval = 60 * 60
    static let maximumConversations = 10

    private let databaseURL: URL
    private let now: @Sendable () -> Date
    private var database: OpaquePointer?

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.now = now
    }

    func refresh() async throws -> [CodexAgentTask] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            closeDatabase()
            return []
        }
        let database = try openDatabaseIfNeeded()
        do {
            return try tasks(from: database)
        } catch {
            // Cursor may replace the database underneath us; a handle that
            // failed once must not be reused, or every poll fails after it.
            closeDatabase()
            throw error
        }
    }

    private func tasks(from database: OpaquePointer) throws -> [CodexAgentTask] {
        let currentDate = now()
        let sinceMilliseconds = Int64((currentDate.timeIntervalSince1970 - Self.recentWindow) * 1000)
        let headers = try Self.query(
            database,
            sql: """
            SELECT composerId, lastUpdatedAt, value FROM composerHeaders
            WHERE isArchived = 0 AND isSubagent = 0 AND lastUpdatedAt >= ?
            ORDER BY lastUpdatedAt DESC LIMIT \(Self.maximumConversations)
            """,
            bindings: [.integer(sinceMilliseconds)]
        )
        var tasks: [CodexAgentTask] = []
        for row in headers {
            guard case let .text(composerID)? = row[0], case let .integer(updatedMilliseconds)? = row[1] else { continue }
            let header = (row[2].flatMap { value -> JSONValue? in
                guard case let .text(text) = value else { return nil }
                return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            }) ?? .null
            let status = try Self.query(
                database,
                sql: """
                SELECT json_extract(value, '$.status'), json_array_length(json_extract(value, '$.generatingBubbleIds'))
                FROM cursorDiskKV WHERE key = ?
                """,
                bindings: [.text("composerData:\(composerID)")]
            ).first
            let generatingCount: Int
            if case let .integer(count)? = status?[1] { generatingCount = Int(count) } else { generatingCount = 0 }
            let statusText: String?
            if case let .text(text)? = status?[0] { statusText = text } else { statusText = nil }
            let phase = CursorComposerState.phase(
                status: statusText,
                generatingCount: generatingCount,
                hasBlockingPendingActions: header["hasBlockingPendingActions"]?.boolValue == true
            )
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedMilliseconds) / 1000)
            let title = header["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            tasks.append(CodexAgentTask(
                id: composerID,
                title: (title?.isEmpty == false ? title : nil) ?? "Cursor agent",
                workspaceName: Self.workspaceName(from: header),
                phase: CodexAgentSessionDecoder.settledPhase(phase, updatedAt: updatedAt, now: currentDate),
                updatedAt: updatedAt,
                toolID: .cursor
            ))
        }
        return tasks
    }

    func stop() async {
        closeDatabase()
    }

    private static func workspaceName(from header: JSONValue) -> String {
        let path = header["draftTarget"]?["environment"]?["uri"]?["fsPath"]?.stringValue
            ?? header["workspaceFolderPath"]?.stringValue
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return name.isEmpty ? "Cursor" : name
    }

    // MARK: SQLite

    enum Value: Equatable {
        case integer(Int64)
        case text(String)
    }

    struct DatabaseError: Error {
        let message: String
    }

    private func openDatabaseIfNeeded() throws -> OpaquePointer {
        if let database { return database }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError(message: message)
        }
        // Cursor writes to this database; wait briefly instead of failing
        // whenever a write is in flight.
        sqlite3_busy_timeout(handle, 200)
        database = handle
        return handle
    }

    private func closeDatabase() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    private static func query(_ database: OpaquePointer, sql: String, bindings: [Value]) throws -> [[Value?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case let .integer(value): sqlite3_bind_int64(statement, Int32(index + 1), value)
            case let .text(value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
        }
        var rows: [[Value?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                let count = Int(sqlite3_column_count(statement))
                rows.append((0..<count).map { column in
                    switch sqlite3_column_type(statement, Int32(column)) {
                    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, Int32(column)))
                    case SQLITE_FLOAT: return .integer(Int64(sqlite3_column_double(statement, Int32(column))))
                    case SQLITE_TEXT: return sqlite3_column_text(statement, Int32(column)).map { .text(String(cString: $0)) }
                    default: return nil
                    }
                })
            } else if step == SQLITE_DONE {
                return rows
            } else {
                throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}

/// Maps Cursor's composer status to a light.
enum CursorComposerState {
    static func phase(status: String?, generatingCount: Int, hasBlockingPendingActions: Bool) -> CodexAgentPhase {
        if hasBlockingPendingActions { return .needsInput }
        if generatingCount > 0 { return .thinking }
        switch status?.lowercased() {
        case "generating", "running", "streaming", "pending", "queued", "submitted": return .thinking
        case "completed", "done", "finished": return .complete
        case "error", "failed", "errored": return .error
        default: return .idle
        }
    }
}
