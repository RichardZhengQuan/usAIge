import Combine
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

@MainActor
@Test func remoteToolsBeginUnconfiguredWithoutALocalLink() async throws {
    let fixture = try RelayControllerFixture(linked: false, responses: [])
    defer { fixture.cleanup() }

    do {
        _ = try await fixture.controller.refreshRemoteTools()
        Issue.record("A Mac without a relay link must not produce authenticated remote usage.")
    } catch RemoteUsageError.noSources {
        #expect(fixture.controller.remoteToolsState == .unconfigured)
    }
    #expect(fixture.stub.requests.isEmpty)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test func remoteToolsPublishLoadedStateAndUseTheMacCredential() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools])
    defer { fixture.cleanup() }
    #expect(fixture.controller.remoteToolsState == .idle)
    var states: [RelaySyncController.RemoteToolsState] = []
    let observation = fixture.controller.$remoteToolsState.sink { states.append($0) }
    defer { observation.cancel() }

    let snapshots = try await fixture.controller.refreshRemoteTools()

    #expect(fixture.controller.remoteToolsState == .loaded)
    #expect(states == [.idle, .loading, .loaded])
    #expect(fixture.controller.remoteTools.map(\.name) == ["Team Claude"])
    #expect(snapshots.map(\.remainingPercent) == [75])
    #expect(fixture.controller.status == .connected)
    let request = try #require(fixture.stub.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path.hasSuffix("/channels/test-channel/tools") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer disposable-test-token")
}

@MainActor
@Test func remoteToolsRetainCachedToolsWhenFetchingFails() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .failure("Temporarily unavailable")])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let cached = fixture.controller.remoteTools

    await expectRemoteRefreshFailure(fixture.controller)

    #expect(fixture.controller.remoteToolsState == .failed("Temporarily unavailable"))
    #expect(fixture.controller.remoteTools == cached)
    #expect(fixture.controller.status == .connected)
}

@MainActor
@Test func overlappingRemoteToolsRefreshesShareOneRequest() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools], holdResponses: true)
    defer {
        fixture.stub.releaseResponses()
        fixture.cleanup()
    }
    let first = Task { try await fixture.controller.refreshRemoteTools() }
    let waitDeadline = Date().addingTimeInterval(5)
    while fixture.stub.requests.isEmpty, Date() < waitDeadline { await Task.yield() }
    try #require(!fixture.stub.requests.isEmpty)
    #expect(fixture.controller.remoteToolsState == .loading)
    var startedSecond = false
    let second = Task {
        startedSecond = true
        return try await fixture.controller.refreshRemoteTools()
    }
    while !startedSecond { await Task.yield() }
    fixture.stub.releaseResponses()

    let firstResult = try await first.value
    let secondResult = try await second.value

    #expect(firstResult == secondResult)
    #expect(fixture.stub.requests.count == 1)
    #expect(fixture.controller.remoteToolsState == .loaded)
}

@MainActor
@Test func remoteToolsEmptyRetryClearsTheFailureWithoutAuthenticatingUsage() async throws {
    let fixture = try RelayControllerFixture(responses: [.failure("Temporarily unavailable"), .emptyTools])
    defer { fixture.cleanup() }
    await expectRemoteRefreshFailure(fixture.controller)
    #expect(fixture.controller.remoteToolsState == .failed("Temporarily unavailable"))

    do {
        _ = try await fixture.controller.refreshRemoteTools()
        Issue.record("A loaded empty list must not supply an authenticated quota source.")
    } catch RemoteUsageError.noSources {
        #expect(fixture.controller.remoteToolsState == .loaded)
        #expect(fixture.controller.remoteTools.isEmpty)
    }
    #expect(fixture.stub.requests.count == 2)
}

@MainActor
@Test func remoteToolsRefreshDoesNotClearAnUnrelatedPhoneFailure() async throws {
    let fixture = try RelayControllerFixture(responses: [.failure("Could not load phones"), .tools])
    defer { fixture.cleanup() }
    await fixture.controller.refreshDevices()
    #expect(fixture.controller.status == .failed("Could not load phones"))
    #expect(fixture.controller.remoteToolsState == .idle)

    _ = try await fixture.controller.refreshRemoteTools()

    #expect(fixture.controller.remoteToolsState == .loaded)
    #expect(fixture.controller.status == .failed("Could not load phones"))
}

