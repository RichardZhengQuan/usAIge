import Foundation
import Testing
import UserNotifications
@testable import UsageHUD

@Test func usageLimitTrackerBootstrapsWithoutAlertingThenReportsFivePercentSteps() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 4.9)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 5.1)]).map(\.thresholdPercent) == [5])
    #expect(tracker.events(for: [snapshot(usedPercent: 9.9)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 10)]).map(\.thresholdPercent) == [10])
}

@Test func usageLimitTrackerDefaultsToTenPercentSteps() {
    var tracker = UsageLimitThresholdTracker()

    #expect(tracker.events(for: [snapshot(usedPercent: 4.9)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 9.9)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 10)]).map(\.thresholdPercent) == [10])
    #expect(tracker.events(for: [snapshot(usedPercent: 19.9)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 20)]).map(\.thresholdPercent) == [20])
}

@Test func usageLimitTrackerCoalescesAJumpToTheNewestCrossedBoundary() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 11)]).isEmpty)
    let event = try #require(tracker.events(for: [snapshot(usedPercent: 23)]).only)

    #expect(event.thresholdPercent == 20)
    #expect(event.usedPercent == 23)
    #expect(event.remainingPercent == 77)
}

@Test func usageLimitTrackerObservesPrimaryAndSecondaryWindowsIndependently() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(
        tracker.events(
            for: [snapshot(usedPercent: 1, secondaryUsedPercent: 4)]
        ).isEmpty
    )
    let events = tracker.events(
        for: [snapshot(usedPercent: 6, secondaryUsedPercent: 11)]
    )

    #expect(events.map(\.windowKind) == [.primary, .secondary])
    #expect(events.map(\.thresholdPercent) == [5, 10])
}

@Test func usageLimitTrackerNotifiesThenStartsANewThresholdBaselineAfterAReset() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let firstReset = Date(timeIntervalSince1970: 1_800_003_600)
    let nextReset = Date(timeIntervalSince1970: 1_800_021_600)

    #expect(
        tracker.events(for: [snapshot(usedPercent: 49, resetAt: firstReset)]).isEmpty
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 51, resetAt: firstReset)])
            .map(\.thresholdPercent) == [50]
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 2, resetAt: nextReset)])
            .map(\.notificationKind) == [.reset]
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 6, resetAt: nextReset)])
            .map(\.thresholdPercent) == [5]
    )
}

@Test func usageLimitTrackerNotifiesOnceWhenTheLimitResetsToOneHundredPercent() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let firstReset = Date(timeIntervalSince1970: 1_800_003_600)
    let nextReset = Date(timeIntervalSince1970: 1_800_021_600)

    #expect(tracker.events(for: [snapshot(usedPercent: 51, resetAt: firstReset)]).isEmpty)
    let event = try #require(
        tracker.events(for: [snapshot(usedPercent: 0, resetAt: nextReset)]).only
    )

    #expect(event.notificationKind == .reset)
    #expect(event.remainingPercent == 100)
    #expect(tracker.events(for: [snapshot(usedPercent: 0, resetAt: nextReset)]).isEmpty)
}

@Test func usageLimitTrackerNotifiesAboutAFullResetWithoutAResetDate() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 51, resetAt: nil)]).isEmpty)
    let event = try #require(
        tracker.events(for: [snapshot(usedPercent: 0, resetAt: nil)]).only
    )

    #expect(event.notificationKind == .reset)
    #expect(event.remainingPercent == 100)
}

@Test func usageLimitTrackerDoesNotRepeatAfterADownwardCorrection() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let resetAt = Date(timeIntervalSince1970: 1_800_003_600)

    #expect(tracker.events(for: [snapshot(usedPercent: 24, resetAt: resetAt)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 26, resetAt: resetAt)])
            .map(\.thresholdPercent) == [25]
    )
    #expect(tracker.events(for: [snapshot(usedPercent: 24, resetAt: resetAt)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 26, resetAt: resetAt)]).isEmpty)
}

@Test func usageLimitTrackerDoesNotMistakeABoundaryCorrectionForAReset() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let resetAt = Date(timeIntervalSince1970: 1_800_003_600)

    #expect(tracker.events(for: [snapshot(usedPercent: 4.9, resetAt: resetAt)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 5.1, resetAt: resetAt)])
            .map(\.thresholdPercent) == [5]
    )
    #expect(tracker.events(for: [snapshot(usedPercent: 4, resetAt: resetAt)]).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 5.1, resetAt: resetAt)]).isEmpty)
}

