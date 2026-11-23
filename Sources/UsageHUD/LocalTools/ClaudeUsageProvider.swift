import Foundation
import Security

/// The OAuth credential Claude Code keeps on this Mac. Only the fields needed
/// to read usage are lifted out; the refresh token is deliberately ignored
/// because redeeming it would rotate the credential Claude Code owns.
struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = JSONValue.parse(data), root.objectValue != nil else {
            throw LocalToolUsageError.invalidResponse
        }
        // The Keychain item also carries MCP server OAuth state; only a
        // `claudeAiOauth` entry is a Claude plan sign-in.
        guard let oauth = root["claudeAiOauth"]?.objectValue else {
            throw LocalToolUsageError.notSignedIn
        }
        let token = oauth["accessToken"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw LocalToolUsageError.notSignedIn }
        let expiresAt = oauth["expiresAt"]?.lenientNumber.map { value -> Date in
            // Stored as epoch milliseconds.
            Date(timeIntervalSince1970: value > 32_503_680_000 ? value / 1000 : value)
        }
        let scopes = oauth["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: oauth["subscriptionType"]?.stringValue,
            rateLimitTier: oauth["rateLimitTier"]?.stringValue
        )
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    var canReadUsage: Bool {
        scopes.isEmpty || scopes.contains("user:profile")
    }
}

protocol ClaudeCredentialSource: Sendable {
    /// `nil` means Claude Code has no sign-in on this Mac.
    func load() async throws -> ClaudeCredentials?
}

/// Desktop usage tracking needs only already-recorded usage files. No secret
/// or password-key read is allowed in the app's automatic Claude collector.
struct NoClaudeCredentialSource: ClaudeCredentialSource {
    func load() async throws -> ClaudeCredentials? { nil }
}

/// Reads the sign-in Claude Code stores in the login Keychain (service
/// `Claude Code-credentials`), falling back to `~/.claude/.credentials.json`
/// for installs that predate Keychain storage. Read-only: the token is used
/// in memory for one request and never written anywhere by usAIge.
struct ClaudeCodeCredentialStore: ClaudeCredentialSource {
    static let keychainService = "Claude Code-credentials"

    private let credentialsFileURL: URL
    private let readKeychainItem: @Sendable () async throws -> Data?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        readKeychainItem: @escaping @Sendable () async throws -> Data? = {
            try await KeychainSecurityTool.genericPassword(service: ClaudeCodeCredentialStore.keychainService)
        }
    ) {
        credentialsFileURL = homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        self.readKeychainItem = readKeychainItem
    }

    func load() async throws -> ClaudeCredentials? {
        if let data = try await readKeychainItem() {
            guard !data.isEmpty else { return nil }
            return try Self.credentials(from: data)
        }

        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else { return nil }
        let data = try Data(contentsOf: credentialsFileURL)
        return try Self.credentials(from: data)
    }

    private static func credentials(from data: Data) throws -> ClaudeCredentials? {
        do { return try ClaudeCredentials.parse(data) }
        catch LocalToolUsageError.notSignedIn { return nil }
    }
}

/// Reads a generic-password item through `/usr/bin/security`, the tool
/// Claude Code itself uses to save its sign-in. The item's access list
/// trusts that tool, so the read needs no macOS prompt; asking the Keychain
/// API directly from usAIge would prompt, and prompt again after every
/// update because each release is a new ad-hoc-signed build.
enum KeychainSecurityTool {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/security")

    /// The item's secret, or `nil` when there is no such item. The tool runs
    /// on a dispatch queue so waiting for it never ties up a Swift
    /// concurrency thread.
    static func genericPassword(service: String, timeout: TimeInterval = 60) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try readGenericPassword(service: service, timeout: timeout) })
            }
        }
    }

    private static func readGenericPassword(service: String, timeout: TimeInterval) throws -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LocalToolUsageError.keychain(errSecNotAvailable)
        }
        // If the access list ever stops trusting the tool, `security` waits on
        // a macOS prompt; don't hold the refresh forever behind it.
        let box = ProcessBox(process)
        let deadline = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        if process.terminationReason == .uncaughtSignal { throw LocalToolUsageError.timedOut }
        return try secret(fromOutput: data, exitStatus: process.terminationStatus)
    }

    /// Interprets what `security find-generic-password -w` printed. The tool
    /// exits with the low byte of the Keychain status, and prints a secret
    /// that isn't plain printable ASCII (any non-ASCII character in the
    /// JSON, say) as hex instead of text. A JSON secret starts with `{`, so
    /// it can't be mistaken for hex.
    static func secret(fromOutput output: Data, exitStatus: Int32) throws -> Data? {
        switch exitStatus {
        case 0:
            break
        case exitCode(for: errSecItemNotFound):
            return nil
        case exitCode(for: errSecAuthFailed),
             exitCode(for: errSecUserCanceled),
             exitCode(for: errSecInteractionNotAllowed):
            throw LocalToolUsageError.keychainAccessDenied
        default:
            throw LocalToolUsageError.keychain(exitStatus)
        }
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return hexDecoded(text) ?? Data(text.utf8)
    }

    static func exitCode(for status: OSStatus) -> Int32 {
        status & 0xFF
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let digits = Array((text.hasPrefix("0x") ? text.dropFirst(2) : Substring(text)).utf8)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
}

