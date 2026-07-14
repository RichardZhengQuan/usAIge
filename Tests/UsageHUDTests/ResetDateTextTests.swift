import Foundation
import Testing
@testable import UsageHUD

@Test func resetDateUsesARealLocalizedDateAndTime() throws {
    let date = try #require(
        ISO8601DateFormatter().date(from: "2027-01-15T21:00:00Z")
    )
    let text = ResetDateText.format(
        date,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: try #require(TimeZone(secondsFromGMT: 0))
    )

    #expect(text.contains("Jan 15, 2027"))
    #expect(text.contains("9:00"))
    #expect(text.contains("PM"))
    #expect(!text.contains("Resets in"))
}

@Test func resetDateReportsUnavailableWhenMissing() {
    #expect(ResetDateText.format(nil) == "Unavailable")
}
