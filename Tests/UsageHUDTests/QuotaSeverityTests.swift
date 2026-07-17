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

@Test func breathesAgentGloryFromThinToThickWithoutChangingItsDiameter() {
    #expect(AgentBreathingMotion.minimumThickness == 2)
    #expect(AgentBreathingMotion.midpointThickness == 4)
    #expect(AgentBreathingMotion.maximumThickness == 6)
    #expect(AgentBreathingMotion.opacity(for: 2) == 0.68)
    #expect(AgentBreathingMotion.opacity(for: 4) == 0.84)
    #expect(AgentBreathingMotion.opacity(for: 6) == 1.00)
}

@Test func sizesHUDToVisibleRowsWithoutLeavingBlankSpace() {
    #expect(HUDMetrics.railHeight(rowCount: 2) == 227)
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
