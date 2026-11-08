import Foundation
import Testing
@testable import UsageHUD

private func storage(measuring: Bool = false, free: Int64? = 100) -> PaperweightConfiguration {
    PaperweightConfiguration(id: .storage, capacityBytes: 1_000, layers: [
        PaperweightLayer(id: "other", title: "macOS and apps", bytes: 500, colorHex: 0, inkHex: 0),
        PaperweightLayer(id: "tool", title: "Tool storage", bytes: 200, colorHex: 0, inkHex: 0, isMeasuring: measuring),
        PaperweightLayer(id: "cache", title: "Build cache", bytes: 120, colorHex: 0, inkHex: 0),
        PaperweightLayer(id: "wt", title: "Worktrees", bytes: 80, colorHex: 0, inkHex: 0),
    ], freeBytes: free)
}

@Test func aStorageBreakdownKeepsOnlyAFinishedMeasurement() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(StorageBreakdown(storage: storage(measuring: true), freeableBytes: 10, measuredAt: now) == nil)
    #expect(StorageBreakdown(storage: storage(free: nil), freeableBytes: 10, measuredAt: now) == nil)
    let breakdown = try #require(StorageBreakdown(storage: storage(), freeableBytes: 10, measuredAt: now))
    #expect(breakdown.worktreeBytes == 80)
    #expect(breakdown.cacheBytes == 120)
    #expect(breakdown.toolBytes == 200)
    #expect(breakdown.freeableBytes == 10)
}

@Test func aStorageBreakdownSurvivesTheDefaultsAndIsWrittenOnlyWhenItChanges() throws {
    let suite = "usaige.storage-breakdown.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = try #require(StorageBreakdown(storage: storage(), freeableBytes: 10, measuredAt: Date(timeIntervalSince1970: 1)))
    first.save(to: defaults)
    #expect(StorageBreakdown.load(from: defaults) == first)

    let later = try #require(StorageBreakdown(storage: storage(), freeableBytes: 10, measuredAt: Date(timeIntervalSince1970: 2)))
    #expect(later.sameAmounts(as: first))
    #expect(!later.sameAmounts(as: nil))
}
