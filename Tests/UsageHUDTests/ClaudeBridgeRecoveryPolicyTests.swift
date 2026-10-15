import Foundation
import Testing
@testable import UsageHUD

private let recoverySession = "local_33333333-3333-4333-8333-333333333333"
private let otherRecoverySession = "local_44444444-4444-4444-8444-444444444444"
private let recoveryNow = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z")!
private let recoveryUTC = TimeZone(secondsFromGMT: 0)!

private func pausedCollector(at date: Date = recoveryNow.addingTimeInterval(-60)) -> ClaudeBridgeLifecycleEvent {
    ClaudeBridgeLifecycleEvent(recordedAt: date, kind: .paused)
}

private func previousHeartbeat() -> ClaudeBridgeRecoveryHeartbeat {
    ClaudeBridgeRecoveryHeartbeat(observedAt: recoveryNow.addingTimeInterval(-120),
                                 checkedAt: recoveryNow.addingTimeInterval(-120), state: "ready")
}

@Suite("ClaudeBridgeLifecycleParser")
struct ClaudeBridgeLifecycleParserTests {
    @Test(arguments: ["idle_timeout", "governor_evict"])
    func acceptsOnlySupportedNativePauseReasons(reason: String) throws {
        let text = "2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession) (\(reason))"
        let event = try #require(ClaudeBridgeLifecycleParser.latestEvent(in: text, sessionID: recoverySession, timeZone: recoveryUTC))
        #expect(event == ClaudeBridgeLifecycleEvent(recordedAt: recoveryNow, kind: .paused))
    }

    @Test func exactSessionAndAnchoredNativeRecordsExcludeLookalikes() {
        let records = [
            "2026-10-15 10:00:00 [info] [CCD] Pausing session \(otherRecoverySession) (idle_timeout)",
            "2026-10-15 10:00:00 [info] [CCD] Pausing session prefix-\(recoverySession) (idle_timeout)",
            "2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession)-suffix (idle_timeout)",
            "2026-10-15 10:00:00 [warn] [CCD] Pausing session \(recoverySession) (idle_timeout)",
            "2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession) (user_requested)",
            "2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession) (idle_timeout) extra text",
            "2026-10-15 10:00:00 [info] quoted: [CCD] Pausing session \(recoverySession) (idle_timeout)",
            "prefix 2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession) (idle_timeout)",
            "2026-02-30 10:00:00 [info] [CCD] Pausing session \(recoverySession) (idle_timeout)",
            "2026-10-15 10:00:00 [info] [CCD] Warming session \(otherRecoverySession)",
            "2026-10-15 10:00:00 [info] [CCD] Warming session \(recoverySession)-suffix",
            "2026-10-15 10:00:00 [info] [CCD] Session \(otherRecoverySession) warmed successfully in 12ms",
            "2026-10-15 10:00:00 [info] [CCD] Session \(recoverySession) warmed successfully in NaNms",
            "2026-10-15 10:00:00 [info] [CCD] Session \(recoverySession) warmed successfully in -12ms",
            "2026-10-15 10:00:00 [info] [CCD] Session \(recoverySession) warmed successfully in 1e3ms",
            "2026-10-15 10:00:00 [info] [CCD] Session \(recoverySession) warmed successfully in 12 ms",
            "2026-10-15 10:00:00 [info] [CCD] Session \(recoverySession) warmed successfully in 12ms extra text",
        ]
        for text in records {
            #expect(ClaudeBridgeLifecycleParser.latestEvent(in: text, sessionID: recoverySession, timeZone: recoveryUTC) == nil)
        }
        #expect(ClaudeBridgeLifecycleParser.latestEvent(in: records.joined(separator: "\n"), sessionID: ".*", timeZone: recoveryUTC) == nil)
        let rawCLI = String(recoverySession.dropFirst(6))
        let rawRecord = "2026-10-15 10:00:00 [info] [CCD] Pausing session \(rawCLI) (idle_timeout)"
        #expect(ClaudeBridgeLifecycleParser.latestEvent(in: rawRecord, sessionID: rawCLI, timeZone: recoveryUTC) == nil)
    }

