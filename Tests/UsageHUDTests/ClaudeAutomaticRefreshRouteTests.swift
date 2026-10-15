import Foundation
import Testing
@testable import UsageHUD

private let routeNow = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
private let routeOrganization = "33333333-3333-4333-8333-333333333333"
private let routeSession = "local_8e73d18c-2720-43a7-b704-f01fa4ef27ed"
private let codeURL = URL(string: "claude://code/continue?session=\(routeSession)")!
private let usagePageURL = URL(string: "claude://claude.ai/settings/usage")!

private actor RouteStub: ClaudeCodeRecoveryProviding, ClaudeUsagePageProviding {
    private var url: URL?
    private(set) var calls = 0

    init(_ url: URL?) { self.url = url }

    func set(_ url: URL?) { self.url = url }

    func recoveryURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) -> URL? {
        calls += 1
        return url
    }

    func usagePageURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) -> URL? {
        calls += 1
        return url
    }
}

/// Answers each read in turn, then repeats the last answer.
@MainActor
private final class Answers {
    private var values: [Bool]
    init(_ values: Bool...) { self.values = values }
    func next() -> Bool { values.count > 1 ? values.removeFirst() : values[0] }
}

@MainActor
private final class Harness {
    let home: URL
    var date = routeNow
    var opened: [URL] = []
    var enabled = Answers(true)
    var running = Answers(true)

    var directory: URL { home.appendingPathComponent("Library/Application Support/usAIge/claude-usage") }
    var historyURL: URL { home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json") }
    var logURL: URL { home.appendingPathComponent("Library/Logs/Claude/main.log") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func controller(recovery: any ClaudeCodeRecoveryProviding,
                    page: (any ClaudeUsagePageProviding)?) -> ClaudeBridgeRecoveryController {
        ClaudeBridgeRecoveryController(
            monitor: recovery, pageMonitor: page, grace: ClaudeNavigationGrace(directory: directory),
            isEnabled: { [unowned self] in enabled.next() },
            isClaudeRunning: { [unowned self] in running.next() },
            openURL: { [unowned self] in opened.append($0) },
            now: { [unowned self] in date })
    }

    /// The production routes over this fixture home, with no plugin, settings,
    /// or recovery configuration unless a test writes one.
    func realController() -> ClaudeBridgeRecoveryController {
        controller(recovery: ClaudeBridgeRecoveryMonitor(homeDirectory: home),
                   page: ClaudeUsagePageRefreshMonitor(homeDirectory: home))
    }

    /// Claude Desktop's own poller records a plan reading after sign-in.
    func writeDesktopReading(at date: Date) throws {
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": [[
            "t": date.timeIntervalSince1970 * 1_000, "org": routeOrganization, "u": ["fh": 12, "sd": 37],
        ]]]).write(to: historyURL)
    }

    /// A collector that reported at `routeNow - 900` and whose Desktop session
    /// was later paused by Claude.
    func writePausedCodeCollector() throws {
        try json(["schemaVersion": 1, "desktopSessionID": routeSession, "enabled": true], "recovery.json")
        try json([
            "schemaVersion": 1, "observedAt": iso(routeNow.addingTimeInterval(-900)), "organizationID": routeOrganization,
            "usage": ["five_hour": ["utilization": 12, "resets_at": iso(routeNow.addingTimeInterval(3_600))]],
        ], "response.json")
        try writeStatus(checkedAt: routeNow.addingTimeInterval(-900), next: routeNow.addingTimeInterval(-600), state: "ready")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pausedAt = formatter.string(from: routeNow.addingTimeInterval(-600))
        try Data("\(pausedAt) [info] [CCD] Pausing session \(routeSession) (idle_timeout)\n".utf8).write(to: logURL)
    }

    func writeStatus(checkedAt: Date, next: Date, state: String) throws {
        try json(["schemaVersion": 1, "checkedAt": iso(checkedAt), "nextAttemptAt": iso(next), "state": state], "status.json")
    }

    func usAIgeFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func json(_ object: [String: Any], _ name: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name))
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

@Suite("Claude automatic refresh routes")
struct ClaudeAutomaticRefreshRouteTests {
    @Test @MainActor func usAIgeInstalledFirstRefreshesThroughClaudesUsagePageWithoutSetup() async throws {
        let h = try Harness()
        defer { h.remove() }
        let controller = h.realController()

        // Claude is not installed or not open yet: nothing is opened or recorded.
        h.running = Answers(false)
        await controller.check()
        // Claude is installed and open, but Desktop has not recorded a reading.
        h.running = Answers(true)
        h.date = routeNow.addingTimeInterval(60)
        await controller.check()
        #expect(h.opened.isEmpty)
        #expect(h.usAIgeFiles().isEmpty)

        // Desktop records its first reading; a fresh reading keeps Claude quiet.
        try h.writeDesktopReading(at: routeNow.addingTimeInterval(120))
        h.date = routeNow.addingTimeInterval(180)
        await controller.check()
        #expect(h.opened.isEmpty)

        h.date = routeNow.addingTimeInterval(510)
        await controller.check()
        #expect(h.opened == [usagePageURL])
        // Still stale 30 seconds later, but one attempt has been made.
        h.date = routeNow.addingTimeInterval(540)
        await controller.check()
        #expect(h.opened == [usagePageURL])
        // No Code session, plugin, or recovery configuration was involved.
        #expect(h.usAIgeFiles() == ["usage-page-refresh.json"])
        #expect(!FileManager.default.fileExists(atPath: h.home.appendingPathComponent(".claude").path))
    }

