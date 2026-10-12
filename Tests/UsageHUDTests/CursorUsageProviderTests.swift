import Foundation
import Testing
@testable import UsageHUD

private let testNow = Date(timeIntervalSince1970: 1_786_000_000)
private let membershipURL = "https://api2.cursor.sh/auth/full_stripe_profile"

private func liveSession(expiresAt: Date? = Date(timeIntervalSince1970: 1_790_000_000)) -> CursorSession {
    CursorSession(accessToken: "cursor-jwt", expiresAt: expiresAt)
}

@Test func cursorReportsOneBucketPerModelPool() async throws {
    let json = #"{"billingCycleStart":"1785542400000","billingCycleEnd":"1788220800000","planUsage":{"limit":"2000","used":"500","totalPercentUsed":"25","autoPercentUsed":"10","apiPercentUsed":40}}"#
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: json),
        membershipURL: .init(json: #"{"membershipType":"pro","subscriptionStatus":"active"}"#),
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        statusRegistry: registry,
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["cursor", "cursor_other"])
    #expect(snapshots.map(\.displayName) == ["Cursor models", "Other models"])
    #expect(snapshots.allSatisfy { $0.toolID == .cursor && $0.planType == "pro" })
    #expect(snapshots[0].remainingPercent == 90)
    #expect(snapshots[1].remainingPercent == 60)
    #expect(snapshots[0].windowDurationMinutes == 44_640)
    #expect(snapshots[0].typeTag == "31D")
    #expect(snapshots[0].resetAt == Date(timeIntervalSince1970: 1_788_220_800))

    let request = await http.requests.first
    #expect(request?.httpMethod == "POST")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-jwt")
    #expect(request?.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
    #expect(request?.httpBody == Data("{}".utf8))
    #expect(await registry.status(for: .cursor) == .connected)
}

@Test func cursorUsesLiveFreePlanInsteadOfCachedPro() async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: #"{"planUsage":{"autoPercentUsed":10,"apiPercentUsed":40}}"#),
        membershipURL: .init(json: #"{"membershipType":"free","subscriptionStatus":"canceled"}"#),
    ])
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        now: { testNow }
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.count == 2)
    #expect(snapshots.allSatisfy { $0.planType == "free" })
    #expect(snapshots.map(\.remainingPercent) == [90, 60])
    let request = await http.requests.first { $0.url?.absoluteString == membershipURL }
    #expect(request?.httpMethod == "GET")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer cursor-jwt")
    #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request?.httpBody == nil)
}

@Test(arguments: [
    ScriptedUsageHTTPClient.Response(status: 401, json: "{}"),
    .init(status: 429, json: "{}"),
    .init(status: 500, json: "{}"),
    .init(json: "not-json"),
    .init(json: "null"),
    .init(json: "{}"),
    .init(json: #"{"membershipType":null}"#),
    .init(json: #"{"membershipType":"  "}"#),
    .init(json: #"{"membershipType":42}"#),
])
func cursorKeepsUsageWithoutGuessingPlanWhenMembershipIsUnavailable(
    membership: ScriptedUsageHTTPClient.Response
) async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
        membershipURL: membership,
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        statusRegistry: registry,
        now: { testNow }
    )

    let snapshot = try #require(try await provider.refresh().snapshots.first)

    #expect(snapshot.planType == nil)
    #expect(snapshot.remainingPercent == 75)
    #expect(await registry.status(for: .cursor) == .connected)
}

@Test func cursorRefreshesPlanAndClearsPreviousProThroughCompositeCache() async throws {
    let http = ScriptedUsageHTTPClient(sequences: [
        CursorUsageProvider.usageURL.absoluteString: [
            .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
        ],
        membershipURL: [
            .init(json: #"{"membershipType":"pro"}"#),
            .init(json: #"{"membershipType":"free"}"#),
            .init(status: 503, json: "{}"),
        ],
    ])
    let cursor = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        now: { testNow }
    )
    let provider = CompositeUsageProvider(
        local: ScriptedUsageProvider(result: .signedOut),
        throttled: [cursor],
        remote: ScriptedUsageProvider(results: [.failure(RemoteUsageError.noSources)])
    )

    #expect(try await provider.refresh().snapshots.first?.planType == "pro")
    #expect(try await provider.refresh().snapshots.first?.planType == "free")
    let unknown = try #require(try await provider.refresh().snapshots.first)
    #expect(unknown.planType == nil)
    #expect(unknown.remainingPercent == 75)
    #expect(await http.requests.filter { $0.url?.absoluteString == membershipURL }.count == 3)
}

@Test func cursorKeepsUsageWhenMembershipRequestThrows() async throws {
    // No membership response: the HTTP fake throws for that request.
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
    ])
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        now: { testNow }
    )

    let snapshot = try #require(try await provider.refresh().snapshots.first)

    #expect(snapshot.planType == nil)
    #expect(snapshot.remainingPercent == 75)
    #expect(await http.requests.count == 2)
}

