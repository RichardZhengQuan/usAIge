import Foundation

/// Merges every usage source into one result:
///
/// - `local` is the Codex app-server, refreshed on every automatic tick.
/// - `throttled` sources are the built-in local tool providers (Claude Code,
///   Cursor, Grok Build). They talk to provider account endpoints, so they
///   are polled on the remote cadence and each one throttles itself further.
/// - `remote` is the relay of paired adapters.
///
/// A failing source keeps its last successful result so one provider outage
/// never blanks the rail for the others.
actor CompositeUsageProvider: AutomaticUsageProviding {
    private let local: any CodexUsageProviding
    private let throttled: [any CodexUsageProviding]
    private let remote: any CodexUsageProviding
    private let remoteRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var localResult: AccountUsageResult?
    private var throttledResults: [AccountUsageResult?]
    private var remoteResult: AccountUsageResult?
    private var lastRemoteRefresh: Date?

    init(
        local: any CodexUsageProviding,
        throttled: [any CodexUsageProviding] = [],
        remote: any CodexUsageProviding,
        remoteRefreshInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.local = local
        self.throttled = throttled
        self.remote = remote
        self.remoteRefreshInterval = remoteRefreshInterval
        self.now = now
        throttledResults = Array(repeating: nil, count: throttled.count)
    }

    func refresh() async throws -> AccountUsageResult {
        try await refreshAllSources(manual: true)
    }

    func refreshAutomatically() async throws -> AccountUsageResult {
        let current = now()
        if let lastRemoteRefresh,
           current.timeIntervalSince(lastRemoteRefresh) < remoteRefreshInterval {
            return try await refreshLocalSource()
        }
        return try await refreshAllSources(at: current, manual: false)
    }

    private func refreshAllSources(at refreshDate: Date? = nil, manual: Bool) async throws -> AccountUsageResult {
        lastRemoteRefresh = refreshDate ?? now()
        async let localOutcome = capture { try await self.local.refresh() }
        async let remoteOutcome = capture { try await self.remote.refresh() }
        async let throttledOutcomes = refreshThrottledSources(manual: manual)
        let outcomes = await (localOutcome, throttledOutcomes, remoteOutcome)
        var succeeded = false
        var firstError: Error?

        switch outcomes.0 {
        case let .success(result):
            succeeded = true
            localResult = result
        case let .failure(error):
            firstError = error
        }
        for (index, outcome) in outcomes.1.enumerated() {
            switch outcome {
            case let .success(result):
                succeeded = true
                throttledResults[index] = result
            case let .failure(error):
                firstError = firstError ?? error
            }
        }
        switch outcomes.2 {
        case let .success(result):
            succeeded = true
            remoteResult = result
        case let .failure(error):
            if case RemoteUsageError.noSources = error {
                remoteResult = nil
            }
            firstError = firstError ?? error
        }

        if succeeded, let result = combinedResult() { return result }
        throw firstError ?? RemoteUsageError.invalidResponse
    }

    private func refreshThrottledSources(manual: Bool) async -> [Result<AccountUsageResult, Error>] {
        guard !throttled.isEmpty else { return [] }
        let providers = throttled
        return await withTaskGroup(of: (Int, Result<AccountUsageResult, Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let outcome = await capture {
                        if manual, let throttledProvider = provider as? any ThrottledUsageProviding {
                            return try await throttledProvider.refresh(manual: true)
                        }
                        return try await provider.refresh()
                    }
                    return (index, outcome)
                }
            }
            var results: [Result<AccountUsageResult, Error>?] = Array(repeating: nil, count: providers.count)
            for await (index, outcome) in group {
                results[index] = outcome
            }
            return results.map { $0 ?? .failure(RemoteUsageError.invalidResponse) }
        }
    }

    private func refreshLocalSource() async throws -> AccountUsageResult {
        let outcome = await capture { try await self.local.refresh() }
        switch outcome {
        case let .success(result):
            localResult = result
        case let .failure(error):
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
        for provider in throttled { await provider.stop() }
        await remote.stop()
        localResult = nil
        throttledResults = Array(repeating: nil, count: throttled.count)
        remoteResult = nil
        lastRemoteRefresh = nil
    }

    private func mergeLocal(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        localResult = .authenticated(snapshots)
        return combinedResult()?.snapshots ?? snapshots
    }

    private func combinedResult() -> AccountUsageResult? {
        let results = ([localResult] + throttledResults + [remoteResult]).compactMap { $0 }
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
