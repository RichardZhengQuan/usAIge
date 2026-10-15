import Foundation
import Testing
@testable import UsageHUD

private let pageRefreshNow = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
private let pageRefreshOrganization = "33333333-3333-4333-8333-333333333333"

private struct PageRefreshSource: ClaudeAppUsageSource {
    let sample: ClaudeAppUsageSample?
    func latestSample() -> ClaudeAppUsageSample? { sample }
}

private struct PageRefreshFixture {
    let home: URL
    var directory: URL { home.appendingPathComponent("Library/Application Support/usAIge/claude-usage") }
    var history: URL { home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json") }
    var attempt: URL { directory.appendingPathComponent("usage-page-refresh.json") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-page-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func writeHistory(at date: Date = pageRefreshNow.addingTimeInterval(-600), percent: Double = 12,
                      organization: String = pageRefreshOrganization) throws {
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": [[
            "t": date.timeIntervalSince1970 * 1_000, "org": organization, "u": ["fh": percent, "sd": 37],
        ]]]).write(to: history)
    }
    func writeStatus(state: String = "error", reason: String = "rate_limited", next: Date,
                     checkedAt: Date = pageRefreshNow.addingTimeInterval(-10)) throws {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "state": state, "reason": reason,
            "checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "nextAttemptAt": ISO8601DateFormatter().string(from: next),
        ]).write(to: directory.appendingPathComponent("status.json"))
    }
    func monitor(sample: ClaudeAppUsageSample? = nil) -> ClaudeUsagePageRefreshMonitor {
        ClaudeUsagePageRefreshMonitor(homeDirectory: home, source: PageRefreshSource(sample: sample))
    }
}