    @Test func laterStopOrStartSupersedesPauseInFileOrderEvenWhenTheClockMovesBackward() throws {
        let pause = "2026-10-15 10:00:00 [info] [CCD] Pausing session \(recoverySession) (idle_timeout)"
        let stop = "2026-10-15 10:00:00 [info] Stopping session \(recoverySession)"
        let start = "2026-10-15 09:59:00 [info] Starting local session \(recoverySession) in /collector directory"
        #expect(ClaudeBridgeLifecycleParser.latestEvent(in: [pause, stop].joined(separator: "\r\n"),
                                                       sessionID: recoverySession, timeZone: recoveryUTC)?.kind == .stopped)
        let last = try #require(ClaudeBridgeLifecycleParser.latestEvent(in: [pause, stop, start].joined(separator: "\n"),
                                                                       sessionID: recoverySession, timeZone: recoveryUTC))
        #expect(last.kind == .started)
        #expect(last.recordedAt == recoveryNow.addingTimeInterval(-60))
        let unrelatedStop = "2026-10-15 10:01:00 [info] Stopping session \(otherRecoverySession)"
        #expect(ClaudeBridgeLifecycleParser.latestEvent(in: [pause, unrelatedStop].joined(separator: "\n"),
                                                       sessionID: recoverySession, timeZone: recoveryUTC)?.kind == .paused)
    }

    @Test func timestampUsesTheNativeLogsTimeZone() {
        let zone = TimeZone(identifier: "Asia/Singapore")!
        let text = "2026-10-15 18:00:00 [info] [CCD] Pausing session \(recoverySession) (idle_timeout)"
        #expect(ClaudeBridgeLifecycleParser.latestEvent(in: text, sessionID: recoverySession, timeZone: zone)?.recordedAt == recoveryNow)
    }

    @Test(arguments: ["warming", "0", "1200", "12.5"])
    func nativeWarmBoundariesAfterAPauseSuppressAnotherRecovery(marker: String) throws {
        let pause = "2026-10-15 09:59:00 [info] [CCD] Pausing session \(recoverySession) (governor_evict)"
        let message = marker == "warming"
            ? "[info] [CCD] Warming session \(recoverySession)"
            : "[info] [CCD] Session \(recoverySession) warmed successfully in \(marker)ms"
        let event = try #require(ClaudeBridgeLifecycleParser.latestEvent(
            in: pause + "\n2026-10-15 09:59:30 " + message,
            sessionID: recoverySession, timeZone: recoveryUTC
        ))
        #expect(event.kind == .started)
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                         heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        #expect(policy.lastAttempt == nil)
    }
}

