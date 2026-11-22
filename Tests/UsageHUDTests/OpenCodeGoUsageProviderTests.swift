import Foundation
import Testing
@testable import UsageHUD

private let openCodeGoUsageURL = "https://opencode.ai/zen/go/v1/usage"
private let openCodeGoNow = Date(timeIntervalSince1970: 1_796_000_000)

private struct OpenCodeGoFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-opencode-\(UUID().uuidString)")
    var directory: URL { home.appendingPathComponent(".local/share/opencode") }
    var xdgHome: URL { home.appendingPathComponent("xdg-data") }

    func saveAuth(
        _ json: String = #"{"opencode-go":{"type":"api","key":"fixture-go-key"}}"#,
        in alternateDirectory: URL? = nil
    ) throws {
        let folder = alternateDirectory ?? directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("auth.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Test func openCodeGoReadsThePreferredKeyAndGoUsageWindows() async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth("""
    {"opencode-go":{"type":"api","key":"fixture-go-key"},"opencode":{"type":"api","key":"fixture-zen-key"}}
    """)
    let http = ScriptedUsageHTTPClient(responses: [
        openCodeGoUsageURL: .init(json: """
        {"usage":{"rolling":{"status":"ok","percent":"12.5","resetsAt":"2026-12-05T16:00:00.250Z"},
        "weekly":{"status":"ok","percent":40,"resetsAt":"2026-12-07T00:00:00Z"},
        "monthly":{"status":"rate-limited","percent":98,"resetsAt":"2027-01-01T00:00:00Z"}}}
        """),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = OpenCodeGoUsageProvider(
        homeDirectory: fixture.home, environment: [:], http: http, statusRegistry: registry, now: { openCodeGoNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["openCodeGo", "openCodeGo_monthly"])
    #expect(snapshots.map(\.displayName) == ["Plan limits", "Monthly"])
    #expect(snapshots.allSatisfy { $0.toolID == .openCodeGo && $0.planType == nil && $0.updatedAt == openCodeGoNow })
    let plan = try #require(snapshots.first)
    #expect(plan.usedPercent == 12.5)
    #expect(plan.windowDurationMinutes == 300)
    let reset = ISO8601DateFormatter().date(from: "2026-12-05T16:00:00Z")
    #expect(plan.resetAt == reset?.addingTimeInterval(0.25))
    #expect(plan.secondaryWindow?.usedPercent == 40)
    #expect(plan.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(plan.secondaryWindow?.resetAt == ISO8601DateFormatter().date(from: "2026-12-07T00:00:00Z"))
    let monthly = try #require(snapshots.last)
    #expect(monthly.usedPercent == 100)
    #expect(monthly.windowDurationMinutes == nil)
    #expect(monthly.resetAt == ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
    #expect(monthly.secondaryWindow == nil)
    #expect(await registry.status(for: .openCodeGo) == .connected)

    let request = try #require(await http.requests.first)
    #expect(await http.requests.count == 1)
    #expect(request.url?.absoluteString == openCodeGoUsageURL)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-go-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == UsAIgeUserAgent.value)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpBody == nil)
}

@Test func openCodeGoUsesXDGDataHomeAndFallsBackToTheSavedZenKey() async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    try fixture.saveAuth(
        #"{"opencode-go":{"type":"api","key":" "},"opencode":{"type":"api","key":"fixture-xdg-zen"}}"#,
        in: fixture.xdgHome.appendingPathComponent("opencode")
    )
    let http = ScriptedUsageHTTPClient(responses: [
        openCodeGoUsageURL: .init(json: #"{"usage":{"rolling":{"percent":2}}}"#),
    ])
    let provider = OpenCodeGoUsageProvider(
        homeDirectory: fixture.home,
        environment: ["XDG_DATA_HOME": fixture.xdgHome.path, "OPENCODE_API_KEY": "unused-environment-fixture"],
        http: http
    )

    #expect(try await provider.refresh().snapshots.first?.usedPercent == 2)
    let request = try #require(await http.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-xdg-zen")
}

@Test func openCodeGoLeavesOutUnreportedWindowsAndResetDates() async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        openCodeGoUsageURL: .init(json: """
        {"usage":{"rolling":{"status":"ok"},"weekly":{"percent":130,"resetsAt":"invalid"},
        "monthly":{"percent":"-4"}}}
        """),
    ])
    let provider = OpenCodeGoUsageProvider(homeDirectory: fixture.home, environment: ["XDG_DATA_HOME": ""], http: http)

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["openCodeGo", "openCodeGo_monthly"])
    #expect(snapshots.map(\.usedPercent) == [100, 0])
    #expect(snapshots.allSatisfy { $0.resetAt == nil && $0.secondaryWindow == nil })
    #expect(snapshots.first?.windowDurationMinutes == 10_080)
    #expect(snapshots.last?.windowDurationMinutes == nil)
}

@Test func openCodeGoReportsAnExistingFolderWithoutAuthAsSignedOut() async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = OpenCodeGoUsageProvider(
        homeDirectory: fixture.home,
        environment: ["OPENCODE_API_KEY": "unused-environment-fixture"],
        http: http,
        statusRegistry: registry
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .openCodeGo) == .notInstalled)
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data().write(to: fixture.directory.appendingPathComponent("opencode.db"))
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .openCodeGo) == .signedOut)

    try fixture.saveAuth(#"{"unrelated-provider":{"key":"unrelated-fixture"}}"#)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .openCodeGo) == .signedOut)

    try fixture.saveAuth(#"{"opencode-go":{"key":"fixture"}}"# + String(repeating: " ", count: 1_048_576))
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .openCodeGo) == .signedOut)
    #expect(await http.requests.isEmpty)
}

@Test func openCodeGoReportsAMissingSubscriptionForHTTP403() async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        openCodeGoUsageURL: .init(status: 403, json: #"{"message":"private remote data"}"#),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = OpenCodeGoUsageProvider(homeDirectory: fixture.home, environment: [:], http: http, statusRegistry: registry)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .openCodeGo) == .failed("This OpenCode key has no Go subscription."))
    #expect(await http.requests.count == 1)
}

@Test(arguments: [
    (401, LocalToolUsageError.credentialExpired, LocalToolStatus.credentialExpired),
    (429, .rateLimited, .rateLimited),
    (503, .http(503), .failed("The provider returned HTTP 503")),
])
func openCodeGoReportsHTTPFailures(status: Int, error: LocalToolUsageError, connection: LocalToolStatus) async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [
        openCodeGoUsageURL: .init(status: status, json: #"{"message":"private remote data"}"#),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = OpenCodeGoUsageProvider(homeDirectory: fixture.home, environment: [:], http: http, statusRegistry: registry)

    await #expect(throws: error) { try await provider.refresh() }
    #expect(await registry.status(for: .openCodeGo) == connection)
}

@Test(arguments: ["not JSON", "{}", #"{"usage":{}}"#, #"{"usage":{"rolling":{"percent":"invalid"}}}"#])
func openCodeGoThrowsForAnUnreadableUsageResponse(_ json: String) async throws {
    let fixture = OpenCodeGoFixture()
    defer { fixture.remove() }
    try fixture.saveAuth()
    let http = ScriptedUsageHTTPClient(responses: [openCodeGoUsageURL: .init(json: json)])
    let registry = await LocalToolStatusRegistry()
    let provider = OpenCodeGoUsageProvider(homeDirectory: fixture.home, environment: [:], http: http, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .openCodeGo) == .failed("The provider returned an unexpected response"))
}
