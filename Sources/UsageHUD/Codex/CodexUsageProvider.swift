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
        let credits: [ResetCredit]
    }

    private struct UpdateMergeResult {
        let snapshots: [QuotaSnapshot]
        let requiresAuthoritativeRefresh: Bool
    }

    private let rpc: any RPCRequesting
    private let now: @Sendable () -> Date
    private var initialized = false
    private var snapshotsByID: [String: QuotaSnapshot] = [:]
    private var latestResetCredits: ResetCreditSummary?
    /// Counts pushed updates, and records the count at which each limit was
    /// last pushed, so a full read that was already in flight doesn't
    /// overwrite a newer push with older numbers.
    private var mergeCount = 0
    private var mergedAtCount: [String: Int] = [:]
    private var resetCreditsPushedAtCount = 0

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
            latestResetCredits = nil
            return .signedOut
        }

        let countBeforeRead = mergeCount
        let response = try await rpc.request(
            method: "account/rateLimits/read",
            params: .object([:])
        )
        let updatedAt = now()
        if resetCreditsPushedAtCount <= countBeforeRead {
            latestResetCredits = Self.resetCreditSummary(in: response)
        }
        let snapshots = Self.decodeSnapshots(from: response, updatedAt: updatedAt).map { snapshot in
            guard (mergedAtCount[snapshot.id] ?? 0) > countBeforeRead,
                  let pushed = snapshotsByID[snapshot.id] else { return snapshot }
            return pushed
        }
        snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        return .authenticated(applyingResetCredits(to: snapshots, at: updatedAt))
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
        latestResetCredits = nil
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        try await rpc.start()
        _ = try await rpc.request(method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("usaige"),
                "title": .string("usAIge"),
                "version": .string(UsAIgeUserAgent.shortVersion),
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
        let updatedAt = now()
        let updates = Self.decodeSnapshots(from: wrapped, updatedAt: updatedAt)
        mergeCount += 1
        for snapshot in updates {
            snapshotsByID[snapshot.id] = snapshot
            mergedAtCount[snapshot.id] = mergeCount
        }
        var resetCreditWasConsumed = false
        if let resetCredits = Self.resetCreditSummary(in: wrapped) {
            if let previous = latestResetCredits {
                resetCreditWasConsumed = resetCredits.availableCount < previous.availableCount
            }
            latestResetCredits = resetCredits
            resetCreditsPushedAtCount = mergeCount
        }
        return UpdateMergeResult(
            snapshots: applyingResetCredits(to: snapshotsByID.values.sorted { $0.id < $1.id }, at: updatedAt),
            requiresAuthoritativeRefresh: updates.isEmpty || resetCreditWasConsumed
        )
    }

    private func applyingResetCredits(to snapshots: [QuotaSnapshot], at date: Date) -> [QuotaSnapshot] {
        guard let latestResetCredits else { return snapshots }
        let credits = latestResetCredits.credits.filter { $0.isUnexpired(at: date) }
        return snapshots.map { snapshot in
            var snapshot = snapshot
            snapshot.availableResetCount = latestResetCredits.availableCount
            snapshot.resetCreditExpiresAt = credits.first?.expiresAt
            snapshot.resetCredits = credits
            return snapshot
        }
    }

    private static func decodeSnapshots(from response: JSONValue, updatedAt: Date) -> [QuotaSnapshot] {
        if let byID = response["rateLimitsByLimitId"]?.objectValue {
            return byID.keys.sorted().compactMap { key in
                decodeBucket(
                    byID[key],
                    fallbackID: key,
                    updatedAt: updatedAt
                )
            }
        }
        guard let single = response["rateLimits"] else { return [] }
        return [decodeBucket(
            single,
            fallbackID: "codex",
            updatedAt: updatedAt
        )].compactMap { $0 }
    }

    private static func resetCreditSummary(in response: JSONValue) -> ResetCreditSummary? {
        guard let value = response["rateLimitResetCredits"],
              let count = value["availableCount"]?.numberValue,
              let availableCount = Int(exactly: count) else { return nil }
        let credits = (value["credits"]?.arrayValue ?? []).compactMap { credit -> ResetCredit? in
            guard credit["status"]?.stringValue == "available",
                  let id = credit["id"]?.stringValue,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let expiresAt: Date?
            if let expiration = credit["expiresAt"], expiration != .null {
                guard let timestamp = expiration.numberValue, timestamp.isFinite else { return nil }
                expiresAt = Date(timeIntervalSince1970: timestamp)
            } else {
                expiresAt = nil
            }
            return ResetCredit(
                id: id,
                title: nonBlankString(credit["title"]) ?? "Full reset",
                expiresAt: expiresAt,
                detail: nonBlankString(credit["description"]) ?? nonBlankString(credit["subtitle"]),
                grantedAt: credit["grantedAt"]?.numberValue.flatMap {
                    $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
                }
            )
        }.sorted { lhs, rhs in
            guard let expiration = lhs.expiresAt else { return false }
            return rhs.expiresAt.map { expiration < $0 } ?? true
        }
        return ResetCreditSummary(availableCount: max(0, availableCount), credits: credits)
    }

    private static func nonBlankString(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func decodeBucket(
        _ value: JSONValue?,
        fallbackID: String,
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
        return QuotaSnapshot.make(
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
    }
}
