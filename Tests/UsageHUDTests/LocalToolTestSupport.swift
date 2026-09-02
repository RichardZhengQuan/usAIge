import Foundation
@testable import UsageHUD

/// Canned HTTP responses keyed by absolute URL, recording every request so
/// tests can assert on headers and bodies without touching the network.
actor ScriptedUsageHTTPClient: UsageHTTPClient {
    struct Response: Sendable {
        let status: Int
        let body: Data

        init(status: Int = 200, body: Data = Data()) {
            self.status = status
            self.body = body
        }

        init(status: Int = 200, json: String) {
            self.init(status: status, body: Data(json.utf8))
        }
    }

    private var responses: [String: [Response]]
    private(set) var requests: [URLRequest] = []

    init(responses: [String: Response]) {
        self.responses = responses.mapValues { [$0] }
    }

    init(sequences: [String: [Response]]) {
        responses = sequences
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        let key = request.url?.absoluteString ?? ""
        guard var queue = responses[key], !queue.isEmpty else {
            throw LocalToolTestError.unexpectedRequest(key)
        }
        let response = queue.count == 1 ? queue[0] : queue.removeFirst()
        responses[key] = queue
        return (response.status, response.body)
    }

    func header(_ name: String, ofRequestTo url: URL) -> String? {
        requests.first(where: { $0.url == url })?.value(forHTTPHeaderField: name)
    }
}

enum LocalToolTestError: Error, Equatable {
    case unexpectedRequest(String)
    case offline
}

struct StaticClaudeCredentialSource: ClaudeCredentialSource {
    let credentials: ClaudeCredentials?
    var error: LocalToolUsageError?

    func load() throws -> ClaudeCredentials? {
        if let error { throw error }
        return credentials
    }
}

struct StaticCursorSessionSource: CursorSessionSource {
    let session: CursorSession?

    func load() throws -> CursorSession? { session }
}

struct StaticGrokCredentialSource: GrokCredentialSource {
    let credentials: [GrokCredential]

    func load() throws -> [GrokCredential] { credentials }
}

/// Counts refreshes and returns scripted results in order (the last one
/// repeats), for throttling and composite tests.
actor ScriptedUsageProvider: CodexUsageProviding {
    private var results: [Result<AccountUsageResult, Error>]
    private(set) var refreshCount = 0
    private(set) var stopCount = 0

    init(results: [Result<AccountUsageResult, Error>]) {
        self.results = results
    }

    init(result: AccountUsageResult) {
        results = [.success(result)]
    }

    func refresh() async throws -> AccountUsageResult {
        refreshCount += 1
        guard !results.isEmpty else { throw LocalToolTestError.offline }
        let next = results.count == 1 ? results[0] : results.removeFirst()
        return try next.get()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {
        stopCount += 1
    }
}

final class TestClockBox: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

enum ProtoTestBuilder {
    static func varint(_ value: UInt64, into out: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
    }

    static func lengthField(_ field: UInt64, _ payload: [UInt8], into out: inout [UInt8]) {
        varint((field << 3) | 2, into: &out)
        varint(UInt64(payload.count), into: &out)
        out.append(contentsOf: payload)
    }

    static func fixed32Field(_ field: UInt64, _ value: UInt32, into out: inout [UInt8]) {
        varint((field << 3) | 5, into: &out)
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    static func timestamp(_ seconds: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        varint(1 << 3, into: &out)
        varint(seconds, into: &out)
        return out
    }

    static func grpcFrame(flag: UInt8, message: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [flag]
        let length = UInt32(message.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(contentsOf: message)
        return frame
    }

    static func creditsFrame(config: [UInt8], flag: UInt8 = 0) -> [UInt8] {
        var message: [UInt8] = []
        lengthField(1, config, into: &message)
        return grpcFrame(flag: flag, message: message)
    }

    static func creditsConfig(usedPercent: Float?, start: UInt64?, end: UInt64?) -> [UInt8] {
        var config: [UInt8] = []
        if let usedPercent { fixed32Field(1, usedPercent.bitPattern, into: &config) }
        if let start { lengthField(4, timestamp(start), into: &config) }
        if let end { lengthField(5, timestamp(end), into: &config) }
        return config
    }
}

/// A Grok credential source whose contents a test can swap, standing in for
/// the auth file the CLI rewrites when it renews the sign-in.
final class MutableGrokCredentialSource: GrokCredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [GrokCredential]

    init(_ credentials: [GrokCredential]) {
        self.credentials = credentials
    }

    func replace(with credentials: [GrokCredential]) {
        lock.lock()
        self.credentials = credentials
        lock.unlock()
    }

    func load() throws -> [GrokCredential] {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }
}
