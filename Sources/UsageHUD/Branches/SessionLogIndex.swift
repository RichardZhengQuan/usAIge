import Foundation

/// Where one AI session worked. The conversation itself is never read: only
/// the working-folder, branch, and title fields, found by their keys.
struct SessionLogEntry: Codable, Equatable, Sendable {
    var tool: String
    var folder: String
    var branch: String?
    var size: UInt64
    var modifiedAt: Date
    /// The name the tool shows for the session, if it has one.
    var title: String?
}

enum SessionLogFields {
    private static let maximumValueBytes = 4096

    /// The JSON string after `"key":"`, first or last in the data.
    static func string(forKey key: String, in data: Data, last: Bool = false, from start: Data.Index? = nil) -> String? {
        let marker = Data("\"\(key)\":\"".utf8)
        let searchRange = (start ?? data.startIndex)..<data.endIndex
        guard let match = data.range(of: marker, options: last ? .backwards : [], in: searchRange) else { return nil }
        var index = match.upperBound
        let limit = min(data.endIndex, index + maximumValueBytes)
        while index < limit {
            let byte = data[index]
            if byte == 0x22 {
                let quoted = data[(match.upperBound - 1)...index]
                return try? JSONDecoder().decode(String.self, from: Data(quoted))
            }
            index += byte == 0x5C ? 2 : 1
        }
        return nil
    }
}

/// Builds the list of AI sessions from each tool's own files. A log that
/// hasn't changed since the last scan is not opened again.
struct SessionLogIndexer: Sendable {
    let home: URL
    var cursorDatabase: URL?

    private static let claudeHeadBytes = 64 * 1024
    private static let claudeHeadLimitBytes = 1024 * 1024
    private static let claudeTailBytes: UInt64 = 64 * 1024
    private static let codexHeadBytes = 64 * 1024
    private static let maximumCursorConversations = 1000

    init(home: URL, cursorDatabase: URL? = nil) {
        self.home = home
        self.cursorDatabase = cursorDatabase
    }

    func update(from previous: [String: SessionLogEntry]) -> [String: SessionLogEntry] {
        var entries: [String: SessionLogEntry] = [:]
        indexClaudeCode(previous: previous, into: &entries)
        indexCodex(previous: previous, into: &entries)
        indexGrokBuild(into: &entries)
        indexCursor(into: &entries)
        return entries
    }

    /// A title as a card shows it: one line, or nothing if it's blank.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    /// Claude Code adds a record naming the session, and a newer one each time
    /// it's renamed, so the last in the log wins. A name the person typed
    /// beats one the model suggested.
    static func claudeTitle(head: Data?, tail: Data?) -> String? {
        for key in ["customTitle", "aiTitle"] {
            for data in [tail, head].compactMap({ $0 }) {
                if let title = cleanTitle(SessionLogFields.string(forKey: key, in: data, last: true)) { return title }
            }
        }
        return nil
    }