@MainActor
@Test func remoteToolsMissingCredentialIsAFailedFetch() async throws {
    let fixture = try RelayControllerFixture(responses: [])
    defer { fixture.cleanup() }
    try fixture.credentials.delete()

    await expectRemoteRefreshFailure(fixture.controller)

    guard case let .failed(message) = fixture.controller.remoteToolsState else {
        Issue.record("Missing credentials must publish a remote-tool failure.")
        return
    }
    #expect(message.contains("connection key is missing"))
    #expect(fixture.stub.requests.isEmpty)
    #expect(fixture.controller.remoteTools.isEmpty)
}

@MainActor
@Test func remoteToolPairingFailureUsesItsOwnActionState() async throws {
    let fixture = try RelayControllerFixture(responses: [.failure("Could not create connection code")])
    defer { fixture.cleanup() }

    await fixture.controller.createRemoteToolPairingCode()

    #expect(fixture.controller.remoteToolActionState == .failed("Could not create connection code"))
    #expect(fixture.controller.remoteToolsState == .idle)
    #expect(fixture.controller.remotePairingCode == nil)
    #expect(fixture.controller.status == .connected)
}

@MainActor
@Test func remoteToolRevocationFailureRetainsTheToolAndUsesActionState() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .failure("Could not disconnect tool")])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)

    await fixture.controller.revoke(tool)

    #expect(fixture.controller.remoteToolActionState == .failed("Could not disconnect tool"))
    #expect(fixture.controller.remoteTools == [tool])
    #expect(fixture.controller.remoteToolsState == .loaded)
    #expect(fixture.controller.status == .connected)
}

@MainActor
@Test func failedChannelDeletionPreservesTheLocalLinkAndRemoteTools() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .failure("Could not delete channel")])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tools = fixture.controller.remoteTools

    await fixture.controller.disconnectAll()

    #expect(fixture.controller.isLinked)
    #expect(try fixture.credentials.token() == "disposable-test-token")
    #expect(fixture.controller.remoteTools == tools)
    #expect(fixture.controller.remoteToolsState == .loaded)
}

@MainActor
@Test func successfulChannelDeletionResetsRemoteStateAndCredentials() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .failure("Unavailable"), .deleted])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    await expectRemoteRefreshFailure(fixture.controller)

    await fixture.controller.disconnectAll()

    #expect(!fixture.controller.isLinked)
    #expect(try fixture.credentials.token() == nil)
    #expect(fixture.controller.remoteTools.isEmpty)
    #expect(fixture.controller.remoteToolsState == .unconfigured)
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test func missingHostedRelayProducesAFriendlyFailureAndEmptyRetryLoads() async throws {
    let fixture = try RelayControllerFixture(responses: [.missingHostedService, .emptyTools])
    defer { fixture.cleanup() }

    await expectRemoteRefreshFailure(fixture.controller)

    #expect(fixture.controller.remoteToolsState == .failed("The sync service is unavailable. Try again later."))
    do {
        _ = try await fixture.controller.refreshRemoteTools()
        Issue.record("An empty remote-tool list must not authenticate a quota source.")
    } catch RemoteUsageError.noSources {
        #expect(fixture.controller.remoteToolsState == .loaded)
    }
}

@MainActor
@Test func missingHostedRelayDuringRevocationKeepsTheToolAndShowsFriendlyFailure() async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .missingHostedService])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)

    await fixture.controller.revoke(tool)

    #expect(fixture.controller.remoteToolActionState == .failed("The sync service is unavailable. Try again later."))
    #expect(fixture.controller.remoteTools == [tool])
}

@MainActor
@Test(arguments: ["Relay request failed.", "The relay request failed."])
func genericRelayServerErrorsUseFriendlySyncServiceCopy(message: String) async throws {
    let fixture = try RelayControllerFixture(responses: [.failure(message, statusCode: 500)])
    defer { fixture.cleanup() }

    await expectRemoteRefreshFailure(fixture.controller)

    #expect(fixture.controller.remoteToolsState == .failed("The sync service is unavailable. Try again later."))
}

@MainActor
@Test(arguments: ["Relay request failed.", "The relay request failed."])
func genericRelayDeletionErrorsUseFriendlySyncServiceCopy(message: String) async throws {
    let fixture = try RelayControllerFixture(responses: [.tools, .failure(message, statusCode: 500)])
    defer { fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)

    await fixture.controller.revoke(tool)

    #expect(fixture.controller.remoteToolActionState == .failed("The sync service is unavailable. Try again later."))
    #expect(fixture.controller.remoteTools == [tool])
}

