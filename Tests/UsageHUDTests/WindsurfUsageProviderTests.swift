import Foundation
import SQLite3
import Testing
@testable import UsageHUD

private let testNow = Date(timeIntervalSince1970: 1_789_300_000) // 2026-09-13 11:46 UTC
private let devinKey = "windsurf.reactSettings.cachedPlanInfoData:user-00112233445566778899aabbccddeeff"
private let legacyKey = "windsurf.settings.cachedPlanInfo"

/// A paid Devin Desktop plan as it saves it: quota at the top level, a
/// message pool of -1, and reset times in Unix seconds.
private let devinPro = #"{"planName":"Pro","startTimestamp":1788700000000,"endTimestamp":1791300000000,"remainingMessages":-1,"totalMessages":-1,"dailyRemainingPercent":64,"weeklyRemainingPercent":81,"dailyResetAtUnix":1789344000,"weeklyResetAtUnix":1789862400,"hideDailyQuota":false,"hideWeeklyQuota":false}"#

private struct StaticWindsurfPlanSource: WindsurfPlanSource {
    var saved: WindsurfSavedPlans?
    var error: LocalToolUsageError?

    init(_ rows: [(String, String)], savedAt: Date = testNow.addingTimeInterval(-600)) {
        saved = WindsurfSavedPlans(rows: rows.map { WindsurfPlanRow(key: $0.0, value: $0.1) }, modifiedAt: savedAt)
    }

    init(saved: WindsurfSavedPlans?, error: LocalToolUsageError? = nil) {
        self.saved = saved
        self.error = error
    }

    func load() throws -> WindsurfSavedPlans? {
        if let error { throw error }
        return saved
    }
}

private func provider(
    _ rows: [(String, String)],
    registry: LocalToolStatusRegistry? = nil
) -> WindsurfUsageProvider {
    WindsurfUsageProvider(source: StaticWindsurfPlanSource(rows), statusRegistry: registry, now: { testNow })
}

@Test func windsurfShowsDailyAndWeeklyQuotaAsOneLimitWithTwoRings() async throws {
    let registry = await LocalToolStatusRegistry()
    let savedAt = testNow.addingTimeInterval(-600)

    let snapshots = try await provider([(devinKey, devinPro)], registry: registry).refresh().snapshots

    let quota = try #require(snapshots.first)
    #expect(snapshots.count == 1)
    #expect(quota.id == "windsurf")
    #expect(quota.toolID == .windsurf)
    #expect(quota.displayName == "Plan quota")
    #expect(quota.planType == "Pro")
    #expect(quota.remainingPercent == 64)
    #expect(quota.windowDurationMinutes == 1_440)
    #expect(quota.resetAt == Date(timeIntervalSince1970: 1_789_344_000))
    #expect(quota.secondaryWindow?.remainingPercent == 81)
    #expect(quota.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(quota.secondaryWindow?.resetAt == Date(timeIntervalSince1970: 1_789_862_400))
    #expect(quota.combinedTypeTag == "1D + 7D")
    #expect(quota.updatedAt == savedAt)
    #expect(await registry.status(for: .windsurf) == .connected)
}