@Suite("ClaudeUsagePageRefreshPolicy")
struct ClaudeUsagePageRefreshPolicyTests {
    @Test func usAIgeFirstWaitsForClaudeAndAnEstablishedNativeReading() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        let monitor = files.monitor()
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: false, isEnabled: true) == nil)
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        try files.writeHistory()
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: false, isEnabled: true) == nil)
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true)
            == URL(string: "claude://claude.ai/settings/usage"))
        #expect(FileManager.default.fileExists(atPath: files.attempt.path))
    }

    @Test func claudeFirstAndItsInitialZeroPercentReadingNeedNoSetupOrEarlyPageOpen() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        let monitor = ClaudeUsagePageRefreshMonitor(homeDirectory: files.home)
        #expect(await monitor.usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        try files.writeHistory(at: pageRefreshNow, percent: 0)
        let native = ClaudeAppUsageHistory(homeDirectory: files.home, now: { pageRefreshNow })
        let sample = try #require(native.latestSample())
        #expect(sample.sessionPercent == 0)
        #expect(ClaudeUsageProvider.snapshots(fromClaudeApp: sample, planType: nil).first?.remainingPercent == 100)
        #expect(await monitor.usagePageURL(at: pageRefreshNow.addingTimeInterval(389), claudeIsRunning: true, isEnabled: true) == nil)
        #expect(await monitor.usagePageURL(at: pageRefreshNow.addingTimeInterval(390), claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test func freshBridgeReadingKeepsThePublicPageQuietDespiteOldNativeHistory() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory()
        let bridge = ClaudeAppUsageSample(recordedAt: pageRefreshNow.addingTimeInterval(-330), sessionPercent: 21,
                                          weeklyPercent: 40, organizationID: pageRefreshOrganization, origin: .bridge)
        #expect(await files.monitor(sample: bridge).usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
    }

    @Test func unsuccessfulNavigationKeepsItsFifteenMinuteCooldownAcrossRestart() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory()
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) != nil)
        let persisted = try JSONDecoder().decode(ClaudeUsagePageRefreshMonitor.Attempt.self, from: Data(contentsOf: files.attempt))
        #expect(persisted.attemptedAt == pageRefreshNow)
        #expect(persisted.organizationID == pageRefreshOrganization)
        let restarted = files.monitor()
        #expect(await restarted.usagePageURL(at: pageRefreshNow.addingTimeInterval(899), claudeIsRunning: true, isEnabled: true) == nil)
        #expect(await restarted.usagePageURL(at: pageRefreshNow.addingTimeInterval(900), claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test func successfulLaterReadingRestoresTheNormalStaleReadingInterval() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory()
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) != nil)
        let updated = ClaudeAppUsageSample(recordedAt: pageRefreshNow.addingTimeInterval(10), sessionPercent: 13,
                                           weeklyPercent: 38, organizationID: pageRefreshOrganization)
        let monitor = files.monitor(sample: updated)
        #expect(await monitor.usagePageURL(at: pageRefreshNow.addingTimeInterval(399), claudeIsRunning: true, isEnabled: true) == nil)
        #expect(await monitor.usagePageURL(at: pageRefreshNow.addingTimeInterval(400), claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test func rateLimitAndUnknownReasonDeadlinesRetainTheirFullGracePeriod() async throws {
        for (state, reason) in [("error", "rate_limited"), ("unavailable", "other_reason"), ("error", "no_subscription_session")] {
            let files = try PageRefreshFixture()
            defer { files.remove() }
            try files.writeHistory()
            let retry = pageRefreshNow.addingTimeInterval(300)
            try files.writeStatus(state: state, reason: reason, next: retry)
            let monitor = files.monitor()
            #expect(await monitor.usagePageURL(at: retry.addingTimeInterval(89), claudeIsRunning: true, isEnabled: true) == nil)
            #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
            #expect(await monitor.usagePageURL(at: retry.addingTimeInterval(90), claudeIsRunning: true, isEnabled: true) != nil)
        }
    }

    @Test func anAPIKeyCodeSessionCannotStarveValidDesktopUsageWithAuthorizationRetries() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory()
        try files.writeStatus(state: "unavailable", reason: "no_subscription_session", next: pageRefreshNow.addingTimeInterval(120))
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) != nil)
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow.addingTimeInterval(390), claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test(arguments: ["profile_request_failed", "usage_request_failed", "refresh_failed"])
    func renewedKnownCodeFailureDeadlinesCannotStarveTheBoundedPublicFallback(reason: String) async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory()
        for elapsed in stride(from: 0, through: 840, by: 120) {
            let date = pageRefreshNow.addingTimeInterval(TimeInterval(elapsed))
            try files.writeStatus(reason: reason, next: date.addingTimeInterval(120), checkedAt: date)
            let url = await files.monitor().usagePageURL(at: date, claudeIsRunning: true, isEnabled: true)
            #expect((url != nil) == (elapsed == 0))
        }
        let first = try JSONDecoder().decode(ClaudeUsagePageRefreshMonitor.Attempt.self, from: Data(contentsOf: files.attempt))
        #expect(first.attemptedAt == pageRefreshNow)
        let later = pageRefreshNow.addingTimeInterval(900)
        try files.writeStatus(reason: reason, next: later.addingTimeInterval(120), checkedAt: later)
        #expect(await files.monitor().usagePageURL(at: later, claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test func renewedRateLimitRefreshingAndUnknownFailureDeadlinesRemainProtected() async throws {
        for (state, reason, delay) in [("error", "rate_limited", 900.0),
                                       ("refreshing", "profile_request_failed", 300.0),
                                       ("error", "unknown_error", 120.0)] {
            let files = try PageRefreshFixture()
            defer { files.remove() }
            try files.writeHistory()
            for elapsed in stride(from: 0, through: 840, by: 120) {
                let date = pageRefreshNow.addingTimeInterval(TimeInterval(elapsed))
                try files.writeStatus(state: state, reason: reason, next: date.addingTimeInterval(delay), checkedAt: date)
                #expect(await files.monitor().usagePageURL(at: date, claudeIsRunning: true, isEnabled: true) == nil)
            }
            #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
            let finalDeadline = pageRefreshNow.addingTimeInterval(840 + delay)
            let monitor = files.monitor()
            #expect(await monitor.usagePageURL(at: finalDeadline.addingTimeInterval(89), claudeIsRunning: true, isEnabled: true) == nil)
            #expect(await monitor.usagePageURL(at: finalDeadline.addingTimeInterval(90), claudeIsRunning: true, isEnabled: true) != nil)
        }
    }

    @Test func unreadableOrMalformedExistingStatusCannotDiscardBackoff() async throws {
        let statuses = [
            #"{"schemaVersion":1,"checkedAt":"#,
            #"{"schemaVersion":2,"checkedAt":"2026-10-15T11:59:50Z"}"#,
            #"{"schemaVersion":1,"checkedAt":"invalid"}"#,
            #"{"schemaVersion":1,"checkedAt":"2026-10-15T11:59:50Z","nextAttemptAt":null}"#,
        ]
        for status in statuses {
            let files = try PageRefreshFixture()
            defer { files.remove() }
            try files.writeHistory()
            try Data(status.utf8).write(to: files.directory.appendingPathComponent("status.json"))
            #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
            #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
        }
    }

    @Test func futureReadingsAndPersistedFutureAttemptsDoNotOpenAfterClockRollback() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory(at: pageRefreshNow.addingTimeInterval(1))
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        try files.writeHistory()
        let future = ClaudeAppUsageSample(recordedAt: pageRefreshNow.addingTimeInterval(1), sessionPercent: 2,
                                         weeklyPercent: nil, organizationID: pageRefreshOrganization)
        #expect(await files.monitor(sample: future).usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        let attempt = ClaudeUsagePageRefreshMonitor.Attempt(schemaVersion: 1, organizationID: pageRefreshOrganization,
                                                           baselineAt: pageRefreshNow.addingTimeInterval(-600),
                                                           attemptedAt: pageRefreshNow.addingTimeInterval(1))
        try JSONEncoder().encode(attempt).write(to: files.attempt)
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func invalidOrEmptyOrganizationEvidenceNeverOpensAUsagePage() async throws {
        let files = try PageRefreshFixture()
        defer { files.remove() }
        try files.writeHistory(organization: "invalid")
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        try Data(#"{"samples":[]}"#.utf8).write(to: files.history)
        #expect(await files.monitor().usagePageURL(at: pageRefreshNow, claudeIsRunning: true, isEnabled: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: files.attempt.path))
    }
}
