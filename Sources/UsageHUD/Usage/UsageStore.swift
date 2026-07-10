import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var state: UsageState = .connecting

    private let provider: any CodexUsageProviding
    private let now: @Sendable () -> Date
    private var updateTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryIndex = 0

    init(
        provider: any CodexUsageProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.now = now
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

        wakeTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSWorkspace.didWakeNotification
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                await self.handleWake()
            }
        }

        clockTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .NSSystemClockDidChange
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                await self.handleClockChange()
            }
        }
    }

    func refresh() async {
        do {
            let result = try await provider.refresh()
            retryIndex = 0
            retryTask?.cancel()
            retryTask = nil
            switch result {
            case .signedOut:
                state = .signedOut
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

    func handleWake() async {
        await refresh()
    }

    func handleClockChange() async {
        await refresh()
    }

    func stop() {
        updateTask?.cancel()
        wakeTask?.cancel()
        clockTask?.cancel()
        resetTask?.cancel()
        retryTask?.cancel()
        updateTask = nil
        wakeTask = nil
        clockTask = nil
        resetTask = nil
        retryTask = nil
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
        guard let resetAt = snapshots.compactMap(\.resetAt).filter({ $0 > now() }).min() else {
            resetTask = nil
            return
        }
        let delay = resetAt.timeIntervalSince(now())
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.refresh()
        }
    }
}
