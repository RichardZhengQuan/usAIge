/// Reads plan and bonus credits through `_kiro/account/getUsage` over `kiro-cli acp --agent-engine v3`.
/// The command was learned from ClaudeBar's Kiro provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.

import Foundation

protocol KiroUsageFetching: Sendable {
    /// The RPC result, or nil when `kiro-cli` is missing.
    func fetchUsage() async throws -> JSONValue?
}

struct KiroACPUsageSource: KiroUsageFetching {
    private let locate: @Sendable (String) -> URL?
    private let makeTransport: @Sendable (URL, [String]) -> any LineTransport
    private let timeoutNanoseconds: UInt64

    init(
        locate: @escaping @Sendable (String) -> URL? = { LocalCommandLocator.executableURL(named: $0) },
        makeTransport: @escaping @Sendable (URL, [String]) -> any LineTransport = { executable, arguments in
            ProcessLineTransport(executableURL: executable, arguments: arguments)
        },
        timeoutNanoseconds: UInt64 = 45_000_000_000
    ) {
        self.locate = locate
        self.makeTransport = makeTransport
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func fetchUsage() async throws -> JSONValue? {
        guard let executable = locate("kiro-cli") else { return nil }
        let arguments = ["acp", "--agent-engine", "v3"]
        let rpc = JSONRPCConnection(transport: makeTransport(executable, arguments))
        let startedAt = DispatchTime.now().uptimeNanoseconds

        do {
            let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    try await rpc.start()
                    try Task.checkCancellation()
                    _ = try await rpc.request(method: "initialize", params: .object([
                        "protocolVersion": .number(1),
                        "clientCapabilities": .object([:]),
                        "clientInfo": .object([
                            "name": .string("usAIge"),
                            "version": .string(UsAIgeUserAgent.shortVersion),
                        ]),
                    ]))
                    try Task.checkCancellation()
                    return try await rpc.request(method: "_kiro/account/getUsage")
                }
                group.addTask {
                    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                    if elapsed < timeoutNanoseconds {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds - elapsed)
                    }
                    throw LocalToolUsageError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw LocalToolUsageError.invalidResponse }
                try Task.checkCancellation()
                return result
            }
            await rpc.stop()
            return result
        } catch {
            await rpc.stop()
            throw error
        }
    }
}

enum KiroUsageParser {
    static func buckets(
        from response: JSONValue,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [RateLimitBucket] {
        guard response["success"] == nil || response["success"]?.boolValue == true,
              let data = response["data"], data.objectValue != nil else { return [] }

        let planType = nonemptyName(data["planName"])
        var buckets: [RateLimitBucket] = []
        for breakdown in data["usageBreakdowns"]?.arrayValue ?? [] {
            guard breakdown["hasLimit"]?.boolValue == true, isPlanCredits(breakdown),
                  let percent = usedPercent(breakdown["used"], of: breakdown["limit"]) else { continue }
            let reset = resetDate(data["billingCycleReset"]?.stringValue, now: now, calendar: calendar)
            let start = reset.flatMap { calendar.date(byAdding: .month, value: -1, to: $0) }
            buckets.append(RateLimitBucket(
                limitID: AIToolID.kiro.rawValue,
                limitName: "Plan credits",
                usedPercent: percent,
                windowDurationMinutes: LocalToolDates.windowMinutes(from: start, to: reset),
                resetsAt: reset?.timeIntervalSince1970,
                planType: planType
            ))
            break
        }

        for (index, grant) in (data["bonusCredits"]?.arrayValue ?? []).enumerated() {
            guard let percent = usedPercent(grant["used"], of: grant["total"]) else { continue }
            buckets.append(RateLimitBucket(
                limitID: "kiro_bonus_\(index + 1)",
                limitName: nonemptyName(grant["name"]) ?? "Bonus credits",
                usedPercent: percent,
                windowDurationMinutes: nil,
                resetsAt: nil,
                planType: planType
            ))
        }
        return buckets
    }

    private static func isPlanCredits(_ breakdown: JSONValue) -> Bool {
        let resource = nonemptyName(breakdown["resourceType"])?.lowercased()
        let name = nonemptyName(breakdown["displayName"])?.lowercased()
        return resource == "credit" || name == "credits" || name == "credit"
    }

    private static func usedPercent(_ used: JSONValue?, of limit: JSONValue?) -> Double? {
        guard let used = used?.lenientNumber, let limit = limit?.lenientNumber, limit > 0 else { return nil }
        return min(100, max(0, used / limit * 100))
    }

    private static func nonemptyName(_ value: JSONValue?) -> String? {
        guard let name = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private static func resetDate(_ value: String?, now: Date, calendar: Calendar) -> Date? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let full = text.split(separator: "-", omittingEmptySubsequences: false)
        if full.count == 3, full[0].count == 4, full[1].count == 2, full[2].count == 2,
           let year = Int(full[0]), let month = Int(full[1]), let day = Int(full[2]) {
            return date(year: year, month: month, day: day, calendar: calendar)
        }

        let short = text.split(separator: "/", omittingEmptySubsequences: false)
        guard short.count == 2, let month = Int(short[0]), let day = Int(short[1]) else {
            return LocalToolDates.parse(text)
        }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let currentMonth = today.month, let currentDay = today.day else { return nil }
        let resetDay = (month, day)
        let todayDay = (currentMonth, currentDay)
        let passed = resetDay < todayDay || (resetDay == todayDay && now > calendar.startOfDay(for: now))
        return date(year: passed ? year + 1 : year, month: month, day: day, calendar: calendar)
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return date
    }
}

actor KiroUsageProvider: CodexUsageProviding {
    private let source: any KiroUsageFetching
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        source: any KiroUsageFetching = KiroACPUsageSource(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            guard let response = try await source.fetchUsage() else {
                await report(.notInstalled)
                return .signedOut
            }
            let updatedAt = now()
            let buckets = KiroUsageParser.buckets(from: response, now: updatedAt)
            guard !buckets.isEmpty else { throw LocalToolUsageError.invalidResponse }

            let snapshots = buckets.map { bucket in
                var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                snapshot.toolID = .kiro
                return snapshot
            }
            await report(.connected)
            return .authenticated(snapshots)
        } catch {
            let failure = Self.usageError(for: error)
            await report(LocalToolStatus(error: failure))
            if error is CancellationError { throw error }
            if failure == .notInstalled || failure == .notSignedIn { return .signedOut }
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func report(_ status: LocalToolStatus) async {
        await statusRegistry?.report(status, for: .kiro)
    }

    private static func usageError(for error: any Error) -> LocalToolUsageError {
        if let error = error as? LocalToolUsageError { return error }
        guard let rpcError = error as? JSONRPCError,
              case let .server(code, message) = rpcError else { return .invalidResponse }
        switch code {
        case 401: return .credentialExpired
        case 429: return .rateLimited
        case -32000: return .notSignedIn // ACP authentication required
        default:
            let signInMessages = [
                "authentication required", "not authenticated", "not signed in", "not logged in",
                "please sign in", "please log in",
            ]
            return signInMessages.contains(where: { message.localizedCaseInsensitiveContains($0) })
                ? .notSignedIn : .invalidResponse
        }
    }
}
