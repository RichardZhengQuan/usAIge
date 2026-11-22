import Darwin
import Foundation

/// Reads GitHub Copilot limits from `api.github.com/copilot_internal/user`
/// using the local sign-in from `gh auth token --hostname github.com`.
/// The endpoint was learned from ClaudeBar's Copilot provider
/// (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
actor CopilotUsageProvider: CodexUsageProviding {
    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    private let commandRunner: (any LocalCommandRunning)?
    private let http: any UsageHTTPClient
    private let isOptedIn: @Sendable () -> Bool
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        commandRunner: (any LocalCommandRunning)? = nil,
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        isOptedIn: @escaping @Sendable () -> Bool = { LocalToolOptIn.isEnabled(.copilot) },
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.commandRunner = commandRunner
        self.http = http
        self.isOptedIn = isOptedIn
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            let (result, status) = try await read()
            await report(status)
            return result
        } catch {
            guard isOptedIn() else {
                await report(.optInRequired)
                return .signedOut
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }

            // Transport and command errors may contain private request or output details.
            let failure = (error as? LocalToolUsageError)
                ?? ((error as? URLError)?.code == .timedOut ? .timedOut : .invalidResponse)
            switch failure {
            case .notInstalled, .notSignedIn:
                await report(LocalToolStatus(error: failure))
                return .signedOut
            case .http(403):
                await report(.failed(
                    "This GitHub sign-in can't read Copilot limits. "
                    + "Run `gh auth refresh -s copilot` if your plan needs it."
                ))
            default:
                await report(LocalToolStatus(error: failure))
            }
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func read() async throws -> (AccountUsageResult, LocalToolStatus) {
        guard isOptedIn() else { return (.signedOut, .optInRequired) }
        try Task.checkCancellation()
        let runner = commandRunner ?? Self.makeCommandRunner()
        let output = try await runner.run(
            "gh",
            arguments: ["auth", "token", "--hostname", "github.com"],
            timeout: 10,
            environment: ["GH_TOKEN": "", "GITHUB_TOKEN": ""]
        )
        // The user can turn off access while gh is running.
        guard isOptedIn() else { return (.signedOut, .optInRequired) }
        try Task.checkCancellation()
        guard let output else { return (.signedOut, .notInstalled) }
        guard output.exitCode == 0 else { return (.signedOut, .signedOut) }
        guard let text = String(data: output.standardOutput, encoding: .utf8) else {
            throw LocalToolUsageError.invalidResponse
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return (.signedOut, .signedOut) }
        guard token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LocalToolUsageError.invalidResponse
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsAIgeUserAgent.value, forHTTPHeaderField: "User-Agent")

        let (status, body) = try await http.send(request)
        guard isOptedIn() else { return (.signedOut, .optInRequired) }
        try Task.checkCancellation()
        switch status {
        case 200..<300:
            let snapshots = try CopilotQuotaParser.snapshots(from: body, updatedAt: now())
            return (.authenticated(snapshots), .connected)
        case 401: throw LocalToolUsageError.credentialExpired
        case 404: return (.authenticated([]), .failed("No Copilot subscription on this GitHub account."))
        case 429: throw LocalToolUsageError.rateLimited
        default: throw LocalToolUsageError.http(status)
        }
    }

    private static func makeCommandRunner() -> LocalCommandRunner {
        // Inherit the CLI's installation and configuration paths without collecting environment tokens.
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"] {
            if let value = getenv(key) { environment[key] = String(validatingCString: value) }
        }
        return LocalCommandRunner(environment: environment)
    }

    private func report(_ status: LocalToolStatus) async {
        await statusRegistry?.report(status, for: .copilot)
    }
}

private enum CopilotQuotaParser {
    private static let premiumKey = "premium_interactions"
    private static let utc = TimeZone(secondsFromGMT: 0)!

    static func snapshots(from data: Data, updatedAt: Date) throws -> [QuotaSnapshot] {
        guard let response = JSONValue.parse(data)?.objectValue else { throw LocalToolUsageError.invalidResponse }
        let quotas: [String: JSONValue]
        switch response["quota_snapshots"] {
        case nil, .null: return []
        case let .object(snapshots): quotas = snapshots
        default: throw LocalToolUsageError.invalidResponse
        }

        let plan = ["copilot_plan", "plan", "sku", "access_type_sku"].lazy
            .compactMap { response[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let reset = resetDate(response["quota_reset_date_utc"]) ?? resetDate(response["quota_reset_date"])
        let monthlyMinutes = reset.flatMap(monthlyWindowMinutes(endingAt:))
        let keys = [premiumKey] + quotas.keys.filter { $0 != premiumKey }.sorted()

        return keys.compactMap { key in
            guard let quota = quotas[key], quota["unlimited"]?.boolValue != true,
                  quota["has_quota"]?.boolValue != false,
                  key.range(of: #"\A[a-z0-9]+(?:_[a-z0-9]+)*\z"#, options: .regularExpression) != nil else { return nil }
            let isPremium = key == premiumKey
            let entitlement = quota["entitlement"]?.lenientNumber
            guard isPremium || (entitlement ?? 0) > 0,
                  let used = usedPercent(of: quota, entitlement: entitlement) else { return nil }

            let toolID = AIToolID.copilot
            let bucket = RateLimitBucket(
                limitID: isPremium ? toolID.rawValue : "\(toolID.rawValue)_\(key)",
                limitName: isPremium ? "AI credits" : LocalToolText.humanized(key),
                usedPercent: min(100, max(0, used)),
                windowDurationMinutes: isPremium ? monthlyMinutes : nil,
                resetsAt: reset?.timeIntervalSince1970,
                planType: plan
            )
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
            snapshot.toolID = toolID
            return snapshot
        }
    }

    private static func usedPercent(of quota: JSONValue, entitlement: Double?) -> Double? {
        if let percentRemaining = quota["percent_remaining"]?.lenientNumber { return 100 - percentRemaining }
        guard let entitlement, entitlement > 0 else { return nil }
        if let remaining = quota["remaining"]?.lenientNumber { return (1 - remaining / entitlement) * 100 }
        return quota["credits_used"]?.lenientNumber.map { $0 / entitlement * 100 }
    }

    private static func resetDate(_ field: JSONValue?) -> Date? {
        guard let value = field?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let timestamp = LocalToolDates.parse(value) { return timestamp }

        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = utc
        guard let date = dateOnly.date(from: value), dateOnly.string(from: date) == value else { return nil }
        return date
    }

    private static func monthlyWindowMinutes(endingAt reset: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = calendar.date(byAdding: .month, value: -1, to: reset)
        return LocalToolDates.windowMinutes(from: start, to: reset)
    }
}
