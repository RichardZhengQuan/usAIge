import Foundation
import Testing
@testable import UsageHUD

private let copilotEndpoint = "https://api.github.com/copilot_internal/user"
private let copilotTestToken = "copilot-fixture-token"
private let copilotTestNow = Date(timeIntervalSince1970: 1_770_000_000)
private let copilotMonthlyQuotas = """
{
  "copilot_plan": "business",
  "sku": "unused-sku",
  "quota_reset_date_utc": "2026-03-01T00:00:00.000Z",
  "quota_reset_date": "2026-03-02",
  "quota_snapshots": {
    "premium_interactions": {"entitlement": 300, "remaining": 298, "percent_remaining": 99.3},
    "chat": {"has_quota": true, "entitlement": "50", "remaining": "15"},
    "completions": {"entitlement": 2000, "percent_remaining": 80},
    "code_reviews": {"entitlement": 10, "remaining": 5}
  }
}
"""

private func copilotHTTP(_ response: ScriptedUsageHTTPClient.Response) -> ScriptedUsageHTTPClient {
    ScriptedUsageHTTPClient(responses: [copilotEndpoint: response])
}

private func copilotProvider(
    http: any UsageHTTPClient,
    runner: any LocalCommandRunning = ScriptedLocalCommandRunner(stdout: ["gh": copilotTestToken]),
    isOptedIn: @escaping @Sendable () -> Bool = { true },
    registry: LocalToolStatusRegistry? = nil
) -> CopilotUsageProvider {
    CopilotUsageProvider(
        commandRunner: runner,
        http: http,
        isOptedIn: isOptedIn,
        statusRegistry: registry,
        now: { copilotTestNow }
    )
}

@Test func copilotReadsMonthlyCreditsAndOtherLimitedPools() async throws {
    let runner = ScriptedLocalCommandRunner(stdout: ["gh": "\(copilotTestToken)\r\n"])
    let http = copilotHTTP(.init(json: copilotMonthlyQuotas))
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, runner: runner, registry: registry)

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["copilot", "copilot_chat", "copilot_code_reviews", "copilot_completions"])
    #expect(snapshots.map(\.displayName) == ["AI credits", "Chat", "Code reviews", "Completions"])
    #expect(snapshots.allSatisfy { $0.toolID == .copilot && $0.planType == "business" })
    let credits = try #require(snapshots.first)
    #expect(abs(credits.usedPercent - 0.7) < 1e-9)
    #expect(snapshots.dropFirst().map(\.usedPercent) == [70, 50, 20])
    #expect(credits.windowDurationMinutes == 28 * 1_440)
    #expect(snapshots.dropFirst().allSatisfy { $0.windowDurationMinutes == nil })
    let reset = Date(timeIntervalSince1970: 1_772_323_200)
    #expect(snapshots.allSatisfy { $0.resetAt == reset })
    #expect(snapshots.allSatisfy { $0.secondaryWindow == nil && $0.updatedAt == copilotTestNow })
    #expect(await registry.status(for: .copilot) == .connected)

    let calls = await runner.calls
    #expect(calls == [.init(
        name: "gh",
        arguments: ["auth", "token", "--hostname", "github.com"],
        environment: ["GH_TOKEN": "", "GITHUB_TOKEN": ""]
    )])
    let requests = await http.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == copilotEndpoint)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(copilotTestToken)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
    #expect(request.allHTTPHeaderFields?.count == 3)
    #expect(request.httpBody == nil)
}

@Test func copilotDerivesTheMonthFromTheReportedDateAndReadsTheSKU() async throws {
    let json = #"{"sku":"student","quota_reset_date":"2026-05-18","quota_snapshots":{"premium_interactions":{"entitlement":200,"credits_used":25}}}"#
    let provider = copilotProvider(http: copilotHTTP(.init(json: json)))

    let snapshot = try #require(try await provider.refresh().snapshots.first)

    #expect(snapshot.resetAt == LocalToolDates.parse("2026-05-18T00:00:00Z"))
    #expect(snapshot.windowDurationMinutes == 30 * 1_440)
    #expect(snapshot.planType == "student")
    #expect(snapshot.usedPercent == 12.5)
}

@Test func copilotLeavesMissingFieldsUnsetAndClampsUsage() async throws {
    let json = """
    {
      "login": "fixture-user",
      "quota_reset_date_utc": "invalid-date",
      "quota_snapshots": {
        "premium_interactions": {"entitlement": 200, "remaining": -1},
        "chat": {"entitlement": 50, "percent_remaining": 110},
        "completions": {"entitlement": 2000}
      }
    }
    """
    let provider = copilotProvider(http: copilotHTTP(.init(json: json)))

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["copilot", "copilot_chat"])
    #expect(snapshots.map(\.usedPercent) == [100, 0])
    #expect(snapshots.allSatisfy { $0.planType == nil && $0.resetAt == nil && $0.windowDurationMinutes == nil })
}

