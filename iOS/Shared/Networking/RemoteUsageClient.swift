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
