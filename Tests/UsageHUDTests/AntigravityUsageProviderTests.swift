/// Exercises quota responses from the running Antigravity language server.
/// The language-server endpoint was learned from ClaudeBar's Antigravity provider
/// (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Foundation
import Testing
@testable import UsageHUD

private let antigravityTestNow = Date(timeIntervalSince1970: 1_740_000_000)
private let antigravityTestToken = "fixture-csrf"
private let antigravityTestSummary = """
{
  "response": {
    "groups": [
      { "buckets": [
        { "bucketId": "gemini-weekly", "remainingFraction": 0.5, "resetTime": "2025-01-07T00:00:00Z" },
        { "bucketId": "gemini-5h", "remainingFraction": 0.75, "resetTime": "2025-01-01T05:00:00Z" }
      ] },
      { "buckets": [
        { "bucketId": "3p-5h", "remainingFraction": 0.25 },
        { "bucketId": "3p-weekly", "remainingFraction": 0.125 }
      ] },
      { "buckets": [
        { "bucketId": "gemini-argon-wtu-weekly", "remainingFraction": 0.875 }
      ] }
    ]
  }
}
"""

private struct AntigravityTestLocator: AntigravityServerLocating {
    let location: AntigravityServerLocation
    var onLocate: @Sendable () -> Void = {}

    init(httpsPorts: [UInt16] = [42_135], extensionPort: UInt16? = nil) {
        location = .running(csrfToken: antigravityTestToken, httpsPorts: httpsPorts, extensionPort: extensionPort)
    }

    func locate() async throws -> AntigravityServerLocation {
        onLocate()
        return location
    }
}

private func antigravityTestURL(
    _ scheme: String = "https", port: UInt16 = 42_135, method: String = "RetrieveUserQuotaSummary"
) -> String {
    "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)"
}

@Test func antigravityDoesNotLocateOrRequestBeforeOptIn() async throws {
    var locator = AntigravityTestLocator()
    locator.onLocate = { Issue.record("Antigravity discovery ran while the reader was off") }
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(locator: locator, http: http, isOptedIn: { false }, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .antigravity) == .optInRequired)
    #expect(await http.requests.isEmpty)
}

@Test func antigravityDoesNotRequestWhenTurnedOffDuringDiscovery() async throws {
    let suite = "usaige.antigravity.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    LocalToolOptIn.setEnabled(true, for: .antigravity, defaults: defaults)
    var locator = AntigravityTestLocator()
    locator.onLocate = {
        LocalToolOptIn.setEnabled(false, for: .antigravity, defaults: UserDefaults(suiteName: suite)!)
    }
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: locator, http: http,
        isOptedIn: { LocalToolOptIn.isEnabled(.antigravity, defaults: UserDefaults(suiteName: suite)!) },
        statusRegistry: registry
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(!LocalToolOptIn.isEnabled(.antigravity, defaults: defaults))
    #expect(await registry.status(for: .antigravity) == .optInRequired)
    #expect(await http.requests.isEmpty)
}

@Test func antigravityReadsPoolsAsPairedWindowsAndSendsTheExpectedRequest() async throws {
    let url = antigravityTestURL()
    let http = ScriptedUsageHTTPClient(responses: [url: .init(json: antigravityTestSummary)])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: AntigravityTestLocator(extensionPort: 58_445),
        http: http,
        isOptedIn: { true },
        statusRegistry: registry,
        now: { antigravityTestNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["antigravity", "antigravity_others", "antigravity_argon"])
    #expect(snapshots.map(\.displayName) == ["Gemini", "Claude & others", "Gemini Argon"])
    #expect(snapshots.allSatisfy { $0.toolID == .antigravity && $0.updatedAt == antigravityTestNow && $0.planType == nil })
    #expect(snapshots.map(\.usedPercent) == [25, 75, 12.5])
    #expect(snapshots.map(\.windowDurationMinutes) == [300, 300, 10_080])
    #expect(snapshots.map { $0.secondaryWindow?.usedPercent } == [50, 87.5, nil])
    #expect(snapshots.map { $0.secondaryWindow?.windowDurationMinutes } == [10_080, 10_080, nil])
    // The live response's reset times are shown as reported, including past dates.
    #expect(snapshots.map(\.resetAt) == [Date(timeIntervalSince1970: 1_735_707_600), nil, nil])
    #expect(snapshots.map { $0.secondaryWindow?.resetAt } == [Date(timeIntervalSince1970: 1_736_208_000), nil, nil])
    #expect(await registry.status(for: .antigravity) == .connected)

    let requests = await http.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == url)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == antigravityTestToken)
    #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
    #expect(request.httpBody == Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8))
}

