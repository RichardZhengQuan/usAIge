import Foundation

struct GrokCredential: Equatable, Sendable {
    let token: String
    let email: String?
    let expiresAt: Date?
}

protocol GrokCredentialSource: Sendable {
    /// Empty means Grok Build is not installed or not signed in on this Mac.
    func load() throws -> [GrokCredential]
}

/// Reads `$GROK_HOME/auth.json` (default `~/.grok/auth.json`), the file the
/// Grok Build CLI writes after `grok login`. Entries are keyed by issuer;
/// xAI account sign-ins come first when several are present.
struct GrokBuildAuthFile: GrokCredentialSource {
    let fileURL: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            fileURL = URL(fileURLWithPath: grokHome).appendingPathComponent("auth.json")
        } else {
            fileURL = homeDirectory.appendingPathComponent(".grok").appendingPathComponent("auth.json")
        }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [GrokCredential] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let document = JSONValue.parse(data) else { throw LocalToolUsageError.invalidResponse }
        return Self.credentials(in: document)
    }

    static func credentials(in document: JSONValue) -> [GrokCredential] {
        guard let entries = document.objectValue else { return [] }
        var preferred: [GrokCredential] = []
        var others: [GrokCredential] = []
        for scope in entries.keys.sorted() {
            guard let entry = entries[scope], entry.objectValue != nil,
                  let token = entry["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { continue }
            let credential = GrokCredential(
                token: token,
                email: entry["email"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                expiresAt: LocalToolDates.parseFlexible(entry["expires_at"])
            )
            if scope.contains("auth.x.ai") { preferred.append(credential) } else { others.append(credential) }
        }
        return preferred + others
    }
}

/// Grok Build's sign-in is a six-hour token that only the CLI renews. Running
/// `grok models` without a terminal makes the CLI refresh its own auth file,
/// so usAIge asks it to do that when the token is stale instead of touching
/// the refresh token itself.
enum GrokBuildCLI {
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            candidates.append("\(grokHome)/bin/grok")
        }
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.grok/bin/grok")
        }
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append("\(directory)/grok")
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// Returns true when the CLI ran to completion; the caller re-reads the
    /// auth file to see whether the sign-in is fresh now.
    static func refreshSignIn(timeout: TimeInterval = 30) async -> Bool {
        guard let executable = executableURL() else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["models"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let box = ProcessBox(process)
        return await withCheckedContinuation { continuation in
            let resumer = ResumeOnce<Bool>(continuation)
            process.terminationHandler = { _ in resumer.resume(true) }
            do {
                try process.run()
            } catch {
                resumer.resume(false)
                return
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                if box.process.isRunning { box.process.terminate() }
                resumer.resume(false)
            }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
}

actor GrokUsageProvider: CodexUsageProviding {
    static let creditsConfigURL = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
    )!
    static let taskUsageURL = URL(string: "https://grok.com/rest/tasks/usage")!
    static let subscriptionsURL = URL(string: "https://grok.com/rest/subscriptions")!
    static let primaryBucketID = "grok"

    private let credentials: any GrokCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let refreshSignIn: @Sendable () async -> Bool
    private let signInRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSignInRefreshAttempt: Date?

    init(
        credentials: any GrokCredentialSource = GrokBuildAuthFile(),
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        refreshSignIn: @escaping @Sendable () async -> Bool = { await GrokBuildCLI.refreshSignIn() },
        signInRefreshInterval: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.http = http
        self.statusRegistry = statusRegistry
        self.refreshSignIn = refreshSignIn
        self.signInRefreshInterval = signInRefreshInterval
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            let result = try await performRefresh()
            await report(result == .signedOut ? .signedOut : .connected)
            return result
        } catch {
            await report(LocalToolStatus(error: error))
            throw error
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func performRefresh() async throws -> AccountUsageResult {
        var candidates = try credentials.load()
        guard !candidates.isEmpty else { return .signedOut }
        if candidates.allSatisfy(isExpired), await renewSignInIfAllowed() {
            candidates = try credentials.load()
            guard !candidates.isEmpty else { return .signedOut }
        }
        var firstError: Error?
        for credential in candidates {
            if isExpired(credential) {
                firstError = firstError ?? LocalToolUsageError.credentialExpired
                continue
            }
            do {
                return .authenticated(try await fetchUsage(with: credential))
            } catch LocalToolUsageError.credentialExpired {
                // The server rejected a token that looked current: let the CLI
                // renew it once, then retry with whatever it wrote.
                if await renewSignInIfAllowed(),
                   let renewed = try credentials.load().first(where: { !isExpired($0) }) {
                    do {
                        return .authenticated(try await fetchUsage(with: renewed))
                    } catch {
                        firstError = firstError ?? error
                    }
                } else {
                    firstError = firstError ?? LocalToolUsageError.credentialExpired
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? LocalToolUsageError.invalidResponse
    }

    private func isExpired(_ credential: GrokCredential) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return now() >= expiresAt
    }

    /// At most one CLI renewal per `signInRefreshInterval`, so a broken
    /// sign-in cannot make usAIge relaunch the CLI on every poll.
    private func renewSignInIfAllowed() async -> Bool {
        let current = now()
        if let lastSignInRefreshAttempt,
           current.timeIntervalSince(lastSignInRefreshAttempt) < signInRefreshInterval {
            return false
        }
        lastSignInRefreshAttempt = current
        return await refreshSignIn()
    }

    /// Billing gRPC first (percent of the included credits plus the period
    /// bounds), task usage REST as the fallback, subscriptions for the plan.
    private func fetchUsage(with credential: GrokCredential) async throws -> [QuotaSnapshot] {
        var buckets: [RateLimitBucket] = []
        var firstError: Error?
        var planType: String?

        do {
            let body = try await send(Self.creditsRequest(token: credential.token))
            if let metric = Self.parseCreditsConfigResponse([UInt8](body)) {
                buckets.append(metric.bucket(planType: nil))
            } else {
                firstError = LocalToolUsageError.invalidResponse
            }
        } catch {
            firstError = firstError ?? error
        }

        if buckets.isEmpty {
            do {
                let body = try await send(Self.jsonRequest(url: Self.taskUsageURL, token: credential.token))
                if let value = JSONValue.parse(body) {
                    buckets.append(contentsOf: Self.taskUsageBuckets(in: value))
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        do {
            let body = try await send(Self.jsonRequest(url: Self.subscriptionsURL, token: credential.token))
            planType = JSONValue.parse(body).flatMap(Self.subscriptionPlan(in:))
        } catch {
            firstError = firstError ?? error
        }

        if buckets.isEmpty {
            if planType != nil { return [] }
            throw firstError ?? LocalToolUsageError.invalidResponse
        }

        let updatedAt = now()
        return buckets.map { bucket in
            var value = bucket
            if let planType { value = value.replacingPlanType(planType) }
            var snapshot = QuotaSnapshot.make(from: value, updatedAt: updatedAt)
            snapshot.toolID = .grok
            return snapshot
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (status, body) = try await http.send(request)
        switch status {
        case 200..<300: return body
        case 401, 403: throw LocalToolUsageError.credentialExpired
        case 429: throw LocalToolUsageError.rateLimited
        default: throw LocalToolUsageError.http(status)
        }
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .grok)
    }

    // MARK: Requests

    static func jsonRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Grok Build", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func creditsRequest(token: String) -> URLRequest {
        var request = URLRequest(url: creditsConfigURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("Grok Build", forHTTPHeaderField: "User-Agent")
        // An empty request message in a grpc-web frame: flag 0, zero length.
        request.httpBody = Data([0, 0, 0, 0, 0])
        return request
    }

    // MARK: Decoding

    struct CreditsMetric: Equatable, Sendable {
        let usedPercent: Double
        let periodStart: Date?
        let periodEnd: Date?

        var label: String {
            guard let periodStart, let periodEnd else { return "Credits" }
            let days = Int(periodEnd.timeIntervalSince(periodStart) / 86_400)
            if (6...8).contains(days) { return "Weekly credits" }
            if (27...33).contains(days) { return "Monthly credits" }
            return "Credits"
        }

        func bucket(planType: String?) -> RateLimitBucket {
            RateLimitBucket(
                limitID: GrokUsageProvider.primaryBucketID,
                limitName: label,
                usedPercent: usedPercent,
                windowDurationMinutes: LocalToolDates.windowMinutes(from: periodStart, to: periodEnd),
                resetsAt: periodEnd?.timeIntervalSince1970,
                planType: planType
            )
        }
    }

    /// Task usage REST payload: `usage`/`limit`, `frequentUsage`/`frequentLimit`,
    /// `occasionalUsage`/`occasionalLimit`, searched recursively.
    static func taskUsageBuckets(in value: JSONValue) -> [RateLimitBucket] {
        var buckets: [RateLimitBucket] = []
        collectTaskUsage(value, into: &buckets)
        return buckets
    }

    private static func collectTaskUsage(_ value: JSONValue, into buckets: inout [RateLimitBucket]) {
        if let object = value.objectValue {
            let reset = LocalToolDates.parseFlexible(
                object["resetTime"] ?? object["resetsAt"] ?? object["resetAt"]
            )
            let pairs: [(id: String, name: String, used: String, limit: String)] = [
                ("grok_tasks", "Tasks", "usage", "limit"),
                ("grok_frequent", "Frequent tasks", "frequentUsage", "frequentLimit"),
                ("grok_occasional", "Occasional tasks", "occasionalUsage", "occasionalLimit"),
            ]
            for pair in pairs {
                guard let limit = object[pair.limit]?.lenientNumber, limit > 0,
                      !buckets.contains(where: { $0.limitID == pair.id }) else { continue }
                let used = min(max(object[pair.used]?.lenientNumber ?? 0, 0), limit)
                buckets.append(RateLimitBucket(
                    limitID: pair.id,
                    limitName: pair.name,
                    usedPercent: used / limit * 100,
                    windowDurationMinutes: nil,
                    resetsAt: reset?.timeIntervalSince1970,
                    planType: nil
                ))
            }
            for key in object.keys.sorted() {
                collectTaskUsage(object[key]!, into: &buckets)
            }
        } else if let items = value.arrayValue {
            for item in items { collectTaskUsage(item, into: &buckets) }
        }
    }

    static func subscriptionPlan(in value: JSONValue) -> String? {
        guard let subscriptions = value["subscriptions"]?.arrayValue else { return nil }
        let active = subscriptions.first { subscription in
            let status = subscription["status"]?.stringValue?.uppercased() ?? ""
            return status == "ACTIVE" || status.hasSuffix("STATUS_ACTIVE")
        }
        guard var tier = active?["tier"]?.stringValue else { return nil }
        for prefix in ["SUBSCRIPTION_TIER_", "TIER_"] where tier.hasPrefix(prefix) {
            tier = String(tier.dropFirst(prefix.count))
        }
        return LocalToolText.humanized(tier, capitalizeEachWord: true)
    }

    // MARK: grpc-web protobuf decoding

    enum ProtoValue: Equatable {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64
        case bytes([UInt8])
    }

    static func readVarint(_ data: [UInt8], _ position: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.count, shift <= 63 {
            let byte = data[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func nextField(_ data: [UInt8], _ position: inout Int) -> (field: UInt32, value: ProtoValue)? {
        guard let key = readVarint(data, &position),
              let field = UInt32(exactly: key >> 3) else { return nil }
        switch key & 0x07 {
        case 0:
            guard let value = readVarint(data, &position) else { return nil }
            return (field, .varint(value))
        case 1:
            guard position + 8 <= data.count else { return nil }
            position += 8
            return (field, .fixed64)
        case 2:
            guard let rawLength = readVarint(data, &position),
                  let length = Int(exactly: rawLength),
                  position + length <= data.count else { return nil }
            let bytes = Array(data[position..<position + length])
            position += length
            return (field, .bytes(bytes))
        case 5:
            guard position + 4 <= data.count else { return nil }
            let value = UInt32(data[position])
                | (UInt32(data[position + 1]) << 8)
                | (UInt32(data[position + 2]) << 16)
                | (UInt32(data[position + 3]) << 24)
            position += 4
            return (field, .fixed32(value))
        default:
            return nil
        }
    }

    /// `google.protobuf.Timestamp`: field 1 varint seconds.
    static func timestamp(in message: [UInt8]) -> Date? {
        var position = 0
        while position < message.count {
            guard let (field, value) = nextField(message, &position) else { return nil }
            if field == 1, case let .varint(seconds) = value, let signed = Int64(exactly: seconds) {
                return Date(timeIntervalSince1970: TimeInterval(signed))
            }
        }
        return nil
    }

    /// Credits config message: field 1 fixed32 float percent used, fields 4
    /// and 5 nested timestamps for the period bounds. Proto3 omits a zero
    /// percent, so bounds without a percent mean nothing used yet.
    static func parseCreditsConfig(_ message: [UInt8]) -> CreditsMetric? {
        var position = 0
        var usedPercent: Double?
        var start: Date?
        var end: Date?
        while position < message.count {
            guard let (field, value) = nextField(message, &position) else { return nil }
            switch (field, value) {
            case let (1, .fixed32(bits)):
                let percent = Double(Float(bitPattern: bits))
                if percent.isFinite { usedPercent = min(100, max(0, percent)) }
            case let (4, .bytes(bytes)):
                start = timestamp(in: bytes)
            case let (5, .bytes(bytes)):
                end = timestamp(in: bytes)
            default:
                break
            }
        }
        guard usedPercent != nil || start != nil || end != nil else { return nil }
        return CreditsMetric(usedPercent: usedPercent ?? 0, periodStart: start, periodEnd: end)
    }

    /// grpc-web framing: one flag byte plus a big-endian length per frame;
    /// trailer frames (flag & 0x80) are skipped. The response's field 1 nests
    /// the config message.
    static func parseCreditsConfigResponse(_ body: [UInt8]) -> CreditsMetric? {
        var position = 0
        while position + 5 <= body.count {
            let flag = body[position]
            let length = Int(
                (UInt32(body[position + 1]) << 24)
                    | (UInt32(body[position + 2]) << 16)
                    | (UInt32(body[position + 3]) << 8)
                    | UInt32(body[position + 4])
            )
            position += 5
            guard position + length <= body.count else { return nil }
            let payload = Array(body[position..<position + length])
            position += length
            if flag & 0x80 != 0 { continue }

            var payloadPosition = 0
            while payloadPosition < payload.count {
                guard let (field, value) = nextField(payload, &payloadPosition) else { return nil }
                if field == 1, case let .bytes(config) = value,
                   let metric = parseCreditsConfig(config) {
                    return metric
                }
            }
        }
        return nil
    }
}

private extension RateLimitBucket {
    func replacingPlanType(_ planType: String) -> RateLimitBucket {
        RateLimitBucket(
            limitID: limitID,
            limitName: limitName,
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt,
            planType: planType,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryWindowDurationMinutes: secondaryWindowDurationMinutes,
            secondaryResetsAt: secondaryResetsAt
        )
    }
}
