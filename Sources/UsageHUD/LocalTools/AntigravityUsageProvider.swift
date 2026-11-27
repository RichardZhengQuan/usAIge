/// Reads quota pools and legacy model limits from the local language server
/// of the running Antigravity app or `agy` CLI.
/// The language-server endpoint was learned from ClaudeBar's Antigravity provider
/// (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import CryptoKit
import Foundation

enum AntigravityServerLocation: Equatable, Sendable {
    case notRunning
    case missingCSRFToken
    case running(csrfToken: String, httpsPorts: [UInt16], extensionPort: UInt16?)
}

protocol AntigravityServerLocating: Sendable {
    func locate() async throws -> AntigravityServerLocation
}

struct AntigravityProcessLocator: AntigravityServerLocating {
    private let commands: any LocalCommandRunning

    init(commands: any LocalCommandRunning = LocalCommandRunner(environment: ["PATH": "/usr/bin:/usr/sbin"])) {
        self.commands = commands
    }

    func locate() async throws -> AntigravityServerLocation {
        // On macOS, -l with -f prints the PID and the full arguments.
        guard let processes = try await commands.run("pgrep", arguments: ["-lf", "language_server|agy"], timeout: 3)
        else { throw LocalToolUsageError.invalidResponse }
        if processes.exitCode == 1 { return .notRunning }
        guard processes.exitCode == 0 else { throw LocalToolUsageError.invalidResponse }

        let candidates = processes.text.split(whereSeparator: \.isNewline).compactMap(Self.candidate)
        guard !candidates.isEmpty else { return .notRunning }
        guard let process = candidates.filter({ $0.csrfToken != nil }).min(by: { $0.pid < $1.pid }),
              let token = process.csrfToken else { return .missingCSRFToken }

        let listeners = try await commands.run(
            "lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(process.pid)], timeout: 3
        )
        guard let listeners, listeners.exitCode == 0 || listeners.exitCode == 1 else {
            throw LocalToolUsageError.invalidResponse
        }
        return .running(
            csrfToken: token, httpsPorts: Self.listeningPorts(in: listeners.text), extensionPort: process.extensionPort
        )
    }

    private struct Candidate {
        let pid: Int32
        let csrfToken: String?
        let extensionPort: UInt16?
    }

    private static func candidate(in line: Substring) -> Candidate? {
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else { return nil }
        let command = fields[1].drop(while: \.isWhitespace)
        // Path components can contain spaces. A space immediately before a slash
        // separates an argument from the executable's path in pgrep's output.
        let executablePattern = #"^/?(?:[^/\s](?:[^/]*[^/\s])?/)*(?:agy|language_server(?:_macos(?:_arm)?)?)(?=\s|$)"#
        guard let executable = command.range(of: executablePattern, options: .regularExpression),
              !command[executable].contains(" --") else { return nil }
        let path = command[executable]
        let arguments = command[executable.upperBound...]
        let dataDirectory = value(of: "app_data_dir", in: arguments)
        guard path.split(separator: "/").last == "agy" || isAntigravityPath(path) ||
              dataDirectory.map(isAntigravityPath) == true else { return nil }

        let token = value(of: "csrf_token", in: arguments)?.split(whereSeparator: \.isWhitespace).first
        let csrfToken = token.flatMap { text in
            text.utf8.allSatisfy { (0x21...0x7E).contains($0) } ? String(text) : nil
        }
        let port = value(of: "extension_server_port", in: arguments)?.split(whereSeparator: \.isWhitespace).first
        return Candidate(pid: pid, csrfToken: csrfToken, extensionPort: port.flatMap(parsePort))
    }

    private static func isAntigravityPath(_ path: Substring) -> Bool {
        path.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            .lowercased().split(separator: "/")
            .contains { $0 == "antigravity" || $0 == ".antigravity" || $0 == "antigravity.app" }
    }

    /// pgrep flattens arguments, so a data directory may contain spaces up
    /// to the next flag. Token and port callers take only the first word.
    private static func value(of flag: String, in arguments: Substring) -> Substring? {
        guard let match = arguments.range(of: "(?:^|[ \\t])--\(flag)(?:=|[ \\t]+)", options: .regularExpression)
        else { return nil }
        let tail = arguments[match.upperBound...]
        guard !tail.isEmpty, !tail.hasPrefix("--") else { return nil }
        let nextFlag = tail.range(of: #"[ \t]+--"#, options: .regularExpression)
        return tail[..<(nextFlag?.lowerBound ?? tail.endIndex)]
    }

    private static func parsePort(_ text: Substring) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }

    private static func listeningPorts(in output: String) -> [UInt16] {
        var seen: Set<UInt16> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns.last == "(LISTEN)",
                  let separator = columns[columns.count - 2].lastIndex(of: ":") else { return nil }
            let address = columns[columns.count - 2]
            let text = address[address.index(after: separator)...]
            guard let port = parsePort(text), seen.insert(port).inserted else { return nil }
            return port
        }
    }
}

