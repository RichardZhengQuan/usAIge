import Foundation

protocol RemoteDataLoading: Sendable {
    func data(for request: URLRequest, maxBytes: Int) async throws -> RemoteHTTPPayload
}

struct RemoteHTTPPayload: Sendable {
    let data: Data
    let statusCode: Int
}

struct URLSessionRemoteLoader: RemoteDataLoading {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest, maxBytes: Int) async throws -> RemoteHTTPPayload {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteUsageError.invalidResponse }
        var data = Data()
        data.reserveCapacity(min(maxBytes, http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0))
        for try await byte in bytes {
            guard data.count < maxBytes else { throw RemoteUsageError.responseTooLarge }
            data.append(byte)
        }
        return RemoteHTTPPayload(data: data, statusCode: http.statusCode)
    }
}

struct RemoteQuotaResponse: Decodable, Sendable {
    let limits: [RemoteQuotaLimit]
}

struct RemoteQuotaLimit: Decodable, Sendable {
    let id: String
    let name: String?
    let planType: String?
    let primary: RemoteQuotaWindow?
    let secondary: RemoteQuotaWindow?
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?

    var resolvedPrimary: RemoteQuotaWindow? {
        if let primary { return primary }
        guard usedPercent != nil || remainingPercent != nil else { return nil }
        return RemoteQuotaWindow(
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt
        )
    }
}

struct RemoteQuotaWindow: Decodable, Sendable {
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?

    init(
        usedPercent: Double?,
        remainingPercent: Double?,
        windowDurationMinutes: Int?,
        resetsAt: TimeInterval?
    ) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    var resolvedUsedPercent: Double? {
        usedPercent ?? remainingPercent.map { 100 - $0 }
    }
}

actor RemoteUsageProvider: CodexUsageProviding {
    typealias Configuration = @MainActor @Sendable () -> [RemoteAITool]

    private let configuration: Configuration
    private let credentials: any RemoteCredentialStoring
    private let loader: any RemoteDataLoading
    private let now: @Sendable () -> Date

    init(
        configuration: @escaping Configuration,
        credentials: any RemoteCredentialStoring,
        loader: any RemoteDataLoading = URLSessionRemoteLoader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.loader = loader
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        let tools = await configuration().filter(\.isEnabled)
        guard !tools.isEmpty else { throw RemoteUsageError.noSources }

        var snapshots: [QuotaSnapshot] = []
        var firstError: Error?
        var successfulRequests = 0
        await withTaskGroup(of: Result<[QuotaSnapshot], Error>.self) { group in
            for tool in tools {
                group.addTask { [loader, credentials, now] in
                    do {
                        return .success(try await Self.fetch(
                            tool: tool,
                            credentials: credentials,
                            loader: loader,
                            updatedAt: now()
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(values):
                    successfulRequests += 1
                    snapshots.append(contentsOf: values)
                case let .failure(error): firstError = firstError ?? error
                }
            }
        }

        if successfulRequests == 0, let firstError { throw firstError }
        return .authenticated(snapshots.sorted { $0.id < $1.id })
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { _ in }
    }

    func stop() async {}

    private static func fetch(
        tool: RemoteAITool,
        credentials: any RemoteCredentialStoring,
        loader: any RemoteDataLoading,
        updatedAt: Date
    ) async throws -> [QuotaSnapshot] {
        try validate(endpoint: tool.endpoint)
        try validate(toolID: tool.id)
        var request = URLRequest(url: tool.endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("usAIge/0.1.12", forHTTPHeaderField: "User-Agent")
        if let token = try credentials.token(for: tool.id), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let finalizedRequest = request
        let payload = try await withThrowingTaskGroup(of: RemoteHTTPPayload.self) { group in
            group.addTask { try await loader.data(for: finalizedRequest, maxBytes: 1_048_576) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw RemoteUsageError.requestTimedOut
            }
            guard let first = try await group.next() else { throw RemoteUsageError.invalidResponse }
            group.cancelAll()
            return first
        }
        guard (200..<300).contains(payload.statusCode) else {
            throw RemoteUsageError.httpStatus(payload.statusCode)
        }
        let response = try JSONDecoder().decode(RemoteQuotaResponse.self, from: payload.data)
        guard response.limits.count <= 100 else { throw RemoteUsageError.tooManyLimits }
        var seenIDs: Set<String> = []
        return response.limits.compactMap { limit in
            guard !limit.id.isEmpty,
                  seenIDs.insert(limit.id).inserted,
                  let primary = limit.resolvedPrimary,
                  let used = primary.resolvedUsedPercent else { return nil }
            let secondaryUsed = limit.secondary?.resolvedUsedPercent
            var snapshot = QuotaSnapshot.make(
                from: RateLimitBucket(
                    limitID: "\(tool.id.rawValue):\(limit.id)",
                    limitName: limit.name,
                    usedPercent: used,
                    windowDurationMinutes: primary.windowDurationMinutes,
                    resetsAt: primary.resetsAt,
                    planType: limit.planType,
                    secondaryUsedPercent: secondaryUsed,
                    secondaryWindowDurationMinutes: limit.secondary?.windowDurationMinutes,
                    secondaryResetsAt: limit.secondary?.resetsAt
                ),
                updatedAt: updatedAt
            )
            snapshot.toolID = tool.id
            snapshot.toolName = tool.name
            snapshot.toolWebURL = tool.webURL
            snapshot.toolSystemImage = tool.systemImage
            return snapshot
        }
    }

    private static func validate(endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(), endpoint.host != nil else {
            throw RemoteUsageError.invalidEndpoint
        }
        let isLocal = endpoint.host == "localhost" || endpoint.host == "127.0.0.1" || endpoint.host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw RemoteUsageError.insecureEndpoint
        }
    }

    private static func validate(toolID: AIToolID) throws {
        guard UUID(uuidString: toolID.rawValue) != nil,
              !AIToolID.builtInIDs.contains(toolID) else {
            throw RemoteToolConfigurationError.invalidIdentifier
        }
    }
}

enum RemoteUsageError: LocalizedError {
    case noSources
    case invalidEndpoint
    case insecureEndpoint
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case tooManyLimits
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .noSources: "No remote AI tools configured"
        case .invalidEndpoint: "The remote endpoint is invalid"
        case .insecureEndpoint: "Remote endpoints must use HTTPS"
        case .invalidResponse: "The remote endpoint returned an invalid response"
        case let .httpStatus(code): "The remote endpoint returned HTTP \(code)"
        case .responseTooLarge: "The remote response exceeds 1 MB"
        case .tooManyLimits: "The remote response contains more than 100 limits"
        case .requestTimedOut: "The remote endpoint did not respond within 15 seconds"
        }
    }
}
