import Darwin
import Foundation

/// Refreshes Claude's public Usage page only after an established native
/// reading becomes stale. Claude owns the page and all account requests.
actor ClaudeUsagePageRefreshMonitor {
    static let freshReadingAge: TimeInterval = 390
    static let failedAttemptInterval: TimeInterval = 15 * 60
    static let retryGrace: TimeInterval = 90
    static let usagePageURL = URL(string: "claude://claude.ai/settings/usage")!

    struct Attempt: Codable, Sendable {
        let schemaVersion: Int
        let organizationID: String
        let baselineAt: Date
        let attemptedAt: Date
    }

    private enum FileRead {
        case missing
        case invalid
        case data(Data)
    }

    private let homeDirectory: URL
    private let directory: URL
    private let historyURL: URL
    private let source: (any ClaudeAppUsageSource)?

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         source: (any ClaudeAppUsageSource)? = nil) {
        self.homeDirectory = homeDirectory
        directory = homeDirectory.appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        historyURL = homeDirectory.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        self.source = source
    }

    func usagePageURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) -> URL? {
        guard claudeIsRunning, isEnabled, date.timeIntervalSince1970.isFinite,
              case let .data(history) = Self.read(historyURL, maximum: 4 * 1_024 * 1_024),
              let baseline = ClaudeAppUsageHistory.latestSample(from: history),
              let organization = baseline.organizationID.flatMap(UUID.init(uuidString:)),
              baseline.recordedAt.timeIntervalSince1970.isFinite, baseline.recordedAt <= date
        else { return nil }
        let percentages = [baseline.sessionPercent, baseline.weeklyPercent].compactMap { $0 }
        guard !percentages.isEmpty, percentages.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        var observedAt = baseline.recordedAt
        if let latest = latestUsage(at: date) {
            guard latest.recordedAt.timeIntervalSince1970.isFinite, latest.recordedAt <= date else { return nil }
            observedAt = max(observedAt, latest.recordedAt)
        }
        guard date.timeIntervalSince(observedAt) >= Self.freshReadingAge else { return nil }

        switch Self.read(directory.appendingPathComponent("status.json"), maximum: 4_096) {
        case .missing: break
        case .invalid: return nil
        case let .data(data):
            guard let status = JSONValue.parse(data), status["schemaVersion"]?.numberValue == 1,
                  let checked = LocalToolDates.parse(status["checkedAt"]?.stringValue), checked <= date else { return nil }
            var nextAttempt: Date?
            if let value = status["nextAttemptAt"] {
                guard let next = LocalToolDates.parse(value.stringValue) else { return nil }
                nextAttempt = next
            }
            // These known Code failures retry independently of Desktop's
            // public page. Their renewed deadlines must not starve the page
            // fallback; its own persisted cooldown still bounds attempts.
            let noSubscription = status["state"]?.stringValue == "unavailable"
                && status["reason"]?.stringValue == "no_subscription_session"
            let failedCodeRequest = status["state"]?.stringValue == "error"
                && ["profile_request_failed", "usage_request_failed", "refresh_failed"]
                    .contains(status["reason"]?.stringValue ?? "")
            if !noSubscription, !failedCodeRequest,
               let nextAttempt, date < nextAttempt.addingTimeInterval(Self.retryGrace) { return nil }
        }

        let attemptURL = directory.appendingPathComponent("usage-page-refresh.json")
        switch Self.read(attemptURL, maximum: 4_096) {
        case .missing: break
        case .invalid: return nil
        case let .data(data):
            guard let attempt = try? JSONDecoder().decode(Attempt.self, from: data), attempt.schemaVersion == 1,
                  UUID(uuidString: attempt.organizationID) != nil,
                  attempt.attemptedAt.timeIntervalSince1970.isFinite, attempt.attemptedAt <= date,
                  attempt.baselineAt.timeIntervalSince1970.isFinite, attempt.baselineAt <= attempt.attemptedAt else { return nil }
            // A later successful reading permits the normal stale interval.
            // Without one, a failed navigation is retried no more than every
            // fifteen minutes, including after usAIge restarts.
            if observedAt <= attempt.attemptedAt,
               date.timeIntervalSince(attempt.attemptedAt) < Self.failedAttemptInterval { return nil }
        }
        let attempt = Attempt(schemaVersion: 1, organizationID: organization.uuidString.lowercased(),
                              baselineAt: observedAt, attemptedAt: date)
        do {
            let data = try JSONEncoder().encode(attempt)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: attemptURL, options: .atomic)
        } catch { return nil }
        return Self.usagePageURL
    }

    private func latestUsage(at date: Date) -> ClaudeAppUsageSample? {
        if let source { return source.latestSample() }
        return ClaudeAutomaticUsageSource(
            bridge: ClaudeUsageBridgeSource(homeDirectory: homeDirectory, now: { date }),
            desktop: ClaudeAppUsageHistory(homeDirectory: homeDirectory, now: { date })
        ).latestSample()
    }

    private static func read(_ url: URL, maximum: Int) -> FileRead {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return .invalid }
        return .data(data)
    }
}
