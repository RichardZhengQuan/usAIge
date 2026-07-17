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
                let notifications = await rpc.notifications()
                for await notification in notifications {
                    guard notification.method == "account/rateLimits/updated" else { continue }
                    let updated = self.mergeUpdate(notification.params)
                    continuation.yield(updated)
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
                "version": .string("0.2.1"),
            ]),
        ]))
        try await rpc.notify(method: "initialized", params: .object([:]))
        initialized = true
    }

    private func mergeUpdate(_ params: JSONValue) -> [QuotaSnapshot] {
        let wrapped: JSONValue
        if params["rateLimits"] != nil || params["rateLimitsByLimitId"] != nil {
            wrapped = params
        } else {
            wrapped = .object(["rateLimits": params])
        }
        let availableResetCount = Self.availableResetCount(in: wrapped)
        let updates = Self.decodeSnapshots(from: wrapped, updatedAt: now())
        for var snapshot in updates {
            snapshot.availableResetCount = availableResetCount
                ?? snapshotsByID[snapshot.id]?.availableResetCount
                ?? snapshotsByID.values.compactMap(\.availableResetCount).first
            snapshotsByID[snapshot.id] = snapshot
        }
        if let availableResetCount {
            for id in snapshotsByID.keys {
                snapshotsByID[id]?.availableResetCount = availableResetCount
            }
        }
        return snapshotsByID.values.sorted { $0.id < $1.id }
    }

    private static func decodeSnapshots(from response: JSONValue, updatedAt: Date) -> [QuotaSnapshot] {
        let availableResetCount = availableResetCount(in: response)
        if let byID = response["rateLimitsByLimitId"]?.objectValue {
            return byID.keys.sorted().compactMap { key in
                decodeBucket(
                    byID[key],
                    fallbackID: key,
                    availableResetCount: availableResetCount,
                    updatedAt: updatedAt
                )
            }
        }
        guard let single = response["rateLimits"] else { return [] }
        return [decodeBucket(
            single,
            fallbackID: "codex",
            availableResetCount: availableResetCount,
            updatedAt: updatedAt
        )].compactMap { $0 }
    }

    private static func availableResetCount(in response: JSONValue) -> Int? {
        response["rateLimitResetCredits"]?["availableCount"]?.intValue
    }

    private static func decodeBucket(
        _ value: JSONValue?,
        fallbackID: String,
        availableResetCount: Int?,
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
        snapshot.availableResetCount = availableResetCount
        return snapshot
    }
}
