import AppKit
import Combine
import Foundation
import Security

struct RelayWindowPayload: Encodable, Equatable, Sendable {
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?
}

struct RelayLimitPayload: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let planType: String?
    let primary: RelayWindowPayload
    let secondary: RelayWindowPayload?
}

struct RelayToolPayload: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let symbolName: String
    let limits: [RelayLimitPayload]
}

struct RelaySnapshotPayload: Encodable, Equatable, Sendable {
    let schemaVersion = 1
    let generatedAt: Date
    let tools: [RelayToolPayload]

    static func make(from snapshots: [QuotaSnapshot], at date: Date = Date()) -> Self {
        let orderedIDs = snapshots.reduce(into: [AIToolID]()) { values, snapshot in
            if !values.contains(snapshot.toolID) { values.append(snapshot.toolID) }
        }
        let tools = orderedIDs.compactMap { toolID -> RelayToolPayload? in
            let values = snapshots.filter { $0.toolID == toolID }
            guard let first = values.first else { return nil }
            let descriptor = AIToolDescriptor.descriptor(for: first)
            return RelayToolPayload(
                id: toolID.rawValue,
                name: first.toolName ?? descriptor.name,
                symbolName: first.toolSystemImage ?? descriptor.systemImage,
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
                }
            )
        }
        return Self(generatedAt: date, tools: tools)
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

@MainActor
final class RelaySyncController: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, connected, uploading, failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var devices: [RelayPhoneDevice] = []
    @Published private(set) var lastUploadAt: Date?

    private static let relayURL = URL(string: "https://usaige-macos.richardqz.chatgpt.site/api/v1/")!
    private static let channelKey = "usageHUD.relay.channelID"
    private static let macNameKey = "usageHUD.relay.macName"
    private static let heartbeatInterval: TimeInterval = 20 * 60
    private let defaults: UserDefaults
    private let session: URLSession
    private let credentials: RelayMacCredentialStore
    private var latestSnapshots: [QuotaSnapshot] = []
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isUploadInFlight = false
    private var hasPendingUpload = false

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        credentials: RelayMacCredentialStore = RelayMacCredentialStore()
    ) {
        self.defaults = defaults
        self.session = session
        self.credentials = credentials
        status = channelID == nil ? .disconnected : .connected
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
            }
        }
        if isLinked { Task { await refreshDevices() } }
    }

    func observe(_ snapshots: [QuotaSnapshot]) {
        latestSnapshots = snapshots
        guard isLinked else { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.uploadLatest(force: false)
        }
    }

    func createChannel() async {
        status = .connecting
        do {
            var request = URLRequest(url: Self.relayURL.appendingPathComponent("channels"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["macName": macName])
            let response: CreateChannelResponse = try await send(request)
            try credentials.save(response.uploadToken)
            defaults.set(response.channelID, forKey: Self.channelKey)
            defaults.set(response.macName, forKey: Self.macNameKey)
            pairingCode = response.pairingCode
            pairingExpiresAt = response.expiresAt
            status = .connected
            retryAttempt = 0
            await uploadLatest(force: true)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func createPairingCode() async {
        guard let channelID else { await createChannel(); return }
        do {
            let response: PairingResponse = try await authorizedRequest(method: "POST", path: "channels/\(channelID)/pairings")
            pairingCode = response.pairingCode
            pairingExpiresAt = response.expiresAt
            status = .connected
        } catch { status = .failed(error.localizedDescription) }
    }

    func refreshDevices() async {
        guard let channelID else { return }
        do {
            let response: DeviceListResponse = try await authorizedRequest(method: "GET", path: "channels/\(channelID)/devices")
            devices = response.devices
            status = .connected
        } catch { status = .failed(error.localizedDescription) }
    }

    func revoke(_ device: RelayPhoneDevice) async {
        guard let channelID else { return }
        do {
            try await authorizedVoid(method: "DELETE", path: "channels/\(channelID)/devices/\(device.id)")
            devices.removeAll { $0.id == device.id }
        } catch { status = .failed(error.localizedDescription) }
    }

    func disconnectAll() async {
        guard let channelID else { return }
        do { try await authorizedVoid(method: "DELETE", path: "channels/\(channelID)") }
        catch { status = .failed(error.localizedDescription); return }
        try? credentials.delete()
        defaults.removeObject(forKey: Self.channelKey)
        pairingCode = nil
        pairingExpiresAt = nil
        devices = []
        lastUploadAt = nil
        status = .disconnected
    }

    private func uploadLatest(force: Bool) async {
        guard let channelID else { return }
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
            let payload = RelaySnapshotPayload.make(from: latestSnapshots)
            var request = try authorizedURLRequest(method: "PUT", path: "channels/\(channelID)/snapshot")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let _: UploadResponse = try await send(request)
            lastUploadAt = Date()
            status = .connected
            retryAttempt = 0
        } catch {
            status = .failed(error.localizedDescription)
            guard force || retryAttempt < 5 else { return }
            retryAttempt += 1
            let delay = min(300.0, pow(2.0, Double(retryAttempt)))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self?.uploadLatest(force: false)
            }
        }
    }

    private func authorizedRequest<T: Decodable>(method: String, path: String) async throws -> T {
        try await send(authorizedURLRequest(method: method, path: path))
    }

    private func authorizedVoid(method: String, path: String) async throws {
        let request = try authorizedURLRequest(method: method, path: path)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelaySyncError.requestFailed
        }
    }

    private func authorizedURLRequest(method: String, path: String) throws -> URLRequest {
        guard let token = try credentials.token() else { throw RelaySyncError.missingCredential }
        var request = URLRequest(url: Self.relayURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "The relay request failed."
            throw RelaySyncError.server(message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

private struct CreateChannelResponse: Decodable { let channelID, uploadToken, macName, pairingCode: String; let expiresAt: Date }
private struct PairingResponse: Decodable { let pairingCode: String; let expiresAt: Date }
private struct DeviceListResponse: Decodable { let devices: [RelayPhoneDevice] }
private struct UploadResponse: Decodable { let version: Int; let serverReceivedAt: Date; let changed: Bool }
private struct ErrorResponse: Decodable { let error: String }
private enum RelaySyncError: LocalizedError { case missingCredential, requestFailed, server(String); var errorDescription: String? { switch self { case .missingCredential: "The Mac relay key is missing. Disconnect and pair again."; case .requestFailed: "The relay request failed."; case let .server(message): message } } }

struct RelayMacCredentialStore: Sendable {
    private let service = "com.richardq.usaige.relay"
    private let account = "mac-upload-token"
    func token() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw RelaySyncError.requestFailed }
        return value
    }
    func save(_ value: String) throws {
        try? delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw RelaySyncError.requestFailed }
    }
    func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelaySyncError.requestFailed }
    }
}
