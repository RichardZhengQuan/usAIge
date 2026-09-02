import Foundation
import Testing
@testable import UsageHUD

@Test func localToolDatesParseFractionalAndEpochForms() {
    #expect(LocalToolDates.parse("2026-04-17T00:59:59Z") == Date(timeIntervalSince1970: 1_776_387_599))
    #expect(LocalToolDates.parse("2026-04-17T00:59:59.951713+00:00") == Date(timeIntervalSince1970: 1_776_387_599.951))
    #expect(LocalToolDates.parse("2026-04-17T00:59:59.5Z") == Date(timeIntervalSince1970: 1_776_387_599.5))
    #expect(LocalToolDates.parse("not a date") == nil)
    #expect(LocalToolDates.parse("   ") == nil)
    #expect(LocalToolDates.parseFlexible(.string("1785542400000")) == Date(timeIntervalSince1970: 1_785_542_400))
    #expect(LocalToolDates.parseFlexible(.number(1_785_542_400)) == Date(timeIntervalSince1970: 1_785_542_400))
    #expect(LocalToolDates.parseFlexible(.string("2026-08-01T00:00:00Z")) == Date(timeIntervalSince1970: 1_785_542_400))
    #expect(LocalToolDates.parseFlexible(.bool(true)) == nil)
    #expect(LocalToolDates.windowMinutes(
        from: Date(timeIntervalSince1970: 0),
        to: Date(timeIntervalSince1970: 7 * 86_400)
    ) == 10_080)
    #expect(LocalToolDates.windowMinutes(from: Date(timeIntervalSince1970: 10), to: Date(timeIntervalSince1970: 5)) == nil)
}

@Test func lenientNumbersAcceptStringsAndWrappers() {
    #expect(JSONValue.number(12.5).lenientNumber == 12.5)
    #expect(JSONValue.string(" 42 ").lenientNumber == 42)
    #expect(JSONValue.object(["val": .number(7)]).lenientNumber == 7)
    #expect(JSONValue.object(["value": .string("3")]).lenientNumber == 3)
    #expect(JSONValue.bool(true).lenientNumber == nil)
    #expect(JSONValue.string("nope").lenientNumber == nil)
}

@Test func jsonWebTokenExpiryIsReadFromThePayload() {
    let header = Data(#"{"alg":"HS256"}"#.utf8).base64EncodedString()
    let payload = Data(#"{"sub":"auth0|user_1","exp":1790000000}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    #expect(JSONWebToken.expiry(of: "\(header).\(payload).sig") == Date(timeIntervalSince1970: 1_790_000_000))
    #expect(JSONWebToken.expiry(of: "not-a-jwt") == nil)
}

@Test func humanizedLabelsAndStatusMapping() {
    #expect(LocalToolText.humanized("oauth_apps") == "Oauth apps")
    #expect(LocalToolText.humanized("SUPER_GROK-pro", capitalizeEachWord: true) == "Super Grok Pro")
    #expect(LocalToolStatus(error: LocalToolUsageError.rateLimited) == .rateLimited)
    #expect(LocalToolStatus(error: LocalToolUsageError.notSignedIn) == .signedOut)
    #expect(LocalToolStatus(error: LocalToolTestError.offline) == .failed(LocalToolTestError.offline.localizedDescription))
    let guidance = LocalToolGuidance.supported.first { $0.id == .claude }!
    #expect(guidance.presentation(for: .credentialExpired).isProblem)
    #expect(guidance.presentation(for: .connected).text.hasPrefix("Connected"))
    #expect(guidance.presentation(for: .disabled).text.hasPrefix("Off."))
    #expect(!guidance.presentation(for: .disabled).isProblem)
    #expect(LocalToolGuidance.supported.map(\.id) == [.chatGPT, .claude, .cursor, .grok])
}

@MainActor
@Test func statusRegistryPublishesOnlyChanges() {
    let registry = LocalToolStatusRegistry()
    #expect(registry.status(for: .claude) == .unknown)
    registry.report(.connected, for: .claude)
    registry.report(.signedOut, for: .grok)
    #expect(registry.status(for: .claude) == .connected)
    #expect(registry.status(for: .grok) == .signedOut)
    #expect(registry.statuses.count == 2)
}
