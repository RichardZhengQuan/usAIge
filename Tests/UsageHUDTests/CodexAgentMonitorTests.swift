import Foundation
import Testing
@testable import UsageHUD

private let referenceDate = Date(timeIntervalSince1970: 2_000_000)

@Test func mapsActiveCodexTurnToThinking() {
    #expect(agentPhase("task_started") == .thinking)
}

@Test func mapsCompletedCodexTurnToComplete() {
    #expect(agentPhase("task_complete") == .complete)
}

@Test func mapsCodexElicitationToNeedsInput() {
    #expect(agentPhase("request_user_input") == .needsInput)
    #expect(agentPhase("exec_approval_request") == .needsInput)
}

@Test func mapsCodexErrorsAndInterruptionsSeparately() {
    #expect(agentPhase("error") == .error)
    #expect(agentPhase("turn_aborted", extra: ",\"reason\":\"interrupted\"") == .idle)
}

@Test func newestAgentEventWins() {
    let data = Data(
        """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"request_user_input"}}
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8
    )
    #expect(CodexAgentSessionDecoder.phase(
        from: data,
        updatedAt: referenceDate,
        now: referenceDate
    ) == .complete)
}

@Test func oldCompletedAgentSettlesToIdle() {
    #expect(CodexAgentSessionDecoder.phase(
        from: eventData("task_complete"),
        updatedAt: referenceDate.addingTimeInterval(-3_601),
        now: referenceDate
    ) == .idle)
}

@Test func findsActiveTurnBeforeAFullTailOfNonLifecycleEvents() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-long-session-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    var data = eventData("task_started")
    let noise = Data(
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8
    )
    while data.count < 512 * 1024 { data.append(noise) }
    try data.write(to: url)

    #expect(CodexAgentSessionDecoder.phase(
        at: url,
        updatedAt: referenceDate,
        now: referenceDate
    ) == .thinking)
}

@Test func recentDecodePreservesActiveStateWhenStartFallsOutOfTail() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-appended-session-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let noise = Data(
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8
    )
    var data = Data()
    while data.count < 512 * 1024 { data.append(noise) }
    try data.write(to: url)

    #expect(CodexAgentSessionDecoder.recentPhase(
        at: url,
        initialPhase: .thinking,
        updatedAt: referenceDate,
        now: referenceDate
    ) == .thinking)
}

@Test func aggregatesAgentStatesIntoOnePrioritizedLight() {
    #expect(CodexAgentStore.aggregate([task(.idle), task(.thinking)]) == .thinking)
    #expect(CodexAgentStore.aggregate([task(.thinking), task(.needsInput)]) == .needsInput)
    #expect(CodexAgentStore.aggregate([task(.thinking), task(.complete)]) == .complete)
    #expect(CodexAgentStore.aggregate([task(.needsInput), task(.complete)]) == .complete)
    #expect(CodexAgentStore.aggregate([task(.thinking), task(.error)]) == .error)
    #expect(CodexAgentStore.aggregate([task(.error), task(.needsInput)]) == .error)
    #expect(CodexAgentStore.aggregate([task(.error), task(.complete)]) == .error)
}

@Test func aggregateTargetsMostRecentTaskWithinWinningStatus() throws {
    let olderError = task(
        .error,
        id: "older-error",
        updatedAt: referenceDate.addingTimeInterval(-10)
    )
    let newerError = task(.error, id: "newer-error", updatedAt: referenceDate)
    let newerCompletion = task(
        .complete,
        id: "newer-completion",
        updatedAt: referenceDate.addingTimeInterval(10)
    )

    let aggregate = CodexAgentStore.aggregateStatus([
        olderError,
        newerCompletion,
        newerError,
    ])

    #expect(aggregate.phase == .error)
    #expect(aggregate.task?.id == "newer-error")
}

@Test func idleAggregateDoesNotRenderAStatusLight() {
    #expect(CodexAgentStore.aggregate([]) == .idle)
    #expect(CodexAgentPhase.idle.showsLight == false)
    #expect(CodexAgentPhase.thinking.showsLight)
    #expect(CodexAgentPhase.complete.showsLight)
    #expect(CodexAgentPhase.needsInput.showsLight)
    #expect(CodexAgentPhase.error.showsLight)
}

@Test func oneNeedsInputSessionMakesHundredActiveSessionAggregateYellow() {
    let tasks = Array(repeating: CodexAgentPhase.thinking, count: 99).map { task($0) }
        + [task(.needsInput)]
    #expect(tasks.count == CodexAgentProvider.maximumActiveSessions)
    #expect(CodexAgentStore.aggregate(tasks) == .needsInput)
}

@Test func acknowledgingAttentionStatesAdvancesThroughTheAggregate() throws {
    let error = task(.error, id: "error", updatedAt: referenceDate)
    let completion = task(.complete, id: "completion", updatedAt: referenceDate)
    let needsInput = task(.needsInput, id: "input", updatedAt: referenceDate)
    let thinking = task(.thinking, id: "thinking", updatedAt: referenceDate)
    let tasks = [thinking, needsInput, completion, error]
    var acknowledgements: [String: CodexAgentAcknowledgement] = [:]

    func currentTarget() throws -> CodexAgentTask {
        try #require(CodexAgentStore.aggregateStatus(CodexAgentStore.unacknowledgedTasks(
            tasks,
            acknowledgements: acknowledgements
        )).task)
    }

    #expect(try currentTarget().id == "error")
    acknowledgements[error.id] = acknowledgement(for: error)
    #expect(try currentTarget().id == "completion")
    acknowledgements[completion.id] = acknowledgement(for: completion)
    #expect(try currentTarget().id == "input")
    acknowledgements[needsInput.id] = acknowledgement(for: needsInput)
    #expect(try currentTarget().id == "thinking")
}

@Test func acknowledgedTaskReturnsWhenItsStateChanges() {
    let completed = task(.complete, id: "task", updatedAt: referenceDate)
    let acknowledgement = [completed.id: acknowledgement(for: completed)]

    #expect(CodexAgentStore.unacknowledgedTasks(
        [completed],
        acknowledgements: acknowledgement
    ).isEmpty)
    #expect(CodexAgentStore.unacknowledgedTasks(
        [task(.thinking, id: completed.id, updatedAt: referenceDate)],
        acknowledgements: acknowledgement
    ).count == 1)
    #expect(CodexAgentStore.unacknowledgedTasks(
        [task(.complete, id: completed.id, updatedAt: referenceDate.addingTimeInterval(1))],
        acknowledgements: acknowledgement
    ).count == 1)
}

private func agentPhase(_ type: String, extra: String = "") -> CodexAgentPhase {
    CodexAgentSessionDecoder.phase(
        from: eventData(type, extra: extra),
        updatedAt: referenceDate,
        now: referenceDate
    )
}

private func eventData(_ type: String, extra: String = "") -> Data {
    Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"\(extra)}}\n".utf8)
}

private func task(
    _ phase: CodexAgentPhase,
    id: String = UUID().uuidString,
    updatedAt: Date = referenceDate
) -> CodexAgentTask {
    CodexAgentTask(
        id: id,
        title: "Task",
        workspaceName: "Workspace",
        phase: phase,
        updatedAt: updatedAt
    )
}

private func acknowledgement(for task: CodexAgentTask) -> CodexAgentAcknowledgement {
    CodexAgentAcknowledgement(phase: task.phase, updatedAt: task.updatedAt)
}
