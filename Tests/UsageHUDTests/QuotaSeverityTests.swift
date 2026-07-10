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
    #expect(HUDMetrics.height(rowCount: 2, includesStatusBanner: false) == 226)
    #expect(HUDMetrics.height(rowCount: 8, includesStatusBanner: false) == 420)
    #expect(HUDMetrics.messageHeight == 260)
}