@Test func usageLimitTrackerReportsAResetEvenWhenSomeNewLimitWasAlreadyUsed() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let firstReset = Date(timeIntervalSince1970: 1_800_003_600)
    let nextReset = Date(timeIntervalSince1970: 1_800_021_600)

    #expect(tracker.events(for: [snapshot(usedPercent: 95, resetAt: firstReset)]).isEmpty)
    let event = try #require(
        tracker.events(for: [snapshot(usedPercent: 7, resetAt: nextReset)]).only
    )

    #expect(event.notificationKind == .reset)
    #expect(event.remainingPercent == 93)
}

@Test func usageLimitTrackerHandlesUsageAndResetDateArrivingInSeparateUpdates() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let firstReset = Date(timeIntervalSince1970: 1_800_003_600)
    let nextReset = Date(timeIntervalSince1970: 1_800_021_600)

    #expect(tracker.events(for: [snapshot(usedPercent: 49, resetAt: firstReset)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 51, resetAt: firstReset)])
            .map(\.thresholdPercent) == [50]
    )
    #expect(tracker.events(for: [snapshot(usedPercent: 2, resetAt: firstReset)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 2, resetAt: nextReset)])
            .map(\.notificationKind) == [.reset]
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 6, resetAt: nextReset)])
            .map(\.thresholdPercent) == [5]
    )
}

@Test func usageLimitTrackerRearmsAfterARolloverWithoutAResetDate() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 49, resetAt: nil)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 51, resetAt: nil)])
            .map(\.thresholdPercent) == [50]
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 2, resetAt: nil)])
            .map(\.notificationKind) == [.reset]
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 6, resetAt: nil)])
            .map(\.thresholdPercent) == [5]
    )
}

@Test func usageLimitTrackerIgnoresSmallResetDateCorrections() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let resetAt = Date(timeIntervalSince1970: 1_800_003_600)
    let correctedReset = resetAt.addingTimeInterval(5 * 60)

    #expect(tracker.events(for: [snapshot(usedPercent: 24, resetAt: resetAt)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 26, resetAt: resetAt)])
            .map(\.thresholdPercent) == [25]
    )
    #expect(tracker.events(for: [snapshot(usedPercent: 24, resetAt: resetAt)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 24, resetAt: correctedReset)]).isEmpty
    )
    #expect(
        tracker.events(for: [snapshot(usedPercent: 26, resetAt: correctedReset)]).isEmpty
    )
}

@Test func usageLimitTrackerRecognizesAConsumedResetCreditBeforeTheQuotaRefreshArrives() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let resetAt = Date(timeIntervalSince1970: 1_800_003_600)

    #expect(
        tracker.events(for: [
            snapshot(usedPercent: 95, resetAt: resetAt, availableResetCount: 1),
        ]).isEmpty
    )
    #expect(
        tracker.events(for: [
            snapshot(usedPercent: 95, resetAt: resetAt, availableResetCount: 0),
        ]).isEmpty
    )
    let event = try #require(
        tracker.events(for: [
            snapshot(usedPercent: 1, resetAt: resetAt, availableResetCount: 0),
        ]).only
    )

    #expect(event.notificationKind == .reset)
    #expect(event.remainingPercent == 99)
}

@Test func usageLimitTrackerReportsOneHundredPercentOnlyOnce() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 94)]).isEmpty)
    #expect(
        tracker.events(for: [snapshot(usedPercent: 100)])
            .map(\.thresholdPercent) == [100]
    )
    #expect(tracker.events(for: [snapshot(usedPercent: 100)]).isEmpty)
}

@Test func usageLimitTrackerTreatsAReappearingLimitAsANewBaseline() {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)

    #expect(tracker.events(for: [snapshot(usedPercent: 24)]).isEmpty)
    #expect(tracker.events(for: []).isEmpty)
    #expect(tracker.events(for: [snapshot(usedPercent: 26)]).isEmpty)
}

