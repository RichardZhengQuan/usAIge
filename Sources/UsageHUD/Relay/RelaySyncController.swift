import AppKit
import Combine
import Foundation

struct RelayWindowPayload: Codable, Equatable, Sendable {
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?
}

struct RelayLimitPayload: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let planType: String?
    let primary: RelayWindowPayload
    let secondary: RelayWindowPayload?
}

struct RelaySessionStatusPayload: Codable, Equatable, Sendable {
    let phase: CodexAgentPhase
    let updatedAt: Date
}

struct RelayResetCreditsPayload: Codable, Equatable, Sendable {
    let availableCount: Int
    let expiresAt: Date?
}

struct RelayToolPayload: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let symbolName: String
    let resetCredits: RelayResetCreditsPayload?
    let limits: [RelayLimitPayload]
    let sessionStatus: RelaySessionStatusPayload?
}

struct RelaySnapshotPayload: Encodable, Equatable, Sendable {
    let schemaVersion = 1
    let generatedAt: Date
    let tools: [RelayToolPayload]

    static func make(
        from snapshots: [QuotaSnapshot],
        codexSessionStatus: RelaySessionStatusPayload? = nil,
        at date: Date = Date()
    ) -> Self {
        make(
            from: snapshots,
            sessionStatuses: codexSessionStatus.map { [.chatGPT: $0] } ?? [:],
            at: date
        )
    }

    /// Every tool carries its own session light, so the iPhone shows the
    /// same activity the rail does.
    static func make(
        from snapshots: [QuotaSnapshot],
        sessionStatuses: [AIToolID: RelaySessionStatusPayload],
        at date: Date = Date()
    ) -> Self {
        let orderedIDs = snapshots.reduce(into: [AIToolID]()) { values, snapshot in
            if !values.contains(snapshot.toolID) { values.append(snapshot.toolID) }
        }
        let tools = orderedIDs.compactMap { toolID -> RelayToolPayload? in
            let values = snapshots.filter { $0.toolID == toolID }
            guard let first = values.first else { return nil }
            let descriptor = AIToolDescriptor.descriptor(for: first)
            let availableResetCount = values.compactMap(\.availableResetCount).first
            let resetCreditExpiresAt = values.compactMap(\.resetCreditExpiresAt).first
            return RelayToolPayload(
                id: toolID.rawValue,
                name: first.toolName ?? descriptor.name,
                symbolName: first.toolSystemImage ?? descriptor.systemImage,
                resetCredits: availableResetCount.map {
                    RelayResetCreditsPayload(
                        availableCount: $0,
                        expiresAt: resetCreditExpiresAt
                    )
                },
                limits: values.map { snapshot in
                    RelayLimitPayload(
                        id: snapshot.id,
                        name: snapshot.displayName,
                        planType: snapshot.planType,
                        primary: RelayWindowPayload(
                            remainingPercent: snapshot.remainingPercent,
                            resetAt: snapshot.resetAt,
                            windowDurationMinutes: snapshot.windowDurationMinutes
                        ),
                        secondary: snapshot.secondaryWindow.map {
                            RelayWindowPayload(
                                remainingPercent: $0.remainingPercent,
                                resetAt: $0.resetAt,
                                windowDurationMinutes: $0.windowDurationMinutes
                            )
                        }
                    )
                },
                sessionStatus: sessionStatuses[toolID]
            )
        }
        return Self(generatedAt: date, tools: tools)
    }
}

struct RelaySessionEventPayload: Encodable, Equatable, Sendable {
    enum Kind: String, Encodable, Sendable {
        case finished
        case error
        case permissionNeeded = "permission_needed"
    }

    let schemaVersion = 1
    let eventID: String
    let kind: Kind
    let sessionTitle: String
    let workspaceName: String
    let occurredAt: Date

    init?(task: CodexAgentTask) {
        switch task.phase {
        case .complete: kind = .finished
        case .error: kind = .error
        case .needsInput: kind = .permissionNeeded
        case .idle, .thinking: return nil
        }
        eventID = String("\(task.toolID.rawValue):\(task.id):\(task.phase.rawValue):\(task.updatedAt.timeIntervalSince1970)".prefix(256))
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = task.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = AIToolDescriptor.descriptor(for: task.toolID).name
        sessionTitle = String((title.isEmpty ? "\(toolName) session" : title).prefix(160))
        workspaceName = String((workspace.isEmpty ? "Mac workspace" : workspace).prefix(160))
        occurredAt = task.updatedAt
    }
}

