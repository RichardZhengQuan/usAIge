import Combine
import Foundation

enum CodexAgentPhase: String, Codable, Equatable, Sendable {
    case idle
    case thinking
    case complete
    case needsInput
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .complete: "Complete"
        case .needsInput: "Needs input"
        case .error: "Error"
        }
    }

    var showsLight: Bool {
        self != .idle
    }

    var requiresAcknowledgement: Bool {
        switch self {
        case .complete, .needsInput, .error: true
        case .idle, .thinking: false
        }
    }
}

/// One agent session of any supported tool. `toolID` says which rail row
/// its light belongs to; the store stamps it from the provider that
/// reported the task.
struct CodexAgentTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let workspaceName: String
    let phase: CodexAgentPhase
    let updatedAt: Date
    var toolID: AIToolID = .chatGPT
}

struct CodexAgentAggregate: Equatable, Sendable {
    let phase: CodexAgentPhase
    let task: CodexAgentTask?
}

struct CodexAgentAcknowledgement: Equatable, Sendable {
    let phase: CodexAgentPhase
    let updatedAt: Date
}

protocol CodexAgentProviding: Sendable {
    func refresh() async throws -> [CodexAgentTask]
    func stop() async
}

actor CodexAgentProvider: CodexAgentProviding {
    static let maximumActiveSessions = 100

    private struct CachedSessionPhase {
        let fileSize: UInt64
        let modificationDate: Date
        let phase: CodexAgentPhase
    }

    private let rpc: any RPCRequesting
    private let now: @Sendable () -> Date
    private var initialized = false
    private var sessionCache: [String: CachedSessionPhase] = [:]

    init(
        rpc: any RPCRequesting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rpc = rpc
        self.now = now
    }

    func refresh() async throws -> [CodexAgentTask] {
        do {
            return try await performRefresh()
        } catch JSONRPCError.disconnected {
            // The Codex app-server can restart independently of usAIge. Reset
            // the transport and initialize a fresh process so one dropped
            // connection cannot leave the activity light permanently stale.
            await rpc.stop()
            initialized = false
            return try await performRefresh()
        }
    }

    private func performRefresh() async throws -> [CodexAgentTask] {
        try await initializeIfNeeded()
        let response = try await rpc.request(method: "thread/list", params: .object([
            "archived": .bool(false),
            "limit": .number(Double(Self.maximumActiveSessions)),
            "sortDirection": .string("desc"),
            "sortKey": .string("recency_at"),
            "useStateDbOnly": .bool(true),
        ]))
        guard let threads = response["data"]?.arrayValue else { return [] }
        let currentDate = now()
        var tasks: [CodexAgentTask] = []
        var visiblePaths: Set<String> = []
        for thread in threads {
            if let path = thread["path"]?.stringValue { visiblePaths.insert(path) }
            if let task = decodeTask(thread, now: currentDate) { tasks.append(task) }
        }
        sessionCache = sessionCache.filter { visiblePaths.contains($0.key) }
        return tasks
    }

    func stop() async {
        await rpc.stop()
        initialized = false
        sessionCache = [:]
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        try await rpc.start()
        _ = try await rpc.request(method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("usaige-agent-monitor"),
                "title": .string("usAIge Agent Monitor"),
                "version": .string(UsAIgeUserAgent.shortVersion),
            ]),
        ]))
        try await rpc.notify(method: "initialized", params: .object([:]))
        initialized = true
    }

    private func decodeTask(_ value: JSONValue, now: Date) -> CodexAgentTask? {
        guard let id = value["id"]?.stringValue,
              let path = value["path"]?.stringValue,
              let updatedAtSeconds = value["updatedAt"]?.numberValue else { return nil }

        let title = value["name"]?.stringValue
            ?? value["preview"]?.stringValue
            ?? "Codex task"
        let workspace = value["cwd"]?.stringValue
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Codex"
        let updatedAt = Date(timeIntervalSince1970: updatedAtSeconds)
        let phase = cachedPhase(at: URL(fileURLWithPath: path), updatedAt: updatedAt, now: now)
        return CodexAgentTask(
            id: id,
            title: title,
            workspaceName: workspace,
            phase: phase,
            updatedAt: updatedAt
        )
    }

    private func cachedPhase(at url: URL, updatedAt: Date, now: Date) -> CodexAgentPhase {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date ?? .distantPast
        if let cached = sessionCache[url.path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return CodexAgentSessionDecoder.settledPhase(cached.phase, updatedAt: updatedAt, now: now)
        }

        let rawPhase: CodexAgentPhase
        if let cached = sessionCache[url.path], fileSize >= cached.fileSize {
            rawPhase = CodexAgentSessionDecoder.recentPhase(
                at: url,
                initialPhase: cached.phase,
                updatedAt: updatedAt,
                now: updatedAt
            )
        } else {
            rawPhase = CodexAgentSessionDecoder.phase(
                at: url,
                updatedAt: updatedAt,
                now: updatedAt
            )
        }
        sessionCache[url.path] = CachedSessionPhase(
            fileSize: fileSize,
            modificationDate: modificationDate,
            phase: rawPhase
        )
        return CodexAgentSessionDecoder.settledPhase(rawPhase, updatedAt: updatedAt, now: now)
    }
}

