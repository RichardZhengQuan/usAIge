import Foundation
import Testing
@testable import UsageHUD

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: Claude Code

private func claudeRecord(_ type: String, extra: String = "") -> String {
    "{\"type\":\"\(type)\"\(extra),\"sessionId\":\"s1\"}\n"
}

@Test func claudeCodePromptAndToolResultsMeanWorking() {
    let prompt = Data(claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":\"hi\"}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(prompt).phase == .thinking)
    let toolResult = Data(claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(toolResult).phase == .thinking)
    let toolCall = Data(claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\"}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(toolCall).phase == .thinking)
}

@Test func claudeCodeQuestionsAndPlanApprovalsNeedInput() {
    let question = Data(claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"text\",\"text\":\"?\"},{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\"}]}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(question).phase == .needsInput)
    let plan = Data(claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"name\":\"ExitPlanMode\"}]}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(plan).phase == .needsInput)
    let ordinary = Data(claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\"}]}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(ordinary).phase == .thinking)
    // The answer arrives as a tool result and the session is working again.
    let answered = question + Data(claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(answered).phase == .thinking)
}

@Test func claudeCodeEndOfTurnMeansCompleteAndAPIErrorMeansError() {
    let ended = Data(claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(ended).phase == .complete)
    let failed = Data(claudeRecord("system", extra: ",\"subtype\":\"api_error\"").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(failed).phase == .error)
    let hook = Data(claudeRecord("system", extra: ",\"subtype\":\"stop_hook_summary\"").utf8)
    #expect(ClaudeCodeSessionDecoder.decode(hook).phase == nil)
}

@Test func claudeCodeNewestRecordWinsAndTitlesPreferTheCustomOne() {
    let transcript = Data((
        claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":\"go\"}")
        + claudeRecord("ai-title", extra: ",\"aiTitle\":\"Generated\"")
        + claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}")
        + claudeRecord("custom-title", extra: ",\"customTitle\":\"Chosen\"")
        + claudeRecord("attachment", extra: ",\"attachment\":{\"type\":\"total_tokens_reminder\"}")
    ).utf8)
    let result = ClaudeCodeSessionDecoder.decode(transcript)
    #expect(result.phase == .complete)
    #expect(result.title == "Chosen")

    // A tail that starts mid-line drops the partial first line.
    let partial = Data(("garbage" + claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":\"go\"}")).utf8)
    #expect(ClaudeCodeSessionDecoder.decode(partial, startsMidLine: true).phase == nil)
}

@Test func claudeCodeProjectDirectoriesReplaceEveryOtherCharacter() {
    #expect(ClaudeCodeAgentProvider.projectDirectoryName(for: "/Users/me/Developer/usAIge") == "-Users-me-Developer-usAIge")
    #expect(ClaudeCodeAgentProvider.projectDirectoryName(for: "/Users/me/.slock/agents") == "-Users-me--slock-agents")
    #expect(ClaudeCodeAgentProvider.projectDirectoryName(for: "/Users/me/My App") == "-Users-me-My-App")
}

@Test func claudeCodeProviderReportsOnlyRunningSessions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-claude-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let project = root.appendingPathComponent("projects/-Users-me-app", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    for (pid, session) in [(11, "live"), (22, "dead")] {
        try Data("{\"pid\":\(pid),\"sessionId\":\"\(session)\",\"cwd\":\"/Users/me/app\",\"name\":\"app-1\"}".utf8)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
        try Data((
            claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":\"go\"}")
            + claudeRecord("assistant", extra: ",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}")
        ).utf8).write(to: project.appendingPathComponent("\(session).jsonl"))
    }

    let provider = ClaudeCodeAgentProvider(
        claudeDirectory: root,
        isProcessAlive: { $0 == 11 },
        now: { Date() }
    )
    let tasks = try await provider.refresh()
    #expect(tasks.count == 1)
    #expect(tasks.first?.id == "live")
    #expect(tasks.first?.toolID == .claude)
    #expect(tasks.first?.phase == .complete)
    #expect(tasks.first?.title == "app-1")
    #expect(tasks.first?.workspaceName == "app")

    // Appending a prompt turns the session back to working.
    let handle = try FileHandle(forWritingTo: project.appendingPathComponent("live.jsonl"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(claudeRecord("user", extra: ",\"message\":{\"role\":\"user\",\"content\":\"more\"}").utf8))
    try handle.close()
    #expect(try await provider.refresh().first?.phase == .thinking)
}

// MARK: Grok Build

private func grokLine(_ message: String, pid: Int = 500, sid: String? = "sid-1", ctx: String = "{}", level: String = "info", at seconds: Int = 0) -> String {
    let sidField = sid.map { ",\"sid\":\"\($0)\"" } ?? ""
    return "{\"ts\":\"2026-09-02T15:50:\(String(format: "%02d", seconds)).000Z\",\"src\":\"grok-pager\",\"pid\":\(pid),\"lvl\":\"\(level)\"\(sidField),\"msg\":\"\(message)\",\"ctx\":\(ctx)}\n"
}

@Test func grokBuildTurnsLightWhileWorkingAndSettleWhenComplete() {
    let working = Data((grokLine("prompt received") + grokLine("turn.phase_transition", ctx: "{\"from\":\"waiting_model\",\"to\":\"thinking\"}", at: 1)).utf8)
    #expect(GrokBuildLogDecoder.sessions(from: working)["sid-1"]?.phase == .thinking)

    let complete = Data((grokLine("turn.phase_transition", ctx: "{\"from\":\"tool_running\",\"to\":\"idle\"}") + grokLine("turn.complete", ctx: "{\"ok\":true,\"was_cancelling\":false}", at: 1)).utf8)
    let state = GrokBuildLogDecoder.sessions(from: complete)["sid-1"]
    #expect(state?.phase == .complete)
    #expect(state?.pid == 500)
    #expect(state?.updatedAt == AgentActivityFiles.timestamp("2026-09-02T15:50:01.000Z"))

    let cancelled = Data(grokLine("turn.complete", ctx: "{\"ok\":true,\"was_cancelling\":true}").utf8)
    #expect(GrokBuildLogDecoder.sessions(from: cancelled)["sid-1"]?.phase == .idle)

    let failed = Data(grokLine("shell.turn.inference_failed", level: "error").utf8)
    #expect(GrokBuildLogDecoder.sessions(from: failed)["sid-1"]?.phase == .error)
}

@Test func grokBuildSessionEndClosesEverySessionOfThatProcess() {
    let data = Data((
        grokLine("prompt received", pid: 500, sid: "a")
        + grokLine("prompt received", pid: 600, sid: "b", at: 1)
        + grokLine("session_end.worker_join", pid: 500, sid: nil, at: 2)
    ).utf8)
    let sessions = GrokBuildLogDecoder.sessions(from: data)
    #expect(sessions["a"]?.phase == .idle)
    #expect(sessions["b"]?.phase == .thinking)
}

@Test func grokBuildSessionEndClosesASessionThatStartedBeforeTheTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-grok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
    let log = root.appendingPathComponent("logs/unified.jsonl")
    try Data(grokLine("prompt received", pid: 500, sid: "long").utf8).write(to: log)
    let provider = GrokBuildAgentProvider(grokDirectory: root, isProcessAlive: { _ in true }, now: { Date() })
    #expect(try await provider.refresh().first?.phase == .thinking)

    // Push the start record out of the tail, then end the process.
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    let noise = Data(grokLine("shell.image_budget", pid: 500, sid: nil, at: 2).utf8)
    var padding = Data()
    while padding.count < Int(GrokBuildAgentProvider.maximumTailBytes) + 1024 { padding.append(noise) }
    try handle.write(contentsOf: padding)
    try handle.write(contentsOf: Data(grokLine("session_end.worker_join", pid: 500, sid: nil, at: 3).utf8))
    try handle.close()
    #expect(try await provider.refresh().first?.phase == .idle)
}

@Test func grokBuildProviderDropsSessionsWhoseProcessIsGone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-grok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/%2FUsers%2Fme%2Fapp/live-sid"), withIntermediateDirectories: true)
    try Data((grokLine("prompt received", pid: 500, sid: "live-sid") + grokLine("prompt received", pid: 600, sid: "dead-sid", at: 1)).utf8)
        .write(to: root.appendingPathComponent("logs/unified.jsonl"))

    let provider = GrokBuildAgentProvider(grokDirectory: root, isProcessAlive: { $0 == 500 }, now: { Date() })
    let tasks = try await provider.refresh()
    #expect(tasks.map(\.id) == ["live-sid"])
    #expect(tasks.first?.toolID == .grok)
    #expect(tasks.first?.phase == .thinking)
    #expect(tasks.first?.workspaceName == "app")
}

