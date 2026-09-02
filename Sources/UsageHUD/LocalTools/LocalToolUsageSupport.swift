import Combine
import Foundation

/// Failures shared by the built-in local tool providers (Claude Code, Cursor,
/// Grok Build). Each case maps to a short, actionable status in Settings.
enum LocalToolUsageError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case notSignedIn
    case credentialExpired
    case missingScope
    case rateLimited
    case http(Int)
    case invalidResponse
    case keychainAccessDenied
    case keychain(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The tool is not installed on this Mac"
        case .notSignedIn: "The tool is not signed in on this Mac"
        case .credentialExpired: "The saved sign-in has expired"
        case .missingScope: "The saved sign-in cannot read usage limits"
        case .rateLimited: "The provider is rate limiting usage checks"
        case let .http(status): "The provider returned HTTP \(status)"
        case .invalidResponse: "The provider returned an unexpected response"
        case .keychainAccessDenied: "Keychain access was denied"
        case let .keychain(status): "Keychain read failed (\(status))"
        case .timedOut: "The provider did not respond in time"
        }
    }
}

/// Per-tool connection state surfaced in Settings. Providers report it after
/// every refresh so a signed-out or expired tool explains itself instead of
/// silently disappearing from the rail.
enum LocalToolStatus: Equatable, Sendable {
    case unknown
    case disabled
    case apiKeyOnly
    case connected
    case notInstalled
    case signedOut
    case credentialExpired
    case missingScope
    case rateLimited
    case keychainAccessDenied
    case failed(String)

    init(error: Error) {
        switch error as? LocalToolUsageError {
        case .notInstalled: self = .notInstalled
        case .notSignedIn: self = .signedOut
        case .credentialExpired: self = .credentialExpired
        case .missingScope: self = .missingScope
        case .rateLimited: self = .rateLimited
        case .keychainAccessDenied: self = .keychainAccessDenied
        case .http, .invalidResponse, .keychain, .timedOut:
            self = .failed(error.localizedDescription)
        case nil:
            self = .failed(error.localizedDescription)
        }
    }
}

@MainActor
final class LocalToolStatusRegistry: ObservableObject {
    @Published private(set) var statuses: [AIToolID: LocalToolStatus] = [:]

    func report(_ status: LocalToolStatus, for tool: AIToolID) {
        guard statuses[tool] != status else { return }
        statuses[tool] = status
    }

    func status(for tool: AIToolID) -> LocalToolStatus {
        statuses[tool] ?? .unknown
    }
}

// MARK: - HTTP

protocol UsageHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// Ephemeral session: no cookies, no cache, no credential persistence. Each
/// provider adds its own bearer token per request and nothing survives it.
struct URLSessionUsageHTTPClient: UsageHTTPClient {
    private let session: URLSession

    init(requestTimeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum UsAIgeUserAgent {
    static var value: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "usAIge/\(version) (macOS)"
    }
}

// MARK: - Dates and numbers

enum LocalToolDates {
    /// Parses RFC 3339 timestamps with zero, three, or more fractional digits.
    /// Anthropic returns microseconds; `ISO8601DateFormatter` only accepts
    /// milliseconds, so longer fractions are trimmed before parsing.
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let normalized = truncatingFractionalSeconds(trimmed),
           let date = fractional.date(from: normalized) {
            return date
        }
        return nil
    }

    /// Accepts RFC 3339 text or epoch milliseconds/seconds encoded as a
    /// number or a string (Connect encodes int64 as JSON strings).
    static func parseFlexible(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let .string(text):
            if let date = parse(text) { return date }
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return epoch(number)
        case let .number(number):
            return epoch(number)
        default:
            return nil
        }
    }

    private static func epoch(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        // Anything past the year 3000 in seconds is really milliseconds.
        let seconds = number > 32_503_680_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func truncatingFractionalSeconds(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        var end = value.index(after: dot)
        while end < value.endIndex, value[end].isNumber { end = value.index(after: end) }
        let digits = value[value.index(after: dot)..<end]
        guard digits.count > 3 else { return nil }
        return value[..<dot] + "." + digits.prefix(3) + value[end...]
    }

    static func windowMinutes(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end, end > start else { return nil }
        return Int((end.timeIntervalSince(start) / 60).rounded())
    }
}

