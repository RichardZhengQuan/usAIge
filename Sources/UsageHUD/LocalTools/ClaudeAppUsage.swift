import Foundation

/// One plan-usage reading the Claude desktop app recorded.
struct ClaudeAppUsageSample: Equatable, Sendable {
    let recordedAt: Date
    let sessionPercent: Double?
    let weeklyPercent: Double?
    var organizationID: String? = nil
    var cachedUsage: ClaudeDesktopCachedUsage? = nil
    var origin: Origin = .desktop
    /// Reset times an earlier response gave for the windows this reading
    /// is still in. A window's reset doesn't move until it passes.
    var sessionResetAt: Date? = nil
    var weeklyResetAt: Date? = nil
    /// The free resets Claude last listed, kept while the week's usage
    /// hasn't dropped since: using a reset lowers it.
    var resetCredits: [ResetCredit]? = nil
    /// The weekly reset of the response that listed them, which ties them
    /// to one account.
    var resetCreditsWeeklyResetAt: Date? = nil

    enum Origin: Sendable { case desktop, bridge }
}

protocol ClaudeAppUsageSource: Sendable {
    /// The newest reading, or `nil` when the Claude app has recorded none.
    func latestSample() -> ClaudeAppUsageSample?
}

/// Reads the plan usage the Claude desktop app records while it runs, in
/// `~/Library/Application Support/Claude/plan-usage-history.json`. The app
/// polls its own signed-in account every few minutes and appends the 5-hour
/// (`fh`) and 7-day (`sd`) percentages. Its HTTP response cache also carries
/// server reset timestamps and model-scoped limits. Both are local reads;
/// usAIge never accesses the desktop app's sign-in or sends a request.
struct ClaudeAppUsageHistory: ClaudeAppUsageSource {
    private let fileURL: URL
    private let readCachedUsage: @Sendable (String, Date) -> ClaudeDesktopCachedUsage?
    /// The newest response from earlier in the week, read only for the
    /// reset times of windows still running.
    private let readEarlierUsage: @Sendable (String, Date) -> ClaudeDesktopCachedUsage?
    /// The newest response that lists Claude's free resets.
    private let readResetCredits: @Sendable (String, Date) -> ClaudeDesktopCachedUsage?
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        readCachedUsage: (@Sendable (String, Date) -> ClaudeDesktopCachedUsage?)? = nil,
        readEarlierUsage: (@Sendable (String, Date) -> ClaudeDesktopCachedUsage?)? = nil,
        readResetCredits: (@Sendable (String, Date) -> ClaudeDesktopCachedUsage?)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        fileURL = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("plan-usage-history.json")
        let cache = ClaudeDesktopUsageCache(homeDirectory: homeDirectory)
        let earlier = ClaudeDesktopUsageCache(homeDirectory: homeDirectory, acceptedAge: ClaudeDesktopUsageCache.resetLookback)
        let credits = ClaudeDesktopUsageCache(homeDirectory: homeDirectory, acceptedAge: ClaudeDesktopUsageCache.resetLookback,
                                              requiresResetCredits: true)
        self.readCachedUsage = readCachedUsage ?? { cache.latestUsage(organizationID: $0, now: $1) }
        // A test that supplies its own cache reads nothing else from disk.
        if let readEarlierUsage {
            self.readEarlierUsage = readEarlierUsage
        } else if readCachedUsage != nil {
            self.readEarlierUsage = { @Sendable _, _ in nil }
        } else {
            self.readEarlierUsage = { @Sendable id, date in earlier.latestUsage(organizationID: id, now: date) }
        }
        if let readResetCredits {
            self.readResetCredits = readResetCredits
        } else if readCachedUsage != nil {
            self.readResetCredits = { @Sendable _, _ in nil }
        } else {
            self.readResetCredits = { @Sendable id, date in credits.latestUsage(organizationID: id, now: date) }
        }
        self.now = now
    }

    func latestSample() -> ClaudeAppUsageSample? {
        guard let sample = readingWithoutResetCredits() else { return nil }
        guard let organizationID = sample.organizationID else { return sample }
        let date = now()
        guard let response = readResetCredits(organizationID, date) else { return sample }
        return Self.attachingResetCredits(from: response, to: sample, now: date)
    }

    /// Claude's free resets from a response that lists them, while the
    /// week's usage hasn't dropped since it: using a reset lowers it, so a
    /// response from before that may list one that's gone.
    static func attachingResetCredits(from usage: ClaudeDesktopCachedUsage, to sample: ClaudeAppUsageSample,
                                      now: Date) -> ClaudeAppUsageSample {
        guard usage.recordedAt <= now,
              let payload = ClaudeDesktopUsageCache.validatedPayload(usage.payload, now: now),
              let current = sample.weeklyPercent, let earlier = percentages(from: payload).weekly, current >= earlier
        else { return sample }
        let credits = ClaudeUsageProvider.resetCredits(from: usage.payload)
        guard !credits.isEmpty else { return sample }
        var sample = sample
        sample.resetCredits = credits
        sample.resetCreditsWeeklyResetAt = resetTimes(from: payload).weekly
        return sample
    }

    private func readingWithoutResetCredits() -> ClaudeAppUsageSample? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        guard var sample = Self.latestSample(from: data) else { return nil }
        let date = now()
        // A clock correction can leave native history ahead of the current
        // time. It must not outrank a usable bridge response and then cause
        // the provider to discard both sources as future data.
        guard sample.recordedAt <= date else { return nil }
        // History identifies the most recently observed organization. Its
        // percentages can be stale even while Claude writes a new response.
        // Freshness is required of the response we display, not that older
        // observation; a future history record still cannot select a cache.
        guard let organizationID = sample.organizationID else { return sample }
        let cached = readCachedUsage(organizationID, date)
        guard let usage = cached,
              (0...ClaudeDesktopUsageCache.maximumAge).contains(date.timeIntervalSince(usage.recordedAt))
        else {
            // Too old to show, but its reset times still hold for any
            // window that hasn't reset since.
            let earlier = cached.flatMap { $0.recordedAt <= date ? $0 : nil } ?? readEarlierUsage(organizationID, date)
            return Self.carryingResets(from: earlier, into: sample, now: date)
        }
        let percents = Self.percentages(from: usage.payload)
        if usage.recordedAt < sample.recordedAt {
            // A later history observation must agree with an older response
            // before that response is shown. When it has moved on, only the
            // reset times of windows still running carry over.
            guard sample.sessionPercent.map({ $0 == percents.session }) ?? true,
                  sample.weeklyPercent.map({ $0 == percents.weekly }) ?? true
            else { return Self.carryingResets(from: usage, into: sample, now: date) }
        } else {
            sample = ClaudeAppUsageSample(
                recordedAt: usage.recordedAt,
                sessionPercent: percents.session,
                weeklyPercent: percents.weekly,
                organizationID: organizationID
            )
        }
        sample.cachedUsage = usage
        return sample
    }

    static func latestSample(from data: Data) -> ClaudeAppUsageSample? {
        guard let samples = JSONValue.parse(data)?["samples"]?.arrayValue else { return nil }
        // Even an empty reading can record an organization switch. Never
        // borrow the previous organization's cached usage after that switch.
        let newestRecord = samples.enumerated().compactMap { index, sample -> (Double, Int, JSONValue)? in
            guard let time = sample["t"]?.lenientNumber, time.isFinite else { return nil }
            return (time, index, sample)
        }.max(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 })?.2
        let currentOrganization = newestRecord?["org"]?.stringValue.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
        var latest: ClaudeAppUsageSample?
        for sample in samples {
            let organization = sample["org"]?.stringValue.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
            guard currentOrganization == nil || organization == currentOrganization,
                  let millis = sample["t"]?.lenientNumber, millis.isFinite,
                  let usage = sample["u"], usage.objectValue != nil else { continue }
            let reading = ClaudeAppUsageSample(
                recordedAt: Date(timeIntervalSince1970: millis / 1000),
                sessionPercent: usage["fh"]?.lenientNumber.flatMap { $0.isFinite ? $0 : nil },
                weeklyPercent: usage["sd"]?.lenientNumber.flatMap { $0.isFinite ? $0 : nil },
                organizationID: currentOrganization
            )
            guard reading.sessionPercent != nil || reading.weeklyPercent != nil else { continue }
            if latest.map({ reading.recordedAt >= $0.recordedAt }) ?? true { latest = reading }
        }
        return latest
    }

    /// Includes empty observations, which can identify an account switch
    /// before that account has any usage to display.
    static func latestOrganization(from data: Data) -> (id: String, recordedAt: Date)? {
        guard let samples = JSONValue.parse(data)?["samples"]?.arrayValue,
              let newest = samples.enumerated().compactMap({ index, sample -> (Double, Int, String)? in
                  guard let time = sample["t"]?.lenientNumber, time.isFinite,
                        let id = sample["org"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
                  return (time, index, id.uuidString.lowercased())
              }).max(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 })
        else { return nil }
        return (newest.2, Date(timeIntervalSince1970: newest.0 / 1_000))
    }

    /// Takes an earlier response's reset times for the windows this reading
    /// is still in. Usage only grows within a window, so a reading below
    /// the response's means that window has reset since, and its time is
    /// dropped; so is any reset that has already passed.
    static func carryingResets(from usage: ClaudeDesktopCachedUsage?, into sample: ClaudeAppUsageSample,
                               now: Date) -> ClaudeAppUsageSample {
        guard let usage, usage.recordedAt <= now,
              let payload = ClaudeDesktopUsageCache.validatedPayload(usage.payload, now: now) else { return sample }
        let percents = percentages(from: payload)
        let resets = resetTimes(from: payload)
        var sample = sample
        let sessionRunning = sample.sessionPercent.flatMap { current in percents.session.map { current >= $0 } }
        let weekRunning = sample.weeklyPercent.flatMap { current in percents.weekly.map { current >= $0 } }
        if sessionRunning == true { sample.sessionResetAt = resets.session }
        if weekRunning == true { sample.weeklyResetAt = resets.weekly }
        return sample
    }

    static func resetTimes(from payload: JSONValue) -> (session: Date?, weekly: Date?) {
        if let limits = payload["limits"]?.arrayValue, !limits.isEmpty {
            func reset(_ kind: String) -> Date? {
                LocalToolDates.parse(limits.first(where: { $0["kind"]?.stringValue == kind })?["resets_at"]?.stringValue)
            }
            return (reset("session"), reset("weekly_all"))
        }
        return (LocalToolDates.parse(payload["five_hour"]?["resets_at"]?.stringValue),
                LocalToolDates.parse(payload["seven_day"]?["resets_at"]?.stringValue))
    }

    private static func percentages(from payload: JSONValue) -> (session: Double?, weekly: Double?) {
        if let limits = payload["limits"]?.arrayValue, !limits.isEmpty {
            return (
                limits.first(where: { $0["kind"]?.stringValue == "session" })?["percent"]?.lenientNumber,
                limits.first(where: { $0["kind"]?.stringValue == "weekly_all" })?["percent"]?.lenientNumber
            )
        }
        return (payload["five_hour"]?["utilization"]?.lenientNumber, payload["seven_day"]?["utilization"]?.lenientNumber)
    }
}
