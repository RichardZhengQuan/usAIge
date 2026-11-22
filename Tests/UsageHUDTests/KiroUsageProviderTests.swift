import Foundation
import Testing
@testable import UsageHUD

@Test func kiroReadsPlanAndBonusCreditsWithTheExactACPExchange() async throws {
    let usage = """
    {
      "jsonrpc": "2.0", "id": 2, "result": {
        "success": true, "data": {
          "planName": "KIRO PRO MAX", "billingCycleReset": "2026-12-01",
          "usageBreakdowns": [
            {"resourceType": "CREDIT", "displayName": "Credits", "used": 338.62, "limit": 5000, "percentage": 6, "hasLimit": true}
          ],
          "bonusCredits": [
            {"name": "Welcome", "used": 125, "total": 500, "daysUntilExpiry": 29},
            {"name": "No allowance", "used": 0, "total": 0},
            {"used": 50, "total": 100, "daysUntilExpiry": 10}
          ],
          "addOnCredits": []
        }
      }
    }
    """
    let transport = KiroTestLineTransport(replies: [kiroInitializeReply, usage.components(separatedBy: .newlines).joined()])
    let executable = URL(fileURLWithPath: "/fake/.local/bin/kiro-cli")
    let source = KiroACPUsageSource(
        locate: { name in
            #expect(name == "kiro-cli")
            return executable
        },
        makeTransport: { url, arguments in
            #expect(url == executable)
            #expect(arguments == ["acp", "--agent-engine", "v3"])
            return transport
        }
    )
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    let reset = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
    let registry = await LocalToolStatusRegistry()
    let provider = KiroUsageProvider(source: source, statusRegistry: registry, now: { now })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["kiro", "kiro_bonus_1", "kiro_bonus_3"])
    #expect(snapshots.map(\.displayName) == ["Plan credits", "Welcome", "Bonus credits"])
    #expect(snapshots.allSatisfy { $0.toolID == .kiro && $0.planType == "KIRO PRO MAX" && $0.updatedAt == now })
    #expect(snapshots.allSatisfy { $0.secondaryWindow == nil })
    let monthly = try #require(snapshots.first)
    #expect(abs(monthly.usedPercent - 6.7724) < 0.0001)
    #expect(monthly.resetAt == reset)
    #expect(monthly.windowDurationMinutes == Int(reset.timeIntervalSince(start) / 60))
    let grants = snapshots.dropFirst()
    #expect(grants.map(\.usedPercent) == [25, 50])
    #expect(grants.allSatisfy { $0.resetAt == nil && $0.windowDurationMinutes == nil })
    #expect(await registry.status(for: .kiro) == .connected)
    #expect(await transport.requests == [
        .object([
            "id": .number(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("usAIge"),
                    "version": .string(UsAIgeUserAgent.shortVersion),
                ]),
            ]),
        ]),
        .object(["id": .number(2), "method": .string("_kiro/account/getUsage"), "params": .object([:])]),
    ])
    #expect(await transport.startCount == 1)
    #expect(await transport.stopCount == 1)
}

