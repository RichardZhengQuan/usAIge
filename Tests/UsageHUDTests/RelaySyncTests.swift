import Foundation
import Testing
@testable import UsageHUD

@Test func relayCredentialStoreUsesOwnerOnlyLocalFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("relay-upload-token")
    let store = RelayMacCredentialStore(fileURL: fileURL)

    #expect(try store.token() == nil)
    try store.save("relay-secret")

    #expect(try store.token() == "relay-secret")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)

    try store.delete()
    #expect(try store.token() == nil)
}

@MainActor
@Test func relayControllerResetsLegacyLinkWithoutReadingKeychain() throws {
    let suiteName = "RelaySyncTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("legacy-channel", forKey: "usageHUD.relay.channelID")
    defaults.set("My Mac", forKey: "usageHUD.relay.macName")
    let missingFile = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("relay-upload-token")

    let controller = RelaySyncController(
        defaults: defaults,
        credentials: RelayMacCredentialStore(fileURL: missingFile)
    )

    #expect(!controller.isLinked)
    #expect(controller.status == .disconnected)
    #expect(defaults.string(forKey: "usageHUD.relay.channelID") == nil)
}

@Test func relaySnapshotContainsOnlyVisibleNormalizedQuotaData() throws {
    var snapshot = Fixtures.codexSnapshot
    snapshot.toolName = "Codex"
    snapshot.toolWebURL = URL(string: "https://example.com/private?token=secret")
    snapshot.toolSystemImage = "sparkles"
    snapshot.availableResetCount = 1
    snapshot.resetCreditExpiresAt = Date(timeIntervalSince1970: 1_800_950_400)

    let payload = RelaySnapshotPayload.make(
        from: [snapshot],
        codexSessionStatus: RelaySessionStatusPayload(
            phase: .thinking,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_099)
        ),
        at: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(payload)
    let text = try #require(String(data: encoded, encoding: .utf8))

    #expect(payload.tools.count == 1)
    #expect(payload.tools[0].limits[0].primary.remainingPercent == 75)
    #expect(payload.tools[0].limits[0].secondary?.remainingPercent == 67)
    #expect(payload.tools[0].sessionStatus?.phase == .thinking)
    #expect(payload.tools[0].resetCredits?.availableCount == 1)
    #expect(payload.tools[0].resetCredits?.expiresAt == Date(timeIntervalSince1970: 1_800_950_400))
    #expect(payload.tools[0].sessionStatus?.phase == .thinking)
    #expect(text.contains("thinking"))
    #expect(!text.contains("session-id"))
    #expect(!text.contains("workspace"))
    #expect(!text.contains("token"))
    #expect(!text.contains("example.com"))
    #expect(!text.contains("task"))
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

@Test func relaySessionEventMapsAttentionStatesWithoutSessionContent() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_100)
    let task = CodexAgentTask(
        id: "session-id",
        title: "Approve release",
        workspaceName: "GPTUsage",
        phase: .needsInput,
        updatedAt: date
    )
    let payload = try #require(RelaySessionEventPayload(task: task))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let text = try #require(String(data: encoder.encode(payload), encoding: .utf8))

    #expect(payload.kind == .permissionNeeded)
    #expect(text.contains("Approve release"))
    #expect(text.contains("GPTUsage"))
    #expect(!text.contains("prompt"))
    #expect(RelaySessionEventPayload(task: CodexAgentTask(
        id: "running",
        title: "Running",
        workspaceName: "GPTUsage",
        phase: .thinking,
        updatedAt: date
    )) == nil)
}

@Test func relaySessionStatusIsAttachedOnlyToChatGPT() {
    var remote = Fixtures.codexSnapshot
    remote.toolID = AIToolID(rawValue: "11111111-1111-4111-8111-111111111111")
    remote.toolName = "Team Claude"

    let status = RelaySessionStatusPayload(
        phase: .needsInput,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    let payload = RelaySnapshotPayload.make(
        from: [remote, Fixtures.codexSnapshot],
        codexSessionStatus: status
    )

    #expect(payload.tools[0].sessionStatus == nil)
    #expect(payload.tools[1].sessionStatus == status)
}