@MainActor
@Test func revokedToolCannotReturnFromAnOlderListRequest() async throws {
    let fixture = try RelayControllerFixture(
        responses: [.tools, .tools, .deleted, .emptyTools],
        heldPathSuffix: "/tools"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)
    fixture.stub.holdResponses()
    let staleRefresh = Task { try? await fixture.controller.refreshRemoteTools() }
    try await waitForRelayRequests(fixture.stub, count: 2)

    await fixture.controller.revoke(tool)
    fixture.stub.releaseResponses()
    let staleResult = await staleRefresh.value

    #expect(staleResult == nil)
    #expect(fixture.controller.remoteTools.isEmpty)
    #expect(fixture.controller.remoteToolActionState == .idle)
    do {
        _ = try await fixture.controller.refreshRemoteTools()
        Issue.record("The fresh empty list must not authenticate a usage source.")
    } catch RemoteUsageError.noSources {
        #expect(fixture.controller.remoteToolsState == .loaded)
    }
    #expect(fixture.stub.requests.count == 4)
}

@MainActor
@Test(arguments: [false, true])
func delayedPhoneListCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [shouldFail ? .failure("Old phone request failed") : .devices, .deleted],
        holdResponses: true,
        heldPathSuffix: "/devices"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    let refresh = Task { await fixture.controller.refreshDevices() }
    try await waitForRelayRequests(fixture.stub, count: 1)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await refresh.value

    #expect(fixture.controller.devices.isEmpty)
    #expect(fixture.controller.status == .disconnected)
    #expect(fixture.controller.remoteToolsState == .unconfigured)
}

@MainActor
@Test(arguments: [false, true])
func delayedPhonePairingCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [shouldFail ? .failure("Old phone pairing failed") : .pairing("PHONE"), .deleted],
        holdResponses: true,
        heldPathSuffix: "/pairings"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    let pairing = Task { await fixture.controller.createPairingCode() }
    try await waitForRelayRequests(fixture.stub, count: 1)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await pairing.value

    #expect(fixture.controller.pairingCode == nil)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test(arguments: [false, true])
func delayedRemotePairingCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [shouldFail ? .failure("Old tool pairing failed") : .pairing("TOOL"), .deleted],
        holdResponses: true,
        heldPathSuffix: "/tool-pairings"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    let pairing = Task { await fixture.controller.createRemoteToolPairingCode() }
    try await waitForRelayRequests(fixture.stub, count: 1)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await pairing.value

    #expect(fixture.controller.remotePairingCode == nil)
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test(arguments: [false, true])
func delayedToolRemovalCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [.tools, shouldFail ? .failure("Old removal failed") : .deleted, .deleted],
        heldPathSuffix: "/tools/remote-claude"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)
    fixture.stub.holdResponses()
    let removal = Task { await fixture.controller.revoke(tool) }
    try await waitForRelayRequests(fixture.stub, count: 2)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await removal.value

    #expect(fixture.controller.remoteTools.isEmpty)
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(fixture.controller.remoteToolsState == .unconfigured)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test(arguments: [false, true])
func delayedInitialRemoteConnectionAndUploadCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        linked: false,
        responses: [.createdChannel, shouldFail ? .failure("Old upload failed") : .uploaded, .deleted],
        holdResponses: true,
        heldPathSuffix: "/snapshot"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    let channelCreation = Task { await fixture.controller.createRemoteToolPairingCode() }
    try await waitForRelayRequests(fixture.stub, count: 2)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await channelCreation.value

    #expect(fixture.controller.lastUploadAt == nil)
    #expect(fixture.controller.status == .disconnected)
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(!fixture.controller.isLinked)
    #expect(fixture.stub.requests.count == 3)
}

@MainActor
@Test(arguments: [false, true])
func oldDeviceCallbackCannotChangeAReconnectedChannelWithTheSameID(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [shouldFail ? .failure("Old device request failed") : .devices, .deleted, .createdChannel, .uploaded],
        holdResponses: true,
        heldPathSuffix: "/devices"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    let oldRefresh = Task { await fixture.controller.refreshDevices() }
    try await waitForRelayRequests(fixture.stub, count: 1)

    await fixture.controller.disconnectAll()
    await fixture.controller.createChannel()
    #expect(fixture.controller.channelID == "test-channel")
    fixture.stub.releaseResponses()
    await oldRefresh.value

    #expect(fixture.controller.devices.isEmpty)
    #expect(fixture.controller.status == .connected)
    #expect(fixture.controller.remoteToolsState == .idle)
}

