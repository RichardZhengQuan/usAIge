import Foundation
import Testing
@testable import UsageHUD

private let testNow = Date(timeIntervalSince1970: 1_781_000_000)

private func liveCredential(token: String = "grok-token") -> GrokCredential {
    GrokCredential(token: token, email: "dev@example.com", expiresAt: Date(timeIntervalSince1970: 1_790_000_000))
}

private let subscriptionsJSON = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE"}]}"#

@Test func grokAuthFileOrdersXAIAccountsFirst() {
    let document = JSONValue.parse(Data("""
    {
      "https://example.com": { "key": "secondary-token", "email": "secondary@example.com" },
      "https://auth.x.ai::b1a00492": { "key": "primary-token", "email": "primary@example.com", "expires_at": "2026-09-01T00:00:00Z" },
      "https://empty.example.com": { "key": "" }
    }
    """.utf8))!

    let credentials = GrokBuildAuthFile.credentials(in: document)

    #expect(credentials.map(\.token) == ["primary-token", "secondary-token"])
    #expect(credentials[0].email == "primary@example.com")
    #expect(credentials[0].expiresAt == Date(timeIntervalSince1970: 1_788_220_800))
    #expect(GrokBuildAuthFile.credentials(in: .array([])).isEmpty)
    #expect(GrokBuildAuthFile.credentials(in: .object([:])).isEmpty)
}

@Test func grokDecodesCreditsConfigFrames() {
    let config = ProtoTestBuilder.creditsConfig(usedPercent: 25, start: 1_780_272_000, end: 1_782_864_000)
    let metric = GrokUsageProvider.parseCreditsConfigResponse(ProtoTestBuilder.creditsFrame(config: config))

    #expect(metric?.label == "Monthly credits")
    #expect(abs((metric?.usedPercent ?? 0) - 25) < 1e-6)
    #expect(metric?.periodEnd == Date(timeIntervalSince1970: 1_782_864_000))

    let boundsOnly = ProtoTestBuilder.creditsConfig(usedPercent: nil, start: 1_780_272_000, end: 1_780_876_800)
    let untouched = GrokUsageProvider.parseCreditsConfigResponse(ProtoTestBuilder.creditsFrame(config: boundsOnly))
    #expect(untouched?.usedPercent == 0)
    #expect(untouched?.label == "Weekly credits")

    let trailer = ProtoTestBuilder.grpcFrame(flag: 0x80, message: Array("grpc-status: 0".utf8))
    #expect(GrokUsageProvider.parseCreditsConfigResponse(trailer) == nil)
    let endOnly = ProtoTestBuilder.creditsConfig(usedPercent: 40, start: nil, end: 1_782_864_000)
    let afterTrailer = GrokUsageProvider.parseCreditsConfigResponse(trailer + ProtoTestBuilder.creditsFrame(config: endOnly))
    #expect(abs((afterTrailer?.usedPercent ?? 0) - 40) < 1e-6)
    #expect(afterTrailer?.label == "Credits")
    #expect(GrokUsageProvider.parseCreditsConfigResponse(ProtoTestBuilder.creditsFrame(config: [])) == nil)
}

@Test func grokVarintEdgeCases() {
    var position = 0
    #expect(GrokUsageProvider.readVarint([0x80], &position) == nil)
    position = 0
    #expect(GrokUsageProvider.readVarint([UInt8](repeating: 0x80, count: 10) + [0x01], &position) == nil)
    position = 0
    #expect(GrokUsageProvider.readVarint([0xAC, 0x02], &position) == 300)
    #expect(position == 2)
    position = 0
    #expect(GrokUsageProvider.nextField([0x0D, 0x01, 0x02], &position) == nil)
    position = 0
    #expect(GrokUsageProvider.nextField([0x0A, 0x05, 0x01], &position) == nil)
}