@Test func antigravityPromotesTheOnlyUsableWindowAndMatchesExactBucketIDs() throws {
    let json = """
    {
      "planName": "Pro",
      "groups": [{ "buckets": [
        { "bucketId": "gemini-5h" },
        { "bucketId": "gemini-weekly", "remainingFraction": "NaN" },
        { "bucketId": "gemini-weekly", "remaining_fraction": 1.2, "reset_time": "1736208000" },
        { "bucketId": "gemini-weekly", "remainingFraction": 0.5 },
        { "bucketId": "3p-5h", "remainingFraction": -0.1, "resetTime": "unknown" },
        { "bucketId": "3p-weekly", "remainingFraction": true },
        { "bucketId": "gemini-argon-wtu-5h", "remainingFraction": 0.9 },
        { "id": "gemini-argon-wtu-weekly", "remainingFraction": 0.9 }
      ] }]
    }
    """
    let document = try #require(JSONValue.parse(Data(json.utf8)))
    let buckets = try #require(AntigravityQuotaParser.summary(from: document))

    #expect(buckets.map(\.limitID) == ["antigravity", "antigravity_others"])
    #expect(buckets.map(\.windowDurationMinutes) == [10_080, 300])
    #expect(buckets.map(\.usedPercent) == [0, 100])
    #expect(buckets.map(\.resetsAt) == [1_736_208_000, nil])
    #expect(buckets.map(\.planType) == ["Pro", "Pro"])
    #expect(buckets.allSatisfy { $0.secondaryUsedPercent == nil && $0.secondaryResetsAt == nil })
}

