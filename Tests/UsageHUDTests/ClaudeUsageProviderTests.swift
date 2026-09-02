import Foundation
import Testing
@testable import UsageHUD

private let claudeUsageJSON = """
{
  "five_hour": { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
  "seven_day": { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
  "seven_day_opus": null,
  "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-04-16T03:00:00.951719+00:00" },
  "seven_day_oauth_apps": null,
  "seven_day_cowork": { "utilization": 0, "resets_at": null },
  "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": "1250", "currency": "usd" }
}
"""

private func liveCredentials(scopes: [String] = ["user:inference", "user:profile"]) -> ClaudeCredentials {
    ClaudeCredentials(
        accessToken: "sk-ant-oat01-test",
        expiresAt: Date(timeIntervalSince1970: 1_800_100_000),
        scopes: scopes,
        subscriptionType: "max",
        rateLimitTier: nil
    )
}

private let testNow = Date(timeIntervalSince1970: 1_800_000_000)

@Test func claudeCredentialsParseKeychainBlob() throws {
    let raw = """
    {"claudeAiOauth":{"accessToken":" sk-ant-oat01-abc ","refreshToken":"sk-ant-ort01-x","expiresAt":1748276587173,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}
    """
    let credentials = try ClaudeCredentials.parse(Data(raw.utf8))

    #expect(credentials.accessToken == "sk-ant-oat01-abc")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_748_276_587.173))
    #expect(credentials.scopes == ["user:inference", "user:profile"])
    #expect(credentials.subscriptionType == "max")
    #expect(credentials.canReadUsage)
    #expect(!credentials.isExpired(at: Date(timeIntervalSince1970: 1_748_276_587)))
    #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_748_276_588)))
}

@Test func claudeCredentialsRejectMissingToken() {
    #expect(throws: LocalToolUsageError.notSignedIn) {
        _ = try ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"  "}}"#.utf8))
    }
    #expect(throws: LocalToolUsageError.notSignedIn) {
        _ = try ClaudeCredentials.parse(Data("{}".utf8))
    }
    #expect(throws: LocalToolUsageError.invalidResponse) {
        _ = try ClaudeCredentials.parse(Data("not json".utf8))
    }
}

@Test func claudeDecodesUsageWindowsIntoRailBuckets() async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        ClaudeUsageProvider.usageURL.absoluteString: .init(json: claudeUsageJSON),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = ClaudeUsageProvider(
        credentials: StaticClaudeCredentialSource(credentials: liveCredentials()),
        http: http,
        statusRegistry: registry,
        userAgentVersion: { "2.1.212" },
        now: { testNow }
    )

    let result = try await provider.refresh()
    let snapshots = result.snapshots

    #expect(snapshots.map(\.id) == ["claude", "claude_sonnet", "claude_cowork", "claude_extra"])
    #expect(snapshots.allSatisfy { $0.toolID == .claude })
    #expect(snapshots.allSatisfy { $0.planType == "max" })

    let main = snapshots[0]
    #expect(main.displayName == "All models")
    #expect(main.remainingPercent == 67)
    #expect(main.typeTag == "5H")
    #expect(main.resetAt == Date(timeIntervalSince1970: 1_775_890_800.528))
    #expect(main.secondaryWindow?.remainingPercent == 87)
    #expect(main.secondaryWindow?.typeTag == "7D")

    #expect(snapshots[1].displayName == "Sonnet")
    #expect(snapshots[1].remainingPercent == 99)
    #expect(snapshots[1].typeTag == "7D")
    #expect(snapshots[2].displayName == "Cowork")
    #expect(snapshots[2].resetAt == nil)
    #expect(snapshots[3].displayName == "Extra usage")
    #expect(snapshots[3].usedPercent == 25)

    #expect(await http.header("Authorization", ofRequestTo: ClaudeUsageProvider.usageURL) == "Bearer sk-ant-oat01-test")
    #expect(await http.header("anthropic-beta", ofRequestTo: ClaudeUsageProvider.usageURL) == "oauth-2025-04-20")
    #expect(await http.header("User-Agent", ofRequestTo: ClaudeUsageProvider.usageURL) == "claude-code/2.1.212")
    #expect(await registry.status(for: .claude) == .connected)
}

@Test func claudeReportsSignedOutWithoutCredentials() async throws {
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = ClaudeUsageProvider(
        credentials: StaticClaudeCredentialSource(credentials: nil),
        http: http,
        statusRegistry: registry,
        usesAPIKeyHelper: { false },
        now: { testNow }
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(await http.requests.isEmpty)
    #expect(await registry.status(for: .claude) == .signedOut)
}

@Test func claudeReportsExpiredCredentialsWithoutRequesting() async {
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let expired = ClaudeCredentials(
        accessToken: "token",
        expiresAt: Date(timeIntervalSince1970: 1_799_999_999),
        scopes: ["user:profile"],
        subscriptionType: nil,
        rateLimitTier: nil
    )
    let provider = ClaudeUsageProvider(
        credentials: StaticClaudeCredentialSource(credentials: expired),
        http: http,
        statusRegistry: registry,
        now: { testNow }
    )

    await #expect(throws: LocalToolUsageError.credentialExpired) {
        try await provider.refresh()
    }
    #expect(await http.requests.isEmpty)
    #expect(await registry.status(for: .claude) == .credentialExpired)
}