struct RelayPhoneDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct RelayRemoteToolSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let limits: [RelayLimitPayload]
}

struct RelayRemoteTool: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let symbolName: String
    let websiteURL: URL?
    let createdAt: Date
    let lastUploadAt: Date?
    let snapshot: RelayRemoteToolSnapshot?

    var toolID: AIToolID { AIToolID(rawValue: id) }

    func quotaSnapshots() -> [QuotaSnapshot] {
        guard let snapshot else { return [] }
        return snapshot.limits.map { limit in
            var value = QuotaSnapshot.make(
                from: RateLimitBucket(
                    limitID: "\(id):\(limit.id)",
                    limitName: limit.name,
                    usedPercent: 100 - limit.primary.remainingPercent,
                    windowDurationMinutes: limit.primary.windowDurationMinutes,
                    resetsAt: limit.primary.resetAt?.timeIntervalSince1970,
                    planType: limit.planType,
                    secondaryUsedPercent: limit.secondary.map { 100 - $0.remainingPercent },
                    secondaryWindowDurationMinutes: limit.secondary?.windowDurationMinutes,
                    secondaryResetsAt: limit.secondary?.resetAt?.timeIntervalSince1970
                ),
                updatedAt: snapshot.generatedAt
            )
            value.toolID = toolID
            value.toolName = name
            value.toolWebURL = websiteURL
            value.toolSystemImage = symbolName
            return value
        }
    }
}

