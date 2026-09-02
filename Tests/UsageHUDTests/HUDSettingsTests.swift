import Foundation
import Testing
@testable import UsageHUD

@MainActor
@Test func ordersKnownRowsHidesSelectionsAndAppendsNewRows() {
    let defaults = isolatedDefaults()
    let settings = HUDSettings(defaults: defaults)
    settings.bucketOrder = ["weekly", "codex"]
    settings.hiddenBucketIDs = ["weekly"]
    let weekly = quota(id: "weekly")
    let other = quota(id: "other")

    let ordered = settings.ordered([other, Fixtures.codexSnapshot, weekly])

    #expect(ordered.map(\.id) == ["codex", "other"])
}

@MainActor
@Test func persistsClampedAppearanceAndPerDisplayPosition() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    settings?.scale = 4
    settings?.opacity = 0.1
    settings?.setPosition(CGPoint(x: 42, y: 84), for: "display-1")
    settings = nil

    let restored = HUDSettings(defaults: defaults)

    #expect(restored.scale == 2.5)
    #expect(restored.opacity == 0.1)
    #expect(restored.position(for: "display-1") == CGPoint(x: 42, y: 84))
}

@MainActor
@Test func persistsOrderedVisibleTools() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    settings?.hiddenToolIDs = [.gemini]
    settings?.toolOrder = [.cursor, .chatGPT, .claude, .gemini]
    settings = nil

    let restored = HUDSettings(defaults: defaults)

    #expect(restored.visibleTools.map(\.id) == [.cursor, .chatGPT, .claude])
}

@MainActor
@Test func defaultsToTenPercentUsageAlertsAndPersistsASelectedInterval() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)

    #expect(HUDSettings.usageAlertIntervalOptions == [5, 10, 20, 50])
    #expect(settings?.usageAlertIntervalPercent == 10)
    settings?.usageAlertIntervalPercent = 20
    settings = nil

    let restored = HUDSettings(defaults: defaults)
    #expect(restored.usageAlertIntervalPercent == 20)
}

@MainActor
@Test func resetsUnsupportedPersistedUsageAlertIntervalToDefault() throws {
    let defaults = isolatedDefaults()
    let existingSettings: [String: Any] = [
        "version": 8,
        "usageAlertIntervalPercent": 15,
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: existingSettings),
        forKey: "usageHUD.settings.v1"
    )

    let restored = HUDSettings(defaults: defaults)

    #expect(restored.usageAlertIntervalPercent == 10)
}

@MainActor
@Test func resetCreditVisibilityDefaultsOnAndPersistsUserChoice() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)

    #expect(settings?.showsResetCredits == true)
    settings?.showsResetCredits = false
    settings = nil

    let restored = HUDSettings(defaults: defaults)
    #expect(restored.showsResetCredits == false)
}

@MainActor
@Test func migratesVersionOneSettingsWithNewToolDefaults() throws {
    let defaults = isolatedDefaults()
    let legacy: [String: Any] = [
        "version": 1,
        "bucketOrder": ["codex"],
        "hiddenBucketIDs": [],
        "scale": 1.1,
        "opacity": 0.9,
        "positions": [:],
        "hideTriggers": [
            "fullScreenApps": true,
            "fullScreenVideo": true,
            "games": true,
            "presentations": true,
            "screenSharing": true,
        ],
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "usageHUD.settings.v1")

    let restored = HUDSettings(defaults: defaults)

    #expect(restored.bucketOrder == ["codex"])
    #expect(restored.visibleTools.map(\.id) == AIToolID.builtInIDs)
}

@MainActor
@Test func removesLegacyEndpointBasedRemoteToolsDuringMigration() throws {
    let defaults = isolatedDefaults()
    let remoteID = "5f73a498-85b0-49c5-97b1-288a081e532e"
    let legacy: [String: Any] = [
        "version": 6,
        "toolOrder": ["chatGPT", remoteID],
        "bucketOrder": ["\(remoteID):weekly"],
        "hiddenBucketIDs": ["\(remoteID):weekly"],
        "remoteTools": [[
            "id": remoteID,
            "name": "Legacy Remote",
            "endpoint": "https://example.com/limits",
            "systemImage": "cpu",
            "isEnabled": true,
        ]],
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "usageHUD.settings.v1")

    let settings = HUDSettings(defaults: defaults)

    #expect(!settings.toolOrder.contains(AIToolID(rawValue: remoteID)))
    #expect(!settings.bucketOrder.contains("\(remoteID):weekly"))
    #expect(!settings.hiddenBucketIDs.contains("\(remoteID):weekly"))
}