@Test func kiroDerivesTheMonthlyWindowFromYearlessAndFullResetDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 12)))
    let full = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))
    let nextYear = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 31)))

    for (text, date) in [("2026-03-31", full), ("03/31", nextYear)] {
        let result = try #require(JSONValue.parse(Data("""
        {"data":{"billingCycleReset":"\(text)","usageBreakdowns":[{"displayName":"Credits","used":10,"limit":50,"hasLimit":true}]}}
        """.utf8)))
        let bucket = try #require(KiroUsageParser.buckets(from: result, now: now, calendar: calendar).first)

        #expect(bucket.resetsAt == date.timeIntervalSince1970)
        #expect(bucket.windowDurationMinutes == 31 * 1_440 - 60)
    }
}

@Test(arguments: [JSONValue.null, .string("2026-02-30")])
func kiroLeavesUnreportedMetadataAndUnusablePoolsOut(reset: JSONValue) async throws {
    let result = JSONValue.object(["data": .object([
        "billingCycleReset": reset,
        "usageBreakdowns": .array([
            .object(["displayName": .string("Other usage"), "used": .number(1), "limit": .number(2), "hasLimit": .bool(true)]),
            .object(["displayName": .string("Credits"), "used": .number(40), "limit": .number(50), "hasLimit": .bool(false)]),
            .object(["resourceType": .string("CREDIT"), "used": .string("75"), "limit": .string("50"), "hasLimit": .bool(true)]),
        ]),
        "bonusCredits": .array([.object(["name": .string("Balance"), "used": .number(5)])]),
    ])])
    let provider = KiroUsageProvider(source: KiroTestUsageSource(result: .success(result)))

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["kiro"])
    let monthly = try #require(snapshots.first)
    #expect(monthly.usedPercent == 100)
    #expect(monthly.planType == nil)
    #expect(monthly.resetAt == nil)
    #expect(monthly.windowDurationMinutes == nil)
}

@Test func kiroReportsMissingCLIAsNotInstalled() async throws {
    let registry = await LocalToolStatusRegistry()
    let source = KiroACPUsageSource(locate: { _ in nil }, makeTransport: { _, _ in
        Issue.record("A missing executable must not start a transport")
        return KiroTestLineTransport()
    })
    let provider = KiroUsageProvider(source: source, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .kiro) == .notInstalled)
}

@Test(arguments: [
    JSONRPCError.server(code: -32000, message: "Sign-in is needed"),
    .server(code: -32603, message: "You are not signed in"),
])
func kiroReportsAuthenticationRequiredAsSignedOut(error: JSONRPCError) async throws {
    let registry = await LocalToolStatusRegistry()
    let provider = KiroUsageProvider(source: KiroTestUsageSource(result: .failure(error)), statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .kiro) == .signedOut)
}

@Test(arguments: [401, 429])
func kiroMapsAuthorizationAndRateLimitRPCErrors(code: Int) async {
    let registry = await LocalToolStatusRegistry()
    let error = JSONRPCError.server(code: code, message: "Account reader@example.invalid")
    let provider = KiroUsageProvider(source: KiroTestUsageSource(result: .failure(error)), statusRegistry: registry)
    let expected: LocalToolUsageError = code == 401 ? .credentialExpired : .rateLimited

    await #expect(throws: expected) { try await provider.refresh() }
    #expect(await registry.status(for: .kiro) == LocalToolStatus(error: expected))
}

@Test(arguments: ["null", #"{"data":[]}"#, #"{"success":true,"data":{"usageBreakdowns":[],"bonusCredits":[]}}"#])
func kiroRejectsMalformedOrUnusableUsageResult(json: String) async throws {
    let response = try #require(JSONValue.parse(Data(json.utf8)))
    let registry = await LocalToolStatusRegistry()
    let provider = KiroUsageProvider(source: KiroTestUsageSource(result: .success(response)), statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .kiro) == LocalToolStatus(error: LocalToolUsageError.invalidResponse))
}

@Test func kiroStopsAndReportsGenericFailureWhenRPCReturnsAnUnexpectedError() async {
    let transport = KiroTestLineTransport(replies: [
        kiroInitializeReply,
        #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Backend failure for reader@example.invalid"}}"#,
    ])
    let registry = await LocalToolStatusRegistry()
    let provider = KiroUsageProvider(source: kiroTestACPSource(transport), statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .kiro) == LocalToolStatus(error: LocalToolUsageError.invalidResponse))
    #expect(await transport.stopCount == 1)
}

@Test(arguments: [false, true])
func kiroStopsWhenTheACPExchangeTimesOut(initialized: Bool) async {
    let transport = KiroTestLineTransport(replies: initialized ? [kiroInitializeReply] : [])
    let registry = await LocalToolStatusRegistry()
    let source = kiroTestACPSource(transport, timeoutNanoseconds: 100_000_000)
    let provider = KiroUsageProvider(source: source, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.timedOut) { try await provider.refresh() }
    #expect(await registry.status(for: .kiro) == LocalToolStatus(error: LocalToolUsageError.timedOut))
    #expect(await transport.stopCount == 1)
}

private let kiroInitializeReply = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#

private struct KiroTestUsageSource: KiroUsageFetching {
    let result: Result<JSONValue?, any Error>

    func fetchUsage() async throws -> JSONValue? { try result.get() }
}

private func kiroTestACPSource(_ transport: KiroTestLineTransport, timeoutNanoseconds: UInt64 = 45_000_000_000) -> KiroACPUsageSource {
    KiroACPUsageSource(
        locate: { _ in URL(fileURLWithPath: "/fake/kiro-cli") },
        makeTransport: { _, _ in transport },
        timeoutNanoseconds: timeoutNanoseconds
    )
}

private actor KiroTestLineTransport: LineTransport {
    private let replies: [String]
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var requests: [JSONValue] = []

    init(replies: [String] = []) {
        self.replies = replies
        (stream, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func start() async throws { startCount += 1 }

    func write(_ line: String) async throws {
        let value = try #require(JSONValue.parse(Data(line.utf8)))
        let index = requests.count
        requests.append(value)
        if replies.indices.contains(index) { continuation.yield(replies[index]) }
    }

    func lines() async -> AsyncStream<String> { stream }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }
}
