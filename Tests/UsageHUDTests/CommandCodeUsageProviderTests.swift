import Foundation
import Testing
@testable import UsageHUD

private let commandCodeNow = Date(timeIntervalSince1970: 1_795_400_000)
private let commandCodeIdentityURL = "https://api.commandcode.ai/alpha/whoami?limits=1"
private let commandCodeCreditsURL = "https://api.commandcode.ai/alpha/billing/credits"
private let commandCodeSubscriptionsURL = "https://api.commandcode.ai/alpha/billing/subscriptions"
private let commandCodeSummaryURL = "https://api.commandcode.ai/alpha/usage/summary"

private struct CommandCodeFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-cmd-\(UUID().uuidString)")
    var directory: URL { home.appendingPathComponent(".commandcode") }

    func saveAuth(_ json: String = #"{"apiKey":"fixture-cmd-key"}"#) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("auth.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func commandCodeReadsPlanWindowsAndCreditRenewal() async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let credits = """
    {"data":{"credits":{"monthlyCredits":"20","purchasedCredits":10,"freeCredits":10},
    "windowLimits":{"fiveHour":{"used":"10","cap":40,"resetAt":1794653072303},
    "weekly":{"used":80,"cap":"200","resetAt":"1795174633"}}}}
    """
    let subscriptions = """
    {"data":{"status":"active","planId":"Individual_Pro_V1","currentPeriodStart":"2026-10-25T09:28:05.000Z",
    "currentPeriodEnd":"2026-11-25T09:28:05.000Z"}}
    """
    let creditsURL = commandCodeCreditsURL + "?orgId=42"
    let subscriptionsURL = commandCodeSubscriptionsURL + "?orgId=42"
    let http = ScriptedUsageHTTPClient(responses: [
        commandCodeIdentityURL: .init(json: #"{"data":{"org":{"id":42}}}"#),
        creditsURL: .init(json: credits),
        subscriptionsURL: .init(json: subscriptions),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = CommandCodeUsageProvider(
        homeDirectory: fixture.home, http: http, statusRegistry: registry, now: { commandCodeNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["commandCode", "commandCode_credits"])
    #expect(snapshots.map(\.displayName) == ["Plan limits", "Credits"])
    #expect(snapshots.allSatisfy {
        $0.toolID == .commandCode && $0.planType == "Individual_Pro_V1" && $0.updatedAt == commandCodeNow
    })
    let windows = try #require(snapshots.first)
    #expect(windows.usedPercent == 25)
    #expect(windows.windowDurationMinutes == 300)
    #expect(windows.resetAt == Date(timeIntervalSince1970: 1_794_653_072.303))
    #expect(windows.secondaryWindow?.usedPercent == 40)
    #expect(windows.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(windows.secondaryWindow?.resetAt == Date(timeIntervalSince1970: 1_795_174_633))
    let creditQuota = try #require(snapshots.last)
    #expect(creditQuota.usedPercent == 60)
    #expect(creditQuota.windowDurationMinutes == 44_640)
    #expect(creditQuota.resetAt == Date(timeIntervalSince1970: 1_795_598_885))
    #expect(creditQuota.secondaryWindow == nil)
    #expect(await registry.status(for: .commandCode) == .connected)

    let requests = await http.requests
    #expect(requests.compactMap { $0.url?.absoluteString } == [commandCodeIdentityURL, creditsURL, subscriptionsURL])
    for request in requests {
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cmd-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
        #expect(request.timeoutInterval == 15)
        #expect(request.httpBody == nil)
    }
}

@Test func commandCodeUsesPeriodSpendForAnAccountWithAnUnknownAllowance() async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let query = "?orgId=team%2Bqa%20%26%20org"
    let summaryURL = commandCodeSummaryURL + query + "&since=2026-10-25T17:28:05%2B08:00"
    let http = ScriptedUsageHTTPClient(responses: [
        commandCodeIdentityURL: .init(json: #"{"org":{"id":"team+qa & org"}}"#),
        commandCodeCreditsURL + query: .init(json: #"{"credits":{"monthlyCredits":7.5}}"#),
        commandCodeSubscriptionsURL + query: .init(json: """
        {"status":"active","planId":"custom-tier","currentPeriodStart":"2026-10-25T17:28:05+08:00",
        "currentPeriodEnd":1795598885000}
        """),
        summaryURL: .init(json: #"{"data":{"totalCost":"22.5"}}"#),
    ])
    let provider = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http)

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["commandCode_credits"])
    let quota = try #require(snapshots.first)
    #expect(quota.usedPercent == 75)
    #expect(quota.planType == "custom-tier")
    #expect(quota.windowDurationMinutes == 44_640)
    #expect(quota.resetAt == Date(timeIntervalSince1970: 1_795_598_885))
    let request = try #require(await http.requests.last)
    #expect(request.url?.absoluteString == summaryURL)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cmd-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
    #expect(request.httpBody == nil)
}

@Test func commandCodeLeavesOutMissingLimitsAndBalanceWithoutAnAllowance() async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        commandCodeIdentityURL: .init(json: "{}"),
        commandCodeCreditsURL: .init(json: """
        {"credits":{"monthlyCredits":5},"windowLimits":{"fiveHour":{"cap":20},"weekly":{"used":11,"cap":10}}}
        """),
        commandCodeSubscriptionsURL: .init(status: 404),
    ])
    let provider = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http)

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["commandCode"])
    let quota = try #require(snapshots.first)
    #expect(quota.usedPercent == 100)
    #expect(quota.windowDurationMinutes == 10_080)
    #expect(quota.resetAt == nil)
    #expect(quota.planType == nil)
    #expect(quota.secondaryWindow == nil)
    #expect(await http.requests.count == 3)
}

@Test func commandCodeDoesNotUseCanceledPlanAllowances() async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        commandCodeIdentityURL: .init(json: "{}"),
        commandCodeCreditsURL: .init(json: #"{"credits":{"monthlyCredits":3,"planId":"individual-go"}}"#),
        commandCodeSubscriptionsURL: .init(json: #"{"status":"canceled","currentPeriodEnd":"2026-11-25T09:28:05Z"}"#),
    ])

    let provider = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await http.requests.count == 3)
}

@Test func commandCodeDistinguishesMissingFolderFromUnusableAuth() async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .commandCode) == .notInstalled)
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .commandCode) == .signedOut)

    for auth in ["not JSON", #"{"apiKey":"first\nsecond"}"#, #"{"apiKey":"fixture"}"# + String(repeating: " ", count: 1_048_576)] {
        try fixture.saveAuth(auth)
        #expect(try await provider.refresh() == .signedOut)
        #expect(await registry.status(for: .commandCode) == .signedOut)
    }
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [
    (401, LocalToolUsageError.credentialExpired, LocalToolStatus.credentialExpired),
    (403, .credentialExpired, .credentialExpired),
    (429, .rateLimited, .rateLimited),
    (503, .http(503), .failed("The provider returned HTTP 503")),
])
func commandCodeReportsHTTPFailures(
    status: Int, error: LocalToolUsageError, connection: LocalToolStatus
) async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        commandCodeIdentityURL: .init(json: "{}"),
        commandCodeCreditsURL: .init(json: #"{"windowLimits":{"fiveHour":{"used":2,"cap":4}}}"#),
        commandCodeSubscriptionsURL: .init(status: status, json: #"{"message":"private remote data"}"#),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    await #expect(throws: error) { try await provider.refresh() }
    #expect(await registry.status(for: .commandCode) == connection)
}

@Test(arguments: [
    "<html>unexpected body</html>",
    "[]",
    #"{"data":[]}"#,
    #"{"data":{"credits":"unexpected"}}"#,
])
func commandCodeMalformedResponseThrowsAndPreservesTheLastReading(_ malformed: String) async throws {
    let fixture = CommandCodeFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(sequences: [
        commandCodeIdentityURL: [.init(json: "{}")],
        commandCodeCreditsURL: [
            .init(json: #"{"windowLimits":{"fiveHour":{"used":1,"cap":4}}}"#),
            .init(json: malformed),
        ],
        commandCodeSubscriptionsURL: [.init(json: "{}")],
    ])
    let registry = await LocalToolStatusRegistry()
    let commandCode = CommandCodeUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)
    let provider = CompositeUsageProvider(
        local: ScriptedUsageProvider(result: .signedOut),
        throttled: [commandCode],
        remote: ScriptedUsageProvider(result: .signedOut)
    )

    let first = try await provider.refresh()
    #expect(first.snapshots.first?.usedPercent == 25)
    await #expect(throws: LocalToolUsageError.invalidResponse) { try await commandCode.refresh() }
    #expect(try await provider.refresh() == first)
    #expect(await registry.status(for: .commandCode) == .failed("The provider returned an unexpected response"))
}
