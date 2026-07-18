import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    var tools: [RemoteToolConfiguration] = []
    var snapshots: [QuotaSnapshot] = []
    var refreshMetadata: [RefreshScheduleMetadata] = []
    var errorsByToolID: [UUID: String] = [:]
    var isRefreshing = false
    private(set) var isSavingToolChanges = false
    var isPresentingAddTool = false
    var toolPendingDeletion: RemoteToolConfiguration?

    private(set) var cacheSavedAt: Date?
    private(set) var systemErrorMessage: String?
    private(set) var canRetryPersistence = false
    private(set) var canModifyTools = false

    private let toolStore: ToolConfigurationStore
    private let quotaCache: SharedQuotaCache
    private let tokenVault: KeychainTokenVault
    private let usageClient: RemoteUsageClient
    private let watchCoordinator: WatchSyncCoordinator
    private var startupTask: Task<Void, Never>?
    private var pendingTokenDeletionIDs: Set<UUID> = []
    private var connectionRevisionByToolID: [UUID: UInt] = [:]
    private var pendingEnabledStateByToolID: [UUID: Bool] = [:]
    private var pendingRefreshToolIDs: Set<UUID> = []
    private var activeRefreshRevisionByToolID: [UUID: UInt] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        toolStore: ToolConfigurationStore = ToolConfigurationStore(),
        quotaCache: SharedQuotaCache = SharedQuotaCache(),
        tokenVault: KeychainTokenVault = KeychainTokenVault(),
        usageClient: RemoteUsageClient = RemoteUsageClient(),
        watchCoordinator: WatchSyncCoordinator? = nil
    ) {
        self.toolStore = toolStore
        self.quotaCache = quotaCache
        self.tokenVault = tokenVault
        self.usageClient = usageClient
        let resolvedWatchCoordinator = watchCoordinator ?? WatchSyncCoordinator()
        self.watchCoordinator = resolvedWatchCoordinator
        resolvedWatchCoordinator.refreshHandler = { [weak self] in
            guard let self else {
                return WatchUsageSnapshotEnvelope(generatedAt: Date(), tools: [])
            }
            await self.refreshAll()
            return self.watchSnapshotEnvelope()
        }
        resolvedWatchCoordinator.activate()
    }

    var enabledTools: [RemoteToolConfiguration] {
        tools.filter(\.isEnabled)
    }

    var canStartToolMutation: Bool {
        canModifyTools && !isSavingToolChanges
    }

    var isConfirmingDeletion: Bool {
        get { toolPendingDeletion != nil }
        set {
            if !newValue { toolPendingDeletion = nil }
        }
    }

    var lastRefreshByToolID: [UUID: Date] {
        Dictionary(
            uniqueKeysWithValues: refreshMetadata.compactMap { metadata in
                metadata.lastSuccessAt.map { (metadata.toolID, $0) }
            }
        )
    }

    var minimumRefreshIntervalMinutes: Int {
        enabledTools.map(\.refreshIntervalMinutes).min() ?? 60
    }

    var isCacheStale: Bool {
        guard !snapshots.isEmpty else { return false }
        let now = Date()
        return enabledTools.contains { tool in
            let toolSnapshots = snapshots(for: tool.id)
            guard !toolSnapshots.isEmpty else { return true }
            if let metadata = refreshMetadata.first(where: { $0.toolID == tool.id }) {
                if metadata.consecutiveFailureCount > 0 { return true }
                if let nextRefreshAt = metadata.nextRefreshAt {
                    return now >= nextRefreshAt
                }
            }
            let oldestUpdate = toolSnapshots.map(\.updatedAt).min() ?? .distantPast
            return now.timeIntervalSince(oldestUpdate) > tool.refreshInterval
        }
    }

    var primaryErrorMessage: String? {
        systemErrorMessage ?? errorsByToolID.values.sorted().first
    }

    var statusDetail: String {
        if isCacheStale {
            return "Open the app or pull down to request current values."
        }
        let failed = errorsByToolID.count
        return failed == 1 ? "One tool could not be refreshed." : "\(failed) tools could not be refreshed."
    }

    func start() async {
        if let startupTask {
            await startupTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPersistedState()
        }
        startupTask = task
        await task.value
    }

    private func loadPersistedState() async {
        var didLoadTools = false
        canModifyTools = false
        do {
            tools = try await toolStore.load()
            didLoadTools = true
            canModifyTools = true
            reconcileStoredTokens()
        } catch {
            systemErrorMessage = "Saved tools could not be loaded: \(error.localizedDescription)"
        }

        do {
            let cache = try await quotaCache.load()
            if didLoadTools {
                let enabledToolIDs = Set(enabledTools.map(\.id))
                snapshots = cache.snapshots.filter { enabledToolIDs.contains($0.toolID) }
                refreshMetadata = cache.refreshMetadata.filter {
                    enabledToolIDs.contains($0.toolID)
                }
            } else {
                snapshots = cache.snapshots
                refreshMetadata = cache.refreshMetadata
            }
            cacheSavedAt = cache.savedAt

            if didLoadTools,
               snapshots.count != cache.snapshots.count
                || refreshMetadata.count != cache.refreshMetadata.count {
                do {
                    try await saveCacheAndReloadWidget()
                } catch {
                    recordPersistenceError(
                        "Obsolete widget limits could not be removed: \(error.localizedDescription)"
                    )
                }
            }
            watchCoordinator.publish(watchSnapshotEnvelope(generatedAt: cache.savedAt))
        } catch {
            systemErrorMessage = "Saved limits could not be loaded: \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        await refresh(tools: enabledTools)
    }

    func refresh(toolID: UUID) async {
        guard let tool = tools.first(where: { $0.id == toolID && $0.isEnabled }) else { return }
        await refresh(tools: [tool])
    }

    @discardableResult
    func refreshDueTools(forceWhenCacheIsEmpty: Bool = false) async -> Bool {
        let now = Date()
        let due = enabledTools.filter { tool in
            if forceWhenCacheIsEmpty, snapshots(for: tool.id).isEmpty { return true }
            return refreshMetadata.first(where: { $0.toolID == tool.id })?.isRefreshDue(at: now) ?? true
        }
        guard !due.isEmpty else { return systemErrorMessage == nil }
        await refresh(tools: due)
        return !Task.isCancelled
            && systemErrorMessage == nil
            && !due.contains { errorsByToolID[$0.id] != nil }
    }

    func testAndAddTool(
        name: String,
        endpointURL: URL,
        bearerToken: String,
        refreshIntervalMinutes: Int
    ) async throws {
        try beginToolMutation()
        defer { endToolMutation() }
        guard !tools.contains(where: { $0.endpointURL == endpointURL }) else {
            throw AppModelError.duplicateEndpoint
        }

        let tool = RemoteToolConfiguration(
            id: UUID(),
            name: name,
            endpointURL: endpointURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            isEnabled: true
        )
        let normalizedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let fetched = try await usageClient.fetch(configuration: tool, token: normalizedToken)
        guard !fetched.isEmpty else { throw AppModelError.emptyLimits }

        if !normalizedToken.isEmpty {
            try tokenVault.save(normalizedToken, for: tool.id)
        }

        let updatedTools = tools + [tool]
        do {
            try await toolStore.save(updatedTools)
        } catch let saveError {
            if !normalizedToken.isEmpty {
                do {
                    try tokenVault.deleteToken(for: tool.id)
                } catch let cleanupError {
                    pendingTokenDeletionIDs.insert(tool.id)
                    recordPersistenceError(
                        "The unsaved tool's bearer token still needs cleanup: \(cleanupError.localizedDescription)"
                    )
                    throw AppModelError.credentialCleanupFailed(
                        saveError: saveError.localizedDescription,
                        cleanupError: cleanupError.localizedDescription
                    )
                }
            }
            throw saveError
        }

        tools = updatedTools
        let now = Date()
        snapshots.removeAll { $0.toolID == tool.id }
        snapshots.append(contentsOf: fetched)
        refreshMetadata.removeAll { $0.toolID == tool.id }
        refreshMetadata.append(
            RefreshScheduleMetadata(toolID: tool.id)
                .recordingAttempt(at: now)
                .recordingSuccess(at: now, refreshIntervalMinutes: tool.refreshIntervalMinutes)
        )
        errorsByToolID[tool.id] = nil
        do {
            try await saveCacheAndReloadWidget()
        } catch {
            recordPersistenceError(
                "The tool was added, but its limits could not be saved for the widget: \(error.localizedDescription)"
            )
        }
    }

    func testAndUpdateTool(
        toolID: UUID,
        name: String,
        endpointURL: URL,
        replacementBearerToken: String,
        removeSavedToken: Bool,
        refreshIntervalMinutes: Int
    ) async throws -> UUID {
        try beginToolMutation()
        defer { endToolMutation() }
        guard let index = tools.firstIndex(where: { $0.id == toolID }) else {
            throw AppModelError.toolNotFound
        }
        guard !tools.contains(where: { $0.id != toolID && $0.endpointURL == endpointURL }) else {
            throw AppModelError.duplicateEndpoint
        }

        let oldTool = tools[index]
        bumpConnectionRevision(for: oldTool.id)
        let oldToken = try tokenVault.token(for: toolID)
        let normalizedReplacement = replacementBearerToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken: String
        let originChanged = !Self.haveSameOrigin(oldTool.endpointURL, endpointURL)
        if originChanged,
           oldToken != nil,
           normalizedReplacement.isEmpty,
           !removeSavedToken {
            throw AppModelError.tokenDecisionRequired
        }
        if removeSavedToken {
            effectiveToken = ""
        } else if normalizedReplacement.isEmpty {
            effectiveToken = oldToken ?? ""
        } else {
            effectiveToken = normalizedReplacement
        }

        // A saved edit becomes a new connection identity. This keeps the old
        // endpoint, Keychain item, and cache mutually consistent across every
        // possible process-termination point in the transaction.
        let updatedTool = RemoteToolConfiguration(
            id: UUID(),
            name: name,
            endpointURL: endpointURL,
            refreshIntervalMinutes: refreshIntervalMinutes,
            isEnabled: oldTool.isEnabled
        )
        let testConfiguration = RemoteToolConfiguration(
            id: updatedTool.id,
            name: updatedTool.name,
            endpointURL: updatedTool.endpointURL,
            refreshIntervalMinutes: updatedTool.refreshIntervalMinutes,
            isEnabled: true
        )
        let fetched = try await usageClient.fetch(
            configuration: testConfiguration,
            token: effectiveToken
        )
        guard !fetched.isEmpty else { throw AppModelError.emptyLimits }

        var updatedTools = tools
        updatedTools[index] = updatedTool
        if !effectiveToken.isEmpty {
            try tokenVault.save(effectiveToken, for: updatedTool.id)
        }

        do {
            try await toolStore.save(updatedTools)
        } catch let saveError {
            if !effectiveToken.isEmpty {
                do {
                    try tokenVault.deleteToken(for: updatedTool.id)
                } catch let cleanupError {
                    pendingTokenDeletionIDs.insert(updatedTool.id)
                    recordPersistenceError(
                        "The unsaved replacement token still needs cleanup: \(cleanupError.localizedDescription)"
                    )
                    throw AppModelError.credentialCleanupFailed(
                        saveError: saveError.localizedDescription,
                        cleanupError: cleanupError.localizedDescription
                    )
                }
            }
            throw saveError
        }

        tools = updatedTools
        snapshots.removeAll { $0.toolID == oldTool.id || $0.toolID == updatedTool.id }
        refreshMetadata.removeAll { $0.toolID == oldTool.id || $0.toolID == updatedTool.id }
        errorsByToolID[oldTool.id] = nil
        errorsByToolID[updatedTool.id] = nil

        if updatedTool.isEnabled {
            let now = Date()
            snapshots.append(contentsOf: fetched)
            refreshMetadata.append(
                RefreshScheduleMetadata(toolID: updatedTool.id)
                    .recordingSuccess(
                        at: now,
                        refreshIntervalMinutes: updatedTool.refreshIntervalMinutes
                    )
            )
        }

        do {
            try await saveCacheAndReloadWidget()
        } catch {
            recordPersistenceError(
                "The connection was updated, but its limits could not be saved for the widget: \(error.localizedDescription)"
            )
        }

        if oldToken != nil {
            do {
                try tokenVault.deleteToken(for: oldTool.id)
            } catch {
                pendingTokenDeletionIDs.insert(oldTool.id)
                recordPersistenceError(
                    "The previous connection token still needs cleanup: \(error.localizedDescription)"
                )
            }
        }

        return updatedTool.id
    }

    func displayedEnabledState(for toolID: UUID) -> Bool {
        pendingEnabledStateByToolID[toolID]
            ?? tools.first(where: { $0.id == toolID })?.isEnabled
            ?? false
    }

    @discardableResult
    func setToolEnabled(toolID: UUID, isEnabled: Bool) async -> Bool {
        guard canStartToolMutation,
              let toolIndex = tools.firstIndex(where: { $0.id == toolID }) else {
            return false
        }
        isSavingToolChanges = true
        pendingEnabledStateByToolID[toolID] = isEnabled
        defer {
            pendingEnabledStateByToolID[toolID] = nil
            isSavingToolChanges = false
        }

        bumpConnectionRevision(for: toolID)
        var updatedTools = tools
        updatedTools[toolIndex].isEnabled = isEnabled
        do {
            try await toolStore.save(updatedTools)
        } catch {
            recordPersistenceError(
                "Tool settings could not be saved: \(error.localizedDescription)"
            )
            return false
        }
        tools = updatedTools

        if isEnabled {
            await refresh(toolID: toolID)
        } else {
            snapshots.removeAll { $0.toolID == toolID }
            refreshMetadata.removeAll { $0.toolID == toolID }
            errorsByToolID[toolID] = nil
            do {
                try await saveCacheAndReloadWidget()
            } catch {
                recordPersistenceError(
                    "The widget cache could not be updated: \(error.localizedDescription)"
                )
            }
        }
        return true
    }

    func retrySavingState() async {
        guard canRetryPersistence, !isSavingToolChanges else { return }
        isSavingToolChanges = true
        defer { isSavingToolChanges = false }
        var retryErrors = reconcileStoredTokens(validToolIDs: Set(tools.map(\.id)))

        do {
            try await toolStore.save(tools)
        } catch {
            retryErrors.append("tool list: \(error.localizedDescription)")
        }

        do {
            try await saveCacheAndReloadWidget()
        } catch {
            retryErrors.append("widget cache: \(error.localizedDescription)")
        }

        if retryErrors.isEmpty {
            systemErrorMessage = nil
            canRetryPersistence = false
        } else {
            recordPersistenceError(
                "Saved changes still need attention: \(retryErrors.joined(separator: "; "))."
            )
        }
    }

    func recoverFromSystemError() async {
        if canRetryPersistence {
            await retrySavingState()
            return
        }

        startupTask = nil
        systemErrorMessage = nil
        await start()
        await refreshDueTools(forceWhenCacheIsEmpty: true)
    }

    @discardableResult
    func deleteTool(_ tool: RemoteToolConfiguration) async -> Bool {
        guard canStartToolMutation,
              let toolIndex = tools.firstIndex(where: { $0.id == tool.id }) else {
            return false
        }
        isSavingToolChanges = true
        defer { isSavingToolChanges = false }
        let currentTool = tools[toolIndex]
        bumpConnectionRevision(for: tool.id)
        toolPendingDeletion = nil
        var toolsAfterDeletion = tools
        toolsAfterDeletion.remove(at: toolIndex)

        do {
            try await toolStore.save(toolsAfterDeletion)
        } catch {
            recordPersistenceError(
                "\(currentTool.name) could not be removed: \(error.localizedDescription)"
            )
            return false
        }

        tools = toolsAfterDeletion
        snapshots.removeAll { $0.toolID == currentTool.id }
        refreshMetadata.removeAll { $0.toolID == currentTool.id }
        errorsByToolID[currentTool.id] = nil

        var cleanupErrors: [String] = []
        do {
            try await saveCacheAndReloadWidget()
        } catch {
            cleanupErrors.append("widget cache: \(error.localizedDescription)")
        }
        do {
            try tokenVault.deleteToken(for: currentTool.id)
        } catch {
            pendingTokenDeletionIDs.insert(currentTool.id)
            cleanupErrors.append("saved token: \(error.localizedDescription)")
        }
        if !cleanupErrors.isEmpty {
            recordPersistenceError(
                "\(currentTool.name) was removed, but cleanup failed for \(cleanupErrors.joined(separator: "; "))."
            )
        }
        return true
    }

    func snapshots(for toolID: UUID) -> [QuotaSnapshot] {
        snapshots
            .filter { $0.toolID == toolID }
            .sorted {
                if $0.remainingPercent != $1.remainingPercent {
                    return $0.remainingPercent < $1.remainingPercent
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private func refresh(tools selectedTools: [RemoteToolConfiguration]) async {
        let requestedIDs = Set(selectedTools.filter(\.isEnabled).map(\.id))
        guard !requestedIDs.isEmpty else { return }
        let additionalIDs = Set(requestedIDs.filter { toolID in
            activeRefreshRevisionByToolID[toolID]
                != connectionRevisionByToolID[toolID, default: 0]
        })
        pendingRefreshToolIDs.formUnion(additionalIDs)

        if additionalIDs.isEmpty, let refreshTask {
            await refreshTask.value
            if refreshTask.isCancelled, !Task.isCancelled {
                pendingRefreshToolIDs.formUnion(requestedIDs)
            } else {
                return
            }
        }

        while !pendingRefreshToolIDs.isEmpty, !Task.isCancelled {
            if let refreshTask {
                await refreshTask.value
                continue
            }

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.drainRefreshQueue()
            }
            refreshTask = task
            await task.value
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    private func drainRefreshQueue() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshTask = nil
        }

        while !pendingRefreshToolIDs.isEmpty, !Task.isCancelled {
            let requestedIDs = pendingRefreshToolIDs
            pendingRefreshToolIDs.removeAll()
            let selectedTools = tools.filter {
                $0.isEnabled && requestedIDs.contains($0.id)
            }
            guard !selectedTools.isEmpty else { continue }
            for tool in selectedTools {
                activeRefreshRevisionByToolID[tool.id] =
                    connectionRevisionByToolID[tool.id, default: 0]
            }
            await performRefreshBatch(selectedTools)
            for tool in selectedTools {
                activeRefreshRevisionByToolID[tool.id] = nil
            }
        }
    }

    private func performRefreshBatch(_ selectedTools: [RemoteToolConfiguration]) async {
        let client = usageClient
        var requests: [(RemoteToolConfiguration, String, UInt)] = []
        for tool in selectedTools {
            let revision = connectionRevisionByToolID[tool.id, default: 0]
            do {
                let token = try tokenVault.token(for: tool.id) ?? ""
                requests.append((tool, token, revision))
            } catch {
                apply(
                    .failure(
                        tool: tool,
                        revision: revision,
                        message: "Saved token could not be read: \(error.localizedDescription)",
                        attemptedAt: Date()
                    )
                )
            }
        }

        await withTaskGroup(of: FetchOutcome.self) { group in
            for (tool, token, revision) in requests {
                group.addTask {
                    let attemptedAt = Date()
                    do {
                        let values = try await client.fetch(configuration: tool, token: token)
                        return .success(
                            tool: tool,
                            revision: revision,
                            snapshots: values,
                            attemptedAt: attemptedAt
                        )
                    } catch is CancellationError {
                        return .cancelled
                    } catch let error as URLError
                        where error.code == .cancelled && Task.isCancelled {
                        return .cancelled
                    } catch {
                        return .failure(
                            tool: tool,
                            revision: revision,
                            message: error.localizedDescription,
                            attemptedAt: attemptedAt
                        )
                    }
                }
            }

            for await outcome in group {
                if case .cancelled = outcome {
                    continue
                }
                apply(outcome)
            }
        }

        if Task.isCancelled {
            pendingRefreshToolIDs.formUnion(selectedTools.map(\.id))
            return
        }

        do {
            try await saveCacheAndReloadWidget()
        } catch {
            recordPersistenceError(
                "Current limits could not be saved for the widget: \(error.localizedDescription)"
            )
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .cancelled:
            return
        case let .success(tool, revision, values, attemptedAt):
            guard let currentTool = tools.first(where: { $0.id == tool.id }),
                  currentTool.isEnabled,
                  connectionRevisionByToolID[tool.id, default: 0] == revision else {
                return
            }
            snapshots.removeAll { $0.toolID == tool.id }
            snapshots.append(contentsOf: values)
            errorsByToolID[tool.id] = nil
            updateMetadata(for: tool.id) { metadata in
                metadata
                    .recordingAttempt(at: attemptedAt)
                    .recordingSuccess(
                        at: attemptedAt,
                        refreshIntervalMinutes: currentTool.refreshIntervalMinutes
                    )
            }

        case let .failure(tool, revision, message, attemptedAt):
            guard tools.contains(where: { $0.id == tool.id && $0.isEnabled }),
                  connectionRevisionByToolID[tool.id, default: 0] == revision else {
                return
            }
            errorsByToolID[tool.id] = message
            updateMetadata(for: tool.id) { metadata in
                metadata
                    .recordingAttempt(at: attemptedAt)
                    .recordingFailure(at: attemptedAt, retryDelay: .minutes(5))
            }
        }
    }

    private func updateMetadata(
        for toolID: UUID,
        transform: (RefreshScheduleMetadata) -> RefreshScheduleMetadata
    ) {
        let existing = refreshMetadata.first(where: { $0.toolID == toolID })
            ?? RefreshScheduleMetadata(toolID: toolID)
        refreshMetadata.removeAll { $0.toolID == toolID }
        refreshMetadata.append(transform(existing))
    }

    private func saveCacheAndReloadWidget() async throws {
        let savedAt = Date()
        try await quotaCache.save(
            QuotaCacheState(
                snapshots: snapshots,
                refreshMetadata: refreshMetadata,
                savedAt: savedAt
            )
        )
        cacheSavedAt = savedAt
        WidgetCenter.shared.reloadTimelines(ofKind: "com.richardq.usaige.limits")
        watchCoordinator.publish(watchSnapshotEnvelope(generatedAt: savedAt))
    }

    private func watchSnapshotEnvelope(generatedAt: Date = Date()) -> WatchUsageSnapshotEnvelope {
        let grouped = Dictionary(grouping: snapshots) { $0.toolID }
        let tools = enabledTools.compactMap { tool -> WatchToolQuotaSnapshot? in
            let toolSnapshots = grouped[tool.id] ?? []
            let limits = toolSnapshots.map { snapshot in
                WatchQuotaSnapshot(
                    id: snapshot.limitID,
                    displayName: snapshot.displayName,
                    primary: WatchQuotaWindowSnapshot(
                        remainingPercent: snapshot.remainingPercent,
                        resetAt: snapshot.resetAt,
                        windowDurationSeconds: snapshot.windowDurationMinutes.map { $0 * 60 }
                    ),
                    secondary: snapshot.secondaryWindow.map { window in
                        WatchQuotaWindowSnapshot(
                            remainingPercent: window.remainingPercent,
                            resetAt: window.resetAt,
                            windowDurationSeconds: window.windowDurationMinutes.map { $0 * 60 }
                        )
                    },
                    planType: snapshot.planType
                )
            }
            guard !limits.isEmpty else { return nil }
            return WatchToolQuotaSnapshot(
                id: tool.id.uuidString.lowercased(),
                displayName: tool.name,
                sourceUpdatedAt: toolSnapshots.map(\.updatedAt).min() ?? generatedAt,
                receivedAt: generatedAt,
                limits: limits,
                symbolName: tool.symbolName
            )
        }
        return WatchUsageSnapshotEnvelope(generatedAt: generatedAt, tools: tools)
    }

    private func recordPersistenceError(_ message: String) {
        systemErrorMessage = message
        canRetryPersistence = true
    }

    private func beginToolMutation() throws {
        guard canModifyTools else { throw AppModelError.savedToolsUnavailable }
        guard !isSavingToolChanges else { throw AppModelError.toolChangeInProgress }
        isSavingToolChanges = true
    }

    private func endToolMutation() {
        isSavingToolChanges = false
    }

    private func reconcileStoredTokens() {
        let errors = reconcileStoredTokens(validToolIDs: Set(tools.map(\.id)))
        guard !errors.isEmpty else { return }
        recordPersistenceError(
            "Saved token cleanup needs attention: \(errors.joined(separator: "; "))."
        )
    }

    private func reconcileStoredTokens(validToolIDs: Set<UUID>) -> [String] {
        var errors: [String] = []
        var orphanedIDs = pendingTokenDeletionIDs
        do {
            orphanedIDs.formUnion(
                try tokenVault.storedToolIDs().subtracting(validToolIDs)
            )
        } catch {
            errors.append("token inventory: \(error.localizedDescription)")
        }
        orphanedIDs.subtract(validToolIDs)

        for toolID in orphanedIDs {
            do {
                try tokenVault.deleteToken(for: toolID)
                pendingTokenDeletionIDs.remove(toolID)
            } catch {
                pendingTokenDeletionIDs.insert(toolID)
                errors.append("saved token: \(error.localizedDescription)")
            }
        }
        return errors
    }

    private func bumpConnectionRevision(for toolID: UUID) {
        connectionRevisionByToolID[toolID, default: 0] &+= 1
    }

    private static func haveSameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && (left.port ?? 443) == (right.port ?? 443)
    }
}

@MainActor
@Observable
final class RelayAppModel {
    var connection: RelayConnection?
    var snapshots: [QuotaSnapshot] = []
    var isRefreshing = false
    var pairingCode = ""
    var errorMessage: String?
    private(set) var cacheSavedAt: Date?
    private(set) var serverReceivedAt: Date?

    private let connectionStore: RelayConnectionStore
    private let quotaCache: SharedQuotaCache
    private let tokenVault: KeychainTokenVault
    private let client: RelayClient
    private let watchCoordinator: WatchSyncCoordinator
    private var etag: String?
    private var apnsToken: String?
    private var startupTask: Task<Void, Never>?
    private static let serverReceivedAtKey = "usAIge.relay.serverReceivedAt"

    init(
        connectionStore: RelayConnectionStore = RelayConnectionStore(),
        quotaCache: SharedQuotaCache = SharedQuotaCache(),
        tokenVault: KeychainTokenVault = KeychainTokenVault(service: "com.richardq.usaige.relay"),
        client: RelayClient = RelayClient(),
        watchCoordinator: WatchSyncCoordinator? = nil
    ) {
        self.connectionStore = connectionStore
        self.quotaCache = quotaCache
        self.tokenVault = tokenVault
        self.client = client
        let resolvedWatchCoordinator = watchCoordinator ?? WatchSyncCoordinator()
        self.watchCoordinator = resolvedWatchCoordinator
        resolvedWatchCoordinator.refreshHandler = { [weak self] in
            await self?.refreshAll()
            return self?.watchEnvelope() ?? WatchUsageSnapshotEnvelope(generatedAt: Date(), tools: [])
        }
        resolvedWatchCoordinator.activate()
    }

    var isConnected: Bool { connection != nil }
    var minimumRefreshIntervalMinutes: Int { 15 }
    var isCacheStale: Bool {
        guard let cacheSavedAt else { return !snapshots.isEmpty }
        return Date().timeIntervalSince(cacheSavedAt) > 15 * 60
    }
    var statusDetail: String {
        if let serverReceivedAt { return "Last received from \(connection?.macName ?? "Mac") \(serverReceivedAt.formatted(.relative(presentation: .named)))." }
        return "Open the Mac app and refresh again."
    }

    func start() async {
        if let startupTask { await startupTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                connection = try await connectionStore.load()
                let cache = try await quotaCache.load()
                snapshots = cache.snapshots
                cacheSavedAt = cache.savedAt
                serverReceivedAt = UserDefaults.standard.object(forKey: Self.serverReceivedAtKey) as? Date
                watchCoordinator.publish(watchEnvelope(generatedAt: cache.savedAt))
            } catch { errorMessage = "Saved connection could not be loaded: \(error.localizedDescription)" }
        }
        startupTask = task
        await task.value
    }

    func pair() async {
        let code = pairingCode
        isRefreshing = true
        errorMessage = nil
        do {
            let result = try await client.claim(code: code, deviceName: UIDevice.current.name)
            try tokenVault.save(result.readToken, for: result.connection.deviceID)
            do {
                try await connectionStore.save(result.connection)
            } catch {
                try? tokenVault.deleteToken(for: result.connection.deviceID)
                throw error
            }
            connection = result.connection
            pairingCode = ""
            if let apnsToken { try? await registerAPNs(apnsToken) }
            isRefreshing = false
            await refreshAll()
        } catch {
            isRefreshing = false
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard let connection else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let token = try tokenVault.token(for: connection.deviceID) else { throw RelayClientError.unauthorized }
            guard let result = try await client.fetch(connection: connection, token: token, etag: etag) else {
                errorMessage = nil
                return
            }
            snapshots = result.snapshots
            serverReceivedAt = result.serverReceivedAt
            UserDefaults.standard.set(result.serverReceivedAt, forKey: Self.serverReceivedAtKey)
            etag = result.etag
            errorMessage = nil
            try await saveCache()
        } catch {
            errorMessage = error.localizedDescription
            if let relayError = error as? RelayClientError, case .unauthorized = relayError {
                await clearLocalConnection()
            }
        }
    }

    @discardableResult
    func refreshDueTools(forceWhenCacheIsEmpty: Bool = false) async -> Bool {
        if forceWhenCacheIsEmpty || isCacheStale { await refreshAll() }
        return errorMessage == nil
    }

    func cancelRefresh() {}

    func receiveAPNsToken(_ data: Data, environment: String) async {
        let value = data.map { String(format: "%02x", $0) }.joined()
        apnsToken = value
        do { try await registerAPNs(value, environment: environment) }
        catch { errorMessage = "Push updates could not be enabled: \(error.localizedDescription)" }
    }

    func handleBackgroundPush() async -> Bool {
        await refreshAll()
        return errorMessage == nil
    }

    func disconnect() async {
        if let connection, let token = try? tokenVault.token(for: connection.deviceID) {
            try? await client.disconnect(connection: connection, token: token)
        }
        await clearLocalConnection()
    }

    private func registerAPNs(_ value: String, environment: String? = nil) async throws {
        guard let connection, let token = try tokenVault.token(for: connection.deviceID) else { return }
        #if DEBUG
        let resolvedEnvironment = environment ?? "sandbox"
        #else
        let resolvedEnvironment = environment ?? "production"
        #endif
        try await client.registerAPNs(connection: connection, token: token, apnsToken: value, environment: resolvedEnvironment)
    }

    private func clearLocalConnection() async {
        if let connection { try? tokenVault.deleteToken(for: connection.deviceID) }
        try? await connectionStore.delete()
        connection = nil
        snapshots = []
        etag = nil
        serverReceivedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.serverReceivedAtKey)
        try? await quotaCache.save(.empty)
        WidgetCenter.shared.reloadTimelines(ofKind: "com.richardq.usaige.limits")
    }

    private func saveCache() async throws {
        let now = Date()
        let toolIDs = Set(snapshots.map(\.toolID))
        let metadata = toolIDs.map {
            RefreshScheduleMetadata(toolID: $0).recordingAttempt(at: now).recordingSuccess(at: now, refreshIntervalMinutes: 15)
        }
        try await quotaCache.save(QuotaCacheState(snapshots: snapshots, refreshMetadata: metadata, savedAt: now))
        cacheSavedAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: "com.richardq.usaige.limits")
        watchCoordinator.publish(watchEnvelope(generatedAt: now))
    }

    private func watchEnvelope(generatedAt: Date = Date()) -> WatchUsageSnapshotEnvelope {
        let grouped = Dictionary(grouping: snapshots, by: \.toolID)
        let tools = grouped.compactMap { toolID, values -> WatchToolQuotaSnapshot? in
            guard let first = values.first else { return nil }
            return WatchToolQuotaSnapshot(
                id: toolID.uuidString.lowercased(),
                displayName: first.toolName,
                sourceUpdatedAt: values.map(\.updatedAt).min() ?? generatedAt,
                receivedAt: generatedAt,
                limits: values.map { snapshot in
                    WatchQuotaSnapshot(
                        id: snapshot.limitID,
                        displayName: snapshot.displayName,
                        primary: WatchQuotaWindowSnapshot(remainingPercent: snapshot.remainingPercent, resetAt: snapshot.resetAt, windowDurationSeconds: snapshot.windowDurationMinutes.map { $0 * 60 }),
                        secondary: snapshot.secondaryWindow.map { WatchQuotaWindowSnapshot(remainingPercent: $0.remainingPercent, resetAt: $0.resetAt, windowDurationSeconds: $0.windowDurationMinutes.map { $0 * 60 }) },
                        planType: snapshot.planType
                    )
                },
                symbolName: "sparkles"
            )
        }
        return WatchUsageSnapshotEnvelope(generatedAt: generatedAt, tools: tools)
    }
}

