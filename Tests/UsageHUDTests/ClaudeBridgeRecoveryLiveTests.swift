import Foundation
import Testing
@testable import UsageHUD

private let liveRecoverySession = ProcessInfo.processInfo.environment["USAIGE_LIVE_CLAUDE_RECOVERY_SESSION"]

/// Opt-in smoke test after stopping ONLY the verified, idle collector engine.
/// Lifecycle input is a fixture, while navigation, engine resume, and the
/// resulting usage report are real. No native log or report is falsified.
@Suite("ClaudeBridgeRecoveryLive", .enabled(if: liveRecoverySession != nil))
struct ClaudeBridgeRecoveryLiveTests {
    @Test @MainActor func reopeningExistingCollectorProducesANewRealUsageReport() async throws {
        let session = try #require(liveRecoverySession)
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        let responseURL = real.appendingPathComponent("response.json")
        let responseData = try Data(contentsOf: responseURL)
        let response = try #require(JSONValue.parse(responseData))
        let baseline = try #require(LocalToolDates.parse(response["observedAt"]?.stringValue))
        let statusData = try Data(contentsOf: real.appendingPathComponent("status.json"))
        let status = try #require(JSONValue.parse(statusData))
        let retryAt = LocalToolDates.parse(status["nextAttemptAt"]?.stringValue) ?? Date()
        try #require(status["state"]?.stringValue == "ready", "Live recovery requires an idle, healthy collector")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-live-recovery-\(UUID())")
        let directory = fixture.appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        let log = fixture.appendingPathComponent("Library/Logs/Claude/main.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "desktopSessionID": session, "enabled": true,
        ]).write(to: directory.appendingPathComponent("recovery.json"))
        try responseData.write(to: directory.appendingPathComponent("response.json"))
        try statusData.write(to: directory.appendingPathComponent("status.json"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try Data("\(formatter.string(from: Date())) [info] [CCD] Pausing session \(session) (governor_evict)\n".utf8)
            .write(to: log)
        // The default Usage-page route would read the real home; this proof
        // isolates the Code continuation route.
        let controller = ClaudeBridgeRecoveryController(monitor: ClaudeBridgeRecoveryMonitor(homeDirectory: fixture),
                                                       pageMonitor: nil, isEnabled: { true })
        controller.start()
        defer { controller.stop() }
        let deadline = max(Date().addingTimeInterval(120), retryAt.addingTimeInterval(180))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let data = try? Data(contentsOf: responseURL),
               let value = JSONValue.parse(data),
               let observed = LocalToolDates.parse(value["observedAt"]?.stringValue), observed > baseline {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery-attempt.json").path))
                print("[live recovery] Existing session reopened; new real usage report: \(observed)")
                return
            }
        }
        Issue.record("No new live report after automatic reopening of the existing collector")
    }
}
