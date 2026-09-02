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
        guard let root = JSONValue.parse(data),
              let oauth = root["claudeAiOauth"]?.objectValue else {
            throw LocalToolUsageError.invalidResponse
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
    func load() throws -> ClaudeCredentials?
}

/// Reads the sign-in Claude Code stores in the login Keychain (service
/// `Claude Code-credentials`), falling back to `~/.claude/.credentials.json`
/// for installs that predate Keychain storage. Read-only: the token is used
/// in memory for one request and never written anywhere by usAIge.
struct ClaudeCodeCredentialStore: ClaudeCredentialSource {
    static let keychainService = "Claude Code-credentials"

    private let credentialsFileURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        credentialsFileURL = homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    func load() throws -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return nil }
            return try ClaudeCredentials.parse(data)
        case errSecItemNotFound:
            break
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw LocalToolUsageError.keychainAccessDenied
        default:
            throw LocalToolUsageError.keychain(status)
        }

        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else { return nil }
        let data = try Data(contentsOf: credentialsFileURL)
        return try ClaudeCredentials.parse(data)
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

actor ClaudeUsageProvider: CodexUsageProviding {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let primaryBucketID = "claude"

    private static let knownWindows: [(key: String, id: String, name: String)] = [
        ("seven_day_opus", "claude_opus", "Opus"),
        ("seven_day_sonnet", "claude_sonnet", "Sonnet"),
        ("seven_day_oauth_apps", "claude_oauth_apps", "OAuth apps"),
    ]
    private static let mainWindowKeys: Set<String> = ["five_hour", "seven_day"]

    private let credentials: any ClaudeCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let userAgentVersion: @Sendable () -> String
    private let isEnabled: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private var cachedUserAgent: String?

    /// Reading the Claude Code sign-in shows a macOS Keychain prompt, so the
    /// provider stays inert until the user turns Claude on in Settings.
    init(
        credentials: any ClaudeCredentialSource = ClaudeCodeCredentialStore(),
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        userAgentVersion: @escaping @Sendable () -> String = { ClaudeCodeVersion.resolve() },
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.http = http
        self.statusRegistry = statusRegistry
        self.userAgentVersion = userAgentVersion
        self.isEnabled = isEnabled
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        guard await isEnabled() else {
            await report(.disabled)
            return .signedOut
        }
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
        guard let credentials = try credentials.load() else { return .signedOut }
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
        let snapshots = Self.snapshots(
            from: response,
            planType: credentials.subscriptionType ?? credentials.rateLimitTier,
            updatedAt: now()
        )
        return .authenticated(snapshots)
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

    /// Maps the OAuth usage payload onto rail buckets. The session window
    /// (five hours) and the all-models weekly window share one bucket so the
    /// rail shows them as inner and outer rings, matching the Codex layout.
    /// Every other window with a numeric utilization becomes its own bucket,
    /// so new provider windows appear without a code change.
    static func snapshots(from response: JSONValue, planType: String?, updatedAt: Date) -> [QuotaSnapshot] {
        guard let object = response.objectValue else { return [] }
        var buckets: [RateLimitBucket] = []

        let fiveHour = window(object["five_hour"])
        let sevenDay = window(object["seven_day"])
        if let primary = fiveHour ?? sevenDay {
            let secondary = fiveHour != nil ? sevenDay : nil
            buckets.append(RateLimitBucket(
                limitID: primaryBucketID,
                limitName: "All models",
                usedPercent: primary.usedPercent,
                windowDurationMinutes: fiveHour != nil ? 300 : 10_080,
                resetsAt: primary.resetsAt,
                planType: planType,
                secondaryUsedPercent: secondary?.usedPercent,
                secondaryWindowDurationMinutes: secondary.map { _ in 10_080 },
                secondaryResetsAt: secondary?.resetsAt
            ))
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

        for key in object.keys.sorted() where !consumed.contains(key) && key != "extra_usage" {
            guard let value = window(object[key]) else { continue }
            var name = key
            for prefix in ["seven_day_", "five_hour_", "claude_"] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            buckets.append(RateLimitBucket(
                limitID: "claude_\(name)",
                limitName: LocalToolText.humanized(name),
                usedPercent: value.usedPercent,
                windowDurationMinutes: key.hasPrefix("seven_day") ? 10_080 : (key.hasPrefix("five_hour") ? 300 : nil),
                resetsAt: value.resetsAt,
                planType: planType
            ))
        }

        if let extra = object["extra_usage"], extra["is_enabled"]?.boolValue == true {
            let used: Double? = extra["utilization"]?.lenientNumber ?? {
                guard let usedCredits = extra["used_credits"]?.lenientNumber,
                      let limit = extra["monthly_limit"]?.lenientNumber, limit > 0 else { return nil }
                return usedCredits / limit * 100
            }()
            if let used {
                buckets.append(RateLimitBucket(
                    limitID: "claude_extra",
                    limitName: "Extra usage",
                    usedPercent: used,
                    windowDurationMinutes: 43_200,
                    resetsAt: LocalToolDates.parse(extra["resets_at"]?.stringValue)?.timeIntervalSince1970,
                    planType: planType
                ))
            }
        }

        return buckets.map { bucket in
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
            snapshot.toolID = .claude
            return snapshot
        }
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
