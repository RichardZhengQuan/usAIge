import Foundation
import Testing
@testable import UsageHUD

private let recoveryMonitorNow = LocalToolDates.parse("2026-10-15T00:30:00Z")!
private let recoveryMonitorSession = "local_8e73d18c-2720-43a7-b704-f01fa4ef27ed"
private let recoveryMonitorOtherSession = "local_d512d281-8e24-4afa-8ee2-53787df2c6f9"
private let recoveryMonitorOrganization = "33333333-3333-4333-8333-333333333333"

private struct RecoveryMonitorFixture {
    let home: URL
    let directory: URL
    let lifecycleURL: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usaige-recovery-monitor-\(UUID().uuidString)")
        directory = home.appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        lifecycleURL = home.appendingPathComponent("Library/Logs/Claude/main.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lifecycleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    func writeConfiguration(
        sessionID: String = recoveryMonitorSession,
        enabled: Bool = true,
        schemaVersion: Int = 1
    ) throws {
        try writeJSON([
            "schemaVersion": schemaVersion,
            "desktopSessionID": sessionID,
            "enabled": enabled,
        ], to: directory.appendingPathComponent("recovery.json"))
    }

    func writeResponse(observedAt: Date = recoveryMonitorNow.addingTimeInterval(-900)) throws {
        try writeJSON([
            "schemaVersion": 1,
            "observedAt": iso(observedAt),
            "organizationID": recoveryMonitorOrganization,
            "usage": ["five_hour": ["utilization": 4, "resets_at": iso(recoveryMonitorNow.addingTimeInterval(3_600))]],
        ], to: directory.appendingPathComponent("response.json"))
    }

    func writeStatus(
        checkedAt: Date = recoveryMonitorNow.addingTimeInterval(-900),
        nextAttemptAt: Date? = nil,
        state: String = "ready"
    ) throws {
        var value: [String: Any] = ["schemaVersion": 1, "checkedAt": iso(checkedAt), "state": state]
        if let nextAttemptAt { value["nextAttemptAt"] = iso(nextAttemptAt) }
        try writeJSON(value, to: directory.appendingPathComponent("status.json"))
    }

    func prepareWorkingCollector() throws {
        try writeConfiguration()
        try writeResponse()
        try writeStatus()
    }

    func writeLog(_ lines: [String], prefix: String = "") throws {
        try Data((prefix + lines.joined(separator: "\n") + "\n").utf8).write(to: lifecycleURL)
    }

    func logLine(
        _ action: String = "paused",
        at date: Date = recoveryMonitorNow.addingTimeInterval(-600),
        sessionID: String = recoveryMonitorSession
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let message: String
        switch action {
        case "paused": message = "[info] [CCD] Pausing session \(sessionID) (idle_timeout)"
        case "evicted": message = "[info] [CCD] Pausing session \(sessionID) (governor_evict)"
        case "stopped": message = "[info] Stopping session \(sessionID)"
        case "started": message = "[info] Starting local session \(sessionID) in /fixture/project"
        default: message = action
        }
        return "\(formatter.string(from: date)) \(message)"
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
}

@Suite("ClaudeBridgeRecoveryMonitor")
struct ClaudeBridgeRecoveryMonitorTests {
    @Test func missingConfigurationCannotResumeAStaleCollector() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.writeResponse()
        try fixture.writeStatus()
        try fixture.writeLog([fixture.logLine()])
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test(arguments: [
        "8e73d18c-2720-43a7-b704-f01fa4ef27ed",
        "local_not-a-uuid",
        "local_8e73d18c-2720-43a7-b704-f01fa4ef27ed-suffix",
        " local_8e73d18c-2720-43a7-b704-f01fa4ef27ed",
    ])
    func invalidConfiguredSessionIsNeverOpened(sessionID: String) async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeConfiguration(sessionID: sessionID)
        try fixture.writeLog([fixture.logLine()])
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func disabledOrUnknownConfigurationCannotOpenClaude() async throws {
        for (enabled, version) in [(false, 1), (true, 2)] {
            let fixture = try RecoveryMonitorFixture()
            defer { fixture.cleanup() }
            try fixture.prepareWorkingCollector()
            try fixture.writeConfiguration(enabled: enabled, schemaVersion: version)
            try fixture.writeLog([fixture.logLine()])
            let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
            #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
        }
    }

