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
            planType: "plus",
            secondaryUsedPercent: 33,
            secondaryWindowDurationMinutes: 10_080,
            secondaryResetsAt: 1_800_086_400
        ),
        updatedAt: now
    )

    #expect(snapshot.usedPercent == 100)
    #expect(snapshot.remainingPercent == 0)
    #expect(snapshot.resetAt == Date(timeIntervalSince1970: 1_800_003_600))
    #expect(snapshot.toolID == .chatGPT)
    #expect(snapshot.typeTag == "5H")
    #expect(snapshot.secondaryWindow?.remainingPercent == 67)
    #expect(snapshot.secondaryWindow?.typeTag == "7D")
    #expect(snapshot.combinedTypeTag == "5H + 7D")
}

@Test func formatsUsageWindowAsCompactTypeTag() {
    let weekly = QuotaSnapshot(
        id: "weekly",
        displayName: "Weekly",
        usedPercent: 20,
        remainingPercent: 80,
        resetAt: nil,
        windowDurationMinutes: 10_080,
        planType: nil,
        updatedAt: .distantPast
    )
    let daily = QuotaSnapshot(
        id: "daily",
        displayName: "Daily",
        usedPercent: 20,
        remainingPercent: 80,
        resetAt: nil,
        windowDurationMinutes: 1_440,
        planType: nil,
        updatedAt: .distantPast
    )

    #expect(weekly.typeTag == "7D")
    #expect(daily.typeTag == "1D")
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
