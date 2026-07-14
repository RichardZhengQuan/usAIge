import Foundation
import XCTest
@testable import usAIge_iOS

final class RemoteUsageClientTests: XCTestCase {
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

    private func client(maximumResponseBytes: Int = 1_048_576) -> RemoteUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteUsageStubURLProtocol.self]
        return RemoteUsageClient(
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_000) },
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func configuration(path: String) -> RemoteToolConfiguration {
        RemoteToolConfiguration(
            name: "Remote Tool",
            endpointURL: URL(string: "https://example.com\(path)")!
        )
    }
}

private final class RemoteUsageStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
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
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"limits":[{"id":"messages","usedPercent":25}]}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
