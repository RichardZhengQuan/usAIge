import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchUsageModel: NSObject, ObservableObject {
    @Published private(set) var envelope: WatchUsageSnapshotEnvelope?
    @Published private(set) var isRefreshing = false
    @Published private(set) var phoneIsReachable = false
    @Published var errorMessage: String?

    private let cache: WatchSnapshotFileStore
    private let session: WCSession?

    override init() {
        cache = WatchSnapshotFileStore(fileURL: AppGroup.snapshotURL())
        session = WCSession.isSupported() ? .default : nil
        envelope = try? cache.load()
        super.init()
        session?.delegate = self
        session?.activate()
        phoneIsReachable = session?.isReachable ?? false
    }

    var isStale: Bool {
        guard let envelope, !envelope.tools.isEmpty else { return true }
        return envelope.tools.contains(where: isStale)
    }

    func isStale(_ tool: WatchToolQuotaSnapshot) -> Bool {
        Date().timeIntervalSince(tool.sourceUpdatedAt) > 30 * 60
    }

    func refresh() {
        guard !isRefreshing else { return }
        guard let session, session.activationState == .activated, session.isReachable else {
            errorMessage = "Open usAIge on the paired iPhone, then try again."
            phoneIsReachable = false
            return
        }

        isRefreshing = true
        session.sendMessage(
            [WatchMessageKey.command: WatchMessageKey.refresh],
            replyHandler: { [weak self] reply in
                guard let data = reply[WatchMessageKey.snapshot] as? Data else {
                    Task { @MainActor in
                        self?.isRefreshing = false
                        self?.errorMessage = "The iPhone did not return current limits."
                    }
                    return
                }
                self?.decodeAndAccept(data)
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isRefreshing = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        )
    }

    private nonisolated func decodeAndAccept(_ data: Data) {
        do {
            let envelope = try WatchUsageSnapshotCodec.decode(data)
            Task { @MainActor [weak self] in
                self?.accept(envelope)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.isRefreshing = false
                self?.errorMessage = "The iPhone sent an unsupported usage snapshot."
            }
        }
    }

    private func accept(_ newEnvelope: WatchUsageSnapshotEnvelope) {
        guard newEnvelope.schemaVersion == WatchUsageSnapshotEnvelope.currentSchemaVersion else {
            isRefreshing = false
            errorMessage = "Update usAIge on both devices to continue."
            return
        }

        do {
            try cache.save(newEnvelope)
            envelope = newEnvelope
            isRefreshing = false
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        } catch {
            isRefreshing = false
            errorMessage = "Could not save the latest limits."
        }
    }
}

extension WatchUsageModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isReachable = session.isReachable
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.phoneIsReachable = isReachable
            if let errorDescription { self?.errorMessage = errorDescription }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneIsReachable = isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[WatchMessageKey.snapshot] as? Data else { return }
        decodeAndAccept(data)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo[WatchMessageKey.snapshot] as? Data else { return }
        decodeAndAccept(data)
    }
}
