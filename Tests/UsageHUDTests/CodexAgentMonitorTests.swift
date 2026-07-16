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
