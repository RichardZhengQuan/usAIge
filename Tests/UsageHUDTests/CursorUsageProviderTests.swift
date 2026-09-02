import Foundation
import Testing
@testable import UsageHUD

private let testNow = Date(timeIntervalSince1970: 1_786_000_000)

private func liveSession(expiresAt: Date? = Date(timeIntervalSince1970: 1_790_000_000)) -> CursorSession {
    CursorSession(accessToken: "cursor-jwt", membershipType: "pro", expiresAt: expiresAt)
}

@Test func cursorReportsOneBucketPerModelPool() async throws {
    let json = #"{"billingCycleStart":"1785542400000","billingCycleEnd":"1788220800000","planUsage":{"limit":"2000","used":"500","totalPercentUsed":"25","autoPercentUsed":"10","apiPercentUsed":40}}"#
    let http = ScriptedUsageHTTPClient(responses: [
        CursorUsageProvider.usageURL.absoluteString: .init(json: json),
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

@Test func cursorStateDatabaseReadsTokenAndPlan() throws {
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
    #expect(session.membershipType == "pro")
    #expect(session.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
    #expect(try CursorStateDatabase(databaseURL: root.appendingPathComponent("missing.vscdb")).load() == nil)
}
