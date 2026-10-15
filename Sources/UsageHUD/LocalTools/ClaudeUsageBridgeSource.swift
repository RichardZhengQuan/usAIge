import Darwin
import Foundation

/// Receives quota metadata produced inside Claude's own session. Claude owns
/// the authenticated request; usAIge reads only this small local report.
struct ClaudeUsageBridgeSource: ClaudeAppUsageSource {
    static let maximumAge: TimeInterval = 30 * 60
    static let maximumBytes = 256 * 1_024
    private let directory: URL
    private let historyURL: URL
    private let now: @Sendable () -> Date

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping @Sendable () -> Date = Date.init) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        historyURL = homeDirectory.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        self.now = now
    }

    func latestSample() -> ClaudeAppUsageSample? {
        let date = now()
        let responseURL = directory.appendingPathComponent("response.json")
        guard let data = Self.read(responseURL, limit: Self.maximumBytes),
              let sample = Self.sample(from: data, now: date) else { return nil }
        if let statusData = Self.read(directory.appendingPathComponent("status.json"), limit: 4_096),
           let status = JSONValue.parse(statusData), status["schemaVersion"]?.lenientNumber == 1,
           let checked = LocalToolDates.parse(status["checkedAt"]?.stringValue),
           checked >= sample.recordedAt, checked <= date {
            if status["state"]?.stringValue == "unavailable" { return nil }
            if let organization = status["organizationID"]?.stringValue.flatMap(UUID.init(uuidString:)),
               organization.uuidString.lowercased() != sample.organizationID { return nil }
        }
        if let history = Self.read(historyURL, limit: 4 * 1_024 * 1_024),
           let observation = ClaudeAppUsageHistory.latestOrganization(from: history),
           observation.recordedAt > sample.recordedAt, observation.recordedAt <= date,
           observation.id != sample.organizationID { return nil }
        // fs.write has no atomic rename in the mod SDK. Reject a response
        // replaced during this read; an incomplete write is retried next tick.
        guard Self.read(responseURL, limit: Self.maximumBytes) == data else { return nil }
        return sample
    }

    static func sample(from data: Data, now: Date) -> ClaudeAppUsageSample? {
        guard data.count <= maximumBytes, let root = JSONValue.parse(data),
              root["schemaVersion"]?.lenientNumber == 1,
              let recorded = LocalToolDates.parse(root["observedAt"]?.stringValue),
              (0...maximumAge).contains(now.timeIntervalSince(recorded)),
              let organization = root["organizationID"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let usage = root["usage"],
              let payload = ClaudeDesktopUsageCache.validatedPayload(usage, now: now) else { return nil }
        let limits = payload["limits"]?.arrayValue ?? []
        let session = limits.isEmpty ? payload["five_hour"]?["utilization"]?.lenientNumber
            : limits.first(where: { $0["kind"]?.stringValue == "session" })?["percent"]?.lenientNumber
        let weekly = limits.isEmpty ? payload["seven_day"]?["utilization"]?.lenientNumber
            : limits.first(where: { $0["kind"]?.stringValue == "weekly_all" })?["percent"]?.lenientNumber
        return ClaudeAppUsageSample(recordedAt: recorded, sessionPercent: session, weeklyPercent: weekly,
                                    organizationID: organization.uuidString.lowercased(),
                                    cachedUsage: ClaudeDesktopCachedUsage(payload: payload, recordedAt: recorded),
                                    origin: .bridge)
    }

    private static func read(_ url: URL, limit: Int) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}

/// Prefer the newest response from either Claude's background extension or
/// its native cache. History remains available when neither has exact resets.
struct ClaudeAutomaticUsageSource: ClaudeAppUsageSource {
    private let bridge: any ClaudeAppUsageSource
    private let desktop: any ClaudeAppUsageSource

    init(bridge: any ClaudeAppUsageSource = ClaudeUsageBridgeSource(),
         desktop: any ClaudeAppUsageSource = ClaudeAppUsageHistory()) {
        self.bridge = bridge
        self.desktop = desktop
    }

    func latestSample() -> ClaudeAppUsageSample? {
        let shared = bridge.latestSample()
        let native = desktop.latestSample()
        if let shared, let native {
            if native.recordedAt > shared.recordedAt { return native }
            return shared
        }
        return shared ?? native
    }
}
