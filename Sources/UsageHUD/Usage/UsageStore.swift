import AppKit
import Combine
import Foundation
import Network

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .connecting
    var onSnapshotsChanged: (([QuotaSnapshot]) -> Void)?

    private let provider: any CodexUsageProviding
    private let now: @Sendable () -> Date
    private let automaticRefreshInterval: TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    private let monitorsNetworkChanges: Bool
    private var updateTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var resetTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private var wasNetworkAvailable: Bool?
    private var retryIndex = 0
    private var isRefreshing = false
    private var lastSuccessfulRefresh: Date?
    private var refreshQueued = false

    init(
        provider: any CodexUsageProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        automaticRefreshInterval: TimeInterval = 5,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        monitorsNetworkChanges: Bool = true
    ) {
        self.provider = provider
        self.now = now
        self.automaticRefreshInterval = automaticRefreshInterval
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.monitorsNetworkChanges = monitorsNetworkChanges
    }

    func start() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            let updates = await self.provider.updates()
            for await snapshots in updates {
                guard !Task.isCancelled else { return }
                self.apply(snapshots)
            }
        }

        automaticRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Self.sleep(seconds: self.automaticRefreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshAutomatically()
            }
        }

        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleWake() }
        }

        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleClockChange() }
        }

        if monitorsNetworkChanges {
            startNetworkMonitoring()
        }

    }

    func refresh() async {
        await refresh(automatic: false)
    }

    private func refreshAutomatically() async {
        await refresh(automatic: true)
    }

    private func refresh(automatic: Bool) async {
        guard !isRefreshing else {
            if !automatic { refreshQueued = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var nextRefreshIsAutomatic = automatic
        repeat {
            refreshQueued = false
            await performRefresh(automatic: nextRefreshIsAutomatic)
            nextRefreshIsAutomatic = false
        } while refreshQueued && !Task.isCancelled
    }

    private func performRefresh(automatic: Bool) async {
        do {
            let result: AccountUsageResult
            if automatic,
               let automaticProvider = provider as? any AutomaticUsageProviding {
                result = try await automaticProvider.refreshAutomatically()
            } else {
                result = try await provider.refresh()
            }
            lastSuccessfulRefresh = now()
            retryIndex = 0
            retryTask?.cancel()
            retryTask = nil
            switch result {
            case .signedOut:
                state = .signedOut
                onSnapshotsChanged?([])
                scheduleReset(for: [])
            case let .authenticated(snapshots):
                apply(snapshots)
            }
        } catch {
            let previous = snapshots(in: state)
            if previous.isEmpty {
                state = .unavailable(message: "Open Codex to connect")
            } else {
                state = .stale(previous, since: now())
            }
            scheduleRetry()
        }
    }

    func refreshIfNeeded(maximumAge: TimeInterval) async {
        guard let lastSuccessfulRefresh,
              now().timeIntervalSince(lastSuccessfulRefresh) < maximumAge else {
            await refresh()
            return
        }
    }

    func handleWake() async {
        await refresh()
    }

    func handleClockChange() async {
        await refresh()
    }

    func handleNetworkAvailabilityChange(isAvailable: Bool) async {
        let shouldRefresh = wasNetworkAvailable == false && isAvailable
        wasNetworkAvailable = isAvailable
        if shouldRefresh {
            await refresh()
        }
    }

    func stop() {
        updateTask?.cancel()
        automaticRefreshTask?.cancel()
        if let wakeObserver { workspaceNotificationCenter.removeObserver(wakeObserver) }
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        resetTask?.cancel()
        retryTask?.cancel()
        networkMonitor?.cancel()
        updateTask = nil
        automaticRefreshTask = nil
        wakeObserver = nil
        clockObserver = nil
        resetTask = nil
        retryTask = nil
        networkMonitor = nil
        wasNetworkAvailable = nil
    }

    func shutdown() async {
        stop()
        await provider.stop()
    }

    func countdown(to resetAt: Date) -> String {
        Self.countdown(secondsRemaining: resetAt.timeIntervalSince(now()))
    }

    var visibleSnapshots: [QuotaSnapshot] {
        switch state {
        case let .current(values), let .stale(values, _): values
        default: []
        }
    }

    nonisolated static func countdown(secondsRemaining: TimeInterval) -> String {
        guard secondsRemaining > 0 else { return "Resetting…" }
        let total = Int(secondsRemaining.rounded(.down))
        if total >= 3_600 {
            return "\(total / 3_600)h \((total % 3_600) / 60)m"
        }
        if total >= 60 {
            return "\(total / 60)m"
        }
        return String(format: "0:%02d", total)
    }

    private func apply(_ snapshots: [QuotaSnapshot]) {
        state = snapshots.isEmpty ? .empty : .current(snapshots)
        onSnapshotsChanged?(snapshots)
        scheduleReset(for: snapshots)
    }

    private func snapshots(in state: UsageState) -> [QuotaSnapshot] {
        switch state {
        case let .current(values), let .stale(values, _): values
        default: []
        }
    }

    private func scheduleReset(for snapshots: [QuotaSnapshot]) {
        resetTask?.cancel()
        let resetDates = snapshots.flatMap { snapshot in
            [snapshot.resetAt, snapshot.secondaryWindow?.resetAt].compactMap { $0 }
        }
        guard let resetAt = resetDates.filter({ $0 > now() }).min() else {
            resetTask = nil
            return
        }
        let delay = resetAt.timeIntervalSince(now())
        resetTask = Task { [weak self] in
            try? await Self.sleep(seconds: delay)
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delays = [2.0, 4.0, 8.0, 16.0, 30.0, 60.0]
        let delay = delays[min(retryIndex, delays.count - 1)]
        retryIndex = min(retryIndex + 1, delays.count - 1)
        retryTask = Task { [weak self] in
            try? await Self.sleep(seconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.refresh()
        }
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                await self?.handleNetworkAvailabilityChange(isAvailable: path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.usaige.network-monitor"))
    }

    nonisolated private static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