/// Reads Claude Code's own settings to explain a missing sign-in: a
/// configured `apiKeyHelper` means Claude Code bills an API key here, and
/// there is no plan quota for usAIge to show.
enum ClaudeCodeConfiguration {
    static func usesAPIKeyHelper(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let settings = homeDirectory.appendingPathComponent(".claude").appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: settings.path),
              let helper = JSONValue.parse(data)?["apiKeyHelper"]?.stringValue else { return false }
        return !helper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Resolves the installed Claude Code version without launching it, so the
/// usage request can identify itself the way Claude Code does.
enum ClaudeCodeVersion {
    static let fallback = "2.1.0"

    static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.local/bin/claude")
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append("\(directory)/claude")
        }
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            if let version = version(forExecutableAt: path, fileManager: fileManager) {
                return version
            }
        }
        return fallback
    }

    static func version(forExecutableAt path: String, fileManager: FileManager) -> String? {
        let resolved = (try? fileManager.destinationOfSymbolicLink(atPath: path))
            .map { destination -> String in
                destination.hasPrefix("/")
                    ? destination
                    : (path as NSString).deletingLastPathComponent + "/" + destination
            } ?? path
        let standardized = (resolved as NSString).standardizingPath
        // Native installer: ~/.local/share/claude/versions/<version>
        if let semver = semanticVersion(in: (standardized as NSString).lastPathComponent) {
            return semver
        }
        // npm installer: .../node_modules/@anthropic-ai/claude-code/cli.js + package.json
        let packageJSON = (standardized as NSString).deletingLastPathComponent + "/package.json"
        if let data = fileManager.contents(atPath: packageJSON),
           let version = JSONValue.parse(data)?["version"]?.stringValue,
           let semver = semanticVersion(in: version) {
            return semver
        }
        return nil
    }

    static func semanticVersion(in text: String) -> String? {
        let parts = text.split(separator: ".")
        guard parts.count >= 3, parts.prefix(3).allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
}

