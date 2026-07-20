import Foundation
import Security
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchUsageModel: NSObject, ObservableObject {
    @Published private(set) var envelope: WatchUsageSnapshotEnvelope?
    @Published private(set) var isRefreshing = false
    @Published private(set) var phoneIsReachable = false
    @Published private(set) var hasCellularCredentials = false
    @Published var errorMessage: String?

    private let cache: WatchSnapshotFileStore
    private let credentialStore: WatchRelayCredentialStore
    private let directClient: WatchRelayClient
    private let installationID: UUID
    private let session: WCSession?
    private var isProvisioning = false

    override init() {
        cache = WatchSnapshotFileStore(fileURL: AppGroup.snapshotURL())
        credentialStore = WatchRelayCredentialStore()
        directClient = WatchRelayClient()
        installationID = WatchInstallationIdentity.current()
        session = WCSession.isSupported() ? .default : nil
        envelope = try? cache.load()
        hasCellularCredentials = !((try? credentialStore.load()) ?? []).isEmpty
        super.init()
        session?.delegate = self
        session?.activate()
        phoneIsReachable = session?.isReachable ?? false
        if envelope != nil {
            WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        }
    }

    var isStale: Bool {
        guard let envelope, !envelope.tools.isEmpty else { return true }
        return envelope.tools.contains(where: isStale)
    }

    func isStale(_ tool: WatchToolQuotaSnapshot) -> Bool {
        Date().timeIntervalSince(tool.sourceUpdatedAt) > 30 * 60
    }

    func refresh() {
        guard !isRefreshing else { return }
        if let session, session.activationState == .activated, session.isReachable {
            refreshFromPhone(session)
        } else {
            refreshFromServer()
        }
    }

    var canRefresh: Bool { phoneIsReachable || hasCellularCredentials }

    func refreshIfNeeded() {
        guard isStale, canRefresh else { return }
        refresh()
    }

    private func refreshFromPhone(_ session: WCSession) {
        isRefreshing = true
        sendRefreshMessage(session)
    }

    // WatchConnectivity invokes reply and error handlers on its own operation queue.
    // Create the closures outside MainActor isolation so Swift 6 does not enforce the
    // main executor before the handlers can explicitly hop back to it.
    private nonisolated func sendRefreshMessage(_ session: WCSession) {
        session.sendMessage(
            [WatchMessageKey.command: WatchMessageKey.refresh],
            replyHandler: { [weak self] reply in
                guard let data = reply[WatchMessageKey.snapshot] as? Data else {
                    Task { @MainActor in
                        self?.isRefreshing = false
                        self?.errorMessage = "The iPhone did not return current limits."
                    }
                    return
                }
                self?.decodeAndAccept(data)
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isRefreshing = false
                    self?.errorMessage = error.localizedDescription
                    self?.refreshFromServer()
                }
            }
        )
    }

    private func refreshFromServer() {
        let credentials = (try? credentialStore.load()) ?? []
        guard !credentials.isEmpty else {
            errorMessage = "Open usAIge on the paired iPhone once to enable cellular sync."
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let result = await directClient.fetch(credentials: credentials)
            await MainActor.run {
                guard !result.successfulChannelIDs.isEmpty else {
                    self.isRefreshing = false
                    self.errorMessage = result.errorMessage ?? "The usAIge server could not be reached."
                    return
                }
                let retained = self.envelope?.tools.filter { tool in
                    guard let sourceID = tool.sourceID,
                          let channelID = UUID(uuidString: sourceID) else { return true }
                    return !result.successfulChannelIDs.contains(channelID)
                } ?? []
                self.accept(
                    WatchUsageSnapshotEnvelope(
                        generatedAt: Date(),
                        tools: retained + result.tools
                    )
                )
                if result.failedCount > 0 {
                    self.errorMessage = "Some Macs could not be refreshed from the usAIge server."
                }
            }
        }
    }

    private func provisionCellularIfPossible() {
        guard !isProvisioning,
              let session,
              session.activationState == .activated,
              session.isReachable else { return }
        isProvisioning = true
        sendProvisionMessage(session, installationID: installationID)
    }

    private nonisolated func sendProvisionMessage(
        _ session: WCSession,
        installationID: UUID
    ) {
        session.sendMessage(
            [
                WatchMessageKey.command: WatchMessageKey.provisionCellular,
                WatchMessageKey.installationID: installationID.uuidString.lowercased(),
            ],
            replyHandler: { [weak self] reply in
                guard let data = reply[WatchMessageKey.relayCredentials] as? Data,
                      let credentials = try? WatchRelayCredentialCodec.decode(data) else {
                    Task { @MainActor in self?.isProvisioning = false }
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try credentialStore.save(credentials)
                        hasCellularCredentials = !credentials.isEmpty
                    } catch {
                        errorMessage = "Cellular sync credentials could not be saved."
                    }
                    isProvisioning = false
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in self?.isProvisioning = false }
            }
        )
    }

    private nonisolated func decodeAndAccept(_ data: Data) {
        do {
            let envelope = try WatchUsageSnapshotCodec.decode(data)
            Task { @MainActor [weak self] in
                self?.accept(envelope)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.isRefreshing = false
                self?.errorMessage = "The iPhone sent an unsupported usage snapshot."
            }
        }
    }

    private func accept(_ newEnvelope: WatchUsageSnapshotEnvelope) {
        guard newEnvelope.schemaVersion == WatchUsageSnapshotEnvelope.currentSchemaVersion else {
            isRefreshing = false
            errorMessage = "Update usAIge on both devices to continue."
            return
        }

        do {
            try cache.save(newEnvelope)
            envelope = newEnvelope
            isRefreshing = false
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        } catch {
            isRefreshing = false
            errorMessage = "Could not save the latest limits."
        }
    }
}