// MARK: Cursor

@Test func cursorComposerStatusMapsToALight() {
    #expect(CursorComposerState.phase(status: "completed", generatingCount: 0, hasBlockingPendingActions: false) == .complete)
    #expect(CursorComposerState.phase(status: "completed", generatingCount: 1, hasBlockingPendingActions: false) == .thinking)
    #expect(CursorComposerState.phase(status: "generating", generatingCount: 0, hasBlockingPendingActions: false) == .thinking)
    #expect(CursorComposerState.phase(status: "aborted", generatingCount: 0, hasBlockingPendingActions: false) == .idle)
    #expect(CursorComposerState.phase(status: "none", generatingCount: 0, hasBlockingPendingActions: false) == .idle)
    #expect(CursorComposerState.phase(status: "error", generatingCount: 0, hasBlockingPendingActions: false) == .error)
    #expect(CursorComposerState.phase(status: "generating", generatingCount: 2, hasBlockingPendingActions: true) == .needsInput)
    #expect(CursorComposerState.phase(status: nil, generatingCount: 0, hasBlockingPendingActions: false) == .idle)
}

@Test func cursorProviderIsQuietWithoutADatabase() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-missing-\(UUID().uuidString).vscdb")
    let provider = CursorAgentProvider(databaseURL: missing)
    #expect(try await provider.refresh().isEmpty)
}

