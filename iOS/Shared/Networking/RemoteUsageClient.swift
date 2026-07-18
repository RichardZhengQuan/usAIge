import Foundation

public enum RemoteUsageClientError: Error, Equatable, LocalizedError, Sendable {
    case toolDisabled
    case invalidEndpoint
    case nonHTTPResponse
    case insecureRedirect
    case redirectNotAllowed
    case unsuccessfulStatus(Int)
    case responseTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .toolDisabled:
            return "This remote AI tool is disabled."
        case .invalidEndpoint:
            return "The remote AI tool must use a valid HTTPS endpoint."
        case .nonHTTPResponse:
            return "The remote AI tool returned a non-HTTP response."
        case .insecureRedirect:
            return "The remote AI tool redirected to a non-HTTPS endpoint."
        case .redirectNotAllowed:
            return "The remote AI tool endpoint must not redirect."
        case let .unsuccessfulStatus(status):
            return "The remote AI tool returned HTTP status \(status)."
        case let .responseTooLarge(maximumBytes):
            return "The remote AI tool response exceeds the \(maximumBytes)-byte safety limit."
        }
    }
}

public struct RemoteUsageClient: Sendable {
    private let session: URLSession
    private let decoder: RemoteQuotaPayloadDecoder
    private let now: @Sendable () -> Date
    private let maximumResponseBytes: Int

    public init(
        session: URLSession = .shared,
        decoder: RemoteQuotaPayloadDecoder = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        maximumResponseBytes: Int = 1_048_576
    ) {
        self.session = session
        self.decoder = decoder
        self.now = now
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func fetch(
        configuration: RemoteToolConfiguration,
        token: String
    ) async throws -> [QuotaSnapshot] {
        guard configuration.isEnabled else {
            throw RemoteUsageClientError.toolDisabled
        }
        guard RemoteToolConfiguration.isSupportedEndpoint(configuration.endpointURL) else {
            throw RemoteUsageClientError.invalidEndpoint
        }

        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bearerToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: RejectRedirectsSessionDelegate()
        )
        guard let response = response as? HTTPURLResponse else {
            throw RemoteUsageClientError.nonHTTPResponse
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw RemoteUsageClientError.insecureRedirect
        }
        guard !(300..<400).contains(response.statusCode) else {
            throw RemoteUsageClientError.redirectNotAllowed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteUsageClientError.unsuccessfulStatus(response.statusCode)
        }

        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw RemoteUsageClientError.responseTooLarge(
                maximumBytes: maximumResponseBytes
            )
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(response.expectedContentLength), maximumResponseBytes)
            )
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw RemoteUsageClientError.responseTooLarge(
                    maximumBytes: maximumResponseBytes
                )
            }
            data.append(byte)
        }

        return try decoder.decode(data, for: configuration, updatedAt: now())
    }
}

/// Bearer credentials are never allowed to follow a redirect, including an
/// HTTPS redirect to another origin. Remote adapters must expose a stable final
/// endpoint URL instead.
private final class RejectRedirectsSessionDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct RelayConnection: Codable, Equatable, Sendable {
    public let channelID: UUID
    public let deviceID: UUID
    public let macName: String
}

public actor RelayConnectionStore {
    public nonisolated let storageURL: URL
    public init(fileURL: URL? = nil) {
        storageURL = fileURL ?? JSONFileStorage.applicationSupportDirectory().appendingPathComponent("relay-connection.json")
    }
    public func load() throws -> RelayConnection? { try JSONFileStorage.load(RelayConnection.self, from: storageURL) }
    public func save(_ value: RelayConnection) throws { try JSONFileStorage.save(value, to: storageURL) }
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try FileManager.default.removeItem(at: storageURL)
    }
}

public struct RelayClaimResult: Sendable {
    public let connection: RelayConnection
    public let readToken: String
}

public struct RelaySnapshotResult: Sendable {
    public let snapshots: [QuotaSnapshot]
    public let serverReceivedAt: Date
    public let version: Int
    public let etag: String?
}

public enum RelayClientError: LocalizedError, Sendable {
    case invalidCode, invalidResponse, unauthorized, server(String)
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Enter the 8-character code shown on your Mac."
        case .invalidResponse: "The relay returned an invalid response."
        case .unauthorized: "This iPhone is no longer connected. Pair it again from the Mac."
        case let .server(message): message
        }
    }
}