private enum FetchOutcome: Sendable {
    case cancelled
    case success(
        tool: RemoteToolConfiguration,
        revision: UInt,
        snapshots: [QuotaSnapshot],
        attemptedAt: Date
    )
    case failure(
        tool: RemoteToolConfiguration,
        revision: UInt,
        message: String,
        attemptedAt: Date
    )
}

private enum AppModelError: LocalizedError {
    case duplicateEndpoint
    case emptyLimits
    case toolNotFound
    case savedToolsUnavailable
    case toolChangeInProgress
    case tokenDecisionRequired
    case credentialCleanupFailed(saveError: String, cleanupError: String)

    var errorDescription: String? {
        switch self {
        case .duplicateEndpoint:
            "This endpoint is already connected."
        case .emptyLimits:
            "The endpoint returned no usable limits."
        case .toolNotFound:
            "This AI tool no longer exists."
        case .savedToolsUnavailable:
            "Saved tools are unavailable. Retry loading them before making changes."
        case .toolChangeInProgress:
            "Another tool change is still being saved. Try again in a moment."
        case .tokenDecisionRequired:
            "The endpoint host changed. Enter a token for the new host or choose Remove saved bearer token."
        case let .credentialCleanupFailed(saveError, cleanupError):
            "The connection could not be saved (\(saveError)), and its unsaved token still needs cleanup (\(cleanupError))."
        }
    }
}

private extension TimeInterval {
    static func minutes(_ value: Double) -> TimeInterval {
        value * 60
    }
}