// MARK: Store

private actor ScriptedActivityProvider: CodexAgentProviding {
    private var tasks: [CodexAgentTask]
    init(_ tasks: [CodexAgentTask]) { self.tasks = tasks }
    func set(_ tasks: [CodexAgentTask]) { self.tasks = tasks }
    func refresh() async throws -> [CodexAgentTask] { tasks }
    func stop() async {}
}

private func activity(_ phase: CodexAgentPhase, id: String, tool: AIToolID = .chatGPT) -> CodexAgentTask {
    CodexAgentTask(id: id, title: "Task", workspaceName: "Workspace", phase: phase, updatedAt: referenceDate, toolID: tool)
}

@MainActor
@Test func agentStoreKeepsOneLightPerTool() async {
    let codex = ScriptedActivityProvider([activity(.thinking, id: "codex-1")])
    let claude = ScriptedActivityProvider([activity(.complete, id: "claude-1")])
    let store = CodexAgentStore(sources: [
        .init(toolID: .chatGPT, provider: codex),
        .init(toolID: .claude, provider: claude),
    ])
    var changes: [(AIToolID, CodexAgentPhase)] = []
    store.onAggregatePhaseChanged = { toolID, phase, _ in changes.append((toolID, phase)) }

    await store.refresh()
    #expect(store.phase(for: .chatGPT) == .thinking)
    #expect(store.phase(for: .claude) == .complete)
    #expect(store.phase(for: .cursor) == .idle)
    #expect(store.phase == .thinking)
    // Tasks carry the tool they were reported for, whatever the provider said.
    #expect(store.targetTask(for: .claude)?.toolID == .claude)
    #expect(changes.map(\.0).sorted { $0.rawValue < $1.rawValue } == [.chatGPT, .claude])

    // Acknowledging one tool leaves the other lit.
    store.acknowledge(taskID: "claude-1")
    #expect(store.phase(for: .claude) == .idle)
    #expect(store.phase(for: .chatGPT) == .thinking)

    // Looking at Claude Code's app settles only its attention states.
    await claude.set([activity(.complete, id: "claude-2", tool: .claude)])
    await codex.set([activity(.complete, id: "codex-1")])
    await store.refresh()
    #expect(store.phase(for: .claude) == .complete)
    #expect(store.phase(for: .chatGPT) == .complete)
    store.acknowledgeAttentionStates(for: .claude, viewedAt: referenceDate)
    #expect(store.phase(for: .claude) == .idle)
    #expect(store.phase(for: .chatGPT) == .complete)
}

@MainActor
@Test func agentStoreBacksOffPerSource() async {
    let failing = FailingActivityProvider()
    let working = ScriptedActivityProvider([activity(.thinking, id: "claude-1")])
    let store = CodexAgentStore(sources: [
        .init(toolID: .chatGPT, provider: failing),
        .init(toolID: .claude, provider: working),
    ])
    await store.refresh()
    await store.refresh()
    #expect(store.nextPollingDelay(for: .chatGPT) == CodexAgentStore.failureBackoff[1])
    #expect(store.nextPollingDelay(for: .claude) == CodexAgentStore.pollingInterval)
    #expect(store.phase(for: .claude) == .thinking)
}

private actor FailingActivityProvider: CodexAgentProviding {
    struct Failure: Error {}
    func refresh() async throws -> [CodexAgentTask] { throw Failure() }
    func stop() async {}
}

// MARK: Relay

@Test func relaySnapshotCarriesEachToolsSessionStatus() {
    var claude = QuotaSnapshot(
        id: "claude",
        displayName: "All models",
        usedPercent: 20,
        remainingPercent: 80,
        resetAt: nil,
        windowDurationMinutes: 300,
        planType: nil,
        updatedAt: referenceDate
    )
    claude.toolID = .claude
    let thinking = RelaySessionStatusPayload(phase: .thinking, updatedAt: referenceDate)
    let complete = RelaySessionStatusPayload(phase: .complete, updatedAt: referenceDate)
    let payload = RelaySnapshotPayload.make(
        from: [Fixtures.codexSnapshot, claude],
        sessionStatuses: [.chatGPT: thinking, .claude: complete]
    )
    #expect(payload.tools[0].sessionStatus == thinking)
    #expect(payload.tools[1].sessionStatus == complete)
}

@Test func relaySessionEventsNameTheToolWhenATitleIsMissing() throws {
    let task = CodexAgentTask(id: "s1", title: " ", workspaceName: "app", phase: .complete, updatedAt: referenceDate, toolID: .claude)
    let payload = try #require(RelaySessionEventPayload(task: task))
    #expect(payload.sessionTitle == "Claude session")
    #expect(payload.eventID.hasPrefix("claude:s1:complete:"))
}
