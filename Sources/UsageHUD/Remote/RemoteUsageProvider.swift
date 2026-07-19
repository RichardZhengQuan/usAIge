import Foundation

actor RemoteUsageProvider: CodexUsageProviding {
    typealias Fetch = @MainActor @Sendable () async throws -> [QuotaSnapshot]

    private let fetch: Fetch

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func refresh() async throws -> AccountUsageResult {
        .authenticated(try await fetch())
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

enum RemoteUsageError: LocalizedError {
    case noSources
    case invalidResponse
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .noSources: "No remote AI tools paired"
        case .invalidResponse: "The remote tool returned an invalid response"
        case .requestTimedOut: "The remote tool did not respond in time"
        }
    }
}