@MainActor
@Test(arguments: [false, true])
func delayedPhoneRemovalCannotChangeStateAfterDisconnect(shouldFail: Bool) async throws {
    let fixture = try RelayControllerFixture(
        responses: [.devices, shouldFail ? .failure("Old phone removal failed") : .deleted, .deleted],
        heldPathSuffix: "/devices/test-phone"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    await fixture.controller.refreshDevices()
    let device = try #require(fixture.controller.devices.first)
    fixture.stub.holdResponses()
    let oldRemoval = Task { await fixture.controller.revoke(device) }
    try await waitForRelayRequests(fixture.stub, count: 2)

    await fixture.controller.disconnectAll()
    fixture.stub.releaseResponses()
    await oldRemoval.value

    #expect(fixture.controller.devices.isEmpty)
    #expect(fixture.controller.status == .disconnected)
}

@MainActor
@Test func replacingAPairingCodeCancelsTheOldPollWithoutClearingTheNewCode() async throws {
    let fixture = try RelayControllerFixture(
        responses: [.pairing("OLD"), .emptyTools, .pairing("NEW"), .deleted],
        heldPathSuffix: "/tools"
    )
    defer { fixture.stub.releaseResponses(); fixture.cleanup() }
    await fixture.controller.createRemoteToolPairingCode()
    fixture.stub.holdResponses()
    try await waitForRelayRequests(fixture.stub, count: 2)

    await fixture.controller.createRemoteToolPairingCode()
    #expect(fixture.controller.remotePairingCode == "NEW")
    fixture.stub.releaseResponses()
    let waitDeadline = Date().addingTimeInterval(3)
    while fixture.controller.remoteToolsState == .loading, Date() < waitDeadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    await Task.yield()
    await Task.yield()

    #expect(fixture.controller.remotePairingCode == "NEW")
    #expect(fixture.controller.remoteToolsState == .loaded)
    await fixture.controller.disconnectAll()
    #expect(fixture.controller.remotePairingCode == nil)
}

@MainActor
@Test func verifiedMissingChannelOffersExplicitRecoveryWithoutClearingTheLink() async throws {
    let fixture = try RelayControllerFixture(responses: [.missingChannel])
    defer { fixture.cleanup() }

    await expectRemoteRefreshFailure(fixture.controller)

    #expect(fixture.controller.remoteToolsState == .connectionUnavailable)
    #expect(fixture.controller.canReconnectRemoteTools)
    #expect(fixture.controller.channelID == "test-channel")
    #expect(try fixture.credentials.token() == "disposable-test-token")
}

@MainActor
@Test func explicitRecoveryRechecksTheOldChannelAndCreatesANewPairingCode() async throws {
    let fixture = try RelayControllerFixture(responses: [
        .missingChannel, .missingChannel, .replacementChannel, .uploaded, .pairing("RECONNECT"), .deleted
    ])
    defer { fixture.cleanup() }
    await expectRemoteRefreshFailure(fixture.controller)

    await fixture.controller.reconnectRemoteTools()

    #expect(fixture.controller.channelID == "replacement-channel")
    #expect(try fixture.credentials.token() == "replacement-test-token")
    #expect(!fixture.controller.canReconnectRemoteTools)
    #expect(fixture.controller.remotePairingCode == "RECONNECT")
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(fixture.stub.requests.map(\.httpMethod) == ["GET", "GET", "POST", "PUT", "POST"])
    #expect(fixture.stub.requests[1].url?.path.hasSuffix("/channels/test-channel/tools") == true)
    #expect(fixture.stub.requests[4].url?.path.hasSuffix("/channels/replacement-channel/tool-pairings") == true)
    await fixture.controller.disconnectAll()
}

@MainActor
@Test func recoveredChannelIsKeptWhenExplicitReconnectRechecksIt() async throws {
    let fixture = try RelayControllerFixture(responses: [.missingChannel, .emptyTools])
    defer { fixture.cleanup() }
    await expectRemoteRefreshFailure(fixture.controller)

    await fixture.controller.reconnectRemoteTools()

    #expect(fixture.controller.channelID == "test-channel")
    #expect(try fixture.credentials.token() == "disposable-test-token")
    #expect(fixture.controller.remoteToolsState == .loaded)
    #expect(!fixture.controller.canReconnectRemoteTools)
    #expect(fixture.controller.remoteToolActionState == .idle)
    #expect(fixture.stub.requests.map(\.httpMethod) == ["GET", "GET"])
}

@MainActor
@Test(arguments: [RelayRecoveryFailure.transient, .unauthorized, .htmlNotFound, .genericJSONNotFound, .wrongContentType])
func onlyVerifiedChannelMissingResponsesCanOfferRecovery(failure: RelayRecoveryFailure) async throws {
    let fixture = try RelayControllerFixture(responses: [failure.response])
    defer { fixture.cleanup() }

    await expectRemoteRefreshFailure(fixture.controller)
    await fixture.controller.reconnectRemoteTools()

    #expect(!fixture.controller.canReconnectRemoteTools)
    #expect(fixture.controller.isLinked)
    #expect(try fixture.credentials.token() == "disposable-test-token")
    #expect(fixture.stub.requests.count == 1)
    guard case .failed = fixture.controller.remoteToolsState else {
        Issue.record("An ordinary server or authorization error must not offer channel recovery.")
        return
    }
}

@MainActor
@Test(arguments: [RelayRecoveryFailure.transient, .unauthorized, .htmlNotFound, .genericJSONNotFound, .wrongContentType])
func failedFreshRecoveryCheckPreservesTheOldLocalLink(failure: RelayRecoveryFailure) async throws {
    let fixture = try RelayControllerFixture(responses: [.missingChannel, failure.response])
    defer { fixture.cleanup() }
    await expectRemoteRefreshFailure(fixture.controller)

    await fixture.controller.reconnectRemoteTools()

    #expect(fixture.controller.channelID == "test-channel")
    #expect(try fixture.credentials.token() == "disposable-test-token")
    #expect(fixture.stub.requests.map(\.httpMethod) == ["GET", "GET"])
    guard case .failed = fixture.controller.remoteToolActionState else {
        Issue.record("A failed fresh recovery check must report its error without creating a new channel.")
        return
    }
}

@MainActor
@Test func verifiedAlreadyDeletedChannelAllowsLocalDisconnectCleanup() async throws {
    let fixture = try RelayControllerFixture(responses: [.missingChannel])
    defer { fixture.cleanup() }

    await fixture.controller.disconnectAll()

    #expect(!fixture.controller.isLinked)
    #expect(try fixture.credentials.token() == nil)
    #expect(fixture.controller.status == .disconnected)
    #expect(fixture.controller.remoteToolsState == .unconfigured)
    #expect(!fixture.controller.canReconnectRemoteTools)
}

@MainActor
@Test(arguments: [RelayRecoveryFailure.transient, .unauthorized, .htmlNotFound, .genericJSONNotFound, .wrongContentType])
func unverifiedChannelDeleteFailuresKeepTheLocalLink(failure: RelayRecoveryFailure) async throws {
    let fixture = try RelayControllerFixture(responses: [failure.response])
    defer { fixture.cleanup() }

    await fixture.controller.disconnectAll()

    #expect(fixture.controller.channelID == "test-channel")
    #expect(try fixture.credentials.token() == "disposable-test-token")
    #expect(!fixture.controller.canReconnectRemoteTools)
    guard case .failed = fixture.controller.status else {
        Issue.record("Failed deletion must leave the local link intact and show an error.")
        return
    }
}

@MainActor
private func waitForRelayRequests(_ stub: RelayRequestStub, count: Int) async throws {
    let waitDeadline = Date().addingTimeInterval(5)
    while stub.requests.count < count, Date() < waitDeadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try #require(stub.requests.count >= count)
}

@MainActor
private func expectRemoteRefreshFailure(_ controller: RelaySyncController) async {
    do {
        _ = try await controller.refreshRemoteTools()
        Issue.record("Expected a remote-tool fetch failure.")
    } catch RemoteUsageError.noSources {
        Issue.record("An unavailable relay must not be reported as a successfully loaded empty list.")
    } catch {
        // The dedicated published state is asserted by each caller.
    }
}

private struct RelayTestResponse: Sendable {
    let statusCode: Int
    let body: String
    let contentType: String

    init(statusCode: Int, body: String, contentType: String = "application/json") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }

    static let emptyTools = Self(statusCode: 200, body: "{\"tools\":[]}")
    static let deleted = Self(statusCode: 204, body: "")
    static let missingHostedService = Self(statusCode: 404, body: "<html><body>No site here</body></html>")
    static let missingChannel = Self(statusCode: 404, body: """
        {"error":"This connection is no longer available.","code":"channel_not_found"}
        """)
    static let devices = Self(statusCode: 200, body: """
        {"devices":[{"id":"test-phone","name":"Test Phone","created_at":"2026-10-10T00:00:00Z",\
        "last_seen_at":"2026-10-10T00:01:00Z"}]}
        """)
    static let createdChannel = Self(statusCode: 201, body: """
        {"channelID":"test-channel","uploadToken":"disposable-test-token","macName":"Test Mac",\
        "pairingCode":"PHONE","expiresAt":"2099-01-01T00:00:00Z"}
        """)
    static let uploaded = Self(statusCode: 200, body: """
        {"version":1,"serverReceivedAt":"2026-10-10T00:01:00Z","changed":true}
        """)
    static let replacementChannel = Self(statusCode: 201, body: """
        {"channelID":"replacement-channel","uploadToken":"replacement-test-token","macName":"Test Mac",\
        "pairingCode":"PHONE","expiresAt":"2099-01-01T00:00:00Z"}
        """)
    static let tools = Self(statusCode: 200, body: """
        {"tools":[{"id":"remote-claude","name":"Team Claude","symbolName":"sparkles",\
        "websiteURL":"https://example.test/claude","createdAt":"2026-10-10T00:00:00Z",\
        "lastUploadAt":"2026-10-10T00:01:00Z","snapshot":{"schemaVersion":1,\
        "generatedAt":"2026-10-10T00:01:00Z","limits":[{"id":"weekly","name":"Weekly",\
        "planType":"Pro","primary":{"remainingPercent":75,"windowDurationMinutes":10080}}]}}]}
        """)

    static func failure(_ message: String, statusCode: Int = 503) -> Self {
        let data = try! JSONEncoder().encode(["error": message])
        return Self(statusCode: statusCode, body: String(decoding: data, as: UTF8.self))
    }

    static func pairing(_ code: String) -> Self {
        let data = try! JSONEncoder().encode(["pairingCode": code, "expiresAt": "2099-01-01T00:00:00Z"])
        return Self(statusCode: 200, body: String(decoding: data, as: UTF8.self))
    }
}