public struct RelayClient: Sendable {
    public static let baseURL = URL(string: "https://usaige-macos.richardqz.chatgpt.site/api/v1/")!
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func claim(code: String, deviceName: String) async throws -> RelayClaimResult {
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard normalized.count == 8 else { throw RelayClientError.invalidCode }
        var request = URLRequest(url: Self.baseURL.appending(path: "pairings/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClaimRequest(code: normalized, deviceName: deviceName))
        let response: ClaimResponse = try await send(request)
        guard let channelID = UUID(uuidString: response.channelID), let deviceID = UUID(uuidString: response.deviceID) else { throw RelayClientError.invalidResponse }
        return RelayClaimResult(connection: RelayConnection(channelID: channelID, deviceID: deviceID, macName: response.macName), readToken: response.readToken)
    }

    public func fetch(connection: RelayConnection, token: String, etag: String? = nil) async throws -> RelaySnapshotResult? {
        var request = authorized(connection: connection, token: token, path: "channels/\(connection.channelID.uuidString.lowercased())/snapshot", method: "GET")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        if http.statusCode == 304 { return nil }
        try validate(http: http, data: data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(RelayEnvelope.self, from: data)
        let values = envelope.snapshot.tools.flatMap { tool in
            tool.limits.map { limit in
                let toolID = UUID(uuidString: tool.id) ?? Self.builtInToolUUID(for: tool.id)
                return QuotaSnapshot(
                    id: QuotaSnapshot.stableID(toolID: toolID, limitID: limit.id),
                    limitID: limit.id,
                    toolID: toolID,
                    toolName: tool.name,
                    displayName: limit.name,
                    remainingPercent: limit.primary.remainingPercent,
                    resetAt: limit.primary.resetAt,
                    updatedAt: envelope.snapshot.generatedAt,
                    planType: limit.planType,
                    windowDurationMinutes: limit.primary.windowDurationMinutes,
                    secondaryWindow: limit.secondary.map { QuotaWindowSnapshot(remainingPercent: $0.remainingPercent, resetAt: $0.resetAt, windowDurationMinutes: $0.windowDurationMinutes) }
                )
            }
        }
        return RelaySnapshotResult(snapshots: values, serverReceivedAt: envelope.serverReceivedAt, version: envelope.version, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    public func registerAPNs(connection: RelayConnection, token: String, apnsToken: String, environment: String) async throws {
        var request = authorized(connection: connection, token: token, path: "channels/\(connection.channelID.uuidString.lowercased())/devices/\(connection.deviceID.uuidString.lowercased())", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(APNsRequest(apnsToken: apnsToken, environment: environment))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RelayClientError.invalidResponse }
    }

    public func disconnect(connection: RelayConnection, token: String) async throws {
        let request = authorized(connection: connection, token: token, path: "channels/\(connection.channelID.uuidString.lowercased())/devices/\(connection.deviceID.uuidString.lowercased())", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        try validate(http: http, data: data)
    }

    private func authorized(connection: RelayConnection, token: String, path: String, method: String) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: path)); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        try validate(http: http, data: data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
    private func validate(http: HTTPURLResponse, data: Data) throws {
        if http.statusCode == 401 { throw RelayClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "The relay request failed."
            throw RelayClientError.server(message)
        }
    }
    private static func builtInToolUUID(for id: String) -> UUID {
        let suffix: String
        switch id.lowercased() {
        case "chatgpt": suffix = "0001"
        case "claude": suffix = "0002"
        case "gemini": suffix = "0003"
        case "cursor": suffix = "0004"
        default: suffix = "ffff"
        }
        return UUID(uuidString: "00000000-0000-4000-8000-00000000\(suffix)")!
    }
}

private struct ClaimRequest: Encodable { let code, deviceName: String }
private struct ClaimResponse: Decodable { let channelID, deviceID, readToken, macName: String }
private struct APNsRequest: Encodable { let apnsToken, environment: String }
private struct ServerError: Decodable { let error: String }
private struct RelayEnvelope: Decodable {
    let version: Int; let serverReceivedAt: Date; let snapshot: RelaySnapshotDocument
}
private struct RelaySnapshotDocument: Decodable { let generatedAt: Date; let tools: [RelayToolDocument] }
private struct RelayToolDocument: Decodable { let id, name, symbolName: String; let limits: [RelayLimitDocument] }
private struct RelayLimitDocument: Decodable { let id, name: String; let planType: String?; let primary: RelayWindowDocument; let secondary: RelayWindowDocument? }
private struct RelayWindowDocument: Decodable { let remainingPercent: Double; let resetAt: Date?; let windowDurationMinutes: Int? }
