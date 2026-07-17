import Foundation
import Testing
@testable import UsageHUD

@Test func resetRemainingTextUsesRealTimeUntilReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(ResetRemainingText.compact(until: now.addingTimeInterval(5 * 86_400 + 1), now: now) == "6D")
    #expect(ResetRemainingText.compact(until: now.addingTimeInterval(5 * 3_600 + 1), now: now) == "6H")
    #expect(ResetRemainingText.compact(until: now.addingTimeInterval(44 * 60 + 1), now: now) == "45M")
}

@Test func resetRemainingTextHandlesMissingAndElapsedDates() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(ResetRemainingText.compact(until: nil, now: now) == nil)
    #expect(ResetRemainingText.compact(until: now, now: now) == "NOW")
    #expect(ResetRemainingText.accessibilityLabel(until: now, now: now) == "Resetting now")
}
