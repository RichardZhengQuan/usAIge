import Foundation
import Testing
@testable import UsageHUD

@Test func calculatesAndClampsRemainingPercentage() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = QuotaSnapshot.make(
        from: .init(
            limitID: "codex",
            limitName: "Codex 5-hour",
            usedPercent: 125,
            windowDurationMinutes: 300,
            resetsAt: 1_800_003_600,
            planType: "plus"
        ),
        updatedAt: now
    )

    #expect(snapshot.usedPercent == 100)
    #expect(snapshot.remainingPercent == 0)
    #expect(snapshot.resetAt == Date(timeIntervalSince1970: 1_800_003_600))
}

@Test func fallsBackToReadableBucketName() throws {
    let snapshot = QuotaSnapshot.make(
        from: .init(
            limitID: "codex_other",
            limitName: nil,
            usedPercent: 25,
            windowDurationMinutes: nil,
            resetsAt: nil,
            planType: nil
        ),
        updatedAt: .distantPast
    )

    #expect(snapshot.displayName == "Codex Other")
    #expect(snapshot.remainingPercent == 75)
}

@Test func preservesProvidedDisplayName() throws {
    let snapshot = QuotaSnapshot.make(
        from: .init(
            limitID: "weekly",
            limitName: "Weekly limit",
            usedPercent: -10,
            windowDurationMinutes: 10_080,
            resetsAt: nil,
            planType: nil
        ),
        updatedAt: .distantPast
    )

    #expect(snapshot.displayName == "Weekly limit")
    #expect(snapshot.usedPercent == 0)
    #expect(snapshot.remainingPercent == 100)
}