@Test func claudeMapsHTTPFailuresToActionableErrors() async {
    for (status, expected) in [(401, LocalToolUsageError.credentialExpired), (403, .missingScope), (429, .rateLimited), (503, .http(503))] {
        let http = ScriptedUsageHTTPClient(responses: [
            ClaudeUsageProvider.usageURL.absoluteString: .init(status: status, json: "{}"),
        ])
        let provider = ClaudeUsageProvider(
            credentials: StaticClaudeCredentialSource(credentials: liveCredentials()),
            http: http,
            now: { testNow }
        )
        await #expect(throws: expected) {
            try await provider.refresh()
        }
    }
}

@Test func claudeKeychainDenialSurfacesAsStatus() async {
    let registry = await LocalToolStatusRegistry()
    let provider = ClaudeUsageProvider(
        credentials: StaticClaudeCredentialSource(credentials: nil, error: .keychainAccessDenied),
        http: ScriptedUsageHTTPClient(responses: [:]),
        statusRegistry: registry,
        now: { testNow }
    )

    await #expect(throws: LocalToolUsageError.keychainAccessDenied) {
        try await provider.refresh()
    }
    #expect(await registry.status(for: .claude) == .keychainAccessDenied)
}

@Test func claudeUsesWeeklyWindowAloneWhenSessionWindowIsMissing() {
    let response = JSONValue.parse(Data(#"{"seven_day":{"utilization":50,"resets_at":"2026-04-17T00:59:59Z"},"extra_usage":{"is_enabled":false}}"#.utf8))!

    let snapshots = ClaudeUsageProvider.snapshots(from: response, planType: nil, updatedAt: testNow)

    #expect(snapshots.map(\.id) == ["claude"])
    #expect(snapshots[0].typeTag == "7D")
    #expect(snapshots[0].secondaryWindow == nil)
    #expect(snapshots[0].remainingPercent == 50)
}

@Test func claudeCodeVersionIsReadFromInstallPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-claude-version-\(UUID().uuidString)")
    let versions = root.appendingPathComponent("versions/2.1.212")
    try FileManager.default.createDirectory(at: versions.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: versions)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versions.path)
    let binDirectory = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let link = binDirectory.appendingPathComponent("claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: versions)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(ClaudeCodeVersion.version(forExecutableAt: link.path, fileManager: .default) == "2.1.212")

    let npmDirectory = root.appendingPathComponent("node_modules/@anthropic-ai/claude-code")
    try FileManager.default.createDirectory(at: npmDirectory, withIntermediateDirectories: true)
    try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.0.9"}"#.utf8)
        .write(to: npmDirectory.appendingPathComponent("package.json"))
    let cli = npmDirectory.appendingPathComponent("cli.js")
    try Data("".utf8).write(to: cli)
    #expect(ClaudeCodeVersion.version(forExecutableAt: cli.path, fileManager: .default) == "2.0.9")

    #expect(ClaudeCodeVersion.resolve(environment: ["HOME": root.path, "PATH": ""]) == "2.1.212")
    #expect(ClaudeCodeVersion.resolve(environment: ["HOME": "/nonexistent", "PATH": ""]) == ClaudeCodeVersion.fallback)
}

private struct RecordingCredentialSource: ClaudeCredentialSource {
    let box: TestClockBox // reused as a Sendable mutable flag holder
    func load() throws -> ClaudeCredentials? {
        box.now = Date(timeIntervalSince1970: 1)
        return liveCredentials()
    }
}

@Test func claudeStaysInertUntilEnabledAndNeverTouchesTheKeychain() async throws {
    let touched = TestClockBox(Date(timeIntervalSince1970: 0))
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = ClaudeUsageProvider(
        credentials: RecordingCredentialSource(box: touched),
        http: http,
        statusRegistry: registry,
        isEnabled: { false },
        now: { testNow }
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(touched.now == Date(timeIntervalSince1970: 0))
    #expect(await http.requests.isEmpty)
    #expect(await registry.status(for: .claude) == .disabled)
}

@Test func claudeKeychainBlobWithoutAPlanSignInMeansSignedOut() async throws {
    let mcpOnly = #"{"mcpOAuth":{"plugin:x|abc":{"serverName":"x","accessToken":""}}}"#
    #expect(throws: LocalToolUsageError.notSignedIn) {
        _ = try ClaudeCredentials.parse(Data(mcpOnly.utf8))
    }

    let registry = await LocalToolStatusRegistry()
    let provider = ClaudeUsageProvider(
        credentials: StaticClaudeCredentialSource(credentials: nil),
        http: ScriptedUsageHTTPClient(responses: [:]),
        statusRegistry: registry,
        usesAPIKeyHelper: { true },
        now: { testNow }
    )
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .claude) == .apiKeyOnly)
}

@Test func claudeCodeAPIKeyHelperIsDetectedFromSettings() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-claude-home-\(UUID().uuidString)")
    let dir = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(!ClaudeCodeConfiguration.usesAPIKeyHelper(homeDirectory: home))
    try Data(#"{"apiKeyHelper":"/usr/local/bin/helper"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
    #expect(ClaudeCodeConfiguration.usesAPIKeyHelper(homeDirectory: home))
    try Data(#"{"apiKeyHelper":"  "}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
    #expect(!ClaudeCodeConfiguration.usesAPIKeyHelper(homeDirectory: home))
}