@Test func cursorKeepsCurrentPaidPlanWhileCancellationIsPending() async throws {
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
        membershipURL: .init(json: #"{"membershipType":"pro","subscriptionStatus":"active","pendingCancellationDate":"2026-08-31T00:00:00Z"}"#),
    ])
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        now: { testNow }
    )

    #expect(try await provider.refresh().snapshots.first?.planType == "pro")
}

@Test func cursorFallsBackToBlendedTotalAndDollarFigures() {
    let blended = JSONValue.parse(Data(#"{"planUsage":{"totalPercentUsed":41}}"#.utf8))!
    let blendedSnapshots = CursorUsageProvider.snapshots(from: blended, planType: nil, updatedAt: testNow)
    #expect(blendedSnapshots.map(\.id) == ["cursor"])
    #expect(blendedSnapshots[0].displayName == "Included usage")
    #expect(blendedSnapshots[0].usedPercent == 41)
    #expect(blendedSnapshots[0].typeTag == "30D")

    let money = JSONValue.parse(Data(#"{"billingCycleEnd":"2026-08-01T00:00:00Z","planUsage":{"limit":"2000","remaining":"1500"}}"#.utf8))!
    let moneySnapshots = CursorUsageProvider.snapshots(from: money, planType: nil, updatedAt: testNow)
    #expect(moneySnapshots.count == 1)
    #expect(moneySnapshots[0].usedPercent == 25)
    #expect(moneySnapshots[0].resetAt == Date(timeIntervalSince1970: 1_785_542_400))

    let unusable = JSONValue.parse(Data(#"{"displayMessage":"hi","planUsage":{"limit":0,"used":0}}"#.utf8))!
    #expect(CursorUsageProvider.snapshots(from: unusable, planType: nil, updatedAt: testNow).isEmpty)
    let missing = JSONValue.parse(Data(#"{"displayMessage":"hi"}"#.utf8))!
    #expect(CursorUsageProvider.snapshots(from: missing, planType: nil, updatedAt: testNow).isEmpty)
}

@Test func cursorReportsSignedOutWithoutASession() async throws {
    let http = ScriptedUsageHTTPClient(responses: [:])
    let registry = await LocalToolStatusRegistry()
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: nil),
        http: http,
        statusRegistry: registry,
        now: { testNow }
    )

    #expect(try await provider.refresh() == .signedOut)
    #expect(await http.requests.isEmpty)
    #expect(await registry.status(for: .cursor) == .signedOut)
}

@Test func cursorTreatsExpiredTokensAndAuthFailuresAsExpiredSignIn() async {
    let expiredProvider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession(expiresAt: Date(timeIntervalSince1970: 1_785_000_000))),
        http: ScriptedUsageHTTPClient(responses: [:]),
        now: { testNow }
    )
    await #expect(throws: LocalToolUsageError.credentialExpired) {
        try await expiredProvider.refresh()
    }

    let rejectedProvider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: ScriptedUsageHTTPClient(responses: [
            CursorUsageProvider.usageURL.absoluteString: .init(status: 401, json: "{}"),
        ]),
        now: { testNow }
    )
    await #expect(throws: LocalToolUsageError.credentialExpired) {
        try await rejectedProvider.refresh()
    }
}

@Test func cursorStateDatabaseIgnoresCachedProAndUsesCurrentPlan() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-cursor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("state.vscdb")
    let header = Data(#"{"alg":"HS256"}"#.utf8).base64EncodedString()
    let payload = Data(#"{"sub":"auth0|user_1","exp":1790000000}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    let token = "\(header).\(payload).sig"
    let sql = """
    CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
    INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');
    INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'pro');
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let session = try #require(try CursorStateDatabase(databaseURL: database).load())

    #expect(session.accessToken == token)
    #expect(session.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
    #expect(try CursorStateDatabase(databaseURL: root.appendingPathComponent("missing.vscdb")).load() == nil)

    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
        membershipURL: .init(json: #"{"membershipType":"free"}"#),
    ])
    let provider = CursorUsageProvider(
        session: CursorStateDatabase(databaseURL: database),
        http: http,
        now: { testNow }
    )
    #expect(try await provider.refresh().snapshots.first?.planType == "free")
    // usAIge must leave Cursor's own cache and credentials untouched.
    #expect(try CursorStateDatabase(databaseURL: database).readValue(forKey: "cursorAuth/stripeMembershipType") == "pro")
}


@Test func cursorBacksOffMembershipWhileManualAndAutomaticUsageRefreshesContinue() async throws {
    let clock = TestClockBox(testNow)
    let http = ScriptedUsageHTTPClient(sequences: [
        CursorUsageProvider.usageURL.absoluteString: [
            .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
            .init(json: #"{"planUsage":{"totalPercentUsed":30}}"#),
            .init(json: #"{"planUsage":{"totalPercentUsed":35}}"#),
            .init(json: #"{"planUsage":{"totalPercentUsed":40}}"#),
        ],
        membershipURL: [
            .init(status: 429, json: "{}"),
            .init(json: #"{"membershipType":"free"}"#),
        ],
    ])
    let registry = await LocalToolStatusRegistry()
    let cursor = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        statusRegistry: registry,
        now: { clock.now }
    )
    let provider = ThrottledUsageProvider(
        base: cursor,
        minimumInterval: 120,
        manualMinimumInterval: 20,
        now: { clock.now }
    )

    #expect(try await provider.refresh().snapshots.first?.planType == nil)
    clock.now.addTimeInterval(20)
    let manual = try #require(try await provider.refresh(manual: true).snapshots.first)
    #expect(manual.planType == nil)
    #expect(manual.remainingPercent == 70)
    clock.now.addTimeInterval(120)
    let automatic = try #require(try await provider.refresh().snapshots.first)
    #expect(automatic.planType == nil)
    #expect(automatic.remainingPercent == 65)
    #expect(await http.requests.filter { $0.url?.absoluteString == membershipURL }.count == 1)
    #expect(await registry.status(for: .cursor) == .connected)

    clock.now.addTimeInterval(460)
    let recovered = try #require(try await provider.refresh().snapshots.first)
    #expect(recovered.planType == "free")
    #expect(recovered.remainingPercent == 60)
    #expect(await http.requests.filter { $0.url?.absoluteString == membershipURL }.count == 2)
}

@Test func cursorMembershipRateLimitRestartsOnAnother429AndClearsOnStop() async throws {
    let clock = TestClockBox(testNow)
    let http = ScriptedUsageHTTPClient(sequences: [
        CursorUsageProvider.usageURL.absoluteString: [
            .init(json: #"{"planUsage":{"totalPercentUsed":25}}"#),
        ],
        membershipURL: [
            .init(status: 429, json: "{}"),
            .init(status: 429, json: "{}"),
            .init(json: #"{"membershipType":"free"}"#),
        ],
    ])
    let provider = CursorUsageProvider(
        session: StaticCursorSessionSource(session: liveSession()),
        http: http,
        now: { clock.now }
    )

    #expect(try await provider.refresh().snapshots.first?.planType == nil)
    clock.now.addTimeInterval(600)
    #expect(try await provider.refresh().snapshots.first?.planType == nil)
    clock.now.addTimeInterval(599)
    #expect(try await provider.refresh().snapshots.first?.planType == nil)
    #expect(await http.requests.filter { $0.url?.absoluteString == membershipURL }.count == 2)

    await provider.stop()
    #expect(try await provider.refresh().snapshots.first?.planType == "free")
    #expect(await http.requests.filter { $0.url?.absoluteString == membershipURL }.count == 3)
}