extension JSONValue {
    /// A number, or a numeric string, or a `{ "val": … }` / `{ "value": … }`
    /// wrapper. Anything else is nil rather than an error.
    var lenientNumber: Double? {
        switch self {
        case let .number(value):
            return value.isFinite ? value : nil
        case let .string(text):
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { return nil }
            return value
        case let .object(object):
            if let inner = object["val"] ?? object["value"] { return inner.lenientNumber }
            return nil
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    func value(at path: [String]) -> JSONValue? {
        var current: JSONValue = self
        for segment in path {
            guard let next = current[segment] else { return nil }
            current = next
        }
        return current
    }

    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

enum JSONWebToken {
    static func payload(of token: String) -> JSONValue? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return JSONValue.parse(data)
    }

    static func expiry(of token: String) -> Date? {
        guard let seconds = payload(of: token)?["exp"]?.lenientNumber else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum LocalToolText {
    /// `seven_day_oauth_apps` → `Oauth apps`, `SUPER_GROK_PRO` → `Super Grok Pro`.
    static func humanized(_ raw: String, capitalizeEachWord: Bool = false) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
        guard !words.isEmpty else { return raw }
        return words.enumerated().map { index, word in
            (index == 0 || capitalizeEachWord) ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }
}

// MARK: - Throttling

protocol ThrottledUsageProviding: CodexUsageProviding {
    func refresh(manual: Bool) async throws -> AccountUsageResult
}

/// Rate-limit guard for providers that talk to a provider account endpoint.
/// The composite provider polls on a one-minute cadence; this wrapper returns
/// the last result until the tool's own minimum interval elapses, backs off
/// after failures, and backs off further after an HTTP 429 or a Keychain
/// denial.
///
/// A refresh runs as its own task and callers wait for it only up to
/// `waitLimit`. A provider that is blocked, for example on the macOS Keychain
/// prompt shown the first time the Claude sign-in is read, therefore never
/// holds up the Codex refresh: callers get the last known result and the
/// pending refresh lands on the next cycle.
actor ThrottledUsageProvider: ThrottledUsageProviding {
    private let base: any CodexUsageProviding
    private let minimumInterval: TimeInterval
    private let manualMinimumInterval: TimeInterval
    private let signedOutRetryInterval: TimeInterval
    private let failureRetryInterval: TimeInterval
    private let rateLimitedInterval: TimeInterval
    private let accessDeniedRetryInterval: TimeInterval
    private let waitLimit: TimeInterval
    private let now: @Sendable () -> Date
    private var lastResult: AccountUsageResult?
    private var lastError: Error?
    private var nextAutomaticRefresh: Date?
    private var nextManualRefresh: Date?
    private var inFlight: Task<AccountUsageResult, Error>?

    init(
        base: any CodexUsageProviding,
        minimumInterval: TimeInterval,
        manualMinimumInterval: TimeInterval = 20,
        signedOutRetryInterval: TimeInterval = 30,
        failureRetryInterval: TimeInterval = 120,
        rateLimitedInterval: TimeInterval = 600,
        accessDeniedRetryInterval: TimeInterval = 3_600,
        waitLimit: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.base = base
        self.minimumInterval = minimumInterval
        self.manualMinimumInterval = min(manualMinimumInterval, minimumInterval)
        self.signedOutRetryInterval = signedOutRetryInterval
        self.failureRetryInterval = failureRetryInterval
        self.rateLimitedInterval = rateLimitedInterval
        self.accessDeniedRetryInterval = accessDeniedRetryInterval
        self.waitLimit = waitLimit
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        try await refresh(manual: false)
    }

    func refresh(manual: Bool) async throws -> AccountUsageResult {
        let current = now()
        let gate = manual ? nextManualRefresh : nextAutomaticRefresh
        if inFlight == nil, let gate, current < gate {
            if let lastResult { return lastResult }
            if let lastError { throw lastError }
        }

        let task = inFlight ?? startRefresh()
        if let outcome = await Self.wait(for: task, upTo: waitLimit) {
            return try outcome.get()
        }
        // Still running, most likely blocked on a system prompt. Report the
        // last known state instead of holding up every other source.
        if let lastResult { return lastResult }
        throw lastError ?? LocalToolUsageError.timedOut
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {
        inFlight?.cancel()
        inFlight = nil
        await base.stop()
        lastResult = nil
        lastError = nil
        nextAutomaticRefresh = nil
        nextManualRefresh = nil
    }

    private func startRefresh() -> Task<AccountUsageResult, Error> {
        let base = self.base
        let task = Task<AccountUsageResult, Error>.detached {
            let outcome: Result<AccountUsageResult, Error>
            do { outcome = .success(try await base.refresh()) }
            catch { outcome = .failure(error) }
            await self.finishRefresh(outcome)
            return try outcome.get()
        }
        inFlight = task
        return task
    }

    private func finishRefresh(_ outcome: Result<AccountUsageResult, Error>) {
        inFlight = nil
        let completedAt = now()
        switch outcome {
        case let .success(result):
            lastResult = result
            lastError = nil
            let interval: TimeInterval
            switch result {
            case .signedOut: interval = signedOutRetryInterval
            case .authenticated: interval = minimumInterval
            }
            nextAutomaticRefresh = completedAt.addingTimeInterval(interval)
            // A signed-out or disabled check costs nothing, so a manual refresh
            // (Detect, or turning a tool on) may retry it immediately.
            nextManualRefresh = result == .signedOut
                ? completedAt
                : completedAt.addingTimeInterval(min(manualMinimumInterval, interval))
        case let .failure(error):
            lastError = error
            let interval: TimeInterval
            var manualInterval: TimeInterval
            switch error as? LocalToolUsageError {
            case .rateLimited:
                interval = rateLimitedInterval
                manualInterval = interval
            case .keychainAccessDenied:
                interval = accessDeniedRetryInterval
                manualInterval = manualMinimumInterval
            case .notInstalled, .notSignedIn:
                interval = signedOutRetryInterval
                manualInterval = manualMinimumInterval
            default:
                interval = failureRetryInterval
                manualInterval = manualMinimumInterval
            }
            manualInterval = min(manualInterval, interval)
            nextAutomaticRefresh = completedAt.addingTimeInterval(interval)
            nextManualRefresh = completedAt.addingTimeInterval(manualInterval)
        }
    }

    /// Waits for `task` up to `limit` seconds. Returns nil when the task is
    /// still running; the task itself keeps going. Implemented with a
    /// resume-once continuation rather than a task group, because a group
    /// would wait for the child that is still awaiting the task.
    private static func wait(
        for task: Task<AccountUsageResult, Error>,
        upTo limit: TimeInterval
    ) async -> Result<AccountUsageResult, Error>? {
        await withCheckedContinuation { continuation in
            let resumer = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                resumer.resume(nil)
            }
            Task {
                let outcome = await task.result
                timer.cancel()
                resumer.resume(outcome)
            }
        }
    }
}

final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
