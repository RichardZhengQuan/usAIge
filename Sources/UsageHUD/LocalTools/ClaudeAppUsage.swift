import Foundation

/// One plan-usage reading the Claude desktop app recorded.
struct ClaudeAppUsageSample: Equatable, Sendable {
    let recordedAt: Date
    let sessionPercent: Double?
    let weeklyPercent: Double?
    var organizationID: String? = nil
    var cachedUsage: ClaudeDesktopCachedUsage? = nil
    var origin: Origin = .desktop

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
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        readCachedUsage: (@Sendable (String, Date) -> ClaudeDesktopCachedUsage?)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        fileURL = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("plan-usage-history.json")
        let cache = ClaudeDesktopUsageCache(homeDirectory: homeDirectory)
        self.readCachedUsage = readCachedUsage ?? { cache.latestUsage(organizationID: $0, now: $1) }
        self.now = now
    }

    func latestSample() -> ClaudeAppUsageSample? {
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
        guard let organizationID = sample.organizationID,
              let usage = readCachedUsage(organizationID, date),
              (0...ClaudeDesktopUsageCache.maximumAge).contains(date.timeIntervalSince(usage.recordedAt))
        else { return sample }
        let percents = Self.percentages(from: usage.payload)
        if usage.recordedAt < sample.recordedAt {
            // A later history observation must agree with an older response.
            // Mixing a changed percentage with an earlier reset is misleading.
            guard sample.sessionPercent.map({ $0 == percents.session }) ?? true,
                  sample.weeklyPercent.map({ $0 == percents.weekly }) ?? true
            else { return sample }
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