@Test func antigravityTreatsAnEmptySummaryAsAReading() async throws {
    let http = ScriptedUsageHTTPClient(responses: [antigravityTestURL(): .init(json: #"{"groups":[]}"#)])
    let provider = AntigravityUsageProvider(locator: AntigravityTestLocator(), http: http, isOptedIn: { true })

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await http.requests.count == 1)
}

@Test func antigravityFallsBackToLegacyModelsAndReadsTheReportedPlan() async throws {
    let summary = antigravityTestURL()
    let status = antigravityTestURL(method: "GetUserStatus")
    let json = """
    {
      "userStatus": {
        "planStatus": { "planInfo": { "planName": "Pro" } },
        "cascadeModelConfigData": { "clientModelConfigs": [
          { "label": "Claude Sonnet", "quotaInfo": { "remainingFraction": 0.75 } },
          { "label": "Gemini Pro", "quotaInfo": { "remainingFraction": 0.5, "resetTime": "1735689600" } },
          { "label": "Gemini-Pro", "quotaInfo": { "remainingFraction": 0.25 } },
          { "label": "Gemini Pro", "quotaInfo": { "remainingFraction": 1 } },
          { "label": "Unreported model", "quotaInfo": { "resetTime": "1735689600" } }
        ] }
      }
    }
    """
    let http = ScriptedUsageHTTPClient(responses: [
        summary: .init(status: 404),
        status: .init(json: json),
    ])
    let provider = AntigravityUsageProvider(locator: AntigravityTestLocator(), http: http, isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.displayName) == ["Claude Sonnet", "Gemini Pro", "Gemini-Pro"])
    #expect(snapshots.map(\.remainingPercent) == [75, 50, 25])
    #expect(snapshots.map(\.resetAt) == [nil, Date(timeIntervalSince1970: 1_735_689_600), nil])
    #expect(snapshots.allSatisfy { $0.planType == "Pro" && $0.windowDurationMinutes == 300 && $0.secondaryWindow == nil })
    #expect(snapshots.allSatisfy { $0.id.hasPrefix("antigravity_model_") })
    #expect(Set(snapshots.map(\.id)).count == snapshots.count)
    #expect(try await provider.refresh().snapshots.map(\.id) == snapshots.map(\.id))
    #expect(await http.requests.map { $0.url?.absoluteString } == [summary, status, summary, status])
}

@Test(arguments: [
    "/Volumes/Work Drive/Antigravity.app/Contents/MacOS/language_server_macos_arm --csrf_token=fixture-csrf --extension_server_port 58445",
    "/opt/google/language_server_macos --app_data_dir=/Users/test/Library/Application Support/Antigravity --extension_server_port=58445 --csrf_token fixture-csrf",
    "/Users/test/.local/bin/agy --csrf_token fixture-csrf --extension_server_port=58445",
])
func antigravityDiscoversTheFirstTokenBearingProcessByPID(command: String) async throws {
    let commands = ScriptedLocalCommandRunner(stdout: [
        "pgrep": """
        500 /opt/bin/agy --csrf_token higher-pid
        9 /bin/sh /tmp/antigravity/agy --csrf_token unrelated
        12 /Applications/Other Editor.app/language_server_macos_arm --csrf_token other-editor
        30 agy chat
        41    \(command)
        """,
        "lsof": """
        COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_   41 test   17u  IPv4    0x0      0t0  TCP 127.0.0.1:42135 (LISTEN)
        language_   41 test   18u  IPv6    0x1      0t0  TCP [::1]:42135 (LISTEN)
        language_   41 test   19u  IPv4    0x2      0t0  TCP *:41999 (LISTEN)
        language_   41 test   20u  IPv4    0x3      0t0  TCP *:70000 (LISTEN)
        language_   41 test   21u  IPv4    0x4      0t0  TCP 127.0.0.1:41200->127.0.0.1:41201 (ESTABLISHED)
        """,
    ])
    let locator = AntigravityProcessLocator(commands: commands)

    #expect(try await locator.locate() == .running(
        csrfToken: antigravityTestToken, httpsPorts: [42_135, 41_999], extensionPort: 58_445
    ))
    let calls = await commands.calls
    #expect(calls.map(\.name) == ["pgrep", "lsof"])
    #expect(calls.map(\.arguments) == [
        ["-lf", "language_server|agy"],
        ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "41"],
    ])
}

@Test func antigravityTriesHTTPSPortsInOrderThenThePlainHTTPExtension() async throws {
    let first = antigravityTestURL()
    let second = antigravityTestURL(port: 41_999)
    let extensionURL = antigravityTestURL("http", port: 58_445)
    let http = ScriptedUsageHTTPClient(responses: [
        first: .init(status: 503),
        second: .init(json: "<unreadable>"),
        extensionURL: .init(json: antigravityTestSummary),
    ])
    let provider = AntigravityUsageProvider(
        locator: AntigravityTestLocator(httpsPorts: [42_135, 41_999], extensionPort: 58_445), http: http,
        isOptedIn: { true }
    )

    #expect(try await provider.refresh().snapshots.count == 3)
    #expect(await http.requests.map { $0.url?.absoluteString } == [first, second, extensionURL])
}

@Test(arguments: ["Library/Application Support/Antigravity", ".gemini/antigravity"])
func antigravityDistinguishesMissingAndInstalledWhenNothingRuns(installPath: String) async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-antigravity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let commands = ScriptedLocalCommandRunner(stdout: ["pgrep": ""], exitCode: 1)
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: AntigravityProcessLocator(commands: commands), http: http, homeDirectory: home,
        isOptedIn: { true }, statusRegistry: registry
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .antigravity) == .notInstalled)

    try FileManager.default.createDirectory(at: home.appendingPathComponent(installPath), withIntermediateDirectories: true)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .antigravity) == .signedOut)
    #expect(await commands.calls.map(\.name) == ["pgrep", "pgrep"])
    #expect(await http.requests.isEmpty)
}