    @Test func runningAppAndEnabledToolAreRequiredWithoutConsumingTheRecoveryAttempt() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine()])
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: false, isEnabled: true) == nil)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: false) == nil)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test(arguments: ["paused", "evicted"])
    func genuineNativePauseOfAnOlderWorkingCollectorResumesOnlyItsExactSession(action: String) async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine(action)])
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        let url = try #require(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "claude")
        #expect(components.host == "code")
        #expect(components.path == "/continue")
        #expect(components.queryItems == [URLQueryItem(name: "session", value: recoveryMonitorSession)])
    }

    @Test func mereStalenessOrAnotherSessionsPauseDoesNotTriggerNavigation() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        try fixture.writeLog([fixture.logLine("[info] Collector is idle")])
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
        try fixture.writeLog([fixture.logLine(sessionID: recoveryMonitorOtherSession)])
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
        try fixture.writeLog([fixture.logLine("[info] [CCD] Pausing session \(recoveryMonitorSession) (user_request)")])
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test(arguments: ["stopped", "started"])
    func aLaterExplicitStopOrStartSupersedesTheEarlierPause(action: String) async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([
            fixture.logLine(at: recoveryMonitorNow.addingTimeInterval(-600)),
            fixture.logLine(action, at: recoveryMonitorNow.addingTimeInterval(-300)),
        ])
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func laterSuccessfulReadingOrRecentHeartbeatMeansTheCollectorAlreadyRecovered() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine()])
        try fixture.writeResponse(observedAt: recoveryMonitorNow.addingTimeInterval(-60))
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
        try fixture.writeResponse()
        try fixture.writeStatus(checkedAt: recoveryMonitorNow.addingTimeInterval(-30), state: "refreshing")
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func aFutureRetryDeadlineHonorsServerBackoffWithoutRecordingARecoveryAttempt() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine()])
        try fixture.writeStatus(nextAttemptAt: recoveryMonitorNow.addingTimeInterval(300), state: "error")
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("recovery-attempt.json").path))
    }

    @Test func missingPartialOrInvalidStatusCannotEraseBackoffOrConsumeTheRecoveryAttempt() async throws {
        let invalidStatuses: [String?] = [
            nil,
            #"{"schemaVersion":1,"checkedAt":"#,
            #"{"schemaVersion":2,"checkedAt":"2026-10-15T00:15:00Z"}"#,
            #"{"schemaVersion":"1","checkedAt":"2026-10-15T00:15:00Z"}"#,
            #"{"schemaVersion":1}"#,
            #"{"schemaVersion":1,"checkedAt":"invalid"}"#,
            #"{"schemaVersion":1,"checkedAt":123}"#,
        ]
        for invalidStatus in invalidStatuses {
            let fixture = try RecoveryMonitorFixture()
            defer { fixture.cleanup() }
            try fixture.prepareWorkingCollector()
            try fixture.writeLog([fixture.logLine()])
            let statusURL = fixture.directory.appendingPathComponent("status.json")
            if let invalidStatus {
                try Data(invalidStatus.utf8).write(to: statusURL)
            } else {
                try FileManager.default.removeItem(at: statusURL)
            }
            let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
            #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("recovery-attempt.json").path))

            // Completing the status write restores its actual retry deadline;
            // the earlier incomplete read must not spend the one allowed open.
            let retryAt = recoveryMonitorNow.addingTimeInterval(300)
            try fixture.writeStatus(nextAttemptAt: retryAt, state: "error")
            #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
            #expect(await monitor.recoveryURL(at: retryAt.addingTimeInterval(90), claudeIsRunning: true, isEnabled: true) != nil)
        }
    }

    @Test func malformedPresentRetryDeadlineCannotBeTreatedAsNoBackoff() async throws {
        for invalidDeadline in ["null", "7", "true", "{}", #""not-a-date""#] {
            let fixture = try RecoveryMonitorFixture()
            defer { fixture.cleanup() }
            try fixture.prepareWorkingCollector()
            try fixture.writeLog([fixture.logLine()])
            let status = #"{"schemaVersion":1,"checkedAt":"2026-10-15T00:15:00Z","state":"error","nextAttemptAt":\#(invalidDeadline)}"#
            try Data(status.utf8).write(to: fixture.directory.appendingPathComponent("status.json"))
            let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
            #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("recovery-attempt.json").path))
        }
    }

    @Test func persistedAttemptPreventsTheSameNavigationAfterMonitorRestart() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        let pausedAt = recoveryMonitorNow.addingTimeInterval(-600)
        try fixture.writeLog([fixture.logLine(at: pausedAt)])
        let first = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await first.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) != nil)
        let attemptURL = fixture.directory.appendingPathComponent("recovery-attempt.json")
        let attempt = try JSONDecoder().decode(ClaudeBridgeRecoveryAttempt.self, from: Data(contentsOf: attemptURL))
        #expect(attempt.sessionID == recoveryMonitorSession)
        #expect(attempt.eventDate == pausedAt)
        #expect(attempt.attemptedAt == recoveryMonitorNow)
        let restarted = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await restarted.recoveryURL(at: recoveryMonitorNow.addingTimeInterval(1_800), claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func aSymlinkedConfigurationIsRejectedEvenWhenItsTargetIsValid() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine()])
        let configurationURL = fixture.directory.appendingPathComponent("recovery.json")
        let targetURL = fixture.directory.appendingPathComponent("real-recovery.json")
        try FileManager.default.moveItem(at: configurationURL, to: targetURL)
        try FileManager.default.createSymbolicLink(at: configurationURL, withDestinationURL: targetURL)
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func oversizedButValidConfigurationIsRejectedBeforeDecoding() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([fixture.logLine()])
        let configurationURL = fixture.directory.appendingPathComponent("recovery.json")
        var configuration = try Data(contentsOf: configurationURL)
        configuration.append(contentsOf: String(repeating: " ", count: 4_096).utf8)
        try configuration.write(to: configurationURL)
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }

    @Test func boundedLargeLogTailRetainsTheExactSessionEventAfterAPartialFirstLine() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        try fixture.writeLog([
            fixture.logLine(),
            fixture.logLine("stopped", at: recoveryMonitorNow.addingTimeInterval(-300), sessionID: recoveryMonitorOtherSession),
        ], prefix: String(repeating: "discarded-prefix", count: 30_000) + "\n")
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) != nil)
    }

    @Test func aPauseOutsideTheBoundedLogTailIsNotUsedAsCurrentLifecycleEvidence() async throws {
        let fixture = try RecoveryMonitorFixture()
        defer { fixture.cleanup() }
        try fixture.prepareWorkingCollector()
        let outsideTail = fixture.logLine() + "\n" + String(repeating: "irrelevant-line\n", count: 30_000)
        try fixture.writeLog([], prefix: outsideTail)
        let monitor = ClaudeBridgeRecoveryMonitor(homeDirectory: fixture.home)
        #expect(await monitor.recoveryURL(at: recoveryMonitorNow, claudeIsRunning: true, isEnabled: true) == nil)
    }
}