@Test func windsurfLeavesOutAQuotaWindowThePlanHides() async throws {
    let hidden = devinPro.replacingOccurrences(of: #""hideDailyQuota":false"#, with: #""hideDailyQuota":true"#)

    let quota = try #require(try await provider([(devinKey, hidden)]).refresh().snapshots.first)

    #expect(quota.remainingPercent == 81)
    #expect(quota.windowDurationMinutes == 10_080)
    #expect(quota.secondaryWindow == nil)
}

@Test func windsurfDropsAWindowThatHasResetSinceThePlanWasSaved() async throws {
    let dailyReset = devinPro.replacingOccurrences(of: "1789344000", with: "1789290000")

    let quota = try #require(try await provider([(devinKey, dailyReset)]).refresh().snapshots.first)

    #expect(quota.remainingPercent == 81)
    #expect(quota.windowDurationMinutes == 10_080)
    #expect(quota.secondaryWindow == nil)
}

@Test func windsurfExplainsAQuotaThatHasFullyResetSinceItWasSaved() async throws {
    let reset = devinPro
        .replacingOccurrences(of: "1789344000", with: "1789290000")
        .replacingOccurrences(of: "1789862400", with: "1789299999")
    let registry = await LocalToolStatusRegistry()

    let result = try await provider([(devinKey, reset)], registry: registry).refresh()

    #expect(result == .authenticated([]))
    guard case let .failed(message) = await registry.status(for: .windsurf) else {
        Issue.record("Expected a failed status")
        return
    }
    #expect(message.contains("reset"))
}

@Test func windsurfLeavesOutAPlanWhoseBillingPeriodHasEnded() async throws {
    let ended = devinPro.replacingOccurrences(of: "1791300000000", with: "1789200000000")
    let registry = await LocalToolStatusRegistry()

    let result = try await provider([(devinKey, ended)], registry: registry).refresh()

    #expect(result == .authenticated([]))
    guard case let .failed(message) = await registry.status(for: .windsurf) else {
        Issue.record("Expected a failed status")
        return
    }
    #expect(message.contains("billing period"))
}

@Test func windsurfShowsTheFreePlanMessagePoolBesideItsQuota() async throws {
    let free = #"{"planName":"Free","startTimestamp":0,"endTimestamp":0,"remainingMessages":300,"totalMessages":1200,"dailyRemainingPercent":100,"weeklyRemainingPercent":92,"dailyResetAtUnix":1789344000,"weeklyResetAtUnix":1789862400}"#

    let snapshots = try await provider([(devinKey, free)]).refresh().snapshots

    #expect(snapshots.map(\.id) == ["windsurf", "windsurf_messages"])
    let messages = snapshots[1]
    #expect(messages.displayName == "Messages")
    #expect(messages.remainingPercent == 25)
    #expect(messages.resetAt == nil)
    #expect(messages.windowDurationMinutes == nil)
    #expect(messages.planType == "Free")
}

@Test func windsurfPrefersTheDevinDesktopAccountWhosePlanRunsLongest() async throws {
    let ended = devinPro
        .replacingOccurrences(of: "1791300000000", with: "1789200000000")
        .replacingOccurrences(of: #""planName":"Pro""#, with: #""planName":"Old""#)
    let shorter = devinPro
        .replacingOccurrences(of: "1791300000000", with: "1790000000000")
        .replacingOccurrences(of: #""planName":"Pro""#, with: #""planName":"Teams""#)
    let rows = [
        ("windsurf.reactSettings.cachedPlanInfoData:user-a", ended),
        ("windsurf.reactSettings.cachedPlanInfoData:user-b", shorter),
        ("windsurf.reactSettings.cachedPlanInfoData:user-c", devinPro),
        (legacyKey, #"{"planName":"Legacy"}"#),
    ]

    let snapshots = try await provider(rows).refresh().snapshots

    #expect(snapshots.first?.planType == "Pro")
}

@Test func windsurfReadsTheQuotaWindsurfSavedBeforeTheRename() async throws {
    let legacy = #"{"planName":"Pro Ultimate","endTimestamp":1791300000000,"quotaUsage":{"dailyRemainingPercent":12.5,"weeklyRemainingPercent":40,"dailyResetAtUnix":1789344000,"weeklyResetAtUnix":1789862400}}"#

    let quota = try #require(try await provider([(legacyKey, legacy)]).refresh().snapshots.first)

    #expect(quota.planType == "Pro Ultimate")
    #expect(quota.remainingPercent == 12.5)
    #expect(quota.secondaryWindow?.remainingPercent == 40)
}

@Test func windsurfFallsBackToMessageAndFlowActionAllowances() async throws {
    let allowances = #"{"planName":"Teams","startTimestamp":1788700000000,"endTimestamp":1791292000000,"usage":{"messages":5000,"usedMessages":1250,"flowActions":20000,"remainingFlowActions":15000}}"#

    let snapshots = try await provider([(legacyKey, allowances)]).refresh().snapshots

    #expect(snapshots.map(\.id) == ["windsurf_messages", "windsurf_flow_actions"])
    #expect(snapshots.map(\.displayName) == ["Messages", "Flow actions"])
    #expect(snapshots.map(\.remainingPercent) == [75, 75])
    #expect(snapshots.allSatisfy { $0.resetAt == Date(timeIntervalSince1970: 1_791_292_000) })
    #expect(snapshots.allSatisfy { $0.windowDurationMinutes == 43_200 })
}

@Test func windsurfTellsNotInstalledFromNotSignedIn() async throws {
    let registry = await LocalToolStatusRegistry()
    let missing = WindsurfUsageProvider(
        source: StaticWindsurfPlanSource(saved: nil),
        statusRegistry: registry,
        now: { testNow }
    )
    #expect(try await missing.refresh() == .signedOut)
    #expect(await registry.status(for: .windsurf) == .notInstalled)

    #expect(try await provider([], registry: registry).refresh() == .signedOut)
    #expect(await registry.status(for: .windsurf) == .signedOut)
}

@Test func windsurfKeepsTheLastReadingWhenItsDatabaseCannotBeRead() async throws {
    let registry = await LocalToolStatusRegistry()
    let locked = WindsurfUsageProvider(
        source: StaticWindsurfPlanSource(saved: nil, error: .invalidResponse),
        statusRegistry: registry,
        now: { testNow }
    )

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await locked.refresh() }
    #expect(await locked.refreshLocalUsage() == nil)
    guard case .failed = await registry.status(for: .windsurf) else {
        Issue.record("Expected a failed status")
        return
    }

    await #expect(throws: LocalToolUsageError.invalidResponse) {
        try await provider([(devinKey, "{not json")]).refresh()
    }
}

// MARK: - The editor's own SQLite store

private struct StateDatabaseFixture {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-windsurf-\(UUID().uuidString)", isDirectory: true)

    /// Creates `<app>/User/globalStorage/state.vscdb` with an `ItemTable` like
    /// the editor's: values are BLOBs holding UTF-16LE text, or plain TEXT.
    func save(app: String, rows: [(key: String, value: String, utf16: Bool)], age: TimeInterval) throws {
        let folder = home.appendingPathComponent("Library/Application Support/\(app)/User/globalStorage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw LocalToolUsageError.invalidResponse
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            nil, nil, nil
        ) == SQLITE_OK else { throw LocalToolUsageError.invalidResponse }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows + [(key: "cursorAuth/unrelated", value: "x", utf16: false)] {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, row.key, -1, transient)
            if row.utf16 {
                let bytes = Array(row.value.data(using: .utf16LittleEndian)!)
                sqlite3_bind_blob(statement, 2, bytes, Int32(bytes.count), transient)
            } else {
                sqlite3_bind_text(statement, 2, row.value, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalToolUsageError.invalidResponse }
            sqlite3_finalize(statement)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func windsurfReadsPlanRowsFromTheEditorDatabaseChangedLast() throws {
    let fixture = StateDatabaseFixture()
    defer { fixture.remove() }
    try fixture.save(
        app: "Windsurf",
        rows: [(key: legacyKey, value: #"{"planName":"Before migration"}"#, utf16: false)],
        age: 86_400
    )
    try fixture.save(
        app: "Devin",
        rows: [
            (key: devinKey, value: devinPro, utf16: true),
            (key: "windsurf.reactSettings.somethingElse", value: "{}", utf16: false),
        ],
        age: 60
    )

    let saved = try #require(try WindsurfStateDatabases(homeDirectory: fixture.home).load())

    #expect(saved.rows == [WindsurfPlanRow(key: devinKey, value: devinPro)])
    // The reading carries the Devin database's own write time, not the clock's.
    let devinDatabase = fixture.home.appendingPathComponent(
        "Library/Application Support/Devin/User/globalStorage/state.vscdb"
    )
    let written = try #require(
        FileManager.default.attributesOfItem(atPath: devinDatabase.path)[.modificationDate] as? Date
    )
    #expect(saved.modifiedAt == written)
}

@Test func windsurfFindsNoSavedPlansWhenNeitherEditorHasRun() throws {
    let fixture = StateDatabaseFixture()
    defer { fixture.remove() }

    #expect(try WindsurfStateDatabases(homeDirectory: fixture.home).load() == nil)
}
