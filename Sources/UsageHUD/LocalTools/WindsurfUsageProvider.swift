import Foundation
import SQLite3

/// The plan Windsurf, renamed Devin Desktop in 2026, caches in its own
/// `state.vscdb` when it launches. Devin Desktop keeps its data under
/// `~/Library/Application Support/Devin`, and Windsurf under `…/Windsurf`;
/// after a migration both exist, so the one changed last is read.
///
/// usAIge reads the saved plan rows only: no sign-in, no request, nothing
/// written. The keys and field names were learned from ClaudeBar's Windsurf
/// provider documentation (https://github.com/tddworks/ClaudeBar, Apache-2.0);
/// the reading and the rules below are usAIge's own.
struct WindsurfPlanRow: Equatable, Sendable {
    let key: String
    let value: String
}

struct WindsurfSavedPlans: Equatable, Sendable {
    let rows: [WindsurfPlanRow]
    let modifiedAt: Date
}

protocol WindsurfPlanSource: Sendable {
    /// `nil` means neither Devin Desktop nor Windsurf has run on this Mac.
    func load() throws -> WindsurfSavedPlans?
}

struct WindsurfStateDatabases: WindsurfPlanSource {
    /// Devin Desktop saves one row per signed-in account under this prefix.
    static let devinKeyPrefix = "windsurf.reactSettings.cachedPlanInfoData"
    /// Windsurf before the rename saved a single row under this key.
    static let legacyKey = "windsurf.settings.cachedPlanInfo"
    static let appFolders = ["Devin", "Windsurf"]

    let databaseURLs: [URL]

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        databaseURLs = Self.appFolders.map {
            support.appendingPathComponent("\($0)/User/globalStorage/state.vscdb")
        }
    }

    init(databaseURLs: [URL]) {
        self.databaseURLs = databaseURLs
    }

    func load() throws -> WindsurfSavedPlans? {
        let candidates = databaseURLs.compactMap { url -> (URL, Date)? in
            guard let modified = Self.lastWrite(of: url) else { return nil }
            return (url, modified)
        }
        guard let (url, modified) = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let rows = try ReadOnlyStateDatabase.withConnection(at: url) { database in
            try Self.planRows(in: database)
        }
        return WindsurfSavedPlans(rows: rows, modifiedAt: modified)
    }

    /// The database's own modification time, or its write-ahead log's when
    /// that is newer, since a launch may write only to the log.
    private static func lastWrite(of url: URL) -> Date? {
        let fileManager = FileManager.default
        guard let main = try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            return nil
        }
        let log = try? fileManager.attributesOfItem(atPath: url.path + "-wal")[.modificationDate] as? Date
        return max(main, log ?? main)
    }

    private static func planRows(in database: OpaquePointer) throws -> [WindsurfPlanRow] {
        var statement: OpaquePointer?
        let query = "SELECT key, value FROM ItemTable WHERE key = ? OR substr(key, 1, ?) = ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw LocalToolUsageError.invalidResponse
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, legacyKey, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(devinKeyPrefix.utf8.count))
        sqlite3_bind_text(statement, 3, devinKeyPrefix, -1, transient)

        var rows: [WindsurfPlanRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let key = ReadOnlyStateDatabase.text(of: statement!, column: 0),
                      let value = ReadOnlyStateDatabase.text(of: statement!, column: 1) else { continue }
                rows.append(WindsurfPlanRow(key: key, value: value))
            case SQLITE_DONE:
                return rows
            default:
                throw LocalToolUsageError.invalidResponse
            }
        }
    }
}

/// What a saved plan says, after usAIge's rules for old readings.
enum WindsurfPlanReading: Equatable, Sendable {
    case limits([QuotaSnapshot])
    /// The plan's billing period ended after it was saved.
    case periodEnded
    /// Every window it reports has reset since it was saved, and it reports
    /// nothing else.
    case quotaReset
}

