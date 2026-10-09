import Foundation

/// One plan-usage reading the Claude desktop app recorded.
struct ClaudeAppUsageSample: Equatable, Sendable {
    let recordedAt: Date
    let sessionPercent: Double?
    let weeklyPercent: Double?
}

protocol ClaudeAppUsageSource: Sendable {
    /// The newest reading, or `nil` when the Claude app has recorded none.
    func latestSample() -> ClaudeAppUsageSample?
}

/// Reads the plan usage the Claude desktop app records while it runs, in
/// `~/Library/Application Support/Claude/plan-usage-history.json`. The app
/// polls its own signed-in account every few minutes and appends the 5-hour
/// (`fh`) and 7-day (`sd`) percentages, so usAIge can show Claude limits
/// without any sign-in of its own. The file has no reset times or limits
/// scoped to one model; the Claude Code sign-in stays the richer source.
struct ClaudeAppUsageHistory: ClaudeAppUsageSource {
    private let fileURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("plan-usage-history.json")
    }

    func latestSample() -> ClaudeAppUsageSample? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        return Self.latestSample(from: data)
    }

    static func latestSample(from data: Data) -> ClaudeAppUsageSample? {
        guard let samples = JSONValue.parse(data)?["samples"]?.arrayValue else { return nil }
        var latest: ClaudeAppUsageSample?
        for sample in samples {
            guard let millis = sample["t"]?.lenientNumber,
                  let usage = sample["u"], usage.objectValue != nil else { continue }
            let reading = ClaudeAppUsageSample(
                recordedAt: Date(timeIntervalSince1970: millis / 1000),
                sessionPercent: usage["fh"]?.lenientNumber,
                weeklyPercent: usage["sd"]?.lenientNumber
            )
            guard reading.sessionPercent != nil || reading.weeklyPercent != nil else { continue }
            if latest.map({ reading.recordedAt >= $0.recordedAt }) ?? true { latest = reading }
        }
        return latest
    }
}
