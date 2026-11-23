import Foundation
import Testing
@testable import UsageHUD

@Suite struct UsageCardSummaryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func limit(_ name: String, minutes: Int, resetAfter: TimeInterval?,
                       weeklyAfter: TimeInterval? = nil) -> QuotaSnapshot {
        QuotaSnapshot.make(from: RateLimitBucket(
            limitID: name, limitName: name, usedPercent: 25, windowDurationMinutes: minutes,
            resetsAt: resetAfter.map { now.timeIntervalSince1970 + $0 }, planType: nil,
            secondaryUsedPercent: weeklyAfter.map { _ in 20 }, secondaryWindowDurationMinutes: weeklyAfter.map { _ in 10_080 },
            secondaryResetsAt: weeklyAfter.map { now.timeIntervalSince1970 + $0 }
        ), updatedAt: now)
    }

    @Test func sharedResetsAppearOnceAndDifferentResetTimesKeepTheirModelNames() {
        let shared = limit("All models", minutes: 300, resetAfter: 900, weeklyAfter: 1_800)
        let different = limit("Opus", minutes: 300, resetAfter: 1_200, weeklyAfter: 1_800)
        let more = limit("Daily", minutes: 1_440, resetAfter: nil)
        #expect(UsageCardSummary.resets([shared], now: now) == "5H resets in 15 min  ·  7D resets in 30 min")
        #expect(UsageCardSummary.resets([shared, shared, different, more], now: now)
                == "All models 5H resets in 15 min  ·  7D resets in 30 min  ·  Opus 5H resets in 20 min  ·  +1 more")
        #expect(UsageCardSummary.resets([more], now: now) == "1D reset time unavailable")
        #expect(UsageCardSummary.resets([], now: now) == nil)
    }

    @Test func workNamesTheReportedProjectAndDoesNotInventActivity() {
        func session(_ id: String, _ tool: AIToolID) -> LiveSessionWork {
            LiveSessionWork(id: id, toolID: tool, title: "Review a change", phase: .needsInput, updatedAt: now,
                            folder: "/work/usAIge", repositoryName: "usAIge", branch: "main",
                            detachedAt: nil, placement: .mainCopy, processes: [])
        }
        var summary = LiveWorkSummary(sessions: [session("a", .claude), session("b", .chatGPT), session("c", .claude)])
        #expect(UsageCardSummary.work(summary, for: .claude) == "Needs input · usAIge · 1 other session")
        #expect(UsageCardSummary.work(summary, for: .cursor) == nil)
        summary.appProcesses[.cursor] = [WorkProcess(id: 1, name: "Cursor", folder: "/", memoryBytes: 0,
                                                    startedAt: nil, ports: [])]
        #expect(UsageCardSummary.work(summary, for: .cursor) == "1 process")
        #expect(UsageCardSummary.connection(.optInRequired, tool: .copilot) == "Usage reading is off")
        #expect(UsageCardSummary.connection(.credentialExpired, tool: .cursor) == "Sign-in expired")
    }
}
