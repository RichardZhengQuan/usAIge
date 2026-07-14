import Foundation

public struct RefreshScheduleMetadata: Codable, Equatable, Hashable, Sendable {
    public var toolID: UUID
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextRefreshAt: Date?
    public var consecutiveFailureCount: Int

    public init(
        toolID: UUID,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextRefreshAt: Date? = nil,
        consecutiveFailureCount: Int = 0
    ) {
        self.toolID = toolID
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRefreshAt = nextRefreshAt
        self.consecutiveFailureCount = max(0, consecutiveFailureCount)
    }

    public func isRefreshDue(at date: Date = Date()) -> Bool {
        guard let nextRefreshAt else { return true }
        return date >= nextRefreshAt
    }

    public func recordingAttempt(at date: Date) -> Self {
        var copy = self
        copy.lastAttemptAt = date
        return copy
    }

    public func recordingSuccess(
        at date: Date,
        refreshIntervalMinutes: Int
    ) -> Self {
        var copy = self
        copy.lastAttemptAt = date
        copy.lastSuccessAt = date
        let minutes = min(
            RemoteToolConfiguration.allowedRefreshIntervalMinutes.upperBound,
            max(
                RemoteToolConfiguration.allowedRefreshIntervalMinutes.lowerBound,
                refreshIntervalMinutes
            )
        )
        copy.nextRefreshAt = date.addingTimeInterval(TimeInterval(minutes * 60))
        copy.consecutiveFailureCount = 0
        return copy
    }

    public func recordingFailure(at date: Date, retryDelay: TimeInterval) -> Self {
        var copy = self
        copy.lastAttemptAt = date
        let delay = retryDelay.isFinite ? max(0, retryDelay) : 0
        copy.nextRefreshAt = date.addingTimeInterval(delay)
        copy.consecutiveFailureCount += 1
        return copy
    }
}

public struct QuotaCacheState: Codable, Equatable, Sendable {
    public var snapshots: [QuotaSnapshot]
    public var refreshMetadata: [RefreshScheduleMetadata]
    public var savedAt: Date

    public init(
        snapshots: [QuotaSnapshot] = [],
        refreshMetadata: [RefreshScheduleMetadata] = [],
        savedAt: Date = Date()
    ) {
        self.snapshots = snapshots
        self.refreshMetadata = refreshMetadata
        self.savedAt = savedAt
    }

    public static var empty: Self {
        Self(snapshots: [], refreshMetadata: [], savedAt: .distantPast)
    }

    public func metadata(for toolID: UUID) -> RefreshScheduleMetadata? {
        refreshMetadata.first { $0.toolID == toolID }
    }
}
