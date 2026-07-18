import Foundation
import Testing
@testable import UsageHUD

@Test func relaySnapshotContainsOnlyVisibleNormalizedQuotaData() throws {
    var snapshot = Fixtures.codexSnapshot
    snapshot.toolName = "Codex"
    snapshot.toolWebURL = URL(string: "https://example.com/private?token=secret")
    snapshot.toolSystemImage = "sparkles"

    let payload = RelaySnapshotPayload.make(
        from: [snapshot],
        at: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(payload)
    let text = try #require(String(data: encoded, encoding: .utf8))

    #expect(payload.tools.count == 1)
    #expect(payload.tools[0].limits[0].primary.remainingPercent == 75)
    #expect(payload.tools[0].limits[0].secondary?.remainingPercent == 67)
    #expect(!text.contains("token"))
    #expect(!text.contains("example.com"))
}

@Test func relaySnapshotPreservesToolAndLimitOrder() {
    var remote = Fixtures.codexSnapshot
    remote.toolID = AIToolID(rawValue: "11111111-1111-4111-8111-111111111111")
    remote.toolName = "Team Claude"
    remote.toolSystemImage = "brain.head.profile"

    let payload = RelaySnapshotPayload.make(from: [remote, Fixtures.codexSnapshot])
    #expect(payload.tools.map(\.name) == ["Team Claude", "ChatGPT"])
    #expect(payload.tools.flatMap(\.limits).map(\.id) == ["codex", "codex"])
}
