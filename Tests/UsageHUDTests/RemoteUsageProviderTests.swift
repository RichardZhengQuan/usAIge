import Foundation
import Testing
@testable import UsageHUD

@MainActor
@Test func remoteProviderReturnsRelayPairedSnapshots() async throws {
    var snapshot = Fixtures.codexSnapshot
    snapshot.toolID = AIToolID(rawValue: "d7594d23-6237-4c9d-8b7b-bca32543605e")
    snapshot.toolName = "Remote Assistant"
    let provider = RemoteUsageProvider(fetch: { [snapshot] in [snapshot] })

    let result = try await provider.refresh()

    #expect(result.snapshots == [snapshot])
}

@MainActor
@Test func remoteProviderReportsWhenNoToolsArePaired() async {
    let provider = RemoteUsageProvider(fetch: { throw RemoteUsageError.noSources })
    var receivedNoSources = false

    do {
        _ = try await provider.refresh()
    } catch RemoteUsageError.noSources {
        receivedNoSources = true
    } catch {
        Issue.record("Expected noSources, received \(error)")
    }

    #expect(receivedNoSources)
}

@Test func relayRemoteToolMapsNormalizedPayload() throws {
    let data = Data(#"{"id":"d7594d23-6237-4c9d-8b7b-bca32543605e","name":"Remote Assistant","symbolName":"bolt.fill","websiteURL":"https://assistant.example.com","createdAt":"2026-07-19T12:00:00Z","lastUploadAt":"2026-07-19T12:01:00Z","snapshot":{"schemaVersion":1,"generatedAt":"2026-07-19T12:01:00Z","limits":[{"id":"weekly","name":"Weekly messages","planType":"Pro","primary":{"remainingPercent":35.5,"resetAt":"2026-07-20T12:00:00Z","windowDurationMinutes":10080},"secondary":null}]}}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let tool = try decoder.decode(RelayRemoteTool.self, from: data)
    let snapshot = try #require(tool.quotaSnapshots().first)

    #expect(snapshot.id == "d7594d23-6237-4c9d-8b7b-bca32543605e:weekly")
    #expect(snapshot.remainingPercent == 35.5)
    #expect(snapshot.usedPercent == 64.5)
    #expect(snapshot.toolName == "Remote Assistant")
    #expect(snapshot.toolSystemImage == "bolt.fill")
}