enum WindsurfPlanParser {
    static let quotaBucketID = "windsurf"
    static let messagesBucketID = "windsurf_messages"
    static let flowActionsBucketID = "windsurf_flow_actions"

    /// Picks the plan to show from the saved rows: a Devin Desktop row first,
    /// preferring one whose billing period hasn't ended and then the one that
    /// runs longest, else the legacy Windsurf row. Nil when no row parses.
    static func plan(from rows: [WindsurfPlanRow], now: Date) -> JSONValue? {
        func parsed(_ row: WindsurfPlanRow) -> JSONValue? {
            let value = JSONValue.parse(Data(row.value.utf8))
            return value?.objectValue == nil ? nil : value
        }
        func ends(_ plan: JSONValue) -> Double { plan["endTimestamp"]?.lenientNumber ?? 0 }
        func ended(_ plan: JSONValue) -> Bool {
            let end = ends(plan)
            return end > 0 && end / 1000 < now.timeIntervalSince1970
        }
        let devin = rows
            .filter { $0.key.hasPrefix(WindsurfStateDatabases.devinKeyPrefix) }
            .compactMap(parsed)
            .sorted { lhs, rhs in
                if ended(lhs) != ended(rhs) { return !ended(lhs) }
                return ends(lhs) > ends(rhs)
            }
        if let first = devin.first { return first }
        return rows.first { $0.key == WindsurfStateDatabases.legacyKey }.flatMap(parsed)
    }

    /// Daily and weekly quota left as one limit (daily inner ring, weekly
    /// outer ring), unless the plan hides one. A window whose reset time has
    /// passed is left out: Devin Desktop saves the plan when it launches, so
    /// that percentage belongs to a window that no longer exists. Free plans'
    /// message pools, and older plans' message and flow-action allowances,
    /// are separate limits.
    static func reading(of plan: JSONValue, savedAt: Date, now: Date) -> WindsurfPlanReading {
        let current = now.timeIntervalSince1970
        var periodEnd = plan["endTimestamp"]?.lenientNumber.map { $0 / 1000 }
        if let end = periodEnd, end <= 0 { periodEnd = nil }
        if let periodEnd, periodEnd < current { return .periodEnded }

        let planName = plan["planName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planType = planName.flatMap { $0.isEmpty ? nil : $0 }
        let usage = plan["quotaUsage"]?.objectValue != nil ? plan["quotaUsage"]! : plan
        func hidden(_ flag: String) -> Bool {
            usage[flag]?.boolValue == true || plan[flag]?.boolValue == true
        }

        struct Window {
            let remaining: Double
            let minutes: Int
            let resetsAt: TimeInterval?
        }
        var droppedForReset = false
        func window(_ percent: String, reset: String, minutes: Int, hiddenBy flag: String) -> Window? {
            guard !hidden(flag), let remaining = usage[percent]?.lenientNumber else { return nil }
            let resetsAt = usage[reset]?.lenientNumber.flatMap { $0 > 0 ? $0 : nil }
            if let resetsAt, resetsAt <= current {
                droppedForReset = true
                return nil
            }
            return Window(remaining: min(100, max(0, remaining)), minutes: minutes, resetsAt: resetsAt)
        }
        let windows = [
            window("dailyRemainingPercent", reset: "dailyResetAtUnix", minutes: 1_440, hiddenBy: "hideDailyQuota"),
            window("weeklyRemainingPercent", reset: "weeklyResetAtUnix", minutes: 10_080, hiddenBy: "hideWeeklyQuota"),
        ].compactMap { $0 }

        var buckets: [RateLimitBucket] = []
        if let primary = windows.first {
            let secondary = windows.dropFirst().first
            var bucket = RateLimitBucket(
                limitID: quotaBucketID,
                limitName: "Plan quota",
                usedPercent: 100 - primary.remaining,
                windowDurationMinutes: primary.minutes,
                resetsAt: primary.resetsAt,
                planType: planType
            )
            if let secondary {
                bucket.secondaryUsedPercent = 100 - secondary.remaining
                bucket.secondaryWindowDurationMinutes = secondary.minutes
                bucket.secondaryResetsAt = secondary.resetsAt
            }
            buckets.append(bucket)
        }

        // Devin Desktop's free plan: a pool of messages with no period. Paid
        // plans save -1 here.
        if let total = plan["totalMessages"]?.lenientNumber, total > 0,
           let left = plan["remainingMessages"]?.lenientNumber, left >= 0 {
            buckets.append(RateLimitBucket(
                limitID: messagesBucketID,
                limitName: "Messages",
                usedPercent: min(100, max(0, (total - left) / total * 100)),
                windowDurationMinutes: nil,
                resetsAt: nil,
                planType: planType
            ))
        }

        // Plans from before the daily and weekly quota count messages and
        // flow actions for the billing period instead.
        if buckets.isEmpty, let allowance = plan["usage"], allowance.objectValue != nil {
            let start = plan["startTimestamp"]?.lenientNumber.flatMap { $0 > 0 ? $0 / 1000 : nil }
            let periodMinutes = LocalToolDates.windowMinutes(
                from: start.map(Date.init(timeIntervalSince1970:)),
                to: periodEnd.map(Date.init(timeIntervalSince1970:))
            )
            for (id, name, totalKey, usedKey, leftKey) in [
                (messagesBucketID, "Messages", "messages", "usedMessages", "remainingMessages"),
                (flowActionsBucketID, "Flow actions", "flowActions", "usedFlowActions", "remainingFlowActions"),
            ] {
                guard let total = allowance[totalKey]?.lenientNumber, total > 0 else { continue }
                guard let used = allowance[usedKey]?.lenientNumber
                    ?? allowance[leftKey]?.lenientNumber.map({ total - $0 }) else { continue }
                buckets.append(RateLimitBucket(
                    limitID: id,
                    limitName: name,
                    usedPercent: min(100, max(0, used / total * 100)),
                    windowDurationMinutes: periodMinutes,
                    resetsAt: periodEnd,
                    planType: planType
                ))
            }
        }

        if buckets.isEmpty, droppedForReset { return .quotaReset }
        return .limits(buckets.map { bucket in
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: savedAt)
            snapshot.toolID = .windsurf
            return snapshot
        })
    }
}