@Test(arguments: [
    #"{"copilot_plan":"business"}"#,
    #"{"quota_snapshots":{"premium_interactions":{"unlimited":true,"percent_remaining":100},"chat":{"remaining":20},"completions":{"entitlement":50,"has_quota":false,"remaining":20}}}"#,
])
func copilotOmitsUnlimitedPoolsAndBalancesWithoutAnAllowance(_ json: String) async throws {
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: copilotHTTP(.init(json: json)), registry: registry)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .copilot) == .connected)
}

@Test func copilotDoesNotRunACommandOrRequestBeforeOptIn() async throws {
    let runner = ScriptedLocalCommandRunner(stdout: ["gh": copilotTestToken])
    let http = copilotHTTP(.init(json: copilotMonthlyQuotas))
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, runner: runner, isOptedIn: { false }, registry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .copilot) == .optInRequired)
    #expect(await runner.calls.isEmpty)
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [ScriptedLocalCommandRunner.Reply.notInstalled, .failure(.notInstalled)])
func copilotReportsAGitHubCLIMissingAtLaunch(_ reply: ScriptedLocalCommandRunner.Reply) async throws {
    let runner = ScriptedLocalCommandRunner(["gh": [reply]])
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, runner: runner, registry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .copilot) == .notInstalled)
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [(1, "copilot-fixture-token\n"), (0, " \r\n")])
func copilotReportsSignedOutWithoutAUsableCLISignIn(exitCode: Int32, output: String) async throws {
    let runner = ScriptedLocalCommandRunner(stdout: ["gh": output], exitCode: exitCode)
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, runner: runner, registry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .copilot) == .signedOut)
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [
    ScriptedLocalCommandRunner.Reply.output(.init(exitCode: 0, standardOutput: Data("token\nfixture-user\n".utf8))),
    .output(.init(exitCode: 0, standardOutput: Data([0xFF]))),
    .failure(.timedOut),
])
func copilotRejectsMalformedOrTimedOutCLIOutput(_ reply: ScriptedLocalCommandRunner.Reply) async throws {
    let runner = ScriptedLocalCommandRunner(["gh": [reply]])
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, runner: runner, registry: registry)
    let failure: LocalToolUsageError = if case .failure(.timedOut) = reply { .timedOut } else { .invalidResponse }

    await #expect(throws: failure) { try await provider.refresh() }
    #expect(await registry.status(for: .copilot) == LocalToolStatus(error: failure))
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [
    (401, LocalToolUsageError.credentialExpired, LocalToolStatus.credentialExpired),
    (403, .http(403), .failed("This GitHub sign-in can't read Copilot limits. Run `gh auth refresh -s copilot` if your plan needs it.")),
    (429, .rateLimited, .rateLimited),
    (503, .http(503), .failed("The provider returned HTTP 503")),
])
func copilotReportsHTTPFailuresWithoutEchoingTheResponse(
    code: Int,
    failure: LocalToolUsageError,
    status: LocalToolStatus
) async throws {
    let http = copilotHTTP(.init(status: code, json: #"{"message":"private-fixture@example.invalid"}"#))
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, registry: registry)

    await #expect(throws: failure) { try await provider.refresh() }
    #expect(await registry.status(for: .copilot) == status)
    #expect(await http.requests.count == 1)
}

@Test func copilotReportsNoSubscriptionFor404() async throws {
    let http = copilotHTTP(.init(status: 404))
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: http, registry: registry)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .copilot) == .failed("No Copilot subscription on this GitHub account."))
}

@Test(arguments: ["{truncated", "[]", #"{"quota_snapshots":[]}"#])
func copilotThrowsInvalidResponseForMalformedUsage(_ json: String) async throws {
    let registry = await LocalToolStatusRegistry()
    let provider = copilotProvider(http: copilotHTTP(.init(json: json)), registry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .copilot) == LocalToolStatus(error: LocalToolUsageError.invalidResponse))
}

@Test func copilotUsesTheCurrentCLISignInAndPreservesTheLastGoodReadingOnFailure() async throws {
    let newToken = "copilot-next-fixture-token"
    let runner = ScriptedLocalCommandRunner(["gh": [
        .output(.init(exitCode: 0, standardOutput: Data(copilotTestToken.utf8))),
        .output(.init(exitCode: 0, standardOutput: Data(newToken.utf8))),
    ]])
    let http = ScriptedUsageHTTPClient(sequences: [copilotEndpoint: [
        .init(json: copilotMonthlyQuotas),
        .init(json: "{truncated"),
    ]])
    let copilot = copilotProvider(http: http, runner: runner)
    let composite = CompositeUsageProvider(
        local: ScriptedUsageProvider(result: .signedOut),
        throttled: [copilot],
        remote: ScriptedUsageProvider(results: [.failure(RemoteUsageError.noSources)])
    )

    let first = try await composite.refresh()
    #expect(first.snapshots.first?.id == "copilot")
    #expect(try await composite.refresh() == first)
    let requests = await http.requests
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
        "Bearer \(copilotTestToken)", "Bearer \(newToken)",
    ])
}