@MainActor
@Test func registerBucketsStablyDeduplicatesRemoteRows() {
    let settings = HUDSettings(defaults: isolatedDefaults())
    let daily = quota(id: "remote:daily")
    let weekly = quota(id: "remote:weekly")

    settings.registerBuckets([daily, daily, weekly])

    #expect(settings.bucketOrder == ["remote:daily", "remote:weekly"])
}

@MainActor
@Test func defaultsToPrimaryCodexBucketWhileKeepingNamedBucketAvailable() {
    let settings = HUDSettings(defaults: isolatedDefaults())
    let legacy = quota(id: "codex", displayName: "Codex")
    let newest = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")

    settings.registerBuckets([legacy, newest])

    #expect(settings.ordered([legacy, newest]).map(\.id) == [legacy.id])
    settings.hiddenBucketIDs.remove(newest.id)
    #expect(settings.ordered([legacy, newest]).map(\.id) == [legacy.id, newest.id])
}

@MainActor
@Test func migratesNamedModelDefaultToPrimaryCodexBucket() throws {
    let defaults = isolatedDefaults()
    let existingSettings: [String: Any] = [
        "version": 7,
        "bucketOrder": ["codex", "codex_bengalfox"],
        "hiddenBucketIDs": ["codex"],
        "didApplyLatestBucketDefault": true,
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: existingSettings),
        forKey: "usageHUD.settings.v1"
    )
    let settings = HUDSettings(defaults: defaults)
    let primary = quota(id: "codex", displayName: "Codex")
    let named = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")

    settings.registerBuckets([primary, named])

    #expect(settings.ordered([primary, named]).map(\.id) == [primary.id])
}

@MainActor
@Test func preservesVersionSevenCustomBucketVisibility() throws {
    let defaults = isolatedDefaults()
    let existingSettings: [String: Any] = [
        "version": 7,
        "bucketOrder": ["codex", "codex_bengalfox"],
        "hiddenBucketIDs": [],
        "didApplyLatestBucketDefault": true,
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: existingSettings),
        forKey: "usageHUD.settings.v1"
    )
    let settings = HUDSettings(defaults: defaults)
    let primary = quota(id: "codex", displayName: "Codex")
    let named = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")

    settings.registerBuckets([primary, named])

    #expect(settings.ordered([primary, named]).map(\.id) == [primary.id, named.id])
}

@MainActor
@Test func updatingUsersKeepTheirExistingVisibleBuckets() throws {
    let defaults = isolatedDefaults()
    let existingSettings: [String: Any] = [
        "version": 4,
        "bucketOrder": ["codex", "codex_bengalfox"],
        "hiddenBucketIDs": [],
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: existingSettings),
        forKey: "usageHUD.settings.v1"
    )
    let settings = HUDSettings(defaults: defaults)
    let legacy = quota(id: "codex", displayName: "Codex")
    let newest = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")

    settings.registerBuckets([legacy, newest])

    #expect(settings.ordered([legacy, newest]).map(\.id) == [legacy.id, newest.id])
}

@MainActor
@Test func claudeDefaultsToItsHeadlineBucketWhileCursorShowsEveryBucket() {
    let settings = HUDSettings(defaults: isolatedDefaults())
    let claude = quota(id: "claude", displayName: "All models", toolID: .claude)
    let opus = quota(id: "claude_opus", displayName: "Opus", toolID: .claude)
    let cursor = quota(id: "cursor", displayName: "Cursor models", toolID: .cursor)
    let cursorOther = quota(id: "cursor_other", displayName: "Other models", toolID: .cursor)

    settings.registerBuckets([claude, opus, cursor, cursorOther])

    #expect(settings.ordered([claude, opus, cursor, cursorOther]).map(\.id) == ["claude", "cursor", "cursor_other"])
    #expect(settings.visibleTools.map(\.id).contains(.grok))
    settings.hiddenBucketIDs.remove("claude_opus")
    settings.registerBuckets([claude, opus])
    #expect(settings.ordered([claude, opus]).map(\.id) == ["claude", "claude_opus"])
}