enum RelayRecoveryFailure: Sendable {
    case transient, unauthorized, htmlNotFound, genericJSONNotFound, wrongContentType

    fileprivate var response: RelayTestResponse {
        switch self {
        case .transient: .failure("Temporarily unavailable")
        case .unauthorized: RelayTestResponse(statusCode: 401, body: "{\"error\":\"Not authorized.\",\"code\":\"channel_not_found\"}")
        case .htmlNotFound: .missingHostedService
        case .genericJSONNotFound: RelayTestResponse(statusCode: 404, body: "{\"error\":\"Not found.\"}")
        case .wrongContentType: RelayTestResponse(statusCode: 404, body: RelayTestResponse.missingChannel.body, contentType: "text/html")
        }
    }
}

private final class RelayRequestStub: @unchecked Sendable {
    private let lock = NSLock()
    private let heldPathSuffix: String?
    private var holdsResponses: Bool
    private var heldCompletions: [@Sendable () -> Void] = []
    private var responses: [RelayTestResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [RelayTestResponse], holdResponses: Bool, heldPathSuffix: String?) {
        self.responses = responses
        holdsResponses = holdResponses
        self.heldPathSuffix = heldPathSuffix
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func receive(_ request: URLRequest) -> RelayTestResponse {
        lock.lock()
        recordedRequests.append(request)
        let response = responses.isEmpty
            ? .failure("Unexpected request in isolated relay test")
            : responses.removeFirst()
        lock.unlock()
        return response
    }

    func deliver(for request: URLRequest, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldHold = holdsResponses
            && (heldPathSuffix == nil || request.url?.path.hasSuffix(heldPathSuffix!) == true)
        if shouldHold { heldCompletions.append(completion) }
        lock.unlock()
        if !shouldHold { completion() }
    }

    func releaseResponses() {
        lock.lock()
        holdsResponses = false
        let completions = heldCompletions
        heldCompletions = []
        lock.unlock()
        for completion in completions { completion() }
    }

    func holdResponses() {
        lock.lock()
        holdsResponses = true
        lock.unlock()
    }
}

private final class RelayStubRegistry: @unchecked Sendable {
    static let shared = RelayStubRegistry()
    private let lock = NSLock()
    private var stubs: [String: RelayRequestStub] = [:]

