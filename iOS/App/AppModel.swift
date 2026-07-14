import Foundation
import Observation
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
        usageClient: RemoteUsageClient = RemoteUsageClient()
    ) {
        self.toolStore = toolStore
        self.quotaCache = quotaCache
        self.tokenVault = tokenVault
        self.usageClient = usageClient
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
