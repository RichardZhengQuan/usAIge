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

    #expect(restored.scale == 1.5)
    #expect(restored.opacity == 0.4)
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
    #expect(restored.visibleTools.map(\.id) == AIToolID.allCases)
}

@MainActor
private func isolatedDefaults() -> UserDefaults {
    let suite = "UsageHUDTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func quota(id: String) -> QuotaSnapshot {
    QuotaSnapshot(
        id: id,
        displayName: id,
        usedPercent: 0,
        remainingPercent: 100,
        resetAt: nil,
        windowDurationMinutes: nil,
        planType: nil,
        updatedAt: .distantPast
    )
}
