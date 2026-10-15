import AppKit
import Foundation
import Testing
@testable import UsageHUD

private let liveUsagePageEnabled = ProcessInfo.processInfo.environment["USAIGE_LIVE_CLAUDE_USAGE_PAGE"] == "1"

private struct LiveStaleClaudePageSource: ClaudeAppUsageSource {
    let sample: ClaudeAppUsageSample
    func latestSample() -> ClaudeAppUsageSample? { sample }
}

/// Opt-in verification of the public Usage-page fallback. Only the staleness
/// input is a fixture. URL navigation, Claude's authenticated fetch, Chromium
/// cache update, and the native usAIge decoder are real; no cache is modified.
@Suite("ClaudeUsagePageRefreshLive", .enabled(if: liveUsagePageEnabled))
struct ClaudeUsagePageRefreshLiveTests {
    @Test @MainActor func usagePageNavigationProducesFreshNativeCache() async throws {
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            .contains(where: { !$0.isTerminated }), "Claude must already be running")
        let native = ClaudeAppUsageHistory()
        let before = try #require(native.latestSample(), "An existing Claude usage observation is required")
        let organization = try #require(before.organizationID)
        let started = Date()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-usage-page-live-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stale = ClaudeAppUsageSample(recordedAt: started.addingTimeInterval(-900),
                                        sessionPercent: before.sessionPercent, weeklyPercent: before.weeklyPercent,
                                        organizationID: organization)
        let historyURL = fixture.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": [[
            "t": stale.recordedAt.timeIntervalSince1970 * 1_000,
            "org": organization,
            "u": ["fh": stale.sessionPercent ?? 0, "sd": stale.weeklyPercent ?? 0],
        ]]]).write(to: historyURL)
        let monitor = ClaudeUsagePageRefreshMonitor(homeDirectory: fixture,
                                                   source: LiveStaleClaudePageSource(sample: stale))
        let controller = ClaudeBridgeRecoveryController(
            monitor: ClaudeBridgeRecoveryMonitor(homeDirectory: fixture), pageMonitor: monitor, isEnabled: { true })
        controller.start()
        defer { controller.stop() }
        let deadline = started.addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let reading = native.latestSample(), reading.organizationID == organization,
                  let cache = reading.cachedUsage,
                  cache.recordedAt > before.recordedAt,
                  cache.recordedAt >= started.addingTimeInterval(-1) else { continue }
            print("[live usage page] Public navigation produced a new validated native cache at \(cache.recordedAt)")
            if let destination = ProcessInfo.processInfo.environment["USAIGE_LIVE_EVIDENCE_DIRECTORY"] {
                let receipt: [String: Any] = [
                    "test": "ClaudeUsagePageRefreshLiveTests.usagePageNavigationProducesFreshNativeCache",
                    "stalenessInput": "Isolated fixture; production cache and history unmodified",
                    "url": "claude://claude.ai/settings/usage",
                    "startedAt": ISO8601DateFormatter().string(from: started),
                    "beforeObservedAt": ISO8601DateFormatter().string(from: before.recordedAt),
                    "afterObservedAt": ISO8601DateFormatter().string(from: cache.recordedAt),
                    "organizationMatches": true,
                    "passwordOrKeychainAccess": false,
                    "manualDetect": false,
                    "modelRequests": false,
                ]
                let url = URL(fileURLWithPath: destination).appendingPathComponent("claude-usage-page-live-verification.json")
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            }
            return
        }
        Issue.record("No new validated native cache after public Claude Usage-page navigation")
    }
}
