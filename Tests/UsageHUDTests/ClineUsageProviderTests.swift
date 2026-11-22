import Foundation
import Testing
@testable import UsageHUD

private let clineUsageURL = "https://api.cline.bot/api/v1/users/me/plan/usage-limits"
private let clineNow = Date(timeIntervalSince1970: 1_796_000_000)

private struct ClineFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-cline-\(UUID().uuidString)")
    var directory: URL { home.appendingPathComponent(".cline") }

    func saveAuth(_ settings: String = #"{"auth":{"accessToken":"fixture-cline-session"}}"#) throws {
        let folder = directory.appendingPathComponent("data/settings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = "{\"providers\":{\"cline\":{\"settings\":\(settings)}}}"
        try Data(json.utf8).write(to: folder.appendingPathComponent("providers.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func clineReadsCLIAuthAndCombinesFiveHourAndWeeklyLimits() async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        clineUsageURL: .init(json: """
        {"success":true,"data":{"limits":[
            {"type":"weekly","percentUsed":"25","resetsAt":"2026-12-07T00:00:00Z"},
            {"type":"experimental_pool","percentUsed":77},
            {"type":"five_hour","percentUsed":12.5,"resetsAt":"2026-12-05T15:00:00Z"},
            {"type":"monthly","percentUsed":40,"resetsAt":"2027-01-01T00:00:00Z"}
        ]}}
        """),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry, now: { clineNow })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["cline", "cline_monthly"])
    #expect(snapshots.map(\.displayName) == ["Plan limits", "Monthly"])
    #expect(snapshots.allSatisfy { $0.toolID == .cline && $0.planType == nil && $0.updatedAt == clineNow })
    let plan = try #require(snapshots.first)
    #expect(plan.remainingPercent == 87.5)
    #expect(plan.windowDurationMinutes == 300)
    #expect(plan.resetAt == ISO8601DateFormatter().date(from: "2026-12-05T15:00:00Z"))
    #expect(plan.secondaryWindow?.remainingPercent == 75)
    #expect(plan.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(plan.secondaryWindow?.resetAt == ISO8601DateFormatter().date(from: "2026-12-07T00:00:00Z"))
    let monthly = try #require(snapshots.last)
    #expect(monthly.usedPercent == 40)
    #expect(monthly.resetAt == ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
    #expect(monthly.windowDurationMinutes == nil)
    #expect(monthly.secondaryWindow == nil)
    #expect(await registry.status(for: .cline) == .connected)

    let request = try #require(await http.requests.first)
    #expect(await http.requests.count == 1)
    #expect(request.url?.absoluteString == clineUsageURL)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer workos:fixture-cline-session")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpBody == nil)
}

@Test(arguments: [
    (#"{"auth":{"accessToken":"workos:fixture-session"},"apiKey":"unused-fixture"}"#, "workos:fixture-session"),
    (#"{"apiKey":"fixture-settings-key"}"#, "fixture-settings-key"),
    (#"{"auth":{"accessToken":"workos:","apiKey":"fixture-nested-key"}}"#, "fixture-nested-key"),
])
func clineUsesTheSavedCredentialWithItsExpectedScheme(settings: String, token: String) async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth(settings)
    let http = ScriptedUsageHTTPClient(responses: [
        clineUsageURL: .init(json: #"{"data":{"limits":[{"type":"five_hour","percentUsed":10}]}}"#),
    ])
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http)

    #expect(try await provider.refresh().snapshots.count == 1)
    let request = try #require(await http.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
}

@Test func clineLeavesOutUnknownFieldsAndDoesNotDuplicateAWindow() async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        clineUsageURL: .init(json: """
        {"data":{"limits":[{"type":"five_hour"},{"type":"weekly","percentUsed":-3},
        {"type":"weekly","percentUsed":27},{"type":"monthly","percentUsed":115,"resetsAt":null}]}}
        """),
    ])
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http)

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["cline", "cline_monthly"])
    #expect(snapshots.map(\.usedPercent) == [0, 100])
    #expect(snapshots.allSatisfy { $0.resetAt == nil && $0.secondaryWindow == nil })
    #expect(snapshots.first?.windowDurationMinutes == 10_080)
    #expect(snapshots.last?.windowDurationMinutes == nil)
}

@Test(arguments: [
    #"{"success":false}"#,
    #"{"success":true,"data":{"limits":[]}}"#,
    #"{"data":{"limits":[{"type":"experimental_pool","percentUsed":30}]}}"#,
])
func clineReportsAnAccountWithNoPlanLimits(_ json: String) async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [clineUsageURL: .init(json: json)])
    let registry = await LocalToolStatusRegistry()
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .cline) == .failed("This Cline account has no plan limits."))
}

@Test func clineDistinguishesMissingFolderFromAnUnsignedLogin() async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .cline) == .notInstalled)
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .cline) == .signedOut)

    try fixture.saveAuth(#"{"auth":{"accessToken":""},"other":{"apiKey":"unrelated-fixture"}}"#)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .cline) == .signedOut)

    try fixture.saveAuth(#"{"apiKey":"fixture"}"# + String(repeating: " ", count: 1_048_576))
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .cline) == .signedOut)
    #expect(await http.requests.isEmpty)
}

@Test(arguments: [
    (401, LocalToolUsageError.credentialExpired, LocalToolStatus.credentialExpired),
    (403, .credentialExpired, .credentialExpired),
    (429, .rateLimited, .rateLimited),
    (503, .http(503), .failed("The provider returned HTTP 503")),
])
func clineReportsHTTPFailures(status: Int, error: LocalToolUsageError, connection: LocalToolStatus) async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        clineUsageURL: .init(status: status, json: #"{"message":"private remote data"}"#),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    await #expect(throws: error) { try await provider.refresh() }
    #expect(await registry.status(for: .cline) == connection)
}

@Test(arguments: ["not JSON", "{}", #"{"data":{"limits":[{"type":"five_hour","percentUsed":"invalid"}]}}"#])
func clineThrowsForUnreadableUsage(_ json: String) async throws {
    let fixture = ClineFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [clineUsageURL: .init(json: json)])
    let registry = await LocalToolStatusRegistry()
    let provider = ClineUsageProvider(homeDirectory: fixture.home, http: http, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .cline) == .failed("The provider returned an unexpected response"))
}
