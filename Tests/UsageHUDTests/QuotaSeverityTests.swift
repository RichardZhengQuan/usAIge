import CoreGraphics
import Testing
@testable import UsageHUD

@Test(arguments: [
    (75.0, QuotaSeverity.normal),
    (20.1, QuotaSeverity.normal),
    (20.0, QuotaSeverity.warning),
    (10.1, QuotaSeverity.warning),
    (10.0, QuotaSeverity.critical),
    (0.0, QuotaSeverity.critical),
])
func mapsRemainingPercentageToSeverity(input: (Double, QuotaSeverity)) {
    #expect(QuotaSeverity(remainingPercent: input.0) == input.1)
}

@Test func sizesHUDToVisibleRowsWithoutLeavingBlankSpace() {
    #expect(HUDMetrics.railHeight(rowCount: 2) == 227)
    #expect(HUDMetrics.railHeight(rowCount: 8) == 450)
    #expect(HUDMetrics.messageSize == CGSize(width: 220, height: 176))
    #expect(HUDMetrics.railWidth == 84)
}

@Test func scalesThePanelBoundsWithTheHUDContent() {
    #expect(
        HUDMetrics.scaledSize(CGSize(width: 84, height: 227), scale: 1.5)
            == CGSize(width: 126, height: 340.5)
    )
    #expect(
        HUDMetrics.scaledSize(CGSize(width: 84, height: 120), scale: 0.75)
            == CGSize(width: 63, height: 90)
    )
}

@Test func dimsAllContentToHalfOpacityUntilHovered() {
    #expect(HUDMetrics.contentOpacity(configured: 0.92, isHovered: false) == 0.46)
    #expect(HUDMetrics.contentOpacity(configured: 0.92, isHovered: true) == 0.92)
}
