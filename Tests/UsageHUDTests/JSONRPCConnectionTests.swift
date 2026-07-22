import Foundation
import Testing
@testable import UsageHUD

@Test func correlatesResponseWithRequest() async throws {
    let transport = TestLineTransport()
    let connection = JSONRPCConnection(transport: transport)
    try await connection.start()

    let request = Task {
        try await connection.request(method: "account/read", params: .object([:]))
    }
    let written = try await transport.nextWrittenValue()
    let id = try #require(written["id"]?.intValue)
    await transport.receive(#"{"id":\#(id),"result":{"account":null}}"#)

    #expect(try await request.value == .object(["account": .null]))
    await connection.stop()
}

@Test func emitsServerNotification() async throws {
    let transport = TestLineTransport()
    let connection = JSONRPCConnection(transport: transport)
    try await connection.start()
    let notifications = await connection.notifications()
    var iterator = notifications.makeAsyncIterator()

    await transport.receive(#"{"method":"account/rateLimits/updated","params":{"value":1}}"#)

    let notification = await iterator.next()
    #expect(notification?.method == "account/rateLimits/updated")
    #expect(notification?.params == .object(["value": .number(1)]))
    await connection.stop()
}

@Test func ignoresMalformedFramesAndContinues() async throws {
    let transport = TestLineTransport()
    let connection = JSONRPCConnection(transport: transport)
    try await connection.start()
    await transport.receive("not-json")

    let request = Task {
        try await connection.request(method: "account/read", params: .object([:]))
    }
    let written = try await transport.nextWrittenValue()
    let id = try #require(written["id"]?.intValue)
    await transport.receive(#"{"id":\#(id),"result":{"ok":true}}"#)

    #expect(try await request.value == .object(["ok": .bool(true)]))
    await connection.stop()
}

@Test func writesNotificationWithoutRequestID() async throws {
    let transport = TestLineTransport()
    let connection = JSONRPCConnection(transport: transport)
    try await connection.start()

    try await connection.notify(method: "initialized", params: .object([:]))

    let written = try await transport.nextWrittenValue()
    #expect(written["method"] == .string("initialized"))
    #expect(written["id"] == nil)
    await connection.stop()
}

@Test func processTransportCreatesAFreshStreamAfterRestart() async throws {
    let transport = ProcessLineTransport(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        arguments: []
    )

    try await transport.start()
    var firstLines = await transport.lines().makeAsyncIterator()
    try await transport.write("first")
    #expect(await firstLines.next() == "first")
    await transport.stop()

    try await transport.start()
    var secondLines = await transport.lines().makeAsyncIterator()
    try await transport.write("second")
    #expect(await secondLines.next() == "second")
    await transport.stop()
}

private actor TestLineTransport: LineTransport {
    private var continuation: AsyncStream<String>.Continuation?
    private var written: [String] = []
    private var writeWaiters: [CheckedContinuation<String, Never>] = []

    func start() async throws {}

    func write(_ line: String) async throws {
        if let waiter = writeWaiters.first {
            writeWaiters.removeFirst()
            waiter.resume(returning: line)
        } else {
            written.append(line)
        }
    }

    func lines() async -> AsyncStream<String> {
        AsyncStream { continuation = $0 }
    }

    func stop() async {
        continuation?.finish()
    }

    func receive(_ line: String) {
        continuation?.yield(line)
    }

    func nextWrittenValue() async throws -> JSONValue {
        let line: String
        if written.isEmpty {
            line = await withCheckedContinuation { writeWaiters.append($0) }
        } else {
            line = written.removeFirst()
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }
}
