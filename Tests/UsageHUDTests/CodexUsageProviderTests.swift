import Foundation
import Testing
@testable import UsageHUD

@Test func initializesAndDecodesAllMultiBucketLimits() async throws {
    let rpc = ScriptedRPC(responses: [
        "initialize": .object(["userAgent": .string("test")]),
        "account/read": .object(["account": .object(["type": .string("chatgpt")])]),
        "account/rateLimits/read": Fixtures.multiBucketRateLimits,
    ])
    let provider = CodexUsageProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let result = try await provider.refresh()

    #expect(result.snapshots.map(\.id) == ["codex", "codex_other"])
    #expect(result.snapshots[0].remainingPercent == 75)
    #expect(result.snapshots[0].secondaryWindow?.remainingPercent == 67)
    #expect(result.snapshots[0].secondaryWindow?.typeTag == "7D")
    #expect(result.snapshots.allSatisfy { $0.availableResetCount == 6 })
    #expect(result.snapshots.allSatisfy {
        $0.resetCreditExpiresAt == Date(timeIntervalSince1970: 1_800_950_400)
    })
    #expect(await rpc.requestedMethods == ["initialize", "account/read", "account/rateLimits/read"])
    #expect(await rpc.notifiedMethods == ["initialized"])
}

@Test func fallsBackToSingleBucketView() async throws {
    let rpc = ScriptedRPC(responses: [
        "initialize": .object([:]),
        "account/read": .object(["account": .object(["type": .string("chatgpt")])]),
        "account/rateLimits/read": Fixtures.singleBucketRateLimits,
    ])
    let provider = CodexUsageProvider(rpc: rpc)

    let result = try await provider.refresh()

    #expect(result.snapshots.map(\.id) == ["codex"])
    #expect(result.snapshots[0].remainingPercent == 90)
    #expect(result.snapshots[0].secondaryWindow?.remainingPercent == 60)
    #expect(result.snapshots[0].availableResetCount == nil)
}

@Test func returnsSignedOutWithoutRequestingLimits() async throws {
    let rpc = ScriptedRPC(responses: [
        "initialize": .object([:]),
        "account/read": .object(["account": .null]),
    ])
    let provider = CodexUsageProvider(rpc: rpc)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await rpc.requestedMethods == ["initialize", "account/read"])
}

@Test func reconnectsAfterCodexAppServerDisconnects() async throws {
    let rpc = ReconnectingRPC()
    let provider = CodexUsageProvider(rpc: rpc)

    let result = try await provider.refresh()

    #expect(result.snapshots.map(\.remainingPercent) == [90])
    #expect(await rpc.startCount == 2)
    #expect(await rpc.stopCount == 1)
    #expect(await rpc.requestedMethods == [
        "initialize", "account/read",
        "initialize", "account/read", "account/rateLimits/read",
    ])
}

@Test func refreshesAuthoritativeLimitsAfterAPartialResetCreditUpdate() async throws {
    let rpc = ResetCreditUpdateRPC(rateLimitResponses: [
        resetCreditLimits(usedPercent: 95, availableResetCount: 1),
        resetCreditLimits(usedPercent: 1, availableResetCount: 0),
    ])
    let provider = CodexUsageProvider(
        rpc: rpc,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let initial = try await provider.refresh()
    #expect(initial.snapshots.first?.remainingPercent == 5)
    #expect(initial.snapshots.first?.availableResetCount == 1)

    let updates = await provider.updates()
    var iterator = updates.makeAsyncIterator()
    await rpc.sendResetCreditUsed()
    let synchronized = await iterator.next()

    #expect(synchronized?.first?.remainingPercent == 99)
    #expect(synchronized?.first?.availableResetCount == 0)
    #expect(await rpc.rateLimitReadCount == 2)
    await provider.stop()
}

private actor ScriptedRPC: RPCRequesting {
    private let responses: [String: JSONValue]
    private(set) var requestedMethods: [String] = []
    private(set) var notifiedMethods: [String] = []

    init(responses: [String: JSONValue]) {
        self.responses = responses
    }

    func start() async throws {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requestedMethods.append(method)
        guard let response = responses[method] else { throw TestRPCError.noResponse }
        return response
    }

    func notify(method: String, params: JSONValue) async throws {
        notifiedMethods.append(method)
    }

    func notifications() async -> AsyncStream<JSONRPCNotification> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private enum TestRPCError: Error {
    case noResponse
}

private actor ReconnectingRPC: RPCRequesting {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var requestedMethods: [String] = []
    private var shouldDisconnect = true

    func start() async throws {
        startCount += 1
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requestedMethods.append(method)
        if method == "account/read", shouldDisconnect {
            shouldDisconnect = false
            throw JSONRPCError.disconnected
        }
        switch method {
        case "initialize":
            return .object([:])
        case "account/read":
            return .object(["account": .object(["type": .string("chatgpt")])])
        case "account/rateLimits/read":
            return Fixtures.singleBucketRateLimits
        default:
            throw TestRPCError.noResponse
        }
    }

    func notify(method: String, params: JSONValue) async throws {}

    func notifications() async -> AsyncStream<JSONRPCNotification> {
        AsyncStream { $0.finish() }
    }

    func stop() async {
        stopCount += 1
    }
}

private actor ResetCreditUpdateRPC: RPCRequesting {
    private var rateLimitResponses: [JSONValue]
    private let notificationStream: AsyncStream<JSONRPCNotification>
    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation
    private(set) var rateLimitReadCount = 0

    init(rateLimitResponses: [JSONValue]) {
        self.rateLimitResponses = rateLimitResponses
        let streamPair = AsyncStream.makeStream(of: JSONRPCNotification.self)
        notificationStream = streamPair.stream
        notificationContinuation = streamPair.continuation
    }

    func start() async throws {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            return .object([:])
        case "account/read":
            return .object(["account": .object(["type": .string("chatgpt")])])
        case "account/rateLimits/read":
            rateLimitReadCount += 1
            guard !rateLimitResponses.isEmpty else { throw TestRPCError.noResponse }
            return rateLimitResponses.removeFirst()
        default:
            throw TestRPCError.noResponse
        }
    }

    func notify(method: String, params: JSONValue) async throws {}

    func notifications() async -> AsyncStream<JSONRPCNotification> {
        notificationStream
    }

    func sendResetCreditUsed() {
        notificationContinuation.yield(JSONRPCNotification(
            method: "account/rateLimits/updated",
            params: .object([
                "rateLimitResetCredits": .object([
                    "availableCount": .number(0),
                    "credits": .array([]),
                ]),
            ])
        ))
    }

    func stop() async {
        notificationContinuation.finish()
    }
}

private func resetCreditLimits(
    usedPercent: Double,
    availableResetCount: Int
) -> JSONValue {
    .object([
        "rateLimits": .object([
            "limitId": .string("codex"),
            "limitName": .string("Codex weekly"),
            "primary": .object([
                "usedPercent": .number(usedPercent),
                "windowDurationMins": .number(10_080),
                "resetsAt": .number(1_800_604_800),
            ]),
        ]),
        "rateLimitResetCredits": .object([
            "availableCount": .number(Double(availableResetCount)),
            "credits": .array([]),
        ]),
    ])
}