extension WatchUsageModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isReachable = session.isReachable
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.phoneIsReachable = isReachable
            if let errorDescription { self?.errorMessage = errorDescription }
            if isReachable { self?.provisionCellularIfPossible() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneIsReachable = isReachable
            if isReachable { self?.provisionCellularIfPossible() }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[WatchMessageKey.snapshot] as? Data else { return }
        decodeAndAccept(data)
        Task { @MainActor [weak self] in
            self?.provisionCellularIfPossible()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo[WatchMessageKey.snapshot] as? Data else { return }
        decodeAndAccept(data)
    }
}

private enum WatchInstallationIdentity {
    private static let key = "usAIge.watch.installationID"

    static func current(defaults: UserDefaults = .standard) -> UUID {
        if let value = defaults.string(forKey: key), let identifier = UUID(uuidString: value) {
            return identifier
        }
        let identifier = UUID()
        defaults.set(identifier.uuidString.lowercased(), forKey: key)
        return identifier
    }
}

private struct WatchRelayCredentialStore: Sendable {
    private let service = "com.richardq.usaige.watch.relay"
    private let account = "cellular-credentials"

    func load() throws -> [WatchRelayCredential] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WatchRelayCredentialStoreError.keychain(status)
        }
        return try WatchRelayCredentialCodec.decode(data)
    }

    func save(_ credentials: [WatchRelayCredential]) throws {
        let data = try WatchRelayCredentialCodec.encode(credentials)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw WatchRelayCredentialStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw WatchRelayCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

private enum WatchRelayCredentialStoreError: Error {
    case keychain(OSStatus)
}

private struct WatchDirectSyncResult: Sendable {
    let tools: [WatchToolQuotaSnapshot]
    let successfulChannelIDs: Set<UUID>
    let failedCount: Int
    let errorMessage: String?
}

private struct WatchRelayClient: Sendable {
    private static let baseURL = URL(string: "https://usaige-macos.richardqz.chatgpt.site/api/v1/")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(
            configuration: configuration,
            delegate: WatchRelaySessionDelegate(),
            delegateQueue: nil
        )
    }

    func fetch(credentials: [WatchRelayCredential]) async -> WatchDirectSyncResult {
        var tools: [WatchToolQuotaSnapshot] = []
        var successes: Set<UUID> = []
        var failures = 0
        var lastError: String?
        for credential in credentials {
            do {
                tools.append(contentsOf: try await fetch(credential: credential))
                successes.insert(credential.channelID)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }
        return WatchDirectSyncResult(
            tools: tools,
            successfulChannelIDs: successes,
            failedCount: failures,
            errorMessage: lastError
        )
    }

    private func fetch(credential: WatchRelayCredential) async throws -> [WatchToolQuotaSnapshot] {
        let url = Self.baseURL.appending(
            path: "channels/\(credential.channelID.uuidString.lowercased())/snapshot"
        )
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.readToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WatchRelayClientError.requestFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(WatchRelayEnvelope.self, from: data)
        return envelope.snapshot.tools.map { tool in
            WatchToolQuotaSnapshot(
                id: "\(credential.channelID.uuidString.lowercased()):\(tool.id)",
                displayName: tool.name,
                sourceID: credential.channelID.uuidString.lowercased(),
                sourceName: envelope.macName,
                serverUpdatedAt: envelope.serverReceivedAt,
                sourceUpdatedAt: envelope.snapshot.generatedAt,
                receivedAt: Date(),
                limits: tool.limits.map { limit in
                    WatchQuotaSnapshot(
                        id: limit.id,
                        displayName: limit.name,
                        primary: limit.primary.watchSnapshot,
                        secondary: limit.secondary?.watchSnapshot,
                        planType: limit.planType
                    )
                },
                sessionStatus: tool.sessionStatus.map {
                    WatchSessionStatus(phase: $0.phase, updatedAt: $0.updatedAt)
                },
                symbolName: tool.symbolName
            )
        }
    }
}

private final class WatchRelaySessionDelegate: NSObject,
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

private enum WatchRelayClientError: LocalizedError {
    case requestFailed
    var errorDescription: String? { "The usAIge server could not be reached." }
}

private struct WatchRelayEnvelope: Decodable {
    let serverReceivedAt: Date
    let macName: String
    let snapshot: WatchRelaySnapshotDocument
}

private struct WatchRelaySnapshotDocument: Decodable {
    let generatedAt: Date
    let tools: [WatchRelayToolDocument]
}

private struct WatchRelayToolDocument: Decodable {
    let id: String
    let name: String
    let symbolName: String
    let limits: [WatchRelayLimitDocument]
    let sessionStatus: WatchRelaySessionStatusDocument?
}

private struct WatchRelaySessionStatusDocument: Decodable {
    let phase: WatchSessionPhase
    let updatedAt: Date
}

private struct WatchRelayLimitDocument: Decodable {
    let id: String
    let name: String
    let planType: String?
    let primary: WatchRelayWindowDocument
    let secondary: WatchRelayWindowDocument?
}

private struct WatchRelayWindowDocument: Decodable {
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?

    var watchSnapshot: WatchQuotaWindowSnapshot {
        WatchQuotaWindowSnapshot(
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowDurationSeconds: windowDurationMinutes.map { $0 * 60 }
        )
    }
}