@MainActor
final class RelaySyncController: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, connected, uploading, failed(String)
    }

    enum RemoteToolsState: Equatable {
        case unconfigured, idle, loading, loaded, connectionUnavailable, failed(String)
    }

    enum RemoteToolActionState: Equatable {
        case idle, connecting, failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var devices: [RelayPhoneDevice] = []
    @Published private(set) var remoteTools: [RelayRemoteTool] = []
    @Published private(set) var remoteToolsState: RemoteToolsState = .unconfigured
    @Published private(set) var remoteToolActionState: RemoteToolActionState = .idle
    @Published private(set) var canReconnectRemoteTools = false
    @Published private(set) var remotePairingCode: String?
    @Published private(set) var remotePairingExpiresAt: Date?
    @Published private(set) var lastUploadAt: Date?

    private static let relayURL = URL(string: "https://pmrichq.com/project/usaige/api/v1/")!
    private static let channelKey = "usageHUD.relay.channelID"
    private static let macNameKey = "usageHUD.relay.macName"
    private static let heartbeatInterval: TimeInterval = 20 * 60
    private let defaults: UserDefaults
    private let session: URLSession
    private let credentials: RelayMacCredentialStore
    private var latestSnapshots: [QuotaSnapshot] = []
    private var latestSessionStatuses: [AIToolID: RelaySessionStatusPayload] = [:]
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var remotePairingPollTask: Task<Void, Never>?
    private var remotePairingPollID: UUID?
    private var channelGeneration = UUID()
    private var remoteToolsRequestID: UUID?
    private var remoteToolsRefreshTask: Task<[QuotaSnapshot], Error>?
    private var remoteToolsStateBeforeRefresh: RemoteToolsState?
    private var retryAttempt = 0
    private var isUploadInFlight = false
    private var hasPendingUpload = false
    private var sentSessionEventIDs: Set<String> = []
    private static let maximumRememberedSessionEventIDs = 2_000

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        credentials: RelayMacCredentialStore = RelayMacCredentialStore()
    ) {
        self.defaults = defaults
        self.session = session
        self.credentials = credentials

        // Older ad-hoc-signed builds stored this token in Keychain. Reading that
        // item from a newer build can display a system password prompt because
        // every ad-hoc build has a different code identity. Do not touch the old
        // item; reset the local link and let the user create a prompt-free one.
        if channelID != nil, (try? credentials.token()) == nil {
            defaults.removeObject(forKey: Self.channelKey)
            defaults.removeObject(forKey: Self.macNameKey)
        }
        status = channelID == nil ? .disconnected : .connected
        remoteToolsState = channelID == nil ? .unconfigured : .idle
    }

    var channelID: String? { defaults.string(forKey: Self.channelKey) }
    var macName: String { defaults.string(forKey: Self.macNameKey) ?? Host.current().localizedName ?? "Mac" }
    var isLinked: Bool { channelID != nil }

    func start() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard let self else { return }
                await self.uploadLatest(force: true)
                await self.refreshDevices()
                _ = try? await self.refreshRemoteTools()
            }
        }
        if isLinked {
            Task {
                await refreshDevices()
                _ = try? await refreshRemoteTools()
            }
        }
    }

    func observe(_ snapshots: [QuotaSnapshot]) {
        latestSnapshots = snapshots
        scheduleUpload()
    }

    func observeCodexSession(_ phase: CodexAgentPhase, at date: Date = Date()) {
        observeSession(phase, for: .chatGPT, at: date)
    }

    func observeSession(_ phase: CodexAgentPhase, for toolID: AIToolID, at date: Date = Date()) {
        let status = RelaySessionStatusPayload(phase: phase, updatedAt: date)
        guard status.phase != latestSessionStatuses[toolID]?.phase else { return }
        latestSessionStatuses[toolID] = status
        if !latestSnapshots.isEmpty {
            scheduleUpload()
        }
    }

    private func scheduleUpload() {
        guard isLinked else { return }
        // New data gets a fresh retry budget; the cap only stops one failed
        // upload from retrying forever.
        retryAttempt = 0
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadLatest(force: false)
        }
    }

    func sendSessionEvent(for task: CodexAgentTask) {
        guard let channelID, let payload = RelaySessionEventPayload(task: task),
              sentSessionEventIDs.insert(payload.eventID).inserted else { return }
        // Only recent IDs matter for de-duplication; keep the set bounded over
        // a long-running session.
        if sentSessionEventIDs.count > Self.maximumRememberedSessionEventIDs {
            sentSessionEventIDs.removeAll()
            sentSessionEventIDs.insert(payload.eventID)
        }
        let generation = channelGeneration
        Task { [weak self] in
            guard let self, self.isCurrentChannel(channelID, generation: generation) else { return }
            await self.postSessionEvent(payload)
        }
    }

    func createChannel() async {
        let generation = channelGeneration
        status = .connecting
        do {
            var request = URLRequest(url: Self.relayURL.appendingPathComponent("channels"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["macName": macName])
            let response: CreateChannelResponse = try await send(request)
            guard channelGeneration == generation else { return }
            try credentials.save(response.uploadToken)
            defaults.set(response.channelID, forKey: Self.channelKey)
            defaults.set(response.macName, forKey: Self.macNameKey)
            channelGeneration = UUID()
            remoteToolsState = .idle
            pairingCode = response.pairingCode
            pairingExpiresAt = response.expiresAt
            status = .connected
            retryAttempt = 0
            await uploadLatest(force: true)
        } catch {
            guard channelGeneration == generation else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func createPairingCode() async {
        guard let channelID else { await createChannel(); return }
        let generation = channelGeneration
        do {
            let response: PairingResponse = try await authorizedRequest(method: "POST", path: "channels/\(channelID)/pairings")
            guard isCurrentChannel(channelID, generation: generation) else { return }
            pairingCode = response.pairingCode
            pairingExpiresAt = response.expiresAt
            status = .connected
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func refreshDevices() async {
        guard let channelID else { return }
        let generation = channelGeneration
        do {
            let response: DeviceListResponse = try await authorizedRequest(method: "GET", path: "channels/\(channelID)/devices")
            guard isCurrentChannel(channelID, generation: generation) else { return }
            devices = response.devices
            status = .connected
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func createRemoteToolPairingCode() async {
        remoteToolActionState = .connecting
        if !isLinked {
            await createChannel()
        }
        guard let channelID else {
            guard status != .disconnected else { return }
            if case let .failed(message) = status {
                remoteToolActionState = .failed(message)
            } else {
                remoteToolActionState = .failed("The Mac relay connection could not be created.")
            }
            return
        }
        let generation = channelGeneration
        do {
            let response: PairingResponse = try await authorizedRequest(
                method: "POST",
                path: "channels/\(channelID)/tool-pairings"
            )
            guard isCurrentChannel(channelID, generation: generation) else { return }
            remotePairingCode = response.pairingCode
            remotePairingExpiresAt = response.expiresAt
            remoteToolActionState = .idle
            startRemotePairingPoll(expiresAt: response.expiresAt)
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            remoteToolActionState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func refreshRemoteTools() async throws -> [QuotaSnapshot] {
        if let task = remoteToolsRefreshTask { return try await task.value }
        guard let channelID else {
            remoteToolsState = .unconfigured
            throw RemoteUsageError.noSources
        }
        let requestID = UUID()
        let generation = channelGeneration
        remoteToolsRequestID = requestID
        remoteToolsStateBeforeRefresh = remoteToolsState
        remoteToolsState = .loading
        let task = Task { @MainActor [weak self] () throws -> [QuotaSnapshot] in
            guard let self else { throw CancellationError() }
            let response: RemoteToolsResponse
            do {
                response = try await authorizedRequest(
                    method: "GET",
                    path: "channels/\(channelID)/tools"
                )
            } catch {
                if remoteToolsRequestID == requestID, isCurrentChannel(channelID, generation: generation) {
                    remoteToolsState = isMissingChannel(error) ? .connectionUnavailable : .failed(error.localizedDescription)
                }
                throw error
            }
            guard isCurrentChannel(channelID, generation: generation), remoteToolsRequestID == requestID else {
                throw RemoteUsageError.noSources
            }
            remoteTools = response.tools
            remoteToolsState = .loaded
            canReconnectRemoteTools = false
            // An empty response is a successfully loaded list, but supplies no
            // authenticated usage source to the combined quota provider.
            guard !response.tools.isEmpty else { throw RemoteUsageError.noSources }
            return response.tools.flatMap { $0.quotaSnapshots() }
        }
        remoteToolsRefreshTask = task
        defer {
            if remoteToolsRequestID == requestID {
                remoteToolsRefreshTask = nil
                remoteToolsStateBeforeRefresh = nil
            }
        }
        return try await task.value
    }

    func reconnectRemoteTools() async {
        guard canReconnectRemoteTools, let channelID else { return }
        let generation = channelGeneration
        remoteToolActionState = .connecting
        do {
            _ = try await refreshRemoteTools()
            guard isCurrentChannel(channelID, generation: generation) else { return }
            remoteToolActionState = .idle
            return
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            guard isMissingChannel(error) else {
                if case RemoteUsageError.noSources = error {
                    remoteToolActionState = .idle
                } else {
                    remoteToolActionState = .failed(error.localizedDescription)
                }
                return
            }
        }
        // The user requested recovery and a fresh response confirmed that the
        // old channel is absent. No active server channel is being abandoned.
        clearLocalLink()
        await createRemoteToolPairingCode()
    }

    func revoke(_ tool: RelayRemoteTool) async {
        guard let channelID else { return }
        let generation = channelGeneration
        cancelRemoteToolsRefresh()
        remoteToolActionState = .connecting
        do {
            try await authorizedVoid(
                method: "DELETE",
                path: "channels/\(channelID)/tools/\(tool.id)"
            )
            guard isCurrentChannel(channelID, generation: generation) else { return }
            cancelRemoteToolsRefresh()
            remoteTools.removeAll { $0.id == tool.id }
            remoteToolActionState = .idle
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            remoteToolActionState = .failed(error.localizedDescription)
        }
    }

    func revoke(_ device: RelayPhoneDevice) async {
        guard let channelID else { return }
        let generation = channelGeneration
        do {
            try await authorizedVoid(method: "DELETE", path: "channels/\(channelID)/devices/\(device.id)")
            guard isCurrentChannel(channelID, generation: generation) else { return }
            devices.removeAll { $0.id == device.id }
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func disconnectAll() async {
        guard let channelID else { return }
        let generation = channelGeneration
        do { try await authorizedVoid(method: "DELETE", path: "channels/\(channelID)") }
        catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            guard isMissingChannel(error) else {
                status = .failed(error.localizedDescription)
                return
            }
        }
        guard isCurrentChannel(channelID, generation: generation) else { return }
        clearLocalLink()
    }

    private func clearLocalLink() {
        channelGeneration = UUID()
        try? credentials.delete()
        defaults.removeObject(forKey: Self.channelKey)
        defaults.removeObject(forKey: Self.macNameKey)
        pairingCode = nil
        pairingExpiresAt = nil
        devices = []
        remoteTools = []
        remoteToolsRequestID = nil
        remoteToolsRefreshTask?.cancel()
        remoteToolsRefreshTask = nil
        remoteToolsStateBeforeRefresh = nil
        remoteToolsState = .unconfigured
        remoteToolActionState = .idle
        canReconnectRemoteTools = false
        remotePairingCode = nil
        remotePairingExpiresAt = nil
        remotePairingPollTask?.cancel()
        remotePairingPollTask = nil
        remotePairingPollID = nil
        lastUploadAt = nil
        status = .disconnected
    }

    private func startRemotePairingPoll(expiresAt: Date) {
        remotePairingPollTask?.cancel()
        guard let channelID else { return }
        let generation = channelGeneration
        let pollID = UUID()
        remotePairingPollID = pollID
        let existingIDs = Set(remoteTools.map(\.id))
        remotePairingPollTask = Task { [weak self] in
            while !Task.isCancelled, Date() < expiresAt {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.isCurrentChannel(channelID, generation: generation),
                      self.remotePairingPollID == pollID else { return }
                _ = try? await self.refreshRemoteTools()
                guard !Task.isCancelled,
                      self.isCurrentChannel(channelID, generation: generation),
                      self.remotePairingPollID == pollID else { return }
                if Set(self.remoteTools.map(\.id)) != existingIDs {
                    self.remotePairingCode = nil
                    self.remotePairingExpiresAt = nil
                    return
                }
            }
            guard !Task.isCancelled, let self,
                  self.isCurrentChannel(channelID, generation: generation),
                  self.remotePairingPollID == pollID else { return }
            self.remotePairingCode = nil
            self.remotePairingExpiresAt = nil
        }
    }

    private func uploadLatest(force: Bool) async {
        guard let channelID else { return }
        let generation = channelGeneration
        if isUploadInFlight {
            hasPendingUpload = true
            return
        }
        isUploadInFlight = true
        defer {
            isUploadInFlight = false
            if hasPendingUpload {
                hasPendingUpload = false
                Task { [weak self] in await self?.uploadLatest(force: false) }
            }
        }
        status = .uploading
        do {
            let payload = RelaySnapshotPayload.make(
                from: latestSnapshots,
                sessionStatuses: latestSessionStatuses
            )
            var request = try authorizedURLRequest(method: "PUT", path: "channels/\(channelID)/snapshot")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let _: UploadResponse = try await send(request)
            guard isCurrentChannel(channelID, generation: generation) else { return }
            lastUploadAt = Date()
            status = .connected
            retryAttempt = 0
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            status = .failed(error.localizedDescription)
            guard force || retryAttempt < 5 else { return }
            retryAttempt += 1
            let delay = min(300.0, pow(2.0, Double(retryAttempt)))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.isCurrentChannel(channelID, generation: generation) else { return }
                await self.uploadLatest(force: false)
            }
        }
    }

    private func postSessionEvent(
        _ payload: RelaySessionEventPayload,
        attempt: Int = 0
    ) async {
        guard let channelID else { return }
        let generation = channelGeneration
        do {
            var request = try authorizedURLRequest(
                method: "POST",
                path: "channels/\(channelID)/session-events"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try await sendVoid(request)
        } catch {
            guard isCurrentChannel(channelID, generation: generation) else { return }
            guard attempt < 3 else {
                sentSessionEventIDs.remove(payload.eventID)
                return
            }
            let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard isCurrentChannel(channelID, generation: generation) else { return }
            await postSessionEvent(payload, attempt: attempt + 1)
        }
    }

    private func isCurrentChannel(_ id: String, generation: UUID) -> Bool {
        channelID == id && channelGeneration == generation
    }

    private func cancelRemoteToolsRefresh() {
        remoteToolsRequestID = nil
        remoteToolsRefreshTask?.cancel()
        remoteToolsRefreshTask = nil
        if remoteToolsState == .loading {
            remoteToolsState = remoteToolsStateBeforeRefresh ?? (isLinked ? .idle : .unconfigured)
        }
        remoteToolsStateBeforeRefresh = nil
    }

    private func authorizedRequest<T: Decodable>(method: String, path: String) async throws -> T {
        let requestChannelID = channelID
        let generation = channelGeneration
        do {
            return try await send(authorizedURLRequest(method: method, path: path))
        } catch {
            noteMissingChannel(error, channelID: requestChannelID, generation: generation)
            throw error
        }
    }

    private func authorizedVoid(method: String, path: String) async throws {
        let requestChannelID = channelID
        let generation = channelGeneration
        do {
            try await sendVoid(authorizedURLRequest(method: method, path: path))
        } catch {
            noteMissingChannel(error, channelID: requestChannelID, generation: generation)
            throw error
        }
    }

    private func isMissingChannel(_ error: Error) -> Bool {
        if case RelaySyncError.channelMissing = error { true } else { false }
    }

    private func noteMissingChannel(_ error: Error, channelID: String?, generation: UUID) {
        guard isMissingChannel(error), let channelID,
              isCurrentChannel(channelID, generation: generation) else { return }
        canReconnectRemoteTools = true
        remoteToolsState = .connectionUnavailable
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
    }

    private func authorizedURLRequest(method: String, path: String) throws -> URLRequest {
        guard let token = try credentials.token() else { throw RelaySyncError.missingCredential }
        var request = URLRequest(url: Self.relayURL.appendingPathComponent(Self.encodedPath(path)))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Percent-encodes each path segment so an identifier can never add or
    /// remove segments from the request path.
    nonisolated static func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                // "." and ".." are path syntax, not identifiers.
                let dotsOnly = segment.allSatisfy { $0 == "." }
                return segment.addingPercentEncoding(withAllowedCharacters: dotsOnly ? .alphanumerics : allowed) ?? ""
            }
            .joined(separator: "/")
    }

    /// The relay's error text goes straight into Settings, so keep it to one
    /// short line of printable text.
    nonisolated static func sanitizedServerMessage(
        _ message: String?,
        fallback: String = "The relay request failed."
    ) -> String {
        guard let message else { return fallback }
        let cleaned = message
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(200))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 404, http.mimeType?.lowercased() == "application/json",
               serverError?.code == "channel_not_found" {
                throw RelaySyncError.channelMissing
            }
            let fallback = "The sync service is unavailable. Try again later."
            let sanitized = Self.sanitizedServerMessage(serverError?.error, fallback: fallback)
            let genericMessages = ["Relay request failed.", "The relay request failed."]
            let message = genericMessages.contains(sanitized) ? fallback : sanitized
            throw RelaySyncError.server(message)
        }
    }
}

private struct CreateChannelResponse: Decodable { let channelID, uploadToken, macName, pairingCode: String; let expiresAt: Date }
private struct PairingResponse: Decodable { let pairingCode: String; let expiresAt: Date }
private struct DeviceListResponse: Decodable { let devices: [RelayPhoneDevice] }
private struct RemoteToolsResponse: Decodable { let tools: [RelayRemoteTool] }
private struct UploadResponse: Decodable { let version: Int; let serverReceivedAt: Date; let changed: Bool }
private struct ErrorResponse: Decodable { let error: String; let code: String? }
private enum RelaySyncError: LocalizedError { case missingCredential, requestFailed, channelMissing, server(String); var errorDescription: String? { switch self { case .missingCredential: "This Mac’s connection key is missing. Restart usAIge and connect again."; case .requestFailed: "The sync service is unavailable. Try again later."; case .channelMissing: "This Mac’s previous connection is no longer available. Reconnect to create a new connection."; case let .server(message): message } } }

struct RelayMacCredentialStore: Sendable {
    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/usAIge", isDirectory: true)
        .appendingPathComponent("relay-upload-token", isDirectory: false)

    private let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func token() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw RelaySyncError.requestFailed
        }
        return value
    }

    func save(_ value: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        // Create the file owner-only from the first byte instead of tightening
        // it after the write, then move it into place atomically.
        let staging = directory.appendingPathComponent(".relay-upload-token.\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw RelaySyncError.requestFailed }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