@Test func grokDecodesTaskUsageAndSubscriptionPlan() {
    let usage = JSONValue.parse(Data(#"{"data":{"frequentUsage":3,"frequentLimit":10,"occasionalUsage":"1","occasionalLimit":{"val":5},"resetTime":"2026-06-08T00:00:00Z"}}"#.utf8))!
    let buckets = GrokUsageProvider.taskUsageBuckets(in: usage)

    #expect(buckets.map(\.limitID) == ["grok_frequent", "grok_occasional"])
    #expect(abs(buckets[0].usedPercent - 30) < 1e-9)
    #expect(abs(buckets[1].usedPercent - 20) < 1e-9)
    #expect(buckets[0].resetsAt == 1_780_876_800)

    #expect(GrokUsageProvider.subscriptionPlan(in: JSONValue.parse(Data(subscriptionsJSON.utf8))!) == "Super Grok Pro")
    let inactive = JSONValue.parse(Data(#"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_SUPER_GROK_PRO","status":"SUBSCRIPTION_STATUS_INACTIVE"}]}"#.utf8))!
    #expect(GrokUsageProvider.subscriptionPlan(in: inactive) == nil)
}

@Test func grokPrefersCreditsConfigAndAttachesThePlan() async throws {
    let config = ProtoTestBuilder.creditsConfig(usedPercent: 12.5, start: 1_780_272_000, end: 1_782_864_000)
    let http = ScriptedUsageHTTPClient(responses: [
        GrokUsageProvider.creditsConfigURL.absoluteString: .init(body: Data(ProtoTestBuilder.creditsFrame(config: config))),
        GrokUsageProvider.subscriptionsURL.absoluteString: .init(json: subscriptionsJSON),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [liveCredential()]),
        http: http,
        statusRegistry: registry,
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["grok"])
    #expect(snapshots[0].toolID == .grok)
    #expect(snapshots[0].displayName == "Monthly credits")
    #expect(abs(snapshots[0].remainingPercent - 87.5) < 1e-6)
    #expect(snapshots[0].planType == "Super Grok Pro")
    #expect(snapshots[0].resetAt == Date(timeIntervalSince1970: 1_782_864_000))
    #expect(snapshots[0].typeTag == "30D")
    #expect(await http.header("X-XAI-Token-Auth", ofRequestTo: GrokUsageProvider.creditsConfigURL) == "xai-grok-cli")
    #expect(await http.header("Authorization", ofRequestTo: GrokUsageProvider.subscriptionsURL) == "Bearer grok-token")
    #expect(await http.requests.count == 2)
    #expect(await registry.status(for: .grok) == .connected)
}

@Test func grokFallsBackToTaskUsageWhenCreditsConfigFails() async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        GrokUsageProvider.creditsConfigURL.absoluteString: .init(status: 500),
        GrokUsageProvider.taskUsageURL.absoluteString: .init(json: #"{"usage":2,"limit":8,"resetsAt":"2026-06-08T00:00:00Z"}"#),
        GrokUsageProvider.subscriptionsURL.absoluteString: .init(status: 500),
    ])
    let provider = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [liveCredential()]),
        http: http,
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["grok_tasks"])
    #expect(snapshots[0].displayName == "Tasks")
    #expect(snapshots[0].remainingPercent == 75)
    #expect(snapshots[0].planType == nil)
}

@Test func grokSignedOutExpiredAndRejectedStates() async throws {
    let registry = await LocalToolStatusRegistry()
    let signedOut = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: []),
        http: ScriptedUsageHTTPClient(responses: [:]),
        statusRegistry: registry,
        now: { testNow }
    )
    #expect(try await signedOut.refresh() == .signedOut)
    #expect(await registry.status(for: .grok) == .signedOut)

    let expired = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [
            GrokCredential(token: "old", email: nil, expiresAt: Date(timeIntervalSince1970: 1_780_000_000)),
        ]),
        http: ScriptedUsageHTTPClient(responses: [:]),
        statusRegistry: registry,
        now: { testNow }
    )
    await #expect(throws: LocalToolUsageError.credentialExpired) {
        try await expired.refresh()
    }
    #expect(await registry.status(for: .grok) == .credentialExpired)

    let rejected = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [liveCredential()]),
        http: ScriptedUsageHTTPClient(responses: [
            GrokUsageProvider.creditsConfigURL.absoluteString: .init(status: 401),
            GrokUsageProvider.taskUsageURL.absoluteString: .init(status: 401),
            GrokUsageProvider.subscriptionsURL.absoluteString: .init(status: 401),
        ]),
        now: { testNow }
    )
    await #expect(throws: LocalToolUsageError.credentialExpired) {
        try await rejected.refresh()
    }
}

@Test func grokPlanWithoutLimitsIsAuthenticatedButEmpty() async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        GrokUsageProvider.creditsConfigURL.absoluteString: .init(status: 404),
        GrokUsageProvider.taskUsageURL.absoluteString: .init(status: 404),
        GrokUsageProvider.subscriptionsURL.absoluteString: .init(json: subscriptionsJSON),
    ])
    let provider = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [liveCredential()]),
        http: http,
        now: { testNow }
    )

    #expect(try await provider.refresh() == .authenticated([]))
}