@Test func usageLimitNotificationRequestDescribesTheCurrentLimit() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    #expect(tracker.events(for: [snapshot(usedPercent: 20)]).isEmpty)
    let event = try #require(tracker.events(for: [snapshot(usedPercent: 26)]).only)

    let request = UsageLimitNotificationRequest.make(for: event)

    #expect(request.identifier.contains("chatGPT-codex-primary-25"))
    #expect(request.content.categoryIdentifier == UsageLimitNotifications.categoryIdentifier)
    #expect(request.content.title == "ChatGPT Codex 5-hour: 74% remaining")
    #expect(request.content.body.contains("5H usage reached 25%"))
    #expect(request.content.sound != nil)
    #expect(request.content.userInfo["bucketID"] as? String == "codex")
    #expect(request.content.userInfo["thresholdPercent"] as? Int == 25)
}

@Test func usageLimitNotificationRequestDescribesAFullReset() throws {
    var tracker = UsageLimitThresholdTracker(stepPercent: 5)
    let firstReset = Date(timeIntervalSince1970: 1_800_003_600)
    let nextReset = Date(timeIntervalSince1970: 1_800_021_600)
    #expect(tracker.events(for: [snapshot(usedPercent: 51, resetAt: firstReset)]).isEmpty)
    let event = try #require(
        tracker.events(for: [snapshot(usedPercent: 0, resetAt: nextReset)]).only
    )

    let request = UsageLimitNotificationRequest.make(for: event)

    #expect(request.identifier.contains("chatGPT-codex-primary-reset-100"))
    #expect(request.content.title == "ChatGPT Codex 5-hour: limit reset")
    #expect(request.content.body == "5H usage has reset. 100% is available now.")
    #expect(request.content.userInfo["notificationKind"] as? String == "reset")
}

@Test func usageLimitNotificationCategoryProvidesAForegroundViewAction() throws {
    let category = UsageLimitNotifications.category
    let action = try #require(category.actions.only)

    #expect(category.identifier == UsageLimitNotifications.categoryIdentifier)
    #expect(action.identifier == UsageLimitNotifications.openLimitsActionIdentifier)
    #expect(action.title == "View Limits")
    #expect(action.options.contains(.foreground))
}

@Test func appRegistersUpdateAndUsageLimitNotificationCategoriesTogether() {
    #expect(
        Set(AppNotificationCategories.all.map(\.identifier)) == [
            UpdateController.notificationCategory,
            UsageLimitNotifications.categoryIdentifier,
        ]
    )
}

@Test func appNotificationRouterOpensTheRightNativeSurface() {
    #expect(
        AppNotificationRouter.destination(
            categoryIdentifier: UsageLimitNotifications.categoryIdentifier,
            actionIdentifier: UsageLimitNotifications.openLimitsActionIdentifier
        ) == .limits
    )
    #expect(
        AppNotificationRouter.destination(
            categoryIdentifier: UsageLimitNotifications.categoryIdentifier,
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .limits
    )
    #expect(
        AppNotificationRouter.destination(
            categoryIdentifier: UpdateController.notificationCategory,
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .whatsNew
    )
    #expect(
        AppNotificationRouter.destination(
            categoryIdentifier: UsageLimitNotifications.categoryIdentifier,
            actionIdentifier: UNNotificationDismissActionIdentifier
        ) == nil
    )
    #expect(
        AppNotificationRouter.destination(
            categoryIdentifier: "UNKNOWN",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == nil
    )
}

private func snapshot(
    usedPercent: Double,
    secondaryUsedPercent: Double? = nil,
    resetAt: Date? = Date(timeIntervalSince1970: 1_800_003_600),
    availableResetCount: Int? = nil
) -> QuotaSnapshot {
    var snapshot = QuotaSnapshot(
        id: "codex",
        displayName: "Codex 5-hour",
        usedPercent: usedPercent,
        remainingPercent: 100 - usedPercent,
        resetAt: resetAt,
        windowDurationMinutes: 300,
        planType: "plus",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        secondaryWindow: secondaryUsedPercent.map {
            QuotaWindowSnapshot(
                usedPercent: $0,
                remainingPercent: 100 - $0,
                resetAt: resetAt,
                windowDurationMinutes: 10_080
            )
        }
    )
    snapshot.availableResetCount = availableResetCount
    return snapshot
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