enum CodexAgentSessionDecoder {
    private static let maximumTailBytes: UInt64 = 256 * 1024
    private static let boundaryOverlapBytes: UInt64 = 64 * 1024

    static func phase(at url: URL, updatedAt: Date, now: Date) -> CodexAgentPhase {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .idle }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return .idle }
        var upperBound = end

        while upperBound > 0 {
            let lowerBound = upperBound > maximumTailBytes ? upperBound - maximumTailBytes : 0
            let readUpperBound = min(end, upperBound + boundaryOverlapBytes)
            try? handle.seek(toOffset: lowerBound)
            let data = handle.readData(ofLength: Int(readUpperBound - lowerBound))
            if let latest = latestLifecyclePhase(
                from: data,
                startsMidLine: lowerBound > 0
            ) {
                return settledPhase(latest, updatedAt: updatedAt, now: now)
            }

            guard lowerBound > 0 else { break }
            upperBound = lowerBound
        }

        return .idle
    }

    static func recentPhase(
        at url: URL,
        initialPhase: CodexAgentPhase,
        updatedAt: Date,
        now: Date
    ) -> CodexAgentPhase {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return initialPhase }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return initialPhase }
        let offset = end > maximumTailBytes ? end - maximumTailBytes : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return phase(
            from: data,
            startsMidLine: offset > 0,
            initialPhase: initialPhase,
            updatedAt: updatedAt,
            now: now
        )
    }

    static func phase(
        from data: Data,
        startsMidLine: Bool = false,
        initialPhase: CodexAgentPhase = .idle,
        updatedAt: Date,
        now: Date
    ) -> CodexAgentPhase {
        let phase = latestLifecyclePhase(from: data, startsMidLine: startsMidLine)
            ?? initialPhase
        return settledPhase(phase, updatedAt: updatedAt, now: now)
    }

    private static func latestLifecyclePhase(
        from data: Data,
        startsMidLine: Bool
    ) -> CodexAgentPhase? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }

        var phase: CodexAgentPhase?
        for line in lines {
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let payload = frame["payload"],
                  let type = payload["type"]?.stringValue else { continue }

            switch type {
            case "task_started", "user_message":
                phase = .thinking
            case "task_complete":
                phase = .complete
            case "request_user_input", "elicitation_request", "exec_approval_request",
                 "apply_patch_approval_request":
                phase = .needsInput
            case "error", "stream_error":
                phase = .error
            case "turn_aborted":
                phase = payload["reason"]?.stringValue == "interrupted" ? .idle : .error
            default:
                if type == "custom_tool_call",
                   payload["name"]?.stringValue?.contains("request_user_input") == true {
                    phase = .needsInput
                }
            }
        }

        return phase
    }

    static func settledPhase(
        _ phase: CodexAgentPhase,
        updatedAt: Date,
        now: Date
    ) -> CodexAgentPhase {
        if phase == .complete, now.timeIntervalSince(updatedAt) > 60 * 60 { return .idle }
        return phase
    }
}

@MainActor
final class CodexAgentStore: ObservableObject {
    /// One session source per rail row: the Codex app-server, Claude Code
    /// transcripts, Cursor's composer store, the Grok Build log.
    struct Source {
        let toolID: AIToolID
        let provider: any CodexAgentProviding
    }

    /// The light each tool's row shows, from that tool's unacknowledged
    /// sessions.
    @Published private(set) var aggregatesByTool: [AIToolID: CodexAgentAggregate] = [:]
    @Published private(set) var lastError: String?

