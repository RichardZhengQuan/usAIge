import CoreGraphics
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

@Test func hidesResetCreditsUnlessTheAvailableCountIsPositive() {
    #expect(
        ResetCreditPresentation.displayedCount(
            showsResetCredits: true,
            availableCount: 1
        ) == 1
    )
    #expect(
        ResetCreditPresentation.displayedCount(
            showsResetCredits: true,
            availableCount: 0
        ) == nil
    )
    #expect(
        ResetCreditPresentation.displayedCount(
            showsResetCredits: true,
            availableCount: nil
        ) == nil
    )
    #expect(
        ResetCreditPresentation.displayedCount(
            showsResetCredits: false,
            availableCount: 2
        ) == nil
    )
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
    #expect(HUDMetrics.quotaRowHeight == 84)
    #expect(HUDMetrics.railHeight(rowCount: 1) == 149)
    #expect(HUDMetrics.railHeight(rowCount: 2) == 243)
    #expect(HUDMetrics.railHeight(rowCount: 8) == 450)
    #expect(HUDMetrics.messageSize == CGSize(width: 84, height: 120))
    #expect(HUDMetrics.railWidth == 84)
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
