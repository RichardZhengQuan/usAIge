import Foundation

actor CompositeUsageProvider: AutomaticUsageProviding {
    private let local: any CodexUsageProviding
    private let remote: any CodexUsageProviding
    private let remoteRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var localResult: AccountUsageResult?
    private var remoteResult: AccountUsageResult?
    private var lastRemoteRefresh: Date?

    init(
        local: any CodexUsageProviding,
        remote: any CodexUsageProviding,
        remoteRefreshInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.local = local
        self.remote = remote
        self.remoteRefreshInterval = remoteRefreshInterval
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        try await refreshAllSources()
    }

    func refreshAutomatically() async throws -> AccountUsageResult {
        let current = now()
        if let lastRemoteRefresh,
           current.timeIntervalSince(lastRemoteRefresh) < remoteRefreshInterval {
            return try await refreshLocalSource()
        }
        return try await refreshAllSources(at: current)
    }

    private func refreshAllSources(at refreshDate: Date? = nil) async throws -> AccountUsageResult {
        lastRemoteRefresh = refreshDate ?? now()
        async let localResult = capture { try await self.local.refresh() }
        async let remoteResult = capture { try await self.remote.refresh() }
        let outcomes = await (localResult, remoteResult)
        var succeeded = false
        var firstError: Error?

        switch outcomes.0 {
        case let .success(result):
            succeeded = true
            self.localResult = result
        case let .failure(error):
            self.localResult = nil
            firstError = error
        }
        switch outcomes.1 {
        case let .success(result):
            succeeded = true
            self.remoteResult = result
        case let .failure(error):
            self.remoteResult = nil
            firstError = firstError ?? error
        }

        if succeeded, let result = combinedResult() { return result }
        throw firstError ?? RemoteUsageError.invalidResponse
    }

    private func refreshLocalSource() async throws -> AccountUsageResult {
        let outcome = await capture { try await self.local.refresh() }
        switch outcome {
        case let .success(result):
            localResult = result
        case let .failure(error):
            localResult = nil
            if let result = combinedResult() { return result }
            throw error
        }
        return combinedResult() ?? .authenticated([])
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        let local = self.local
        return AsyncStream { continuation in
            let task = Task {
                let updates = await local.updates()
                for await snapshots in updates {
                    continuation.yield(self.mergeLocal(snapshots))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        await local.stop()
        await remote.stop()
        localResult = nil
        remoteResult = nil
        lastRemoteRefresh = nil
    }

    private func mergeLocal(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        localResult = .authenticated(snapshots)
        return combinedResult()?.snapshots ?? snapshots
    }

    private func combinedResult() -> AccountUsageResult? {
        let results = [localResult, remoteResult].compactMap { $0 }
        guard !results.isEmpty else { return nil }
        var snapshots: [QuotaSnapshot] = []
        var isAuthenticated = false
        for result in results {
            guard case let .authenticated(values) = result else { continue }
            isAuthenticated = true
            snapshots.append(contentsOf: values)
        }
        return isAuthenticated ? .authenticated(snapshots) : .signedOut
    }
}

private func capture<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