    /// Codex's aggregate, kept for callers that predate per-tool lights.
    var phase: CodexAgentPhase { phase(for: .chatGPT) }
    var targetTask: CodexAgentTask? { targetTask(for: .chatGPT) }

    func phase(for toolID: AIToolID) -> CodexAgentPhase {
        aggregatesByTool[toolID]?.phase ?? .idle
    }

    func targetTask(for toolID: AIToolID) -> CodexAgentTask? {
        aggregatesByTool[toolID]?.task
    }

    var onAttentionEvent: (@MainActor (CodexAgentTask) -> Void)?
    var onAggregatePhaseChanged: (@MainActor (AIToolID, CodexAgentPhase, Date) -> Void)?

    private let sources: [Source]
    private var monitorTasks: [AIToolID: Task<Void, Never>] = [:]
    private var tasksByTool: [AIToolID: [CodexAgentTask]] = [:]
    private var acknowledgementsByTool: [AIToolID: [String: CodexAgentAcknowledgement]] = [:]
    private var lastViewedAtByTool: [AIToolID: Date] = [:]
    private var loadedTools: Set<AIToolID> = []
    private var consecutiveFailuresByTool: [AIToolID: Int] = [:]

    init(sources: [Source]) {
        self.sources = sources
    }

    convenience init(provider: any CodexAgentProviding) {
        self.init(sources: [Source(toolID: .chatGPT, provider: provider)])
    }

    /// Polling cadence: one second while a source answers, backing off to a
    /// minute while it does not (for example when Codex is not installed),
    /// so a missing app-server never becomes a subprocess-launch storm. Each
    /// source backs off on its own; a missing Codex never slows Claude Code.
    static let pollingInterval: TimeInterval = 1
    static let failureBackoff: [TimeInterval] = [2, 4, 8, 16, 30, 60]

