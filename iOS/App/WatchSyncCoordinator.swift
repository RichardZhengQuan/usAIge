import Foundation
import WatchConnectivity

private final class WatchReplyHandlerBox: @unchecked Sendable {
    let call: ([String: Any]) -> Void

    init(_ call: @escaping ([String: Any]) -> Void) {
        self.call = call
    }
}

@MainActor
final class WatchSyncCoordinator: NSObject, WCSessionDelegate {
    typealias RefreshHandler = @MainActor () async -> WatchUsageSnapshotEnvelope
    typealias ProvisionHandler = @MainActor (UUID) async -> [WatchRelayCredential]

    var refreshHandler: RefreshHandler?
    var provisionHandler: ProvisionHandler?
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func activate() {
        session?.delegate = self
        session?.activate()
    }

    func publish(_ envelope: WatchUsageSnapshotEnvelope) {
        guard let session, session.activationState == .activated,
              let data = try? WatchUsageSnapshotCodec.encode(envelope) else { return }
        try? session.updateApplicationContext([WatchMessageKey.snapshot: data])
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let reply = WatchReplyHandlerBox(replyHandler)
        let command = message[WatchMessageKey.command] as? String
        let installationIDValue = message[WatchMessageKey.installationID] as? String
        Task { @MainActor [weak self] in
            switch command {
            case WatchMessageKey.refresh:
                guard let handler = self?.refreshHandler else {
                    reply.call([:])
                    return
                }
                let envelope = await handler()
                let data = try? WatchUsageSnapshotCodec.encode(envelope)
                reply.call(data.map { [WatchMessageKey.snapshot: $0] } ?? [:])
            case WatchMessageKey.provisionCellular:
                guard let installationIDValue,
                      let installationID = UUID(uuidString: installationIDValue),
                      let handler = self?.provisionHandler else {
                    reply.call([:])
                    return
                }
                let credentials = await handler(installationID)
                let data = try? WatchRelayCredentialCodec.encode(credentials)
                reply.call(data.map { [WatchMessageKey.relayCredentials: $0] } ?? [:])
            default:
                reply.call([:])
            }
        }
    }
}
