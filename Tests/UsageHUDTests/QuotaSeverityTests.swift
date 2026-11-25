import AppKit
import SwiftUI
import Testing
@testable import UsageHUD

@Test(arguments: [
    (100.0, QuotaSeverity.abundant),
    (60.1, QuotaSeverity.abundant),
    (60.0, QuotaSeverity.healthy),
    (40.1, QuotaSeverity.healthy),
    (40.0, QuotaSeverity.caution),
    (20.1, QuotaSeverity.caution),
    (20.0, QuotaSeverity.low),
    (10.1, QuotaSeverity.low),
    (10.0, QuotaSeverity.critical),
    (0.0, QuotaSeverity.critical),
])
func mapsRemainingPercentageToSeverity(input: (Double, QuotaSeverity)) {
    #expect(QuotaSeverity(remainingPercent: input.0) == input.1)
}

@Test(arguments: [
    (10.1, false),
    (10.0, true),
    (5.0, true),
    (0.0, true),
])
func appliesScaryGlowAcrossTheEntireCriticalRange(input: (Double, Bool)) {
    #expect(
        QuotaSeverity(remainingPercent: input.0).showsScaryGlow == input.1
    )
}

@Test(arguments: [
    (100.0, 1.0),
    (35.0, 0.35),
    (5.0, 0.05),
    (0.0, 1.0),
    (-5.0, 1.0),
])
func mapsRemainingPercentageToVisibleRingFraction(input: (Double, Double)) {
    #expect(QuotaRingPresentation.arcFraction(remainingPercent: input.0) == input.1)
}

private func resetSample(hours: Int, credits: Int? = nil, now: Date = Date()) -> QuotaSnapshot {
    var sample = QuotaSnapshot.make(from: RateLimitBucket(
        limitID: "quota-\(hours)", limitName: nil, usedPercent: 50, windowDurationMinutes: hours * 60,
        resetsAt: now.addingTimeInterval(Double(hours) * 3600).timeIntervalSince1970, planType: nil
    ), updatedAt: now)
    sample.availableResetCount = credits
    return sample
}

@Test func showsPositiveResetCreditsEvenWhenAnotherLimitHoldsTheCount() {
    let model = resetSample(hours: 3)
    let account = resetSample(hours: 16, credits: 2)
    #expect(ResetCreditPresentation.displayedCount(for: model) == nil)
    #expect(ResetCreditPresentation.displayedCount(for: account) == 2)
    #expect(ResetCreditPresentation.displayedCount(for: model, otherLimits: [account]) == 2)
    #expect(ResetCreditPresentation.displayedCount(for: resetSample(hours: 16, credits: 0)) == nil)
    #expect(ResetCreditPresentation.displayedCount(for: resetSample(hours: 16, credits: -1)) == nil)
}

@MainActor
@Test func fullSizeResetBadgesFitSideBySideAtEveryRailTextSize() {
    guard #available(macOS 14.0, *) else { return }
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let primary = resetSample(hours: 3, credits: 2, now: now)
    let secondary = resetSample(hours: 16, now: now)
    let weekly = resetSample(hours: 7 * 24, credits: 3, now: now)
    var pair = primary
    pair.secondaryWindow = secondary.primaryWindow
    for size in HUDTextSize.allCases {
        for modern in [false, true] {
            func width(_ snapshot: QuotaSnapshot, credits: Int?) -> CGFloat {
                let badges = RailResetBadges(snapshot: snapshot, credits: credits, now: now, isModern: modern)
                    .environment(\.hudTextSize, size)
                return NSHostingView(rootView: badges).fittingSize.width
            }
            let first = width(primary, credits: 2)
            let second = width(secondary, credits: nil)
            let together = width(pair, credits: 2)
            #expect(first > width(primary, credits: nil))
            #expect(width(weekly, credits: 3) > width(weekly, credits: nil))
            #expect(second >= 44 * size.factor - 1)
            #expect(abs(together - first - second - 8 * size.factor) < 2)
            for scale in [0.5, 1.0, 1.5] {
                let panel = HUDMetrics.railWidth(for: size, labelWidth: together, maximumWidth: 1280 / scale) * scale
                #expect(panel >= (together + 2 * HUDMetrics.horizontalInset) * scale)
            }
            let long = width(pair, credits: 123_456_789)
            #expect(long > together)
            #expect(HUDMetrics.railWidth(for: size, labelWidth: long) >= long + 2 * HUDMetrics.horizontalInset)
        }
    }
}