    func start() {
        for source in sources where monitorTasks[source.toolID] == nil {
            let toolID = source.toolID
            monitorTasks[toolID] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await refresh(source)
                    let delay = self.nextPollingDelay(for: toolID)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    /// The first source's cadence; every source has its own.
    var nextPollingDelay: TimeInterval {
        guard let first = sources.first else { return Self.pollingInterval }
        return nextPollingDelay(for: first.toolID)
    }

    func nextPollingDelay(for toolID: AIToolID) -> TimeInterval {
        let failures = consecutiveFailuresByTool[toolID] ?? 0
        guard failures > 0 else { return Self.pollingInterval }
        return Self.failureBackoff[min(failures, Self.failureBackoff.count) - 1]
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.refresh(source) }
            }
        }
    }

    private func refresh(_ source: Source) async {
        do {
            let tasks = try await source.provider.refresh()
            updateTasks(tasks, for: source.toolID)
            if source.toolID == .chatGPT { lastError = nil }
            consecutiveFailuresByTool[source.toolID] = 0
        } catch {
            if source.toolID == .chatGPT { lastError = error.localizedDescription }
            consecutiveFailuresByTool[source.toolID, default: 0] += 1
        }
    }

    func shutdown() async {
        for task in monitorTasks.values { task.cancel() }
        monitorTasks = [:]
        for source in sources { await source.provider.stop() }
    }

    func acknowledge(taskID: String) {
        for (toolID, tasks) in tasksByTool {
            guard let task = tasks.first(where: { $0.id == taskID }),
                  task.phase.requiresAcknowledgement
            else { continue }
            acknowledgementsByTool[toolID, default: [:]][taskID] = CodexAgentAcknowledgement(
                phase: task.phase,
                updatedAt: task.updatedAt
            )
            publishAggregate(for: toolID)
        }
    }

    /// The user looked at the tool itself, so its attention states are seen.
    /// Without a tool, every tool counts as seen.
    func acknowledgeAttentionStates(for toolID: AIToolID? = nil, viewedAt: Date = Date()) {
        let toolIDs = toolID.map { [$0] } ?? sources.map(\.toolID)
        for toolID in toolIDs {
            lastViewedAtByTool[toolID] = max(lastViewedAtByTool[toolID] ?? .distantPast, viewedAt)
            acknowledgementsByTool[toolID] = Self.acknowledgements(
                afterAcknowledgingAttentionIn: tasksByTool[toolID] ?? [],
                existing: acknowledgementsByTool[toolID] ?? [:],
                viewedAt: viewedAt
            )
            publishAggregate(for: toolID)
        }
    }

    nonisolated static func aggregate(_ tasks: [CodexAgentTask]) -> CodexAgentPhase {
        aggregateStatus(tasks).phase
    }

    nonisolated static func aggregateStatus(_ tasks: [CodexAgentTask]) -> CodexAgentAggregate {
        let winner = tasks
            .filter { $0.phase.showsLight }
            .sorted { lhs, rhs in
                let leftPriority = priority(of: lhs.phase)
                let rightPriority = priority(of: rhs.phase)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
        return CodexAgentAggregate(phase: winner?.phase ?? .idle, task: winner)
    }

    nonisolated static func unacknowledgedTasks(
        _ tasks: [CodexAgentTask],
        acknowledgements: [String: CodexAgentAcknowledgement]
    ) -> [CodexAgentTask] {
        tasks.filter { task in
            guard let acknowledgement = acknowledgements[task.id] else { return true }
            return task.phase != acknowledgement.phase || task.updatedAt > acknowledgement.updatedAt
        }
    }

    nonisolated static func acknowledgements(
        afterAcknowledgingAttentionIn tasks: [CodexAgentTask],
        existing: [String: CodexAgentAcknowledgement],
        viewedAt: Date
    ) -> [String: CodexAgentAcknowledgement] {
        var updated = existing
        for task in tasks
        where task.phase.requiresAcknowledgement && task.updatedAt <= viewedAt {
            updated[task.id] = CodexAgentAcknowledgement(
                phase: task.phase,
                updatedAt: task.updatedAt
            )
        }
        return updated
    }

    private func updateTasks(_ refreshedTasks: [CodexAgentTask], for toolID: AIToolID) {
        let refreshedTasks = refreshedTasks.map { task -> CodexAgentTask in
            var stamped = task
            stamped.toolID = toolID
            return stamped
        }
        let previousTasks = Dictionary(
            (tasksByTool[toolID] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        if loadedTools.contains(toolID) {
            for task in Self.newAttentionTasks(refreshedTasks, previous: previousTasks) {
                onAttentionEvent?(task)
            }
        } else {
            loadedTools.insert(toolID)
        }
        tasksByTool[toolID] = refreshedTasks
        let tasksByID = Dictionary(
            refreshedTasks.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var acknowledgements = (acknowledgementsByTool[toolID] ?? [:]).filter { taskID, acknowledgement in
            guard let task = tasksByID[taskID] else { return false }
            return task.phase == acknowledgement.phase && task.updatedAt <= acknowledgement.updatedAt
        }
        if let lastViewedAt = lastViewedAtByTool[toolID] {
            acknowledgements = Self.acknowledgements(
                afterAcknowledgingAttentionIn: refreshedTasks,
                existing: acknowledgements,
                viewedAt: lastViewedAt
            )
        }
        acknowledgementsByTool[toolID] = acknowledgements
        publishAggregate(for: toolID)
    }

    nonisolated static func newAttentionTasks(
        _ tasks: [CodexAgentTask],
        previous: [String: CodexAgentTask]
    ) -> [CodexAgentTask] {
        tasks.filter { task in
            guard task.phase.requiresAcknowledgement else { return false }
            guard let earlier = previous[task.id] else { return true }
            return task.phase != earlier.phase || task.updatedAt > earlier.updatedAt
        }
    }

    private func publishAggregate(for toolID: AIToolID) {
        let aggregate = Self.aggregateStatus(Self.unacknowledgedTasks(
            tasksByTool[toolID] ?? [],
            acknowledgements: acknowledgementsByTool[toolID] ?? [:]
        ))
        let previousPhase = phase(for: toolID)
        aggregatesByTool[toolID] = aggregate
        if aggregate.phase != previousPhase {
            onAggregatePhaseChanged?(
                toolID,
                aggregate.phase,
                aggregate.task?.updatedAt ?? Date()
            )
        }
    }

    private nonisolated static func priority(of phase: CodexAgentPhase) -> Int {
        switch phase {
        case .error: 0
        case .complete: 1
        case .needsInput: 2
        case .thinking: 3
        case .idle: 4
        }
    }
}

actor MissingCodexAgentProvider: CodexAgentProviding {
    func refresh() async throws -> [CodexAgentTask] { [] }
    func stop() async {}
}
