import Foundation
import XCTest
@testable import usAIge_iOS

final class RemoteUsageClientTests: XCTestCase {
    func testSessionNotificationRouterTargetsTheInboxEvent() throws {
        let channelID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let destination = try XCTUnwrap(SessionNotificationRouter.destination(
            categoryIdentifier: SessionNotificationRouter.categoryIdentifier,
            userInfo: [
                "sessionEvent": [
                    "id": "session-1:permission_needed:123",
                    "channelID": channelID.uuidString.lowercased(),
                ],
            ]
        ))

        XCTAssertEqual(destination.channelID, channelID)
        XCTAssertEqual(destination.eventID, "session-1:permission_needed:123")
        XCTAssertNil(SessionNotificationRouter.destination(
            categoryIdentifier: "OTHER",
            userInfo: [:]
        ))
    }

    func testFetchOmitsAuthorizationForPublicEndpoint() async throws {
        let snapshots = try await client().fetch(
            configuration: configuration(path: "/public"),
            token: ""
        )

        XCTAssertEqual(snapshots.map(\.remainingPercent), [75])
    }

    func testFetchSendsBearerAuthorizationWhenTokenExists() async throws {
        let snapshots = try await client().fetch(
            configuration: configuration(path: "/secured"),
            token: "secret-token"
        )

        XCTAssertEqual(snapshots.map(\.updatedAt), [Date(timeIntervalSince1970: 1_000)])
    }

    func testFetchRejectsResponsesOverSafetyLimit() async {
        do {
            _ = try await client(maximumResponseBytes: 32).fetch(
                configuration: configuration(path: "/large"),
                token: ""
            )
            XCTFail("Expected an oversized-response error")
        } catch {
            XCTAssertEqual(
                error as? RemoteUsageClientError,
                .responseTooLarge(maximumBytes: 32)
            )
        }
    }

    func testFetchRejectsNonHTTPSAndHTTPFailures() async {
        let insecure = RemoteToolConfiguration(
            name: "Insecure",
            endpointURL: URL(string: "http://example.com/public")!
        )
        do {
            _ = try await client().fetch(configuration: insecure, token: "")
            XCTFail("Expected an invalid endpoint error")
        } catch {
            XCTAssertEqual(error as? RemoteUsageClientError, .invalidEndpoint)
        }

        let credentialInURL = RemoteToolConfiguration(
            name: "Unsafe",
            endpointURL: URL(string: "https://example.com/public?token=secret")!
        )
        do {
            _ = try await client().fetch(configuration: credentialInURL, token: "")
            XCTFail("Expected credentials in URLs to be rejected")
        } catch {
            XCTAssertEqual(error as? RemoteUsageClientError, .invalidEndpoint)
        }

        do {
            _ = try await client().fetch(
                configuration: configuration(path: "/failure"),
                token: ""
            )
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? RemoteUsageClientError, .unsuccessfulStatus(503))
        }
    }

    func testFetchRejectsRedirectResponses() async {
        do {
            _ = try await client().fetch(
                configuration: configuration(path: "/redirect"),
                token: "secret-token"
            )
            XCTFail("Expected redirects to be rejected")
        } catch {
            XCTAssertEqual(error as? RemoteUsageClientError, .redirectNotAllowed)
        }
    }

    func testRelayToolIdentityIsStableWithinMacAndDistinctAcrossMacs() {
        let firstMac = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let secondMac = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        let first = RelayClient.scopedToolUUID(channelID: firstMac, toolID: "chatgpt")

        XCTAssertEqual(
            first,
            RelayClient.scopedToolUUID(channelID: firstMac, toolID: "chatgpt")
        )
        XCTAssertNotEqual(
            first,
            RelayClient.scopedToolUUID(channelID: secondMac, toolID: "chatgpt")
        )
    }

    func testRelayFetchDecodesStatusAndResetCredits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteUsageStubURLProtocol.self]
        let relay = RelayClient(session: URLSession(configuration: configuration))
        let connection = RelayConnection(
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            macName: "Studio Mac"
        )

        let fetched = try await relay.fetch(connection: connection, token: "read-token")
        let result = try XCTUnwrap(fetched)

        XCTAssertEqual(result.snapshots.first?.sessionStatus?.phase, .thinking)
        XCTAssertEqual(
            result.snapshots.first?.sessionStatus?.updatedAt,
            Date(timeIntervalSince1970: 1_800_000_099)
        )
        XCTAssertEqual(result.snapshots.first?.availableResetCount, 1)
        XCTAssertEqual(
            result.snapshots.first?.resetCreditExpiresAt,
            Date(timeIntervalSince1970: 1_800_950_400)
        )
    }

    func testRelayRegistrationIncludesSessionNotificationPreference() async throws {
        RemoteUsageStubURLProtocol.resetLastRequest()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteUsageStubURLProtocol.self]
        let relay = RelayClient(session: URLSession(configuration: configuration))
        let connection = RelayConnection(
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            macName: "Studio Mac"
        )

        try await relay.registerAPNs(
            connection: connection,
            token: "read-token",
            apnsToken: String(repeating: "a", count: 64),
            environment: "sandbox",
            sessionNotificationsEnabled: true
        )

        let request = try XCTUnwrap(RemoteUsageStubURLProtocol.lastRequest)
        let body = try XCTUnwrap(RemoteUsageStubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["sessionNotificationsEnabled"] as? Bool, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer read-token")
    }

    func testRelayFetchesSessionNotificationHistory() async throws {
        let relay = relayClient()
        let connection = RelayConnection(
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            macName: "Studio Mac"
        )

        let events = try await relay.fetchSessionEvents(
            connection: connection,
            token: "read-token"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventID, "session-1:finished:123")
        XCTAssertEqual(events.first?.kind, .finished)
        XCTAssertEqual(events.first?.sessionTitle, "Ship notification inbox")
        XCTAssertEqual(events.first?.workspaceName, "GPTUsage")
        XCTAssertEqual(events.first?.macName, "Studio Mac")
        XCTAssertEqual(
            events.first?.id,
            "11111111-1111-4111-8111-111111111111:session-1:finished:123"
        )
    }

    func testWatchDeviceIdentityIsStableScopedAndRFCCompliant() {
        let firstMac = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let secondMac = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let installation = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

        let first = RelayClient.scopedDeviceUUID(
            channelID: firstMac,
            installationID: installation
        )

        XCTAssertEqual(
            first,
            RelayClient.scopedDeviceUUID(channelID: firstMac, installationID: installation)
        )
        XCTAssertNotEqual(
            first,
            RelayClient.scopedDeviceUUID(channelID: secondMac, installationID: installation)
        )
        XCTAssertNotNil(
            first.uuidString.range(
                of: #"^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"#,
                options: .regularExpression
            )
        )
    }

    private func client(maximumResponseBytes: Int = 1_048_576) -> RemoteUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteUsageStubURLProtocol.self]
        return RemoteUsageClient(
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_000) },
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func relayClient() -> RelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteUsageStubURLProtocol.self]
        return RelayClient(session: URLSession(configuration: configuration))
    }

    private func configuration(path: String) -> RemoteToolConfiguration {
        RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com\(path)")!
        )
    }
}

