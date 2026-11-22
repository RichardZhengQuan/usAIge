/// Reads Cline's saved CLI login and requests the plan's limits from the Cline API.
/// The endpoint was learned from ClaudeBar's Cline provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Darwin
import Foundation

protocol ClineCredentialSource: Sendable {
    func load() -> (isInstalled: Bool, key: String?)
}

struct ClineAuthFile: ClineCredentialSource {
    private let directory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".cline", isDirectory: true)
    }

    func load() -> (isInstalled: Bool, key: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return (false, nil) }

        let url = directory.appendingPathComponent("data/settings/providers.json")
        return (true, Self.readKey(at: url))
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
              let settings = JSONValue.parse(data)?.value(at: ["providers", "cline", "settings"]) else { return nil }

        let auth = settings["auth"]
        if let token = key(auth?["accessToken"]), token != "workos:" {
            return token.hasPrefix("workos:") ? token : "workos:" + token
        }
        return key(settings["apiKey"]) ?? key(auth?["apiKey"])
    }

    private static func key(_ value: JSONValue?) -> String? {
        guard let key = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return key
    }
}

actor ClineUsageProvider: CodexUsageProviding {
    static let usageURL = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!

    private let credentials: any ClineCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        credentials: (any ClineCredentialSource)? = nil,
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials ?? ClineAuthFile(homeDirectory: homeDirectory)
        self.http = http
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        let auth = credentials.load()
        guard auth.isInstalled, let key = auth.key else {
            await statusRegistry?.report(auth.isInstalled ? .signedOut : .notInstalled, for: .cline)
            return .signedOut
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsAIgeUserAgent.value, forHTTPHeaderField: "User-Agent")

        do {
            try Task.checkCancellation()
            let (status, body) = try await http.send(request)
            try Task.checkCancellation()
            switch status {
            case 200..<300: break
            case 401, 403: throw LocalToolUsageError.credentialExpired
            case 429: throw LocalToolUsageError.rateLimited
            default: throw LocalToolUsageError.http(status)
            }
            let updatedAt = now()
            let snapshots = try ClineUsageParser.buckets(from: body).map { bucket in
                var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                snapshot.toolID = .cline
                return snapshot
            }
            let connection: LocalToolStatus = snapshots.isEmpty
                ? .failed("This Cline account has no plan limits.")
                : .connected
            await statusRegistry?.report(connection, for: .cline)
            return .authenticated(snapshots)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = error as? LocalToolUsageError
                ?? ((error as? URLError)?.code == .timedOut ? .timedOut : .invalidResponse)
            await statusRegistry?.report(LocalToolStatus(error: failure), for: .cline)
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private enum ClineUsageParser {
    private enum Kind: String {
        case fiveHour = "five_hour"
        case weekly
        case monthly
    }

    private struct Window {
        let percent: Double
        let reset: TimeInterval?
    }

    static func buckets(from body: Data) throws -> [RateLimitBucket] {
        guard let root = JSONValue.parse(body), root.objectValue != nil else {
            throw LocalToolUsageError.invalidResponse
        }
        if root["success"]?.boolValue == false { return [] }
        guard let limits = root.value(at: ["data", "limits"])?.arrayValue else {
            throw LocalToolUsageError.invalidResponse
        }
        var windows: [Kind: Window] = [:]
        var hasMalformedLimit = false
        for limit in limits {
            guard let type = limit["type"]?.stringValue else {
                hasMalformedLimit = true
                continue
            }
            guard let kind = Kind(rawValue: type), windows[kind] == nil else { continue }
            guard let percent = limit["percentUsed"]?.lenientNumber else {
                hasMalformedLimit = true
                continue
            }
            windows[kind] = Window(
                percent: min(100, max(0, percent)),
                reset: LocalToolDates.parse(limit["resetsAt"]?.stringValue)?.timeIntervalSince1970
            )
        }
        guard !windows.isEmpty || !hasMalformedLimit else { throw LocalToolUsageError.invalidResponse }

        var buckets: [RateLimitBucket] = []
        let fiveHour = windows[.fiveHour]
        let weekly = windows[.weekly]
        if let primary = fiveHour ?? weekly {
            let secondary = fiveHour == nil ? nil : weekly
            buckets.append(RateLimitBucket(
                limitID: AIToolID.cline.rawValue,
                limitName: "Plan limits",
                usedPercent: primary.percent,
                windowDurationMinutes: fiveHour == nil ? 10_080 : 300,
                resetsAt: primary.reset,
                planType: nil,
                secondaryUsedPercent: secondary?.percent,
                secondaryWindowDurationMinutes: secondary == nil ? nil : 10_080,
                secondaryResetsAt: secondary?.reset
            ))
        }
        if let monthly = windows[.monthly] {
            buckets.append(RateLimitBucket(
                limitID: "cline_monthly",
                limitName: "Monthly",
                usedPercent: monthly.percent,
                windowDurationMinutes: nil,
                resetsAt: monthly.reset,
                planType: nil
            ))
        }
        return buckets
    }
}
