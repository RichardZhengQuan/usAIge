import Foundation
import Testing
@testable import UsageHUD

/// Claude lists its free resets in its usage response. usAIge reads each
/// one's name, what it refills and when it expires.
@Test func claudeFreeResetsAreReadFromItsUsageResponse() throws {
    let payload = try #require(JSONValue.parse(Data("""
    {"five_hour":{"utilization":13,"resets_at":"2026-11-23T10:30:00+00:00"},
     "seven_day":{"utilization":85,"resets_at":"2026-11-24T05:00:00+00:00"},
     "cedar_ember":{"grants":[
      {"id":"full-reset-2611","label":"One full limit reset (November 2026)","resets_left":1,
       "ends_at":"2026-12-10T22:00:00+00:00","clears":["five_hour","seven_day","seven_day_overage_included"],
       "usable_now":true,"paused":false,"type":"full","gives_back_weekly":false},
      {"id":"launch-2610-fable","label":"New model launch: one Fable reset","resets_left":1,
       "ends_at":"2027-03-09T07:59:00+00:00","clears":["five_hour","seven_day_overage_included"],
       "usable_now":true,"paused":false,"type":"full","gives_back_weekly":true},
      {"id":"used-2609","label":"Used up","resets_left":0,"ends_at":"2026-12-01T00:00:00+00:00","type":"full"}]}}
    """.utf8)))
    let credits = ClaudeUsageProvider.resetCredits(from: payload)
    #expect(credits.map(\.title) == ["Full reset", "Fable reset"])
    #expect(credits[0].detail == "Refills your 5-hour and weekly limits.")
    #expect(credits[1].detail == "Refills your 5-hour limit and gives back what Fable used this week.")
    #expect(credits.allSatisfy { $0.usableNow })

    let snapshots = ClaudeUsageProvider.snapshots(from: payload, planType: nil,
                                                  updatedAt: Date(timeIntervalSince1970: 1_795_000_000))
    let main = try #require(snapshots.first)
    #expect(main.availableResetCount == 2)
    #expect(main.resetCreditExpiresAt == credits[0].expiresAt)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-23T06:00:00Z"))
    #expect(snapshots.availableResets(now: now).map(\.title) == ["Full reset", "Fable reset"])
    // An expired reset isn't offered.
    let later = try #require(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
    #expect(snapshots.availableResets(now: later).map(\.title) == ["Fable reset"])
}

/// A tool that reports only a count and its earliest expiry, as Codex does,
/// reads as one entry.
@Test func aCountOfResetCreditsReadsAsOneEntry() {
    var snapshot = QuotaSnapshot.make(
        from: RateLimitBucket(limitID: "codex", limitName: "Codex", usedPercent: 10,
                              windowDurationMinutes: 300, resetsAt: nil, planType: nil),
        updatedAt: Date()
    )
    #expect(snapshot.availableResets.isEmpty)
    snapshot.availableResetCount = 2
    snapshot.resetCreditExpiresAt = Date().addingTimeInterval(86_400)
    #expect(snapshot.availableResets.map(\.title) == ["Reset credits"])
    #expect(snapshot.availableResets.first?.remaining == 2)
    #expect(ResetCreditText.count(snapshot.availableResets) == "2 free resets")
}
