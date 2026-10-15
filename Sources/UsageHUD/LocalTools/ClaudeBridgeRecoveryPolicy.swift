import Foundation

struct ClaudeBridgeRecoveryHeartbeat: Equatable, Sendable {
    var observedAt: Date? = nil
    var checkedAt: Date? = nil
    var nextAttemptAt: Date? = nil
    var state: String? = nil
}

enum ClaudeBridgeLifecycleKind: Equatable, Sendable {
    case paused
    case stopped
    case started
}

struct ClaudeBridgeLifecycleEvent: Equatable, Sendable {
    let recordedAt: Date
    let kind: ClaudeBridgeLifecycleKind
}

enum ClaudeBridgeLifecycleParser {
    /// Only native lifecycle records for the configured session are accepted.
    /// File order takes precedence when a clock adjustment moves time backward.
    static func latestEvent(
        in text: String,
        sessionID: String,
        timeZone: TimeZone = .current
    ) -> ClaudeBridgeLifecycleEvent? {
        guard isCanonicalClaudeSessionID(sessionID) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false

        let pauses = [
            "[info] [CCD] Pausing session \(sessionID) (idle_timeout)",
            "[info] [CCD] Pausing session \(sessionID) (governor_evict)",
        ]
        let stop = "[info] Stopping session \(sessionID)"
        let start = "[info] Starting local session \(sessionID) in "
        let warming = "[info] [CCD] Warming session \(sessionID)"
        let warmed = "[info] [CCD] Session \(sessionID) warmed successfully in "
        var latest: ClaudeBridgeLifecycleEvent?
        for line in text.components(separatedBy: .newlines) {
            guard line.count > 20, line.dropFirst(19).first == " " else { continue }
            let timestamp = String(line.prefix(19))
            guard let date = formatter.date(from: timestamp),
                  formatter.string(from: date) == timestamp else { continue }
            let message = String(line.dropFirst(20))
            let kind: ClaudeBridgeLifecycleKind
            if pauses.contains(message) {
                kind = .paused
            } else if message == stop {
                kind = .stopped
            } else if message == warming || isSuccessfulClaudeWarm(message, prefix: warmed) {
                kind = .started
            } else if message.hasPrefix(start),
                      !message.dropFirst(start.count).trimmingCharacters(in: .whitespaces).isEmpty {
                kind = .started
            } else {
                continue
            }
            latest = ClaudeBridgeLifecycleEvent(recordedAt: date, kind: kind)
        }
        return latest
    }
}

struct ClaudeBridgeRecoveryAttempt: Codable, Equatable, Sendable {
    let sessionID: String
    let eventDate: Date
    let attemptedAt: Date
}

/// Decides whether a known, previously working collector was paused by Claude.
/// Opening the session and persisting the attempt belong to the controller.
struct ClaudeBridgeRecoveryPolicy: Sendable {
    static let maximumPauseAge: TimeInterval = 24 * 60 * 60
    static let logPrecisionTolerance: TimeInterval = 1
    static let retryGrace: TimeInterval = 90
    static let activeHeartbeatAge: TimeInterval = 5 * 60 + retryGrace
    static let minimumAttemptInterval: TimeInterval = 15 * 60

    private(set) var lastAttempt: ClaudeBridgeRecoveryAttempt?

    init(lastAttempt: ClaudeBridgeRecoveryAttempt? = nil) {
        self.lastAttempt = lastAttempt
    }

    mutating func shouldRecover(
        sessionID: String,
        now: Date,
        event: ClaudeBridgeLifecycleEvent?,
        heartbeat: ClaudeBridgeRecoveryHeartbeat,
        claudeIsRunning: Bool,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled, claudeIsRunning, isCanonicalClaudeSessionID(sessionID),
              now.timeIntervalSince1970.isFinite,
              let event, event.kind == .paused,
              (0...Self.maximumPauseAge).contains(now.timeIntervalSince(event.recordedAt)),
              let observed = heartbeat.observedAt,
              observed.timeIntervalSince1970.isFinite, observed <= now,
              observed <= event.recordedAt.addingTimeInterval(Self.logPrecisionTolerance)
        else { return false }

        if let next = heartbeat.nextAttemptAt {
            guard next.timeIntervalSince1970.isFinite,
                  now >= next.addingTimeInterval(Self.retryGrace) else { return false }
        }
        if let checked = heartbeat.checkedAt {
            // A future heartbeat after a clock correction cannot prove that
            // the collector has stopped. Wait instead of opening prematurely.
            guard checked.timeIntervalSince1970.isFinite, checked <= now else { return false }
            if checked > event.recordedAt.addingTimeInterval(Self.logPrecisionTolerance),
               now.timeIntervalSince(checked) <= Self.activeHeartbeatAge {
                return false
            }
        }
        if let lastAttempt {
            guard lastAttempt.attemptedAt.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince(lastAttempt.attemptedAt) >= Self.minimumAttemptInterval else { return false }
            // Persisting the latest event is sufficient to reject earlier
            // records after log rotation or restart, including the same pause.
            if lastAttempt.sessionID == sessionID, event.recordedAt <= lastAttempt.eventDate {
                return false
            }
        }

        lastAttempt = ClaudeBridgeRecoveryAttempt(sessionID: sessionID, eventDate: event.recordedAt, attemptedAt: now)
        return true
    }
}

private func isCanonicalClaudeSessionID(_ value: String) -> Bool {
    guard value.hasPrefix("local_"), value.count == 42 else { return false }
    let uuid = String(value.dropFirst(6))
    return UUID(uuidString: uuid)?.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
}

private func isSuccessfulClaudeWarm(_ message: String, prefix: String) -> Bool {
    guard message.hasPrefix(prefix), message.hasSuffix("ms") else { return false }
    let duration = String(message.dropFirst(prefix.count).dropLast(2))
    return duration.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
        && Double(duration)?.isFinite == true
}
