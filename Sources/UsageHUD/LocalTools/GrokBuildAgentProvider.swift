import Foundation

/// Session activity for Grok Build. The CLI writes one shared structured log,
/// `~/.grok/logs/unified.jsonl`, where every turn announces its phases under
/// the session id (`sid`) and process id that own it. The provider reads the
/// end of that log, never the prompts, and keeps a session lit only while
/// its process is still running.
actor GrokBuildAgentProvider: CodexAgentProviding {
    static let maximumTailBytes: UInt64 = 256 * 1024

    private let logURL: URL
    private let sessionsDirectory: URL
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let now: @Sendable () -> Date
    private var logAttributes: AgentActivityFiles.Attributes?
    private var sessions: [String: GrokBuildLogDecoder.SessionState] = [:]
    private var workspaceNames: [String: String] = [:]

    init(
        grokDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = AgentActivityFiles.isProcessAlive,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        logURL = grokDirectory.appendingPathComponent("logs/unified.jsonl")
        sessionsDirectory = grokDirectory.appendingPathComponent("sessions", isDirectory: true)
        self.isProcessAlive = isProcessAlive
        self.now = now
    }

    func refresh() async throws -> [CodexAgentTask] {
        guard let attributes = AgentActivityFiles.attributes(of: logURL) else { return [] }
        if attributes != logAttributes,
           let tail = AgentActivityFiles.tail(of: logURL, maximumBytes: Self.maximumTailBytes) {
            let decoded = GrokBuildLogDecoder.decode(tail.data, startsMidLine: tail.startsMidLine)
            // Sessions that fell out of the tail keep their last known state
            // until their process goes away or announces its end.
            sessions.merge(decoded.sessions) { _, latest in latest }
            for (sid, state) in sessions where decoded.endedProcessIDs.keys.contains(state.pid) {
                let endedAt = decoded.endedProcessIDs[state.pid] ?? state.updatedAt
                guard endedAt >= state.updatedAt else { continue }
                sessions[sid] = GrokBuildLogDecoder.SessionState(pid: state.pid, phase: .idle, updatedAt: endedAt)
            }
            logAttributes = attributes
        }
        sessions = sessions.filter { isProcessAlive($0.value.pid) }
        let currentDate = now()
        return sessions.map { sid, state in
            CodexAgentTask(
                id: sid,
                title: "Grok Build session",
                workspaceName: workspaceName(for: sid),
                phase: CodexAgentSessionDecoder.settledPhase(state.phase, updatedAt: state.updatedAt, now: currentDate),
                updatedAt: state.updatedAt,
                toolID: .grok
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func stop() async {
        logAttributes = nil
        sessions = [:]
        workspaceNames = [:]
    }

    /// Grok Build stores each session under a directory named after its
    /// percent-encoded working directory: `sessions/%2FUsers%2Fme%2Fapp/<sid>`.
    private func workspaceName(for sid: String) -> String {
        if let known = workspaceNames[sid] { return known }
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return "Grok Build" }
        for project in projects
        where FileManager.default.fileExists(atPath: project.appendingPathComponent(sid).path) {
            let decoded = project.lastPathComponent.removingPercentEncoding ?? project.lastPathComponent
            let name = URL(fileURLWithPath: decoded).lastPathComponent
            let workspace = name.isEmpty ? "Grok Build" : name
            workspaceNames[sid] = workspace
            return workspace
        }
        return "Grok Build"
    }
}

/// Reads the per-session lifecycle out of the Grok Build unified log.
enum GrokBuildLogDecoder {
    struct SessionState: Equatable, Sendable {
        let pid: Int32
        let phase: CodexAgentPhase
        let updatedAt: Date
    }

    struct Decoded: Equatable, Sendable {
        var sessions: [String: SessionState] = [:]
        /// Processes that announced their end, with the time they did, so
        /// sessions that started before this tail can be closed too.
        var endedProcessIDs: [Int32: Date] = [:]
    }

    static func sessions(from data: Data, startsMidLine: Bool = false) -> [String: SessionState] {
        decode(data, startsMidLine: startsMidLine).sessions
    }

    static func decode(_ data: Data, startsMidLine: Bool = false) -> Decoded {
        var decoded = Decoded()
        for line in AgentActivityFiles.lines(in: data, startsMidLine: startsMidLine) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: line),
                  let message = record["msg"]?.stringValue,
                  let pid = record["pid"]?.intValue.map(Int32.init) else { continue }
            let timestamp = AgentActivityFiles.timestamp(record["ts"]?.stringValue) ?? .distantPast
            if message.hasPrefix("session_end") {
                // The process is winding down; every session it owned is over.
                for (sid, state) in decoded.sessions where state.pid == pid {
                    decoded.sessions[sid] = SessionState(pid: pid, phase: .idle, updatedAt: timestamp)
                }
                decoded.endedProcessIDs[pid] = timestamp
                continue
            }
            guard let sid = record["sid"]?.stringValue,
                  let phase = phase(for: message, context: record["ctx"], level: record["lvl"]?.stringValue) else { continue }
            decoded.sessions[sid] = SessionState(pid: pid, phase: phase, updatedAt: timestamp)
        }
        return decoded
    }

    static func phase(for message: String, context: JSONValue?, level: String?) -> CodexAgentPhase? {
        switch message {
        case "prompt received", "shell.handle_prompt.start", "turn.first_activity", "shell.turn.inference_start":
            return .thinking
        case "turn.phase_transition":
            return context?["to"]?.stringValue == "idle" ? nil : .thinking
        case "turn.complete":
            return context?["was_cancelling"]?.boolValue == true ? .idle : .complete
        case "agent response complete":
            return .complete
        case "shell.turn.inference_failed":
            return .error
        default:
            return level == "error" ? .error : nil
        }
    }
}
