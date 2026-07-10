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
}

private enum TestRPCError: Error {
    case noResponse
}
