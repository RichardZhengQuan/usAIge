/// Reads the key saved by the OpenCode CLI and requests Go limits from the OpenCode usage API.
/// The endpoint was learned from ClaudeBar's OpenCode Go provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Darwin
import Foundation

protocol OpenCodeGoCredentialSource: Sendable {
    func load() -> (isInstalled: Bool, key: String?)
}

struct OpenCodeGoAuthFile: OpenCodeGoCredentialSource {
    private let directory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        } ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        directory = dataHome.appendingPathComponent("opencode", isDirectory: true)
    }

    func load() -> (isInstalled: Bool, key: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return (false, nil) }

        let url = directory.appendingPathComponent("auth.json")
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
              let auth = JSONValue.parse(data) else { return nil }
        return key(auth["opencode-go"]) ?? key(auth["opencode"])
    }

    private static func key(_ entry: JSONValue?) -> String? {
        guard let key = entry?["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return key
    }
}

actor OpenCodeGoUsageProvider: CodexUsageProviding {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private let credentials: any OpenCodeGoCredentialSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentials: (any OpenCodeGoCredentialSource)? = nil,
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials ?? OpenCodeGoAuthFile(homeDirectory: homeDirectory, environment: environment)
        self.http = http
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        let auth = credentials.load()
        guard auth.isInstalled, let key = auth.key else {
            await statusRegistry?.report(auth.isInstalled ? .signedOut : .notInstalled, for: .openCodeGo)
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
            case 401: throw LocalToolUsageError.credentialExpired
            case 403:
                await statusRegistry?.report(.failed("This OpenCode key has no Go subscription."), for: .openCodeGo)
                return .authenticated([])
            case 429: throw LocalToolUsageError.rateLimited
            default: throw LocalToolUsageError.http(status)
            }
            let updatedAt = now()
            let snapshots = try OpenCodeGoUsageParser.buckets(from: body).map { bucket in
                var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                snapshot.toolID = .openCodeGo
                return snapshot
            }
            await statusRegistry?.report(.connected, for: .openCodeGo)
            return .authenticated(snapshots)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = error as? LocalToolUsageError
                ?? ((error as? URLError)?.code == .timedOut ? .timedOut : .invalidResponse)
            await statusRegistry?.report(LocalToolStatus(error: failure), for: .openCodeGo)
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private enum OpenCodeGoUsageParser {
    private struct Window {
        let percent: Double
        let reset: TimeInterval?

        init?(_ value: JSONValue?) {
            guard let percent = value?["percent"]?.lenientNumber else { return nil }
            self.percent = value?["status"]?.stringValue == "rate-limited" ? 100 : min(100, max(0, percent))
            reset = LocalToolDates.parse(value?["resetsAt"]?.stringValue)?.timeIntervalSince1970
        }
    }

    static func buckets(from body: Data) throws -> [RateLimitBucket] {
        guard let usage = JSONValue.parse(body)?["usage"], usage.objectValue != nil else {
            throw LocalToolUsageError.invalidResponse
        }
        let rolling = Window(usage["rolling"])
        let weekly = Window(usage["weekly"])
        var buckets: [RateLimitBucket] = []
        if let primary = rolling ?? weekly {
            let secondary = rolling == nil ? nil : weekly
            buckets.append(RateLimitBucket(
                limitID: AIToolID.openCodeGo.rawValue,
                limitName: "Plan limits",
                usedPercent: primary.percent,
                windowDurationMinutes: rolling == nil ? 10_080 : 300,
                resetsAt: primary.reset,
                planType: nil,
                secondaryUsedPercent: secondary?.percent,
                secondaryWindowDurationMinutes: secondary == nil ? nil : 10_080,
                secondaryResetsAt: secondary?.reset
            ))
        }
        if let monthly = Window(usage["monthly"]) {
            buckets.append(RateLimitBucket(
                limitID: "openCodeGo_monthly",
                limitName: "Monthly",
                usedPercent: monthly.percent,
                windowDurationMinutes: nil,
                resetsAt: monthly.reset,
                planType: nil
            ))
        }
        guard !buckets.isEmpty else { throw LocalToolUsageError.invalidResponse }
        return buckets
    }
}