/// Antigravity serves its local API with a self-signed certificate. Both
/// the URL and the trust challenge must name the IPv4 loopback address.
final class AntigravityLoopbackHTTPClient: UsageHTTPClient {
    static let host = "127.0.0.1"
    private let session: URLSession

    init(requestTimeout: TimeInterval = 8) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: AntigravityLoopbackDelegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func acceptsServerTrust(host: String, authenticationMethod: String) -> Bool {
        host == Self.host && authenticationMethod == NSURLAuthenticationMethodServerTrust
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        guard let url = request.url, url.host == Self.host, url.scheme == "https" || url.scheme == "http" else {
            throw LocalToolUsageError.invalidResponse
        }
        let maximumBytes = URLSessionUsageHTTPClient.maximumBodyBytes
        guard #available(macOS 12.0, *) else {
            let (body, response) = try await session.data(for: request)
            guard body.count <= maximumBytes, let response = response as? HTTPURLResponse else {
                throw LocalToolUsageError.invalidResponse
            }
            return (response.statusCode, body)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumBytes) else {
            bytes.task.cancel()
            throw LocalToolUsageError.invalidResponse
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBytes else {
                bytes.task.cancel()
                throw LocalToolUsageError.invalidResponse
            }
            body.append(byte)
        }
        return (response.statusCode, body)
    }

    private final class AntigravityLoopbackDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            if !space.isProxy(), AntigravityLoopbackHTTPClient.acceptsServerTrust(
                host: space.host, authenticationMethod: space.authenticationMethod
            ), let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

enum AntigravityQuotaParser {
    static func summary(from document: JSONValue) -> [RateLimitBucket]? {
        let wrapped = document["response"]
        let report = wrapped?["groups"]?.arrayValue != nil ? wrapped ?? document : document
        guard let groups = report["groups"]?.arrayValue else { return nil }
        let plan = planName(report["planName"])

        var windows: [String: Window] = [:]
        for group in groups {
            for bucket in group["buckets"]?.arrayValue ?? [] {
                guard let id = bucket["bucketId"]?.stringValue, windows[id] == nil else { continue }
                switch id {
                case "gemini-5h", "3p-5h": windows[id] = Window(bucket, minutes: 300)
                case "gemini-weekly", "3p-weekly", "gemini-argon-wtu-weekly":
                    windows[id] = Window(bucket, minutes: 10_080)
                default: break
                }
            }
        }

        return [
            bucket("antigravity", name: "Gemini", short: windows["gemini-5h"], weekly: windows["gemini-weekly"], plan: plan),
            bucket("antigravity_others", name: "Claude & others", short: windows["3p-5h"], weekly: windows["3p-weekly"], plan: plan),
            bucket("antigravity_argon", name: "Gemini Argon", short: nil, weekly: windows["gemini-argon-wtu-weekly"], plan: plan),
        ].compactMap { $0 }
    }

