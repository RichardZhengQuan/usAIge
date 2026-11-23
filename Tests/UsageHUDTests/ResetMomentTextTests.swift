import Foundation
import Testing
@testable import UsageHUD

/// A limit says when it resets the way a person would: a time today, then
/// tomorrow, a weekday this week, or a date, and counts down when close.
@Test func resetMomentsReadLikeACalendar() throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let locale = Locale(identifier: "en_US")
    // Sunday 22 November 2026, 12:00 UTC.
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z"))
    func moment(_ iso: String) throws -> String? {
        ResetMomentText.moment(try #require(ISO8601DateFormatter().date(from: iso)),
                               now: now, locale: locale, timeZone: utc)
    }

    #expect(try moment("2026-11-22T12:41:00Z") == "in 41 min")
    #expect(try moment("2026-11-22T15:40:00Z")?.hasPrefix("3:40") == true)
    #expect(try moment("2026-11-23T09:00:00Z")?.hasPrefix("tomorrow 9:00") == true)
    #expect(try moment("2026-11-24T09:00:00Z")?.hasPrefix("Tue 9:00") == true)
    #expect(try moment("2026-12-03T09:00:00Z") == "Dec 3")
    #expect(try moment("2027-01-15T09:00:00Z") == "Jan 15, 2027")
    #expect(try moment("2026-11-22T11:00:00Z") == "now")
    #expect(ResetMomentText.moment(nil, now: now) == nil)
}

@Test func resetSentencesAndCountdowns() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ResetMomentText.sentence(nil, now: now) == "No reset time")
    #expect(ResetMomentText.sentence(now.addingTimeInterval(-5), now: now) == "Resetting now")
    #expect(ResetMomentText.sentence(now.addingTimeInterval(600), now: now) == "Resets in 10 min")
    #expect(ResetMomentText.countdown(now.addingTimeInterval(2 * 3_600 + 41 * 60), now: now) == "2h 41m")
    #expect(ResetMomentText.countdown(now.addingTimeInterval(-1), now: now) == nil)
}