@Test func antigravityAsksForARestartWhenTheProcessHasNoCSRFToken() async throws {
    let commands = ScriptedLocalCommandRunner(stdout: ["pgrep": "30 agy --csrf_token --extension_server_port 58445"])
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: AntigravityProcessLocator(commands: commands), http: http, isOptedIn: { true }, statusRegistry: registry
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .antigravity) == .failed("Restart Antigravity so usAIge can read its limits."))
    #expect(await commands.calls.map(\.name) == ["pgrep"])
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [401, 429])
func antigravityMapsAuthenticationAndRateLimitFailures(httpStatus: Int) async {
    let http = ScriptedUsageHTTPClient(responses: [antigravityTestURL(): .init(status: httpStatus)])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: AntigravityTestLocator(httpsPorts: [42_135, 41_999], extensionPort: 58_445),
        http: http,
        isOptedIn: { true },
        statusRegistry: registry
    )
    let error: LocalToolUsageError = httpStatus == 401 ? .credentialExpired : .rateLimited
    let status: LocalToolStatus = httpStatus == 401 ? .credentialExpired : .rateLimited

    await #expect(throws: error) { try await provider.refresh() }
    #expect(await registry.status(for: .antigravity) == status)
    #expect(await http.requests.count == 1)
}

@Test func antigravityThrowsOnMalformedResponsesAndTheCompositeKeepsLastGoodLimits() async throws {
    let http = ScriptedUsageHTTPClient(sequences: [
        antigravityTestURL(): [.init(json: antigravityTestSummary), .init(json: "{broken")],
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(locator: AntigravityTestLocator(), http: http, isOptedIn: { true }, statusRegistry: registry)
    let composite = CompositeUsageProvider(
        local: ScriptedUsageProvider(result: .signedOut),
        throttled: [provider],
        remote: ScriptedUsageProvider(result: .signedOut)
    )

    let good = try await composite.refresh()
    #expect(good.snapshots.count == 3)
    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(try await composite.refresh() == good)
    #expect(await registry.status(for: .antigravity) == LocalToolStatus(error: LocalToolUsageError.invalidResponse))
}

@Test func antigravityReportsTimeoutWhenNoPortAnswers() async {
    let registry = await LocalToolStatusRegistry()
    let provider = AntigravityUsageProvider(
        locator: AntigravityTestLocator(), http: AntigravityTimedOutHTTPClient(),
        isOptedIn: { true }, statusRegistry: registry
    )

    await #expect(throws: LocalToolUsageError.timedOut) { try await provider.refresh() }
    #expect(await registry.status(for: .antigravity) == LocalToolStatus(error: LocalToolUsageError.timedOut))
}

private struct AntigravityTimedOutHTTPClient: UsageHTTPClient {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        throw URLError(.timedOut)
    }
}

@Test(arguments: [
    "https://example.invalid/usage",
    "https://127.0.0.1.example.invalid/usage",
    "https://127.0.0.1@example.invalid/usage",
    "https://localhost/usage",
    "http://[::1]/usage",
])
func antigravityLoopbackClientRejectsOtherHostsBeforeSending(address: String) async throws {
    let client = AntigravityLoopbackHTTPClient()
    let url = try #require(URL(string: address))

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await client.send(URLRequest(url: url)) }
}

@Test func antigravityTrustExceptionAppliesOnlyToIPv4LoopbackServerTrust() {
    let serverTrust = NSURLAuthenticationMethodServerTrust
    #expect(AntigravityLoopbackHTTPClient.acceptsServerTrust(host: "127.0.0.1", authenticationMethod: serverTrust))
    for host in ["localhost", "::1", "127.0.0.2", "127.0.0.1.example.invalid", "example.invalid"] {
        #expect(!AntigravityLoopbackHTTPClient.acceptsServerTrust(host: host, authenticationMethod: serverTrust))
    }
    #expect(!AntigravityLoopbackHTTPClient.acceptsServerTrust(
        host: "127.0.0.1", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
    ))
}
