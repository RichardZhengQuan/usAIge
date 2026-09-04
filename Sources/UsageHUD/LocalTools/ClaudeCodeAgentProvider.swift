import Foundation

/// Session activity for Claude Code. Claude Code registers every running
/// session in `~/.claude/sessions/<pid>.json` and appends the conversation
/// to `~/.claude/projects/<cwd>/<session>.jsonl`. The provider reads only
/// the record types and stop reasons at the end of that transcript, never
/// the text, to tell a working session from one waiting on the user.
actor ClaudeCodeAgentProvider: CodexAgentProviding {
    private struct LiveSession: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
    }

    private struct CachedTranscript {
        let attributes: AgentActivityFiles.Attributes
        let phase: CodexAgentPhase
        let title: String?
    }

    static let maximumTailBytes: UInt64 = 128 * 1024

    private let sessionsDirectory: URL
    private let projectsDirectory: URL
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let now: @Sendable () -> Date
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var transcriptLocations: [String: URL] = [:]

    init(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = AgentActivityFiles.isProcessAlive,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        sessionsDirectory = claudeDirectory.appendingPathComponent("sessions", isDirectory: true)
        projectsDirectory = claudeDirectory.appendingPathComponent("projects", isDirectory: true)
        self.isProcessAlive = isProcessAlive
        self.now = now
    }

    func refresh() async throws -> [CodexAgentTask] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let currentDate = now()
        var tasks: [CodexAgentTask] = []
        var seenTranscripts: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(LiveSession.self, from: data),
                  isProcessAlive(session.pid),
                  let transcript = locateTranscript(for: session) else { continue }
            seenTranscripts.insert(transcript.path)
            guard let task = task(for: session, transcript: transcript, now: currentDate) else { continue }
            tasks.append(task)
        }
        transcriptCache = transcriptCache.filter { seenTranscripts.contains($0.key) }
        transcriptLocations = transcriptLocations.filter { seenTranscripts.contains($0.value.path) }
        return tasks
    }

    func stop() async {
        transcriptCache = [:]
        transcriptLocations = [:]
    }

    /// Claude Code names a project directory after the working directory
    /// with every non-alphanumeric character replaced by "-". When that
    /// guess misses (an older layout, a moved directory), search for the
    /// session file once and remember where it was.
    private func locateTranscript(for session: LiveSession) -> URL? {
        if let known = transcriptLocations[session.sessionId],
           FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        let fileName = "\(session.sessionId).jsonl"
        let guessed = projectsDirectory
            .appendingPathComponent(Self.projectDirectoryName(for: session.cwd), isDirectory: true)
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: guessed.path) {
            transcriptLocations[session.sessionId] = guessed
            return guessed
        }
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                transcriptLocations[session.sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    static func projectDirectoryName(for workingDirectory: String) -> String {
        String(workingDirectory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private func task(for session: LiveSession, transcript: URL, now: Date) -> CodexAgentTask? {
        guard let attributes = AgentActivityFiles.attributes(of: transcript) else { return nil }
        let cached = transcriptCache[transcript.path]
        let phase: CodexAgentPhase
        let title: String?
        if let cached, cached.attributes == attributes {
            phase = cached.phase
            title = cached.title
        } else {
            let decoded = AgentActivityFiles.tail(of: transcript, maximumBytes: Self.maximumTailBytes)
                .map { ClaudeCodeSessionDecoder.decode($0.data, startsMidLine: $0.startsMidLine) }
                ?? ClaudeCodeSessionDecoder.Result(phase: nil, title: nil)
            // A tail made only of attachments and reminders says nothing new;
            // the last known phase stands.
            phase = decoded.phase ?? cached?.phase ?? .idle
            title = decoded.title ?? cached?.title
            transcriptCache[transcript.path] = CachedTranscript(
                attributes: attributes,
                phase: phase,
                title: title
            )
        }
        let workspace = URL(fileURLWithPath: session.cwd).lastPathComponent
        return CodexAgentTask(
            id: session.sessionId,
            title: title ?? session.name ?? "Claude Code session",
            workspaceName: workspace.isEmpty ? "Claude Code" : workspace,
            phase: CodexAgentSessionDecoder.settledPhase(phase, updatedAt: attributes.modifiedAt, now: now),
            updatedAt: attributes.modifiedAt,
            toolID: .claude
        )
    }
}

/// Reads the lifecycle out of a Claude Code transcript tail. A user record
/// (a prompt or a tool result) means Claude is working; an assistant record
/// that stopped for a tool call means it is still working; one that ended
/// its turn means the session is waiting on the person; an API error record
/// means the last thing that happened was a failure.
enum ClaudeCodeSessionDecoder {
    struct Result: Equatable {
        let phase: CodexAgentPhase?
        let title: String?
    }

    static func decode(_ data: Data, startsMidLine: Bool = false) -> Result {
        var phase: CodexAgentPhase?
        var customTitle: String?
        var generatedTitle: String?
        for line in AgentActivityFiles.lines(in: data, startsMidLine: startsMidLine) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: line),
                  let type = record["type"]?.stringValue else { continue }
            switch type {
            case "user", "queue-operation":
                phase = .thinking
            case "assistant":
                switch record["message"]?["stop_reason"]?.stringValue {
                case "end_turn", "stop_sequence", "max_tokens": phase = .complete
                default: phase = .thinking
                }
            case "system":
                if record["subtype"]?.stringValue == "api_error" { phase = .error }
            case "custom-title":
                customTitle = record["customTitle"]?.stringValue
            case "ai-title":
                generatedTitle = record["aiTitle"]?.stringValue
            default:
                break
            }
        }
        let title = [customTitle, generatedTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return Result(phase: phase, title: title)
    }
}