@Suite("ClaudeBridgeRecoveryPolicy")
struct ClaudeBridgeRecoveryPolicyTests {
    @Test func establishedIdlePauseIsEligibleOnlyWhileEnabledAndClaudeIsRunning() {
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                      heartbeat: previousHeartbeat(), claudeIsRunning: false, isEnabled: true) }())
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                      heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: false) }())
        #expect(policy.lastAttempt == nil)
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                     heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        #expect(policy.lastAttempt == ClaudeBridgeRecoveryAttempt(sessionID: recoverySession,
                                                                  eventDate: pausedCollector().recordedAt, attemptedAt: recoveryNow))
    }

    @Test func staleUsageAloneAndStopOrStartNeverReopenACollector() {
        let events: [ClaudeBridgeLifecycleEvent?] = [
            nil, ClaudeBridgeLifecycleEvent(recordedAt: recoveryNow.addingTimeInterval(-60), kind: .stopped),
            ClaudeBridgeLifecycleEvent(recordedAt: recoveryNow.addingTimeInterval(-60), kind: .started),
            pausedCollector(at: recoveryNow.addingTimeInterval(1)),
            pausedCollector(at: recoveryNow.addingTimeInterval(-ClaudeBridgeRecoveryPolicy.maximumPauseAge - 1)),
        ]
        for event in events {
            var policy = ClaudeBridgeRecoveryPolicy()
            #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                          heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
            #expect(policy.lastAttempt == nil)
        }
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                      heartbeat: ClaudeBridgeRecoveryHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
    }

    @Test func aSuccessfulReadingAfterThePauseProvesTheCollectorAlreadyRecovered() {
        let event = pausedCollector()
        var policy = ClaudeBridgeRecoveryPolicy()
        var heartbeat = previousHeartbeat()
        heartbeat.observedAt = event.recordedAt.addingTimeInterval(1.001)
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        heartbeat.observedAt = event.recordedAt.addingTimeInterval(0.999)
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                     heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
    }

    @Test func rateLimitBackoffAndGraceAreHonoredBeforeReopening() {
        let event = pausedCollector()
        var heartbeat = previousHeartbeat()
        heartbeat.state = "error"
        heartbeat.checkedAt = event.recordedAt.addingTimeInterval(2)
        heartbeat.nextAttemptAt = recoveryNow.addingTimeInterval(15 * 60)
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow.addingTimeInterval(15 * 60 + 89), event: event,
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        #expect(policy.lastAttempt == nil)
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: recoveryNow.addingTimeInterval(15 * 60 + 90), event: event,
                                     heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
    }

    @Test func recentActivityAfterPauseBlocksRecoveryButAnOldCompletionDoesNotBlockForever() {
        let event = pausedCollector()
        var heartbeat = previousHeartbeat()
        let checked = event.recordedAt.addingTimeInterval(2)
        heartbeat.checkedAt = checked
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: checked.addingTimeInterval(390), event: event,
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: checked.addingTimeInterval(391), event: event,
                                     heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
    }

    @Test func futureHeartbeatAndClockRollbackCannotCauseAnEarlyOpen() {
        var heartbeat = previousHeartbeat()
        heartbeat.checkedAt = recoveryNow.addingTimeInterval(1)
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        heartbeat = previousHeartbeat()
        heartbeat.observedAt = recoveryNow.addingTimeInterval(1)
        #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                      heartbeat: heartbeat, claudeIsRunning: true, isEnabled: true) }())
        let attempt = ClaudeBridgeRecoveryAttempt(sessionID: recoverySession,
                                                  eventDate: recoveryNow.addingTimeInterval(-60), attemptedAt: recoveryNow)
        policy = ClaudeBridgeRecoveryPolicy(lastAttempt: attempt)
        let earlierNow = recoveryNow.addingTimeInterval(-600)
        #expect({ !policy.shouldRecover(sessionID: otherRecoverySession, now: earlierNow,
                                      event: pausedCollector(at: earlierNow.addingTimeInterval(-60)),
                                      heartbeat: ClaudeBridgeRecoveryHeartbeat(observedAt: earlierNow.addingTimeInterval(-120)),
                                      claudeIsRunning: true, isEnabled: true) }())
        #expect(policy.lastAttempt == attempt)
    }

    @Test func oneAttemptPerPauseSurvivesPersistenceAndRejectsEarlierRotatedRecords() throws {
        let event = pausedCollector()
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: event,
                                     heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        let attempt = try #require(policy.lastAttempt)
        let persisted = try JSONDecoder().decode(ClaudeBridgeRecoveryAttempt.self, from: JSONEncoder().encode(attempt))
        policy = ClaudeBridgeRecoveryPolicy(lastAttempt: persisted)
        for candidate in [event, pausedCollector(at: event.recordedAt.addingTimeInterval(-1))] {
            #expect({ !policy.shouldRecover(sessionID: recoverySession, now: recoveryNow.addingTimeInterval(3_600), event: candidate,
                                          heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        }
        #expect(policy.lastAttempt == attempt)
    }

    @Test func cooldownAppliesAcrossNewPauseEventsAndDifferentSessions() {
        var policy = ClaudeBridgeRecoveryPolicy()
        #expect({ policy.shouldRecover(sessionID: recoverySession, now: recoveryNow, event: pausedCollector(),
                                     heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        let newerPause = pausedCollector(at: recoveryNow.addingTimeInterval(60))
        #expect({ !policy.shouldRecover(sessionID: otherRecoverySession, now: recoveryNow.addingTimeInterval(899), event: newerPause,
                                      heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        #expect({ policy.shouldRecover(sessionID: otherRecoverySession, now: recoveryNow.addingTimeInterval(900), event: newerPause,
                                     heartbeat: previousHeartbeat(), claudeIsRunning: true, isEnabled: true) }())
        #expect(policy.lastAttempt?.sessionID == otherRecoverySession)
        #expect(policy.lastAttempt?.eventDate == newerPause.recordedAt)
    }
}
