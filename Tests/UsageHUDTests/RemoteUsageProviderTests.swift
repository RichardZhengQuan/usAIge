import Foundation
import Testing
@testable import UsageHUD

@Test func remoteProviderDecodesMapsAndAuthenticatesRequests() async throws {
    let toolID = AIToolID(rawValue: "d7594d23-6237-4c9d-8b7b-bca32543605e")
    let endpoint = try #require(URL(string: "https://limits.example.com/v1/usage"))
    let webURL = try #require(URL(string: "https://assistant.example.com"))
    let tool = RemoteAITool(
        id: toolID,
        name: "Remote Assistant",
        endpoint: endpoint,
        webURL: webURL,
        systemImage: "bolt.fill"
    )
    let payload = Data(
        #"""
        {
          "limits": [
            {
              "id": "weekly",
              "name": "Weekly messages",
              "planType": "pro",
              "primary": {
                "remainingPercent": 35.5,
                "windowDurationMinutes": 10080,
                "resetsAt": 1800003600
              },
              "secondary": {
                "remainingPercent": 82,
                "windowDurationMinutes": 1440,
                "resetsAt": 1800007200
              }
            },
            {
              "id": "daily",
              "name": "Daily requests",
              "usedPercent": 20,
              "windowDurationMinutes": 1440,
              "resetsAt": 1800001800
            }
          ]
        }
        """#.utf8
    )
    let loader = RecordingRemoteLoader(data: payload)
    let credentials = StubRemoteCredentialStore(tokens: [toolID: "test-token"])
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = RemoteUsageProvider(
        configuration: { [tool] in [tool] },
        credentials: credentials,
        loader: loader,
        now: { updatedAt }
    )

    let result = try await provider.refresh()

    #expect(result.snapshots.map(\.id) == ["d7594d23-6237-4c9d-8b7b-bca32543605e:daily", "d7594d23-6237-4c9d-8b7b-bca32543605e:weekly"])
    let daily = try #require(result.snapshots.first { $0.id == "d7594d23-6237-4c9d-8b7b-bca32543605e:daily" })
    #expect(daily.displayName == "Daily requests")
    #expect(daily.usedPercent == 20)
    #expect(daily.remainingPercent == 80)
    #expect(daily.windowDurationMinutes == 1_440)
    #expect(daily.resetAt == Date(timeIntervalSince1970: 1_800_001_800))

    let weekly = try #require(result.snapshots.first { $0.id == "d7594d23-6237-4c9d-8b7b-bca32543605e:weekly" })
    #expect(weekly.displayName == "Weekly messages")
    #expect(weekly.planType == "pro")
    #expect(weekly.usedPercent == 64.5)
    #expect(weekly.remainingPercent == 35.5)
    #expect(weekly.secondaryWindow?.usedPercent == 18)
    #expect(weekly.secondaryWindow?.remainingPercent == 82)
    #expect(weekly.updatedAt == updatedAt)
    #expect(weekly.toolID == toolID)
    #expect(weekly.toolName == "Remote Assistant")
    #expect(weekly.toolWebURL == webURL)
    #expect(weekly.toolSystemImage == "bolt.fill")

    let request = try #require(await loader.requests.first)
    #expect(request.url == endpoint)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "usAIge/0.1.12")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
}

@Test func remoteProviderStablyDeduplicatesLimitIDs() async throws {
    let endpoint = try #require(URL(string: "https://limits.example.com/v1/usage"))
    let tool = RemoteAITool(
        id: AIToolID(rawValue: "4d50d68f-c0ef-4604-ab5d-d029bddf652b"),
        name: "Duplicate Tool",
        endpoint: endpoint
    )
    let payload = Data(
        #"""
        {
          "limits": [
            {
              "id": "shared",
              "name": "First response",
              "usedPercent": 10
            },
            {
              "id": "shared",
              "name": "Later response",
              "usedPercent": 90
            }
          ]
        }
        """#.utf8
    )
    let provider = RemoteUsageProvider(
        configuration: { [tool] in [tool] },
        credentials: StubRemoteCredentialStore(),
        loader: RecordingRemoteLoader(data: payload)
    )

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["4d50d68f-c0ef-4604-ab5d-d029bddf652b:shared"])
    #expect(snapshots.first?.displayName == "First response")
    #expect(snapshots.first?.usedPercent == 10)
}

@Test func remoteProviderRejectsInsecureNonLocalEndpointBeforeLoading() async throws {
    let endpoint = try #require(URL(string: "http://limits.example.com/v1/usage"))
    let tool = RemoteAITool(name: "Insecure Tool", endpoint: endpoint)
    let loader = RecordingRemoteLoader(data: Data(#"{"limits":[]}"#.utf8))
    let provider = RemoteUsageProvider(
        configuration: { [tool] in [tool] },
        credentials: StubRemoteCredentialStore(),
        loader: loader
    )
    var rejectedAsInsecure = false

    do {
        _ = try await provider.refresh()
    } catch RemoteUsageError.insecureEndpoint {
        rejectedAsInsecure = true
    } catch {
        Issue.record("Expected insecureEndpoint, received \(error)")
    }

    #expect(rejectedAsInsecure)
    #expect(await loader.requests.isEmpty)
}

@Test func remoteProviderSurfacesHTTPFailure() async throws {
    let endpoint = try #require(URL(string: "https://limits.example.com/v1/usage"))
    let tool = RemoteAITool(name: "Unavailable Tool", endpoint: endpoint)
    let loader = RecordingRemoteLoader(data: Data(), statusCode: 429)
    let provider = RemoteUsageProvider(
        configuration: { [tool] in [tool] },
        credentials: StubRemoteCredentialStore(),
        loader: loader
    )
    var receivedStatus: Int?

    do {
        _ = try await provider.refresh()
    } catch RemoteUsageError.httpStatus(let statusCode) {
        receivedStatus = statusCode
    } catch {
        Issue.record("Expected httpStatus, received \(error)")
    }

    #expect(receivedStatus == 429)
    #expect(await loader.requests.count == 1)
}

private struct StubRemoteCredentialStore: RemoteCredentialStoring {
    let tokens: [AIToolID: String]

    init(tokens: [AIToolID: String] = [:]) {
        self.tokens = tokens
    }

    func token(for toolID: AIToolID) throws -> String? {
        tokens[toolID]
    }

    func setToken(_ token: String?, for toolID: AIToolID) throws {}
}

private actor RecordingRemoteLoader: RemoteDataLoading {
    let data: Data
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest, maxBytes: Int) async throws -> RemoteHTTPPayload {
        requests.append(request)
        guard data.count <= maxBytes else { throw RemoteUsageError.responseTooLarge }
        return RemoteHTTPPayload(data: data, statusCode: statusCode)
    }
}
