/// Reads the key saved by `cmd login` and the window limits and credits from the Command Code API.
/// The file was learned from ClaudeBar's Command Code provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Darwin
import Foundation

protocol CommandCodeCredentialSource: Sendable {
    func load() -> (isInstalled: Bool, key: String?)
}

struct CommandCodeAuthFile: CommandCodeCredentialSource {
    private let directory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".commandcode", isDirectory: true)
    }

    func load() -> (isInstalled: Bool, key: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return (false, nil) }

        let url = directory.appendingPathComponent("auth.json")
        let key = Self.readKey(at: url)
        return (true, key)
    }

    private static func readKey(at url: URL) -> String? {
        let limit = 1_048_576
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let raw = JSONValue.parse(data)?["apiKey"]?.stringValue else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return key
    }
}

actor CommandCodeUsageProvider: CodexUsageProviding {
    private enum Endpoint: String {
        case identity = "/alpha/whoami"
        case credits = "/alpha/billing/credits"
        case subscriptions = "/alpha/billing/subscriptions"
        case summary = "/alpha/usage/summary"
    }

    private let credentials: any CommandCodeCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        credentials: (any CommandCodeCredentialSource)? = nil,
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials ?? CommandCodeAuthFile(homeDirectory: homeDirectory)
        self.http = http
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        let auth = credentials.load()
        guard auth.isInstalled, let key = auth.key else {
            await statusRegistry?.report(auth.isInstalled ? .signedOut : .notInstalled, for: .commandCode)
            return .signedOut
        }

        do {
            let identity = try await fetch(.identity, query: [URLQueryItem(name: "limits", value: "1")], key: key)
            let organization = CommandCodeUsageParser.organizationID(in: identity)
            let query = organization.map { [URLQueryItem(name: "orgId", value: $0)] } ?? []
            let credits = try await fetch(.credits, query: query, key: key)
            let subscriptions = try await fetch(.subscriptions, query: query, key: key)
            let usage = try CommandCodeUsageParser(credits: credits, subscriptions: subscriptions)
            let summary: JSONValue?
            if let since = usage.summarySince {
                summary = try await fetch(.summary, query: query + [URLQueryItem(name: "since", value: since)], key: key)
            } else {
                summary = nil
            }
            let updatedAt = now()
            let snapshots = usage.buckets(summary: summary).map { bucket in
                var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                snapshot.toolID = .commandCode
                return snapshot
            }
            await statusRegistry?.report(.connected, for: .commandCode)
            return .authenticated(snapshots)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = error as? LocalToolUsageError
                ?? ((error as? URLError)?.code == .timedOut ? .timedOut : .invalidResponse)
            await statusRegistry?.report(LocalToolStatus(error: failure), for: .commandCode)
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func fetch(_ endpoint: Endpoint, query: [URLQueryItem], key: String) async throws -> JSONValue {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.commandcode.ai"
        components.path = endpoint.rawValue
        components.queryItems = query.isEmpty ? nil : query
        // These query values can contain a literal plus, including a time zone offset.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw LocalToolUsageError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsAIgeUserAgent.value, forHTTPHeaderField: "User-Agent")

        try Task.checkCancellation()
        let (status, body) = try await http.send(request)
        try Task.checkCancellation()
        if endpoint == .subscriptions || endpoint == .summary, status == 204 || status == 404 {
            return .object([:])
        }
        switch status {
        case 200..<300: return try CommandCodeUsageParser.response(from: body)
        case 401, 403: throw LocalToolUsageError.credentialExpired
        case 429: throw LocalToolUsageError.rateLimited
        default: throw LocalToolUsageError.http(status)
        }
    }
}

private struct CommandCodeUsageParser {
    private let limits: JSONValue?
    private let planType: String?
    private let balance: (monthly: Double, additional: Double)?
    private let allowance: Double?
    private let periodStart: JSONValue?
    private let periodEnd: Date?
    private let activeSubscription: Bool

    // A reported plan ID can identify its published monthly dollar allowance.
    private static let planAllowances: [String: Double] = [
        "individual-go": 10,
        "individual-go-v1": 10,
        "individual-goat": 70,
        "individual-pro": 30,
        "individual-pro-v1": 80,
        "individual-provider": 15,
        "individual-max": 150,
        "individual-ultra": 300,
        "teams-pro": 40,
    ]

    init(credits: JSONValue, subscriptions: JSONValue) throws {
        let report = Self.payload(of: credits)
        let subscription = Self.payload(of: subscriptions)
        let status = Self.text(subscription["status"])?.lowercased()
        let currentPlan = status == nil || status == "active"
        let amounts = try Self.optionalObject(report["credits"])
        limits = try Self.optionalObject(report["windowLimits"])
        activeSubscription = status == "active"
        planType = currentPlan ? Self.text(subscription["planId"]) ?? Self.text(amounts?["planId"]) : nil
        allowance = planType.flatMap(Self.monthlyAllowance)
        periodStart = currentPlan ? subscription["currentPeriodStart"] : nil
        periodEnd = currentPlan ? LocalToolDates.parseFlexible(subscription["currentPeriodEnd"]) : nil
        if let monthly = amounts?["monthlyCredits"]?.lenientNumber {
            let purchased = max(0, amounts?["purchasedCredits"]?.lenientNumber ?? 0)
            let free = max(0, amounts?["freeCredits"]?.lenientNumber ?? 0)
            balance = (max(0, monthly), purchased + free)
        } else {
            balance = nil
        }
    }

    var summarySince: String? {
        guard allowance == nil, balance != nil, activeSubscription,
              LocalToolDates.parseFlexible(periodStart) != nil else { return nil }
        return Self.text(periodStart)
    }

    func buckets(summary: JSONValue?) -> [RateLimitBucket] {
        let fiveHour = Self.window(limits?["fiveHour"])
        let weekly = Self.window(limits?["weekly"])
        var buckets: [RateLimitBucket] = []
        if let primary = fiveHour ?? weekly {
            let secondary = fiveHour == nil ? nil : weekly
            buckets.append(RateLimitBucket(
                limitID: AIToolID.commandCode.rawValue,
                limitName: "Plan limits",
                usedPercent: primary.percent,
                windowDurationMinutes: fiveHour == nil ? 10_080 : 300,
                resetsAt: primary.reset,
                planType: planType,
                secondaryUsedPercent: secondary?.percent,
                secondaryWindowDurationMinutes: secondary == nil ? nil : 10_080,
                secondaryResetsAt: secondary?.reset
            ))
        }
        if let credits = creditBucket(summary: summary) {
            buckets.append(credits)
        }
        return buckets
    }

    static func organizationID(in identity: JSONValue) -> String? {
        text(identity.value(at: ["data", "org", "id"])) ?? text(identity.value(at: ["org", "id"]))
    }

    static func response(from body: Data) throws -> JSONValue {
        guard let json = JSONValue.parse(body), json.objectValue != nil,
              json["success"]?.boolValue != false else { throw LocalToolUsageError.invalidResponse }
        _ = try optionalObject(json["data"])
        return json
    }

    private func creditBucket(summary: JSONValue?) -> RateLimitBucket? {
        guard let balance else { return nil }
        let usage: (spent: Double, capacity: Double)
        if let allowance {
            let monthlyCapacity = max(allowance, balance.monthly)
            usage = (monthlyCapacity - balance.monthly, monthlyCapacity + balance.additional)
        } else if activeSubscription, let summary,
                  let spent = Self.payload(of: summary)["totalCost"]?.lenientNumber, spent > 0 {
            usage = (spent, spent + balance.monthly + balance.additional)
        } else {
            return nil
        }
        guard usage.capacity.isFinite else { return nil }

        let minutes: Int?
        if let start = LocalToolDates.parseFlexible(periodStart), let periodEnd, periodEnd > start {
            let duration = (periodEnd.timeIntervalSince(start) / 60).rounded()
            minutes = duration > 0 ? Int(exactly: duration) : nil
        } else {
            minutes = nil
        }
        return RateLimitBucket(
            limitID: "commandCode_credits",
            limitName: "Credits",
            usedPercent: usage.spent / usage.capacity * 100,
            windowDurationMinutes: minutes,
            resetsAt: periodEnd?.timeIntervalSince1970,
            planType: planType
        )
    }

    private static func window(_ value: JSONValue?) -> (percent: Double, reset: TimeInterval?)? {
        guard let cap = value?["cap"]?.lenientNumber, cap > 0,
              let used = value?["used"]?.lenientNumber else { return nil }
        let percent = min(cap, max(0, used)) / cap * 100
        return (percent, LocalToolDates.parseFlexible(value?["resetAt"])?.timeIntervalSince1970)
    }

    private static func monthlyAllowance(for planID: String) -> Double? {
        let normalized = planID.lowercased().replacingOccurrences(of: "_", with: "-")
        return planAllowances.filter { normalized == $0.key || normalized.hasPrefix($0.key + "-") }
            .max(by: { $0.key.count < $1.key.count })?.value
    }

    private static func payload(of response: JSONValue) -> JSONValue {
        if let data = response["data"], data.objectValue != nil { return data }
        return response
    }

    private static func optionalObject(_ value: JSONValue?) throws -> JSONValue? {
        guard let value, value != .null else { return nil }
        guard value.objectValue != nil else { throw LocalToolUsageError.invalidResponse }
        return value
    }

    private static func text(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let number = value?.numberValue, number.isFinite {
            return Int64(exactly: number).map(String.init) ?? String(number)
        }
        return nil
    }
}