    static func legacyModels(from document: JSONValue) -> [RateLimitBucket]? {
        let status = document["userStatus"] ?? document.value(at: ["response", "userStatus"])
        guard let models = status?.value(at: ["cascadeModelConfigData", "clientModelConfigs"])?.arrayValue
        else { return nil }
        let plan = planName(status?.value(at: ["planStatus", "planInfo", "planName"]))

        var seen: Set<String> = []
        return models.compactMap { model in
            guard let name = model["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, let info = model["quotaInfo"], let window = Window(info, minutes: 300),
                  seen.insert(name).inserted else { return nil }
            // The legacy response identifies models by label. Preserve distinct
            // labels even when a name with spaces or punctuation would slug the same.
            let digest = SHA256.hash(data: Data(name.utf8))
            let id = "antigravity_model_" + digest.map { String(format: "%02x", $0) }.joined()
            return bucket(id, name: name, short: window, plan: plan)
        }
    }

    private static func planName(_ value: JSONValue?) -> String? {
        guard let name = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private static func bucket(
        _ id: String, name: String, short: Window?, weekly: Window? = nil, plan: String?
    ) -> RateLimitBucket? {
        guard let primary = short ?? weekly else { return nil }
        let secondary = short != nil ? weekly : nil
        return RateLimitBucket(
            limitID: id,
            limitName: name,
            usedPercent: primary.usedPercent,
            windowDurationMinutes: primary.minutes,
            resetsAt: primary.resetsAt,
            planType: plan,
            secondaryUsedPercent: secondary?.usedPercent,
            secondaryWindowDurationMinutes: secondary?.minutes,
            secondaryResetsAt: secondary?.resetsAt
        )
    }

    private struct Window {
        let usedPercent: Double
        let minutes: Int
        let resetsAt: TimeInterval?

        init?(_ quota: JSONValue, minutes: Int) {
            guard let remaining = quota["remainingFraction"]?.lenientNumber ?? quota["remaining_fraction"]?.lenientNumber
            else { return nil }
            usedPercent = (1 - min(1, max(0, remaining))) * 100
            self.minutes = minutes
            resetsAt = (LocalToolDates.parseFlexible(quota["resetTime"])
                ?? LocalToolDates.parseFlexible(quota["reset_time"]))?.timeIntervalSince1970
        }
    }
}

actor AntigravityUsageProvider: CodexUsageProviding {
    private let locator: any AntigravityServerLocating
    private let http: any UsageHTTPClient
    private let homeDirectory: URL
    private let isOptedIn: @Sendable () -> Bool
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        locator: any AntigravityServerLocating = AntigravityProcessLocator(),
        http: any UsageHTTPClient = AntigravityLoopbackHTTPClient(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isOptedIn: @escaping @Sendable () -> Bool = { LocalToolOptIn.isEnabled(.antigravity) },
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.locator = locator
        self.http = http
        self.homeDirectory = homeDirectory
        self.isOptedIn = isOptedIn
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            guard isOptedIn() else { return await reportOptInRequired() }
            let location = try await locator.locate()
            guard isOptedIn() else { return await reportOptInRequired() }
            switch location {
            case .notRunning:
                await report(looksInstalled() ? .signedOut : .notInstalled)
                return .signedOut
            case .missingCSRFToken:
                await report(.failed("Restart Antigravity so usAIge can read its limits."))
                return .signedOut
            case let .running(token, httpsPorts, extensionPort):
                let buckets = try await read(httpsPorts: httpsPorts, extensionPort: extensionPort, token: token)
                guard isOptedIn() else { return await reportOptInRequired() }
                let updatedAt = now()
                let snapshots = buckets.map { bucket in
                    var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                    snapshot.toolID = .antigravity
                    return snapshot
                }
                await report(.connected)
                return .authenticated(snapshots)
            }
        } catch {
            guard isOptedIn() else { return await reportOptInRequired() }
            let failure: any Error = error is CancellationError || Task.isCancelled
                ? CancellationError()
                : (error as? LocalToolUsageError ?? .invalidResponse)
            await report(LocalToolStatus(error: failure))
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func looksInstalled() -> Bool {
        ["Library/Application Support/Antigravity", ".gemini/antigravity"].contains { path in
            FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(path).path)
        }
    }

    private func read(httpsPorts: [UInt16], extensionPort: UInt16?, token: String) async throws -> [RateLimitBucket] {
        var endpoints = httpsPorts.map { (scheme: "https", port: $0) }
        if let extensionPort { endpoints.append((scheme: "http", port: extensionPort)) }

        var failure = LocalToolUsageError.invalidResponse
        for (scheme, port) in endpoints {
            try Task.checkCancellation()
            do {
                return try await read(scheme: scheme, port: port, token: token)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let usageError = error as? LocalToolUsageError
                if usageError == .credentialExpired || usageError == .rateLimited { throw error }
                failure = usageError == .timedOut || (error as? URLError)?.code == .timedOut
                    ? .timedOut : .invalidResponse
            }
        }
        throw failure
    }

    private func read(scheme: String, port: UInt16, token: String) async throws -> [RateLimitBucket] {
        let (status, body) = try await send("RetrieveUserQuotaSummary", scheme: scheme, port: port, token: token)
        switch status {
        case 200..<300:
            guard let response = JSONValue.parse(body), response.objectValue != nil
            else { throw LocalToolUsageError.invalidResponse }
            if let buckets = AntigravityQuotaParser.summary(from: response) { return buckets }
        case 404, 501:
            break
        default:
            throw LocalToolUsageError.invalidResponse
        }

        let (legacyStatus, legacyBody) = try await send("GetUserStatus", scheme: scheme, port: port, token: token)
        guard (200..<300).contains(legacyStatus), let response = JSONValue.parse(legacyBody),
              let buckets = AntigravityQuotaParser.legacyModels(from: response) else {
            throw LocalToolUsageError.invalidResponse
        }
        return buckets
    }

    private func send(_ method: String, scheme: String, port: UInt16, token: String) async throws -> (Int, Data) {
        // Consent can change before a fallback request on another port or method.
        guard isOptedIn() else { throw CancellationError() }
        let service = "exa.language_server_pb.LanguageServerService"
        guard let url = URL(string: "\(scheme)://\(AntigravityLoopbackHTTPClient.host):\(port)/\(service)/\(method)")
        else { throw LocalToolUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UsAIgeUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8)

        let response = try await http.send(request)
        switch response.status {
        case 401: throw LocalToolUsageError.credentialExpired
        case 429: throw LocalToolUsageError.rateLimited
        default: return response
        }
    }

    private func reportOptInRequired() async -> AccountUsageResult {
        await report(.optInRequired)
        return .signedOut
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .antigravity)
    }
}