    @Test @MainActor func claudeInstalledFirstRefreshesOnUsAIgesFirstCheck() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.writeDesktopReading(at: routeNow.addingTimeInterval(-900))
        await h.realController().check()
        #expect(h.opened == [usagePageURL])
        #expect(h.usAIgeFiles() == ["usage-page-refresh.json"])
    }

    @Test @MainActor func hiddenClaudeOrAClosedClaudeNeverConsultsEitherRoute() async throws {
        let h = try Harness()
        defer { h.remove() }
        let code = RouteStub(codeURL), page = RouteStub(usagePageURL)
        let controller = h.controller(recovery: code, page: page)
        h.enabled = Answers(false)
        await controller.check()
        h.enabled = Answers(true)
        h.running = Answers(false)
        await controller.check()
        #expect(await code.calls == 0)
        #expect(await page.calls == 0)
        #expect(h.opened.isEmpty)
    }

    @Test @MainActor func anEstablishedCodeCollectorIsReopenedBeforeThePageIsConsulted() async throws {
        let h = try Harness()
        defer { h.remove() }
        let page = RouteStub(usagePageURL)
        await h.controller(recovery: RouteStub(codeURL), page: page).check()
        #expect(h.opened == [codeURL])
        #expect(await page.calls == 0)
    }

    @Test @MainActor func thePageIsAFallbackOnlyWhenTheReopenedCollectorStaysSilent() async throws {
        for collectorResponds in [false, true] {
            let h = try Harness()
            defer { h.remove() }
            try h.writePausedCodeCollector()
            try h.writeDesktopReading(at: routeNow.addingTimeInterval(-900))
            let controller = h.realController()

            await controller.check()
            #expect(h.opened.count == 1)
            #expect(h.opened.first?.absoluteString.hasPrefix("claude://code/continue") == true)
            #expect(!h.usAIgeFiles().contains("usage-page-refresh.json"))

            // Within the shared grace neither route records or opens anything.
            h.date = routeNow.addingTimeInterval(30)
            await controller.check()
            #expect(h.opened.count == 1)
            #expect(!h.usAIgeFiles().contains("usage-page-refresh.json"))

            if collectorResponds {
                try h.writeStatus(checkedAt: routeNow.addingTimeInterval(20), next: routeNow.addingTimeInterval(320),
                                  state: "refreshing")
            }
            h.date = routeNow.addingTimeInterval(91)
            await controller.check()
            if collectorResponds {
                #expect(h.opened.count == 1)
            } else {
                #expect(h.opened.count == 2)
                #expect(h.opened.last == usagePageURL)
            }
        }
    }

    @Test @MainActor func persistedAttemptsFromEitherRouteHoldBothRoutesAcrossRestart() async throws {
        let recovery = try JSONEncoder().encode(ClaudeBridgeRecoveryAttempt(
            sessionID: routeSession, eventDate: routeNow.addingTimeInterval(-60), attemptedAt: routeNow.addingTimeInterval(-30)))
        let pageAttempt = try JSONEncoder().encode(ClaudeUsagePageRefreshMonitor.Attempt(
            schemaVersion: 1, organizationID: routeOrganization,
            baselineAt: routeNow.addingTimeInterval(-900), attemptedAt: routeNow.addingTimeInterval(-30)))
        for (name, data) in [("recovery-attempt.json", recovery), ("usage-page-refresh.json", pageAttempt)] {
            let h = try Harness()
            defer { h.remove() }
            try data.write(to: h.directory.appendingPathComponent(name))
            let code = RouteStub(codeURL), page = RouteStub(usagePageURL)
            // A freshly launched usAIge has no in-memory record of that attempt.
            let controller = h.controller(recovery: code, page: page)
            h.date = routeNow.addingTimeInterval(59)
            await controller.check()
            #expect(h.opened.isEmpty)
            #expect(await code.calls == 0)
            #expect(await page.calls == 0)
            h.date = routeNow.addingTimeInterval(60)
            await controller.check()
            #expect(h.opened == [codeURL])
        }
    }

    @Test @MainActor func aNavigationHoldsTheOtherRouteEvenWithoutAPersistedRecord() async throws {
        let h = try Harness()
        defer { h.remove() }
        let code = RouteStub(nil)
        let controller = h.controller(recovery: code, page: RouteStub(usagePageURL))
        await controller.check()
        #expect(h.opened == [usagePageURL])
        await code.set(codeURL)
        h.date = routeNow.addingTimeInterval(89)
        await controller.check()
        #expect(h.opened == [usagePageURL])
        #expect(await code.calls == 1)
        h.date = routeNow.addingTimeInterval(90)
        await controller.check()
        #expect(h.opened == [usagePageURL, codeURL])
    }

    @Test @MainActor func enabledAndRunningAreRecheckedAfterEachRouteDecides() async throws {
        let h = try Harness()
        defer { h.remove() }
        // Hidden in the rail while the Code route was deciding.
        h.enabled = Answers(true, false)
        let page = RouteStub(usagePageURL)
        await h.controller(recovery: RouteStub(codeURL), page: page).check()
        #expect(h.opened.isEmpty)
        #expect(await page.calls == 0)

        // Claude quit while the Usage-page route was deciding.
        h.enabled = Answers(true)
        h.running = Answers(true, true, false)
        let fallback = RouteStub(usagePageURL)
        await h.controller(recovery: RouteStub(nil), page: fallback).check()
        #expect(await fallback.calls == 1)
        #expect(h.opened.isEmpty)
    }

    @Test @MainActor func withoutAPageMonitorOnlyTheCodeRouteRuns() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.writeDesktopReading(at: routeNow.addingTimeInterval(-900))
        await h.controller(recovery: ClaudeBridgeRecoveryMonitor(homeDirectory: h.home), page: nil).check()
        #expect(h.opened.isEmpty)
        #expect(h.usAIgeFiles().isEmpty)
    }
}