    /// Codex keeps each thread's name in one index, newest line last.
    static func codexThreadNames(in data: Data) -> [String: String] {
        struct Line: Decodable {
            var id: String
            var thread_name: String?
        }
        var names: [String: String] = [:]
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            guard let decoded = try? decoder.decode(Line.self, from: Data(line)) else { continue }
            let id = decoded.id.lowercased()
            names[id] = cleanTitle(decoded.thread_name) ?? names[id]
        }
        return names
    }

    /// A Codex log is named `rollout-<time>-<thread id>.jsonl`.
    static func codexThreadID(fromFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard base.count > 36 else { return nil }
        let id = String(base.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id.lowercased()
    }

    private func attributes(of url: URL) -> (size: UInt64, modifiedAt: Date)? {
        AgentActivityFiles.attributes(of: url).map { ($0.size, $0.modifiedAt) }
    }

    private func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
    }

    private func indexClaudeCode(previous: [String: SessionLogEntry], into entries: inout [String: SessionLogEntry]) {
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        for project in subdirectories(of: projects) {
            for file in subdirectories(of: project) where file.pathExtension == "jsonl" {
                autoreleasepool {
                    guard let attributes = attributes(of: file) else { return }
                    let key = file.path
                    if let known = previous[key], known.size == attributes.size, known.modifiedAt == attributes.modifiedAt {
                        entries[key] = known
                        return
                    }
                    guard let start = claudeWorkingFolder(in: file) else { return }
                    let tail = AgentActivityFiles.tail(of: file, maximumBytes: Self.claudeTailBytes)?.data
                    entries[key] = SessionLogEntry(
                        tool: "Claude Code",
                        folder: start.folder,
                        branch: tail.flatMap { SessionLogFields.string(forKey: "gitBranch", in: $0, last: true) },
                        size: attributes.size,
                        modifiedAt: attributes.modifiedAt,
                        title: Self.claudeTitle(head: start.head, tail: tail)
                    )
                }
            }
        }
    }

    private func claudeWorkingFolder(in file: URL) -> (folder: String, head: Data)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = ((try? handle.read(upToCount: Self.claudeHeadBytes)) ?? nil) ?? Data()
        if let folder = SessionLogFields.string(forKey: "cwd", in: head) { return (folder, head) }
        // A long first record can push the field further in.
        guard let more = (try? handle.read(upToCount: Self.claudeHeadLimitBytes)) ?? nil else { return nil }
        let longer = head + more
        return SessionLogFields.string(forKey: "cwd", in: longer).map { ($0, longer) }
    }

    private func indexCodex(previous: [String: SessionLogEntry], into entries: inout [String: SessionLogEntry]) {
        var files: [URL] = []
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        for year in subdirectories(of: sessions) {
            for month in subdirectories(of: year) {
                for day in subdirectories(of: month) {
                    files.append(contentsOf: subdirectories(of: day))
                }
            }
        }
        files.append(contentsOf: subdirectories(of: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)))
        // A rename changes only the index, so names are applied every time.
        let names = (try? Data(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl")))
            .map(Self.codexThreadNames(in:)) ?? [:]
        for file in files where file.pathExtension == "jsonl" {
            autoreleasepool {
                guard let attributes = attributes(of: file) else { return }
                let key = file.path
                let title = Self.codexThreadID(fromFileName: file.lastPathComponent).flatMap { names[$0] }
                if var known = previous[key], known.size == attributes.size, known.modifiedAt == attributes.modifiedAt {
                    known.title = title
                    entries[key] = known
                    return
                }
                guard let handle = try? FileHandle(forReadingFrom: file) else { return }
                defer { try? handle.close() }
                guard let head = try? handle.read(upToCount: Self.codexHeadBytes),
                      let folder = SessionLogFields.string(forKey: "cwd", in: head) else { return }
                let gitBlock = head.range(of: Data("\"git\":{".utf8))?.upperBound
                entries[key] = SessionLogEntry(
                    tool: "Codex",
                    folder: folder,
                    branch: gitBlock.flatMap { SessionLogFields.string(forKey: "branch", in: head, from: $0) },
                    size: attributes.size,
                    modifiedAt: attributes.modifiedAt,
                    title: title
                )
            }
        }
    }

    /// Grok Build names a directory after each percent-encoded working folder.
    private func indexGrokBuild(into entries: inout [String: SessionLogEntry]) {
        let sessions = home.appendingPathComponent(".grok/sessions", isDirectory: true)
        for project in subdirectories(of: sessions) {
            guard let folder = project.lastPathComponent.removingPercentEncoding, folder.hasPrefix("/") else { continue }
            for session in subdirectories(of: project) {
                guard let attributes = attributes(of: session) else { continue }
                entries[session.path] = SessionLogEntry(
                    tool: "Grok Build", folder: folder, branch: nil, size: attributes.size, modifiedAt: attributes.modifiedAt
                )
            }
        }
    }

    private func indexCursor(into entries: inout [String: SessionLogEntry]) {
        let database = cursorDatabase ?? home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        for conversation in CursorAgentProvider.recentConversationFolders(
            databaseURL: database,
            limit: Self.maximumCursorConversations
        ) {
            entries["cursor:\(conversation.id)"] = SessionLogEntry(
                tool: "Cursor", folder: conversation.folder, branch: nil, size: 0, modifiedAt: conversation.updatedAt,
                title: Self.cleanTitle(conversation.title)
            )
        }
    }
}

extension WorkSessionSummary {
    /// The title comes from the newest session that was on `branch`, or that
    /// didn't say: a folder reused for another branch keeps older sessions
    /// whose titles describe other work.
    init(entries: [SessionLogEntry], branch: String? = nil) {
        let titled = entries
            .filter { $0.title != nil && ($0.branch == nil || branch == nil || $0.branch == branch) }
            .max { $0.modifiedAt < $1.modifiedAt }
        self.init(
            count: entries.count,
            tools: Array(Set(entries.map(\.tool))).sorted(),
            lastActiveAt: entries.map(\.modifiedAt).max(),
            title: titled?.title
        )
    }
}
