import Foundation

protocol RPCRequesting: Sendable {
    func start() async throws
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func notify(method: String, params: JSONValue) async throws
    func notifications() async -> AsyncStream<JSONRPCNotification>
    func stop() async
}

extension JSONRPCConnection: RPCRequesting {}

enum AccountUsageResult: Equatable, Sendable {
    case signedOut
    case authenticated([QuotaSnapshot])

    var snapshots: [QuotaSnapshot] {
        guard case let .authenticated(snapshots) = self else { return [] }
        return snapshots
    }
}

protocol CodexUsageProviding: Sendable {
    func refresh() async throws -> AccountUsageResult
    func updates() async -> AsyncStream<[QuotaSnapshot]>
    func stop() async
}

protocol AutomaticUsageProviding: CodexUsageProviding {
    func refreshAutomatically() async throws -> AccountUsageResult
}

actor CodexUsageProvider: CodexUsageProviding {
    private struct ResetCreditSummary {
        let availableCount: Int
        let earliestExpiration: Date?
    }

    private struct UpdateMergeResult {
        let snapshots: [QuotaSnapshot]
        let requiresAuthoritativeRefresh: Bool
    }

    private let rpc: any RPCRequesting
    private let now: @Sendable () -> Date
    private var initialized = false
    private var snapshotsByID: [String: QuotaSnapshot] = [:]

    init(
        rpc: any RPCRequesting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rpc = rpc
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            return try await performRefresh()
        } catch JSONRPCError.disconnected {
            // The Codex app-server can restart independently of usAIge. Reset the
            // transport and initialize a fresh process so one dropped connection
            // cannot leave quota polling permanently stale.
            await rpc.stop()
            initialized = false
            return try await performRefresh()
        }
    }

    private func performRefresh() async throws -> AccountUsageResult {
        try await initializeIfNeeded()
        let account = try await rpc.request(method: "account/read", params: .object([
            "refreshToken": .bool(false),
        ]))
        if account["account"] == .null || account["account"] == nil {
            snapshotsByID = [:]
            return .signedOut
        }

        let response = try await rpc.request(
            method: "account/rateLimits/read",
            params: .object([:])
        )
        let snapshots = Self.decodeSnapshots(from: response, updatedAt: now())
        snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        return .authenticated(snapshots)
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        let rpc = self.rpc
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let notifications = await rpc.notifications()
                    for await notification in notifications {
                        guard !Task.isCancelled else { break }
                        guard notification.method == "account/rateLimits/updated" else { continue }
                        let merged = self.mergeUpdate(notification.params)
                        if merged.requiresAuthoritativeRefresh,
                           let refreshed = try? await self.refresh() {
                            continuation.yield(refreshed.snapshots)
                        } else {
                            continuation.yield(merged.snapshots)
                        }
                    }
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        await rpc.stop()
        initialized = false
        snapshotsByID = [:]
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        try await rpc.start()
        _ = try await rpc.request(method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("usaige"),
                "title": .string("usAIge"),
                "version": .string("0.2.5"),
            ]),
        ]))
        try await rpc.notify(method: "initialized", params: .object([:]))
        initialized = true
    }

    private func mergeUpdate(_ params: JSONValue) -> UpdateMergeResult {
        let wrapped: JSONValue
        if params["rateLimits"] != nil
            || params["rateLimitsByLimitId"] != nil
            || params["rateLimitResetCredits"] != nil {
            wrapped = params
        } else {
            wrapped = .object(["rateLimits": params])
        }
        let previousAvailableResetCount = snapshotsByID.values
            .compactMap(\.availableResetCount)
            .first
        let resetCredits = Self.resetCreditSummary(in: wrapped)
        let updates = Self.decodeSnapshots(from: wrapped, updatedAt: now())
        let resetCreditWasConsumed: Bool
        if let previousAvailableResetCount, let resetCredits {
            resetCreditWasConsumed = resetCredits.availableCount < previousAvailableResetCount
        } else {
            resetCreditWasConsumed = false
        }
        for var snapshot in updates {
            if let resetCredits {
                snapshot.availableResetCount = resetCredits.availableCount
                snapshot.resetCreditExpiresAt = resetCredits.earliestExpiration
            } else {
                snapshot.availableResetCount = snapshotsByID[snapshot.id]?.availableResetCount
                    ?? snapshotsByID.values.compactMap(\.availableResetCount).first
                snapshot.resetCreditExpiresAt = snapshotsByID[snapshot.id]?.resetCreditExpiresAt
                    ?? snapshotsByID.values.compactMap(\.resetCreditExpiresAt).first
            }
            snapshotsByID[snapshot.id] = snapshot
        }
        if let resetCredits {
            for id in snapshotsByID.keys {
                snapshotsByID[id]?.availableResetCount = resetCredits.availableCount
                snapshotsByID[id]?.resetCreditExpiresAt = resetCredits.earliestExpiration
            }
        }
        return UpdateMergeResult(
            snapshots: snapshotsByID.values.sorted { $0.id < $1.id },
            requiresAuthoritativeRefresh: updates.isEmpty || resetCreditWasConsumed
        )
    }

    private static func decodeSnapshots(from response: JSONValue, updatedAt: Date) -> [QuotaSnapshot] {
        let resetCredits = resetCreditSummary(in: response)
        if let byID = response["rateLimitsByLimitId"]?.objectValue {
            return byID.keys.sorted().compactMap { key in
                decodeBucket(
                    byID[key],
                    fallbackID: key,
                    resetCredits: resetCredits,
                    updatedAt: updatedAt
                )
            }
        }
        guard let single = response["rateLimits"] else { return [] }
        return [decodeBucket(
            single,
            fallbackID: "codex",
            resetCredits: resetCredits,
            updatedAt: updatedAt
        )].compactMap { $0 }
    }

    private static func resetCreditSummary(in response: JSONValue) -> ResetCreditSummary? {
        guard let value = response["rateLimitResetCredits"],
              let availableCount = value["availableCount"]?.intValue else { return nil }
        let expirations = value["credits"]?.arrayValue?.compactMap { credit -> Date? in
            guard credit["status"]?.stringValue == "available",
                  credit["resetType"]?.stringValue == "codexRateLimits",
                  let timestamp = credit["expiresAt"]?.numberValue else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        } ?? []
        return ResetCreditSummary(
            availableCount: max(0, availableCount),
            earliestExpiration: expirations.min()
        )
    }

    private static func decodeBucket(
        _ value: JSONValue?,
        fallbackID: String,
        resetCredits: ResetCreditSummary?,
        updatedAt: Date
    ) -> QuotaSnapshot? {
        guard let object = value?.objectValue,
              let primary = object["primary"]?.objectValue,
              case let .number(usedPercent)? = primary["usedPercent"] else { return nil }

        let id = object["limitId"]?.stringValue ?? fallbackID
        let limitName = object["limitName"]?.stringValue
        let duration = primary["windowDurationMins"]?.intValue
        let resetsAt: Double?
        if case let .number(value)? = primary["resetsAt"] { resetsAt = value } else { resetsAt = nil }
        let secondary = object["secondary"]?.objectValue
        let secondaryUsedPercent: Double?
        if case let .number(value)? = secondary?["usedPercent"] { secondaryUsedPercent = value }
        else { secondaryUsedPercent = nil }
        let secondaryDuration = secondary?["windowDurationMins"]?.intValue
        let secondaryResetsAt: Double?
        if case let .number(value)? = secondary?["resetsAt"] { secondaryResetsAt = value }
        else { secondaryResetsAt = nil }
        let planType = object["planType"]?.stringValue
        var snapshot = QuotaSnapshot.make(
            from: RateLimitBucket(
                limitID: id,
                limitName: limitName,
                usedPercent: usedPercent,
                windowDurationMinutes: duration,
                resetsAt: resetsAt,
                planType: planType,
                secondaryUsedPercent: secondaryUsedPercent,
                secondaryWindowDurationMinutes: secondaryDuration,
                secondaryResetsAt: secondaryResetsAt
            ),
            updatedAt: updatedAt
        )
        snapshot.availableResetCount = resetCredits?.availableCount
        snapshot.resetCreditExpiresAt = resetCredits?.earliestExpiration
        return snapshot
    }
}