@Test func breathesAgentGloryOutwardWithoutCrossingRingInterior() {
    #expect(AgentBreathingMotion.minimumThickness == 2)
    #expect(AgentBreathingMotion.midpointThickness == 4)
    #expect(AgentBreathingMotion.maximumThickness == 6)
    #expect(AgentBreathingMotion.opacity(for: 2) == 0.52)
    #expect(AgentBreathingMotion.opacity(for: 4) == 0.66)
    #expect(AgentBreathingMotion.opacity(for: 6) == 0.80)

    let breathingDiameter = AgentBreathingMotion.baseDiameter(
        outsideQuotaRing: 46,
        quotaLineWidth: 4
    )
    #expect(breathingDiameter == 53)
    #expect(AgentBreathingMotion.outwardDiameter(baseDiameter: breathingDiameter, thickness: 2) == 55)
    #expect(AgentBreathingMotion.outwardDiameter(baseDiameter: breathingDiameter, thickness: 6) == 59)

    let quotaOuterRadius = (46.0 + 4.0) / 2.0
    let innerRadiusAtMinimum = (55.0 - 2.0) / 2.0
    let innerRadiusAtMaximum = (59.0 - 6.0) / 2.0
    #expect(abs(innerRadiusAtMinimum - quotaOuterRadius - AgentBreathingMotion.quotaRingGap) < 0.001)
    #expect(abs(innerRadiusAtMaximum - quotaOuterRadius - AgentBreathingMotion.quotaRingGap) < 0.001)
}

@Test func sizesHUDToVisibleRowsWithoutLeavingBlankSpace() {
    #expect(HUDMetrics.quotaRowHeight == 102)
    #expect(HUDMetrics.railHeight(rowCount: 1) == 167)
    #expect(HUDMetrics.railHeight(rowCount: 2) == 279)
    #expect(HUDMetrics.railHeight(rowCount: 8) == 450)
    // Five tools no longer scroll when the display has room for them.
    #expect(HUDMetrics.railHeight(rowCount: 5, maximumHeight: 900) == 615)
    #expect(HUDMetrics.railHeight(rowCount: 8, maximumHeight: 900) == 900)
    #expect(HUDMetrics.railHeight(rowCount: 8, maximumHeight: 600) == 600)
    #expect(HUDMetrics.maximumRailHeight(visibleHeight: 932, scale: 1) == 900)
    #expect(HUDMetrics.maximumRailHeight(visibleHeight: 932, scale: 2) == 450)
    #expect(HUDMetrics.maximumRailHeight(visibleHeight: 100, scale: 1) == 120)
    #expect(HUDMetrics.messageSize == CGSize(width: 160, height: 120))
    #expect(HUDMetrics.railWidth(for: .standard) == 160)
}

@Test func theRailFitsTheSelectedTextSizeAndTheWidestActualReadout() {
    let small = HUDMetrics.railWidth(for: .small)
    let standard = HUDMetrics.railWidth(for: .standard)
    let large = HUDMetrics.railWidth(for: .large)
    #expect(small > 84 && small < standard && standard < large)
    for size in HUDTextSize.allCases {
        let width = HUDMetrics.railWidth(for: size, labelWidth: 198.5)
        #expect(width >= 198.5 + 2 * HUDMetrics.horizontalInset)
        #expect(HUDMetrics.railWidth(for: size, labelWidth: 198.5, maximumWidth: 212) == 212)
    }
    #expect(HUDMetrics.railHeight(rowCount: 2, textSize: .large) > HUDMetrics.railHeight(rowCount: 2))
}

@Test func scalesThePanelBoundsWithTheHUDContent() {
    #expect(
        HUDMetrics.scaledSize(CGSize(width: 84, height: 227), scale: 2.5)
            == CGSize(width: 210, height: 567.5)
    )
    #expect(
        HUDMetrics.scaledSize(CGSize(width: 84, height: 120), scale: 0.5)
            == CGSize(width: 42, height: 60)
    )
}

@Test func appliesConfiguredOpacityOnlyUntilHovered() {
    #expect(HUDMetrics.contentOpacity(configured: 0.92, isHovered: false) == 0.92)
    #expect(HUDMetrics.contentOpacity(configured: 0.92, isHovered: true) == 1)
    #expect(HUDMetrics.contentOpacity(configured: 0.1, isHovered: false) == 0.1)
    #expect(HUDMetrics.contentOpacity(configured: 0.1, isHovered: true) == 1)
}

@Test func keepsCriticalQuotaAlertVisibleWithoutHover() {
    #expect(
        HUDMetrics.contentOpacity(configured: 0.92, isHovered: false, isCritical: true)
            == 0.92
    )
    #expect(
        HUDMetrics.contentOpacity(configured: 0.4, isHovered: false, isCritical: true)
            == 0.92
    )
    #expect(
        HUDMetrics.contentOpacity(configured: 0.4, isHovered: true, isCritical: true)
            == 1
    )
}

@Test func keepsConnectionStatusVisibleWithoutHover() {
    #expect(
        HUDMetrics.contentOpacity(
            configured: 0.1,
            isHovered: false,
            forceVisible: true
        ) == 1
    )
}

@Test func hidesFooterControlsUntilHovered() {
    #expect(HUDMetrics.controlOpacity(isHovered: false) == 0)
    #expect(HUDMetrics.controlOpacity(isHovered: true) == 1)
}

@Test func usesFullNativeGlassOnlyWhileActive() {
    #expect(HUDMetrics.glassSurfaceOpacity(isHovered: false) == 0)
    #expect(HUDMetrics.glassSurfaceOpacity(isHovered: true) == 1)
    #expect(HUDMetrics.glassSurfaceOpacity(isHovered: false, forceVisible: true) == 1)
}