    func set(_ stub: RelayRequestStub?, for identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        stubs[identifier] = stub
    }

    func stub(for request: URLRequest) -> RelayRequestStub? {
        guard let identifier = request.value(forHTTPHeaderField: "X-Relay-Test-ID") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return stubs[identifier]
    }
}

private final class RelayTestURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var hasStopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = RelayStubRegistry.shared.stub(for: request), request.url != nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = stub.receive(request)
        stub.deliver(for: request) { [self] in complete(reply) }
    }

    private func complete(_ reply: RelayTestResponse) {
        lock.lock()
        let stopped = hasStopped
        lock.unlock()
        guard !stopped, let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        lock.lock()
        hasStopped = true
        lock.unlock()
    }
}

@MainActor
private final class RelayControllerFixture {
    let identifier = UUID().uuidString
    let directory: URL
    let defaults: UserDefaults
    let credentials: RelayMacCredentialStore
    let session: URLSession
    let stub: RelayRequestStub
    let controller: RelaySyncController

    init(
        linked: Bool = true,
        responses: [RelayTestResponse],
        holdResponses: Bool = false,
        heldPathSuffix: String? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelaySyncTests-\(identifier)", isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: "RelaySyncTests.\(identifier)"))
        credentials = RelayMacCredentialStore(fileURL: directory.appendingPathComponent("relay-upload-token"))
        if linked {
            try credentials.save("disposable-test-token")
            defaults.set("test-channel", forKey: "usageHUD.relay.channelID")
            defaults.set("Test Mac", forKey: "usageHUD.relay.macName")
        }
        stub = RelayRequestStub(responses: responses, holdResponses: holdResponses, heldPathSuffix: heldPathSuffix)
        RelayStubRegistry.shared.set(stub, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayTestURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Relay-Test-ID": identifier]
        session = URLSession(configuration: configuration)
        controller = RelaySyncController(defaults: defaults, session: session, credentials: credentials)
    }

    func cleanup() {
        session.invalidateAndCancel()
        RelayStubRegistry.shared.set(nil, for: identifier)
        defaults.removePersistentDomain(forName: "RelaySyncTests.\(identifier)")
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Test func relayPathSegmentsArePercentEncoded() {
    #expect(RelaySyncController.encodedPath("channels/abc-123/devices/dev_1") == "channels/abc-123/devices/dev_1")
    // An identifier can never add or remove path segments.
    #expect(RelaySyncController.encodedPath("channels/abc/../other/devices") == "channels/abc/%2E%2E/other/devices")
    #expect(RelaySyncController.encodedPath("channels/a b?c#d") == "channels/a%20b%3Fc%23d")
}

@MainActor
@Test func relayServerMessagesAreKeptToOneShortPrintableLine() {
    #expect(RelaySyncController.sanitizedServerMessage(nil) == "The relay request failed.")
    #expect(RelaySyncController.sanitizedServerMessage("   ") == "The relay request failed.")
    #expect(RelaySyncController.sanitizedServerMessage("Not found.") == "Not found.")
    #expect(RelaySyncController.sanitizedServerMessage("line one\nline two\u{07}") == "line one line two")
    #expect(RelaySyncController.sanitizedServerMessage(String(repeating: "x", count: 500)).count == 200)
}

@MainActor
@Test func remoteToolRequestFailuresKeepMainServerMessageSanitization() async throws {
    let rawMessage = "line one\nline two\u{07} " + String(repeating: "x", count: 300)
    let expected = String(("line one line two " + String(repeating: "x", count: 300)).prefix(200))
    let fixture = try RelayControllerFixture(responses: [.failure(rawMessage), .tools, .failure(rawMessage)])
    defer { fixture.cleanup() }

    await expectRemoteRefreshFailure(fixture.controller)
    #expect(fixture.controller.remoteToolsState == .failed(expected))
    _ = try await fixture.controller.refreshRemoteTools()
    let tool = try #require(fixture.controller.remoteTools.first)
    await fixture.controller.revoke(tool)
    #expect(fixture.controller.remoteToolActionState == .failed(expected))
}