actor ClaudeUsageProvider: LocalUsageProviding {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let primaryBucketID = "claude"

    private static let knownWindows: [(key: String, id: String, name: String)] = [
        ("seven_day_opus", "claude_opus", "Opus"),
        ("seven_day_sonnet", "claude_sonnet", "Sonnet"),
        ("seven_day_oauth_apps", "claude_oauth_apps", "OAuth apps"),
    ]
    private static let mainWindowKeys: Set<String> = ["five_hour", "seven_day"]
    /// The Claude app records a reading every few minutes while it runs; an
    /// older one means it has quit, and its numbers are no longer current.
    static let claudeAppMaximumAge: TimeInterval = 30 * 60

    private let credentials: any ClaudeCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let claudeApp: any ClaudeAppUsageSource
    private let userAgentVersion: @Sendable () -> String
    private let usesAPIKeyHelper: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var cachedUserAgent: String?
    /// After a 429 or a blocked Keychain read, the sign-in isn't tried again
    /// until this date. The Claude app reading hides those failures from the
    /// throttle, so the provider keeps the back-off itself.
    private var signInPause: (until: Date, error: LocalToolUsageError)?
    private let rateLimitedPause: TimeInterval
    private let accessDeniedPause: TimeInterval

    init(
        credentials: any ClaudeCredentialSource = NoClaudeCredentialSource(),
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        userAgentVersion: @escaping @Sendable () -> String = { ClaudeCodeVersion.resolve() },
        claudeApp: any ClaudeAppUsageSource = ClaudeAutomaticUsageSource(),
        usesAPIKeyHelper: @escaping @Sendable () -> Bool = { ClaudeCodeConfiguration.usesAPIKeyHelper() },
        rateLimitedPause: TimeInterval = 900,
        accessDeniedPause: TimeInterval = 3_600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.http = http
        self.statusRegistry = statusRegistry
        self.userAgentVersion = userAgentVersion
        self.claudeApp = claudeApp
        self.usesAPIKeyHelper = usesAPIKeyHelper
        self.rateLimitedPause = rateLimitedPause
        self.accessDeniedPause = accessDeniedPause
        self.now = now
    }

    /// A recent, validated desktop cache response supplies exact reset times
    /// before any credential read or request. Otherwise the existing Claude
    /// Code source remains available, with local percentage history as fallback.
    func refresh() async throws -> AccountUsageResult {
        if credentials is NoClaudeCredentialSource {
            return await refreshLocalUsage() ?? .authenticated([])
        }
        if let fromCache = claudeAppResult(requireCachedUsage: true) {
            await report(fromCache.status)
            return fromCache.result
        }
        if let pause = signInPause {
            if now() < pause.until {
                if let fromApp = claudeAppResult() {
                    await report(fromApp.status)
                    return fromApp.result
                }
                await report(LocalToolStatus(error: pause.error))
                throw pause.error
            }
            signInPause = nil
        }
        do {
            let result = try await performRefresh()
            if result != .signedOut {
                await report(.connected)
                return result
            }
            if let fromApp = claudeAppResult() {
                await report(fromApp.status)
                return fromApp.result
            }
            await report(usesAPIKeyHelper() ? .apiKeyOnly : .signedOut)
            return result
        } catch {
            switch error as? LocalToolUsageError {
            case .rateLimited: signInPause = (now().addingTimeInterval(rateLimitedPause), .rateLimited)
            case .keychainAccessDenied: signInPause = (now().addingTimeInterval(accessDeniedPause), .keychainAccessDenied)
            default: break
            }
            if let fromApp = claudeAppResult() {
                await report(fromApp.status)
                return fromApp.result
            }
            if case LocalToolUsageError.credentialExpired = error, usesAPIKeyHelper() {
                await report(.apiKeyHelperSignInExpired)
            } else {
                await report(LocalToolStatus(error: error))
            }
            throw error
        }
    }

    func refreshLocalUsage() async -> AccountUsageResult? {
        if let fromApp = claudeAppResult() {
            await report(fromApp.status)
            return fromApp.result
        }
        // Expired readings and organization switches invalidate this tool's
        // prior values immediately, even while the normal refresh is gated.
        await report(.waitingForClaudeUsage)
        return .authenticated([])
    }

    private func claudeAppResult(requireCachedUsage: Bool = false) -> (result: AccountUsageResult, status: LocalToolStatus)? {
        guard let sample = claudeApp.latestSample() else { return nil }
        let date = now()
        guard (0...Self.claudeAppMaximumAge).contains(date.timeIntervalSince(sample.recordedAt)) else { return nil }
        if let cache = sample.cachedUsage,
           (0...Self.claudeAppMaximumAge).contains(date.timeIntervalSince(cache.recordedAt)),
           let payload = ClaudeDesktopUsageCache.validatedPayload(cache.payload, now: date) {
            var snapshots = Self.snapshots(from: payload, planType: nil, updatedAt: cache.recordedAt)
            if let first = snapshots.first, first.availableResets.isEmpty, let credits = sample.resetCredits {
                snapshots[0].attach(credits)
            }
            if !snapshots.isEmpty {
                let status: LocalToolStatus = sample.origin == .bridge
                    ? .connectedThroughClaudeBridge : .connectedThroughClaudeAppCache
                return (.authenticated(snapshots), status)
            }
        }
        guard !requireCachedUsage else { return nil }
        var historyOnly = sample
        historyOnly.cachedUsage = nil
        // Reset times still running from an earlier response come from
        // Claude's cache; without them, resets are unknown.
        historyOnly.sessionResetAt = historyOnly.sessionResetAt.flatMap { $0 > date ? $0 : nil }
        historyOnly.weeklyResetAt = historyOnly.weeklyResetAt.flatMap { $0 > date ? $0 : nil }
        let snapshots = Self.snapshots(fromClaudeApp: historyOnly, planType: nil)
        let status: LocalToolStatus = historyOnly.sessionResetAt != nil || historyOnly.weeklyResetAt != nil
            ? .connectedThroughClaudeAppCache : .connectedThroughClaudeApp
        return snapshots.isEmpty ? nil : (.authenticated(snapshots), status)
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func performRefresh() async throws -> AccountUsageResult {
        guard let credentials = try await credentials.load() else { return .signedOut }
        if credentials.isExpired(at: now()) { throw LocalToolUsageError.credentialExpired }
        guard credentials.canReadUsage else { throw LocalToolUsageError.missingScope }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")

        let (status, body) = try await http.send(request)
        switch status {
        case 200..<300: break
        case 401: throw LocalToolUsageError.credentialExpired
        case 403: throw LocalToolUsageError.missingScope
        case 429: throw LocalToolUsageError.rateLimited
        default: throw LocalToolUsageError.http(status)
        }
        guard let response = JSONValue.parse(body), response.objectValue != nil else {
            throw LocalToolUsageError.invalidResponse
        }
        var snapshots = Self.snapshots(
            from: response,
            planType: credentials.subscriptionType ?? credentials.rateLimitTier,
            updatedAt: now()
        )
        // The sign-in's response doesn't list free resets; the Claude app's
        // own reading does.
        if let first = snapshots.first, first.availableResets.isEmpty {
            let local = localResetCredits(sameWeekAs: first.secondaryWindow?.resetAt)
            if !local.isEmpty { snapshots[0].attach(local) }
        }
        return .authenticated(snapshots)
    }

    /// The free resets the Claude app last read, only when they're for the
    /// same account: the same account shares one weekly reset, so another
    /// account's resets are never shown.
    private func localResetCredits(sameWeekAs weeklyReset: Date?) -> [ResetCredit] {
        guard let weeklyReset, let sample = claudeApp.latestSample() else { return [] }
        let localWeekly: Date?
        let credits: [ResetCredit]
        if let listed = sample.resetCredits, !listed.isEmpty {
            localWeekly = sample.resetCreditsWeeklyResetAt
            credits = listed
        } else if let cached = sample.cachedUsage {
            localWeekly = ClaudeAppUsageHistory.resetTimes(from: cached.payload).weekly
            credits = Self.resetCredits(from: cached.payload)
        } else {
            return []
        }
        guard let localWeekly, abs(localWeekly.timeIntervalSince(weeklyReset)) < 60 else { return [] }
        return credits
    }

    private func userAgent() -> String {
        if let cachedUserAgent { return cachedUserAgent }
        let value = "claude-code/\(userAgentVersion())"
        cachedUserAgent = value
        return value
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .claude)
    }

    // MARK: Decoding

    /// Maps the OAuth usage payload onto rail buckets.
    ///
    /// Newer payloads carry a `limits` array: the provider's own list of what
    /// gates the account, with a `kind` per entry. That list is authoritative
    /// when present. The session window and the all-models weekly window
    /// share one bucket so the rail shows them as inner and outer rings,
    /// matching the Codex layout; every other limit, such as a weekly limit
    /// scoped to one model, becomes its own bucket.
    ///
    /// Older payloads only have top-level windows (`five_hour`, `seven_day`,
    /// `seven_day_opus`, …), which are mapped the same way. Top-level keys
    /// without a window prefix are internal experiment names and are not
    /// shown.
    static func snapshots(from response: JSONValue, planType: String?, updatedAt: Date) -> [QuotaSnapshot] {
        guard let object = response.objectValue else { return [] }
        var buckets: [RateLimitBucket]
        if let limits = object["limits"]?.arrayValue, !limits.isEmpty {
            buckets = limitBuckets(from: limits, planType: planType)
        } else {
            buckets = windowBuckets(from: object, planType: planType)
        }
        if let extra = extraUsageBucket(from: object, planType: planType) {
            buckets.append(extra)
        }
        let credits = resetCredits(from: response)
        return buckets.enumerated().map { index, bucket in
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
            snapshot.toolID = .claude
            if index == 0 { snapshot.attach(credits) }
            return snapshot
        }
    }

    /// The free resets Claude offers, from its usage response's grants:
    /// each one's name, how many are left, what it refills and when it
    /// expires. usAIge only shows them; using one happens in Claude.
    static func resetCredits(from response: JSONValue) -> [ResetCredit] {
        guard let grants = response["cedar_ember"]?["grants"]?.arrayValue else { return [] }
        return grants.compactMap { grant in
            guard let id = grant["id"]?.stringValue, !id.isEmpty,
                  let left = grant["resets_left"]?.lenientNumber, left.isFinite, left >= 1 else { return nil }
            let clears = Set(grant["clears"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            // A grant for one model names it last in its id: "launch-2610-fable".
            let model = id.split(separator: "-").last.map(String.init)
                .flatMap { $0.allSatisfy(\.isLetter) && $0 != "reset" ? $0.capitalized : nil }
            let givesBackWeekly = grant["gives_back_weekly"]?.boolValue == true
            let name = model.map { "\($0) reset" }
                ?? (grant["type"]?.stringValue == "full" ? "Full reset" : grant["label"]?.stringValue ?? "Reset")
            var refills: [String] = []
            if clears.contains("five_hour") { refills.append("5-hour") }
            if clears.contains("seven_day") { refills.append("weekly") }
            let detail: String? = if let model, givesBackWeekly {
                "Refills your 5-hour limit and gives back what \(model) used this week."
            } else if !refills.isEmpty {
                "Refills your \(refills.joined(separator: " and ")) \(refills.count == 1 ? "limit" : "limits")."
            } else {
                grant["label"]?.stringValue
            }
            return ResetCredit(
                id: "claude-\(id)",
                title: name,
                expiresAt: LocalToolDates.parse(grant["ends_at"]?.stringValue),
                detail: detail,
                grantedAt: LocalToolDates.parse(grant["starts_at"]?.stringValue),
                count: Int(left),
                isUsable: grant["usable_now"]?.boolValue ?? true && grant["paused"]?.boolValue != true
            )
        }
    }

    /// History alone supplies percentages, with reset times only where an
    /// earlier response gave them for a window still running; nothing is
    /// estimated. A separately validated cache response carries the
    /// provider's timestamps and any model-scoped windows.
    static func snapshots(fromClaudeApp sample: ClaudeAppUsageSample, planType: String?) -> [QuotaSnapshot] {
        if let cached = sample.cachedUsage {
            return snapshots(from: cached.payload, planType: planType, updatedAt: cached.recordedAt)
        }
        let clamp = { (value: Double, reset: Date?) in
            Window(usedPercent: min(100, max(0, value)), resetsAt: reset?.timeIntervalSince1970)
        }
        guard let bucket = mainBucket(
            session: sample.sessionPercent.map { clamp($0, sample.sessionResetAt) },
            weekly: sample.weeklyPercent.map { clamp($0, sample.weeklyResetAt) },
            planType: planType
        ) else { return [] }
        var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: sample.recordedAt)
        snapshot.toolID = .claude
        snapshot.attach(sample.resetCredits ?? [])
        return [snapshot]
    }

    private static func limitBuckets(from limits: [JSONValue], planType: String?) -> [RateLimitBucket] {
        var session: Window?
        var weeklyAll: Window?
        var scoped: [RateLimitBucket] = []
        var usedIDs: Set<String> = [primaryBucketID]

        for limit in limits {
            guard let kind = limit["kind"]?.stringValue,
                  let percent = limit["percent"]?.lenientNumber else { continue }
            let window = Window(
                usedPercent: min(100, max(0, percent)),
                resetsAt: LocalToolDates.parse(limit["resets_at"]?.stringValue)?.timeIntervalSince1970
            )
            switch kind {
            case "session":
                if session == nil { session = window }
            case "weekly_all":
                if weeklyAll == nil { weeklyAll = window }
            default:
                let scope = limit["scope"]
                let model = scope?["model"]
                let surface = scope?["surface"]
                let scopeName = model?["display_name"]?.stringValue
                    ?? model?["id"]?.stringValue
                    ?? surface?["display_name"]?.stringValue
                    ?? surface?["id"]?.stringValue
                    ?? surface?.stringValue
                let name = scopeName ?? kind
                // Two limits that slug to the same id are still two limits.
                var id = "claude_\(slug(name))"
                var suffix = 2
                while !usedIDs.insert(id).inserted {
                    id = "claude_\(slug(name))_\(suffix)"
                    suffix += 1
                }
                let minutes: Int? = switch limit["group"]?.stringValue {
                case "session": 300
                case "daily": 1_440
                case "weekly": 10_080
                case "monthly": 43_200
                default: nil
                }
                scoped.append(RateLimitBucket(
                    limitID: id,
                    limitName: model?["display_name"]?.stringValue ?? surface?["display_name"]?.stringValue ?? LocalToolText.humanized(name),
                    usedPercent: window.usedPercent,
                    windowDurationMinutes: minutes,
                    resetsAt: window.resetsAt,
                    planType: planType
                ))
            }
        }

        var buckets: [RateLimitBucket] = []
        if let bucket = mainBucket(session: session, weekly: weeklyAll, planType: planType) {
            buckets.append(bucket)
        }
        buckets.append(contentsOf: scoped)
        return buckets
    }

    private static func windowBuckets(from object: [String: JSONValue], planType: String?) -> [RateLimitBucket] {
        var buckets: [RateLimitBucket] = []
        if let bucket = mainBucket(
            session: window(object["five_hour"]),
            weekly: window(object["seven_day"]),
            planType: planType
        ) {
            buckets.append(bucket)
        }

        var consumed = mainWindowKeys
        for known in knownWindows {
            consumed.insert(known.key)
            guard let value = window(object[known.key]) else { continue }
            buckets.append(RateLimitBucket(
                limitID: known.id,
                limitName: known.name,
                usedPercent: value.usedPercent,
                windowDurationMinutes: 10_080,
                resetsAt: value.resetsAt,
                planType: planType
            ))
        }

        for key in object.keys.sorted() where !consumed.contains(key) {
            guard let prefix = ["seven_day_", "five_hour_"].first(where: { key.hasPrefix($0) }),
                  let value = window(object[key]) else { continue }
            let name = String(key.dropFirst(prefix.count))
            buckets.append(RateLimitBucket(
                limitID: "claude_\(name)",
                limitName: LocalToolText.humanized(name),
                usedPercent: value.usedPercent,
                windowDurationMinutes: prefix == "seven_day_" ? 10_080 : 300,
                resetsAt: value.resetsAt,
                planType: planType
            ))
        }
        return buckets
    }

    private static func mainBucket(session: Window?, weekly: Window?, planType: String?) -> RateLimitBucket? {
        guard let primary = session ?? weekly else { return nil }
        let secondary = session != nil ? weekly : nil
        return RateLimitBucket(
            limitID: primaryBucketID,
            limitName: "All models",
            usedPercent: primary.usedPercent,
            windowDurationMinutes: session != nil ? 300 : 10_080,
            resetsAt: primary.resetsAt,
            planType: planType,
            secondaryUsedPercent: secondary?.usedPercent,
            secondaryWindowDurationMinutes: secondary.map { _ in 10_080 },
            secondaryResetsAt: secondary?.resetsAt
        )
    }

    private static func extraUsageBucket(from object: [String: JSONValue], planType: String?) -> RateLimitBucket? {
        guard let extra = object["extra_usage"], extra["is_enabled"]?.boolValue == true else { return nil }
        let used: Double? = extra["utilization"]?.lenientNumber ?? {
            guard let usedCredits = extra["used_credits"]?.lenientNumber,
                  let limit = extra["monthly_limit"]?.lenientNumber, limit > 0 else { return nil }
            return usedCredits / limit * 100
        }()
        guard let used else { return nil }
        return RateLimitBucket(
            limitID: "claude_extra",
            limitName: "Extra usage",
            usedPercent: used,
            windowDurationMinutes: 43_200,
            resetsAt: LocalToolDates.parse(extra["resets_at"]?.stringValue)?.timeIntervalSince1970,
            planType: planType
        )
    }

    /// `Fable` → `fable`, `claude-fable-5-1` → `fable_5_1`, `Claude Code` → `code`.
    private static func slug(_ name: String) -> String {
        let parts = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let trimmed = parts.first == "claude" && parts.count > 1 ? Array(parts.dropFirst()) : parts
        return trimmed.isEmpty ? "limit" : trimmed.joined(separator: "_")
    }

    private struct Window {
        let usedPercent: Double
        let resetsAt: TimeInterval?
    }

    private static func window(_ value: JSONValue?) -> Window? {
        guard let value, value.objectValue != nil,
              let utilization = value["utilization"]?.lenientNumber else { return nil }
        return Window(
            usedPercent: min(100, max(0, utilization)),
            resetsAt: LocalToolDates.parse(value["resets_at"]?.stringValue)?.timeIntervalSince1970
        )
    }
}