private func expiredCredential() -> GrokCredential {
    GrokCredential(token: "stale", email: nil, expiresAt: Date(timeIntervalSince1970: 1_780_000_000))
}

@Test func grokAsksTheCLIToRenewAnExpiredSignInThenReadsTheFreshOne() async throws {
    let source = MutableGrokCredentialSource([expiredCredential()])
    let renewals = TestClockBox(Date(timeIntervalSince1970: 0))
    let config = ProtoTestBuilder.creditsConfig(usedPercent: 5, start: 1_780_272_000, end: 1_780_876_800)
    let http = ScriptedUsageHTTPClient(responses: [
        GrokUsageProvider.creditsConfigURL.absoluteString: .init(body: Data(ProtoTestBuilder.creditsFrame(config: config))),
        GrokUsageProvider.subscriptionsURL.absoluteString: .init(json: subscriptionsJSON),
    ])
    let provider = GrokUsageProvider(
        credentials: source,
        http: http,
        refreshSignIn: {
            renewals.now = renewals.now.addingTimeInterval(1)
            source.replace(with: [liveCredential(token: "renewed")])
            return true
        },
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["grok"])
    #expect(renewals.now == Date(timeIntervalSince1970: 1))
    #expect(await http.header("Authorization", ofRequestTo: GrokUsageProvider.creditsConfigURL) == "Bearer renewed")
}

@Test func grokRenewalIsThrottledWhenTheCLICannotHelp() async throws {
    let clock = TestClockBox(testNow)
    let renewals = TestClockBox(Date(timeIntervalSince1970: 0))
    let provider = GrokUsageProvider(
        credentials: StaticGrokCredentialSource(credentials: [expiredCredential()]),
        http: ScriptedUsageHTTPClient(responses: [:]),
        refreshSignIn: {
            renewals.now = renewals.now.addingTimeInterval(1)
            return false
        },
        signInRefreshInterval: 600,
        now: { clock.now }
    )

    await #expect(throws: LocalToolUsageError.credentialExpired) { try await provider.refresh() }
    clock.now.addTimeInterval(120)
    await #expect(throws: LocalToolUsageError.credentialExpired) { try await provider.refresh() }
    #expect(renewals.now == Date(timeIntervalSince1970: 1))

    clock.now.addTimeInterval(600)
    await #expect(throws: LocalToolUsageError.credentialExpired) { try await provider.refresh() }
    #expect(renewals.now == Date(timeIntervalSince1970: 2))
}

@Test func grokRetriesOnceAfterTheServerRejectsACurrentLookingToken() async throws {
    let source = MutableGrokCredentialSource([liveCredential(token: "rejected")])
    let config = ProtoTestBuilder.creditsConfig(usedPercent: 40, start: 1_780_272_000, end: 1_782_864_000)
    let http = ScriptedUsageHTTPClient(sequences: [
        GrokUsageProvider.creditsConfigURL.absoluteString: [.init(status: 401), .init(body: Data(ProtoTestBuilder.creditsFrame(config: config)))],
        GrokUsageProvider.taskUsageURL.absoluteString: [.init(status: 401)],
        GrokUsageProvider.subscriptionsURL.absoluteString: [.init(status: 401), .init(json: subscriptionsJSON)],
    ])
    let provider = GrokUsageProvider(
        credentials: source,
        http: http,
        refreshSignIn: {
            source.replace(with: [liveCredential(token: "renewed")])
            return true
        },
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.first?.displayName == "Monthly credits")
    #expect(snapshots.first?.planType == "Super Grok Pro")
    let authorizations = await http.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    #expect(authorizations.first == "Bearer rejected")
    #expect(authorizations.last == "Bearer renewed")
}

@Test func grokCLIIsFoundUnderGrokHomeFirst() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-grok-cli-\(UUID().uuidString)")
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let binary = bin.appendingPathComponent("grok")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(GrokBuildCLI.executableURL(environment: ["GROK_HOME": root.path, "HOME": "/nonexistent", "PATH": ""]) == binary)
    #expect(GrokBuildCLI.executableURL(environment: ["HOME": "/nonexistent", "PATH": ""]) == nil)
}
