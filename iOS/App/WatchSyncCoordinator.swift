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

    var refreshHandler: RefreshHandler?
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
        guard message[WatchMessageKey.command] as? String == WatchMessageKey.refresh else {
            replyHandler([:])
            return
        }

        let reply = WatchReplyHandlerBox(replyHandler)
        Task { @MainActor [weak self] in
            guard let handler = self?.refreshHandler else {
                reply.call([:])
                return
            }
            let envelope = await handler()
            let data = try? WatchUsageSnapshotCodec.encode(envelope)
            reply.call(data.map { [WatchMessageKey.snapshot: $0] } ?? [:])
        }
    }
}
