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

    #expect(settings?.usageAlertIntervalPercent == 10)
    settings?.usageAlertIntervalPercent = 20
    settings = nil

    let restored = HUDSettings(defaults: defaults)
    #expect(restored.usageAlertIntervalPercent == 20)
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
@Test func persistsRemoteToolsAndKeepsTheirIdentifiersUnique() throws {
    let defaults = isolatedDefaults()
    let endpoint = try #require(URL(string: "https://example.com/limits"))
    let remoteID = AIToolID(rawValue: "5f73a498-85b0-49c5-97b1-288a081e532e")
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    try settings?.upsertRemoteTool(RemoteAITool(id: remoteID, name: "Remote", endpoint: endpoint))
    try settings?.upsertRemoteTool(RemoteAITool(id: remoteID, name: "Renamed", endpoint: endpoint))
    settings = nil

    let restored = HUDSettings(defaults: defaults)

    #expect(restored.remoteTools.count == 1)
    #expect(restored.remoteTools.first?.name == "Renamed")
    #expect(restored.toolOrder.filter { $0 == remoteID }.count == 1)
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
@Test func defaultsToNewestNamedChatGPTBucketWhileKeepingLegacyBucketAvailable() {
    let settings = HUDSettings(defaults: isolatedDefaults())
    let legacy = quota(id: "codex", displayName: "Codex")
    let newest = quota(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")

    settings.registerBuckets([legacy, newest])

    #expect(settings.ordered([legacy, newest]).map(\.id) == [newest.id])
    settings.hiddenBucketIDs.remove(legacy.id)
    #expect(settings.ordered([legacy, newest]).map(\.id) == [legacy.id, newest.id])
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
private func isolatedDefaults() -> UserDefaults {
    let suite = "UsageHUDTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func quota(id: String, displayName: String? = nil) -> QuotaSnapshot {
    QuotaSnapshot(
        id: id,
        displayName: displayName ?? id,
        usedPercent: 0,
        remainingPercent: 100,
        resetAt: nil,
        windowDurationMinutes: nil,
        planType: nil,
        updatedAt: .distantPast
    )
}