/// Windsurf's daily and weekly quota, read from the plan Devin Desktop or
/// Windsurf saved on this Mac. A passive local read: it never touches the
/// Windsurf sign-in and makes no request, so it runs on every automatic tick.
actor WindsurfUsageProvider: CodexUsageProviding, LocalUsageProviding {
    private let source: any WindsurfPlanSource
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        source: any WindsurfPlanSource = WindsurfStateDatabases(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            let (result, status) = try read()
            await report(status)
            return result
        } catch {
            await report(.failed("Couldn't read the plan Windsurf saved on this Mac."))
            throw error
        }
    }

    func refreshLocalUsage() async -> AccountUsageResult? {
        try? await refresh()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func read() throws -> (AccountUsageResult, LocalToolStatus) {
        guard let saved = try source.load() else { return (.signedOut, .notInstalled) }
        let current = now()
        guard !saved.rows.isEmpty else { return (.signedOut, .signedOut) }
        guard let plan = WindsurfPlanParser.plan(from: saved.rows, now: current) else {
            throw LocalToolUsageError.invalidResponse
        }
        switch WindsurfPlanParser.reading(of: plan, savedAt: saved.modifiedAt, now: current) {
        case let .limits(snapshots):
            return (.authenticated(snapshots), .connected)
        case .periodEnded:
            return (
                .authenticated([]),
                .failed("The saved plan's billing period has ended. Open Devin Desktop or Windsurf to update it.")
            )
        case .quotaReset:
            return (
                .authenticated([]),
                .failed("The quota has reset since it was saved. Reopen Devin Desktop or Windsurf to update it.")
            )
        }
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .windsurf)
    }
}