final class RelayClientSessionStatusTests: XCTestCase {
    func testRelayFetchDecodesCodexSessionStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelaySnapshotStubURLProtocol.self]
        let client = RelayClient(session: URLSession(configuration: configuration))
        let connection = RelayConnection(
            channelID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            macName: "Test Mac"
        )

        let fetched = try await client.fetch(connection: connection, token: "read-token")
        let result = try XCTUnwrap(fetched)

        XCTAssertEqual(result.snapshots.count, 1)
        XCTAssertEqual(result.snapshots[0].sessionStatus?.phase, .needsInput)
        XCTAssertEqual(
            result.snapshots[0].sessionStatus?.updatedAt,
            ISO8601DateFormatter().date(from: "2026-07-19T12:00:02Z")
        )
    }
}

private final class RemoteUsageStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestRecorder = RelayRequestRecorder()

    static var lastRequest: URLRequest? { requestRecorder.lastRequest }
    static var lastRequestBody: Data? { requestRecorder.lastRequestBody }
    static func resetLastRequest() { requestRecorder.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path.contains("/api/v1/channels/") {
            Self.requestRecorder.record(request)
        }

        let statusCode: Int
        switch url.path {
        case "/public":
            statusCode = request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 400
        case "/secured":
            statusCode = request.value(forHTTPHeaderField: "Authorization")
                == "Bearer secret-token" ? 200 : 401
        case "/large":
            statusCode = 200
        case "/redirect":
            statusCode = 302
        case let path where path.contains("/api/v1/channels/"):
            statusCode = 200
        default:
            statusCode = 503
        }

        var headers = ["Content-Type": "application/json"]
        if url.path == "/large" {
            headers["Content-Length"] = "100"
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let responseBody: Data
        if url.path.hasSuffix("/session-events"), request.httpMethod == "GET" {
            responseBody = Data(#"{"events":[{"id":"session-1:finished:123","kind":"finished","sessionTitle":"Ship notification inbox","workspaceName":"GPTUsage","occurredAt":"2026-07-19T12:00:00Z"}]}"#.utf8)
        } else if url.path.contains("/api/v1/channels/"), request.httpMethod == "GET" {
            responseBody = Data(#"{"version":8,"serverReceivedAt":"2027-01-15T08:01:40Z","snapshot":{"schemaVersion":1,"generatedAt":"2027-01-15T08:01:40Z","tools":[{"id":"chatGPT","name":"ChatGPT","symbolName":"sparkles","resetCredits":{"availableCount":1,"expiresAt":"2027-01-26T08:00:00Z"},"sessionStatus":{"phase":"thinking","updatedAt":"2027-01-15T08:01:39Z"},"limits":[{"id":"codex","name":"Codex","planType":"pro","primary":{"remainingPercent":86,"resetAt":"2027-01-20T08:00:00Z","windowDurationMinutes":10080},"secondary":null}]}]}}"#.utf8)
        } else {
            responseBody = Data(#"{"limits":[{"id":"messages","usedPercent":25}]}"#.utf8)
        }
        client?.urlProtocol(
            self,
            didLoad: responseBody
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RelayRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    var lastRequest: URLRequest? {
        lock.withLock { request }
    }

    var lastRequestBody: Data? {
        lock.withLock { body }
    }

    func record(_ request: URLRequest) {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            data = collected
        }
        lock.withLock {
            self.request = request
            body = data
        }
    }

    func reset() {
        lock.withLock {
            request = nil
            body = nil
        }
    }
}

private final class RelaySnapshotStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let payload = #"{"version":8,"serverReceivedAt":"2026-07-19T12:00:03Z","snapshot":{"generatedAt":"2026-07-19T12:00:02Z","tools":[{"id":"chatGPT","name":"ChatGPT","symbolName":"sparkles","sessionStatus":{"phase":"needsInput","updatedAt":"2026-07-19T12:00:02Z"},"limits":[{"id":"codex","name":"Codex","planType":"Plus","primary":{"remainingPercent":72,"resetAt":"2026-07-20T12:00:00Z","windowDurationMinutes":10080},"secondary":null}]}]}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "ETag": "\"8\""]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