@MainActor
@Test func migratesTheCodexBucketDefaultFlagToPerToolRecords() throws {
    let defaults = isolatedDefaults()
    let existingSettings: [String: Any] = [
        "version": 8,
        "bucketOrder": ["codex", "codex_bengalfox"],
        "hiddenBucketIDs": [],
        "didApplyPrimaryBucketDefault": true,
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: existingSettings),
        forKey: "usageHUD.settings.v1"
    )
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    let codex = quota(id: "codex", displayName: "Codex")
    let named = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")
    let claude = quota(id: "claude", displayName: "All models", toolID: .claude)
    let sonnet = quota(id: "claude_sonnet", displayName: "Sonnet", toolID: .claude)

    settings?.registerBuckets([codex, named, claude, sonnet])

    #expect(settings?.ordered([codex, named, claude, sonnet]).map(\.id) == ["codex", "codex_bengalfox", "claude"])
    settings = nil
    let restored = HUDSettings(defaults: defaults)
    restored.registerBuckets([codex, named, claude, sonnet])
    #expect(restored.ordered([codex, named, claude, sonnet]).map(\.id) == ["codex", "codex_bengalfox", "claude"])
}

@MainActor
private func isolatedDefaults() -> UserDefaults {
    let suite = "UsageHUDTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func quota(id: String, displayName: String? = nil, toolID: AIToolID = .chatGPT) -> QuotaSnapshot {
    QuotaSnapshot(
        id: id,
        toolID: toolID,
        displayName: displayName ?? id,
        usedPercent: 0,
        remainingPercent: 100,
        resetAt: nil,
        windowDurationMinutes: nil,
        planType: nil,
        updatedAt: .distantPast
    )
}

@MainActor
@Test func readingTheClaudeSignInIsOffByDefaultAndPersistsWhenEnabled() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)

    #expect(settings?.readsClaudeSignIn == false)
    settings?.readsClaudeSignIn = true
    settings = nil

    #expect(HUDSettings(defaults: defaults).readsClaudeSignIn == true)
}

@MainActor
@Test func railOrderFollowsTheToolOrderThenTheBucketOrder() {
    let settings = HUDSettings(defaults: isolatedDefaults())
    let codex = quota(id: "codex", displayName: "Codex")
    let cursor = quota(id: "cursor", displayName: "Cursor models", toolID: .cursor)
    let cursorOther = quota(id: "cursor_other", displayName: "Other models", toolID: .cursor)
    let grok = quota(id: "grok", displayName: "Weekly credits", toolID: .grok)
    // Buckets arrive interleaved; the rail still groups them by tool.
    settings.registerBuckets([cursorOther, grok, codex, cursor])

    #expect(settings.ordered([cursorOther, grok, codex, cursor]).map(\.id) == ["codex", "cursor_other", "cursor", "grok"])

    settings.moveTool(.grok, to: .chatGPT)
    #expect(settings.toolOrder.first == .grok)
    #expect(settings.ordered([cursorOther, grok, codex, cursor]).map(\.id) == ["grok", "codex", "cursor_other", "cursor"])

    settings.moveTool(.chatGPT, to: .cursor)
    #expect(settings.ordered([cursorOther, grok, codex, cursor]).map(\.id) == ["grok", "cursor_other", "cursor", "codex"])
    settings.moveBucket("cursor", by: -1, among: ["cursor_other", "cursor"])
    #expect(settings.ordered([cursorOther, grok, codex, cursor]).map(\.id) == ["grok", "cursor", "cursor_other", "codex"])
    // Other tools' buckets keep their slots in the global order.
    #expect(settings.bucketOrder == ["cursor", "grok", "codex", "cursor_other"])
}

@MainActor
@Test func draggedToolOrderPersists() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    settings?.moveTool(.cursor, to: .chatGPT)
    let moved = settings?.toolOrder
    settings = nil

    #expect(moved?.prefix(2) == [.cursor, .chatGPT])
    #expect(HUDSettings(defaults: defaults).toolOrder == moved)
}
