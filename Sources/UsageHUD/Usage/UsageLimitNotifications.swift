import Foundation
import UserNotifications

enum UsageLimitWindowKind: String, Equatable, Sendable {
    case primary
    case secondary
}

struct UsageLimitThresholdEvent: Equatable, Sendable {
    let toolID: AIToolID
    let bucketID: String
    let displayName: String
    let windowKind: UsageLimitWindowKind
    let windowTag: String
    let thresholdPercent: Int
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
}

struct UsageLimitThresholdTracker {
    private let stepPercent: Int

    private struct WindowKey: Hashable {
        let toolID: AIToolID
        let bucketID: String
        let windowKind: UsageLimitWindowKind
    }

    private struct Observation {
        let usedPercent: Double
        let band: Int
        let highWaterBand: Int
        let resetAt: Date?
        let pendingReset: Bool
    }

    private var observations: [WindowKey: Observation] = [:]

    init(stepPercent: Int = HUDSettings.defaultUsageAlertIntervalPercent) {
        self.stepPercent = max(1, min(100, stepPercent))
    }

    mutating func events(for snapshots: [QuotaSnapshot]) -> [UsageLimitThresholdEvent] {
        var activeKeys: Set<WindowKey> = []
        var events: [UsageLimitThresholdEvent] = []

        for snapshot in snapshots {
            let primaryKey = WindowKey(
                toolID: snapshot.toolID,
                bucketID: snapshot.id,
                windowKind: .primary
            )
            activeKeys.insert(primaryKey)
            if let event = observe(
                key: primaryKey,
                snapshot: snapshot,
                windowTag: snapshot.typeTag,
                usedPercent: snapshot.usedPercent,
                remainingPercent: snapshot.remainingPercent,
                resetAt: snapshot.resetAt,
                windowDurationMinutes: snapshot.windowDurationMinutes
            ) {
                events.append(event)
            }

            if let secondary = snapshot.secondaryWindow {
                let secondaryKey = WindowKey(
                    toolID: snapshot.toolID,
                    bucketID: snapshot.id,
                    windowKind: .secondary
                )
                activeKeys.insert(secondaryKey)
                if let event = observe(
                    key: secondaryKey,
                    snapshot: snapshot,
                    windowTag: secondary.typeTag,
                    usedPercent: secondary.usedPercent,
                    remainingPercent: secondary.remainingPercent,
                    resetAt: secondary.resetAt,
                    windowDurationMinutes: secondary.windowDurationMinutes
                ) {
                    events.append(event)
                }
            }
        }

        observations = observations.filter { activeKeys.contains($0.key) }
        return events
    }

    private mutating func observe(
        key: WindowKey,
        snapshot: QuotaSnapshot,
        windowTag: String,
        usedPercent: Double,
        remainingPercent: Double,
        resetAt: Date?,
        windowDurationMinutes: Int?
    ) -> UsageLimitThresholdEvent? {
        let used = min(100, max(0, usedPercent))
        let remaining = min(100, max(0, remainingPercent))
        let maximumBand = 100 / stepPercent
        let band = min(maximumBand, max(0, Int(floor(used / Double(stepPercent)))))

        guard let previous = observations[key] else {
            observations[key] = Observation(
                usedPercent: used,
                band: band,
                highWaterBand: band,
                resetAt: resetAt,
                pendingReset: false
            )
            return nil
        }

        let fellToLowerBand = band < previous.band
        let usageDrop = previous.usedPercent - used
        let resetDateAdvanced = Self.resetDateAdvanced(
            from: previous.resetAt,
            to: resetAt,
            windowDurationMinutes: windowDurationMinutes
        )
        let lacksStableResetIdentity = previous.resetAt == nil || resetAt == nil
        let confirmedByRollover = lacksStableResetIdentity && fellToLowerBand
            && (usageDrop >= Double(stepPercent) || (band == 0 && usageDrop >= 1))
        let confirmedByResetDate = (fellToLowerBand || previous.pendingReset)
            && resetDateAdvanced
        let isNewCycle = confirmedByRollover || confirmedByResetDate

        if isNewCycle {
            observations[key] = Observation(
                usedPercent: used,
                band: band,
                highWaterBand: band,
                resetAt: resetAt,
                pendingReset: false
            )
            guard band > 0 else { return nil }
            return makeEvent(
                key: key,
                snapshot: snapshot,
                windowTag: windowTag,
                thresholdPercent: band * stepPercent,
                usedPercent: used,
                remainingPercent: remaining,
                resetAt: resetAt
            )
        }

        let highWaterBand = max(previous.highWaterBand, band)
        let pendingReset: Bool
        if fellToLowerBand {
            pendingReset = true
        } else if band >= previous.highWaterBand {
            pendingReset = false
        } else {
            pendingReset = previous.pendingReset
        }
        observations[key] = Observation(
            usedPercent: used,
            band: band,
            highWaterBand: highWaterBand,
            resetAt: resetAt,
            pendingReset: pendingReset
        )

        guard !fellToLowerBand,
              band > previous.highWaterBand,
              band > 0 else { return nil }

        return makeEvent(
            key: key,
            snapshot: snapshot,
            windowTag: windowTag,
            thresholdPercent: band * stepPercent,
            usedPercent: used,
            remainingPercent: remaining,
            resetAt: resetAt
        )
    }

    private static func resetDateAdvanced(
        from previous: Date?,
        to current: Date?,
        windowDurationMinutes: Int?
    ) -> Bool {
        guard let previous, let current else { return false }
        let expectedWindow = Double(windowDurationMinutes ?? 0) * 60
        let minimumAdvance = max(60, expectedWindow * 0.5)
        return current.timeIntervalSince(previous) >= minimumAdvance
    }

    private func makeEvent(
        key: WindowKey,
        snapshot: QuotaSnapshot,
        windowTag: String,
        thresholdPercent: Int,
        usedPercent: Double,
        remainingPercent: Double,
        resetAt: Date?
    ) -> UsageLimitThresholdEvent {
        UsageLimitThresholdEvent(
            toolID: snapshot.toolID,
            bucketID: snapshot.id,
            displayName: snapshot.displayName,
            windowKind: key.windowKind,
            windowTag: windowTag,
            thresholdPercent: thresholdPercent,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAt: resetAt
        )
    }
}

enum UsageLimitNotifications {
    static let categoryIdentifier = "USAGE_HUD_LIMIT"
    static let openLimitsActionIdentifier = "USAGE_HUD_OPEN_LIMITS"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: openLimitsActionIdentifier,
                    title: "View Limits",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: []
        )
    }
}

enum AppNotificationCategories {
    static var all: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(
                identifier: UpdateController.notificationCategory,
                actions: [],
                intentIdentifiers: []
            ),
            UsageLimitNotifications.category,
        ]
    }
}

enum UsageLimitNotificationRequest {
    static func make(for event: UsageLimitThresholdEvent) -> UNNotificationRequest {
        let tool = AIToolDescriptor.descriptor(for: event.toolID)
        let remaining = Int(event.remainingPercent.rounded())
        let content = UNMutableNotificationContent()
        content.title = "\(tool.name) \(event.displayName): \(remaining)% remaining"
        content.body = "\(event.windowTag) usage reached \(event.thresholdPercent)%. Open usAIge to see the reset time."
        content.sound = .default
        content.categoryIdentifier = UsageLimitNotifications.categoryIdentifier
        content.threadIdentifier = "usaige-limit-\(event.toolID.rawValue)-\(event.bucketID)"
        content.userInfo = [
            "toolID": event.toolID.rawValue,
            "bucketID": event.bucketID,
            "windowKind": event.windowKind.rawValue,
            "thresholdPercent": event.thresholdPercent,
        ]

        let cycle = Int(event.resetAt?.timeIntervalSince1970 ?? 0)
        let identifier = [
            "usaige-limit",
            event.toolID.rawValue,
            event.bucketID,
            event.windowKind.rawValue,
            String(event.thresholdPercent),
            String(cycle),
        ].joined(separator: "-")
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

enum AppNotificationDestination: Equatable {
    case settings
    case limits
    case whatsNew
}

enum AppNotificationRouter {
    nonisolated static func destination(
        categoryIdentifier: String,
        actionIdentifier: String
    ) -> AppNotificationDestination? {
        switch categoryIdentifier {
        case UsageLimitNotifications.categoryIdentifier:
            guard actionIdentifier == UNNotificationDefaultActionIdentifier
                    || actionIdentifier == UsageLimitNotifications.openLimitsActionIdentifier else {
                return nil
            }
            return .limits
        case UpdateController.notificationCategory:
            guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
            return .whatsNew
        default:
            return nil
        }
    }
}

@MainActor
protocol UsageLimitNotificationScheduling: AnyObject {
    func prepare() async
    func schedule(_ event: UsageLimitThresholdEvent) async
}

@MainActor
final class SystemUsageLimitNotificationScheduler: UsageLimitNotificationScheduling {
    func prepare() async {
        _ = await canSendNotifications(requestIfNeeded: true)
    }

    func schedule(_ event: UsageLimitThresholdEvent) async {
        guard await canSendNotifications(requestIfNeeded: true) else { return }
        do {
            try await UNUserNotificationCenter.current().add(
                UsageLimitNotificationRequest.make(for: event)
            )
        } catch {
            // The floating panel remains the source of truth if delivery is unavailable.
        }
    }

    private func canSendNotifications(requestIfNeeded: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined where requestIfNeeded:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

@MainActor
final class UsageLimitNotificationController {
    private var tracker = UsageLimitThresholdTracker()
    private var intervalPercent = HUDSettings.defaultUsageAlertIntervalPercent
    private let scheduler: any UsageLimitNotificationScheduling
    private var deliveryTask: Task<Void, Never>?
    private var queuedEvents: [UsageLimitThresholdEvent] = []
    private var preparationQueued = false
    private var hasPrepared = false
    private var isStopped = false

    init(scheduler: any UsageLimitNotificationScheduling = SystemUsageLimitNotificationScheduler()) {
        self.scheduler = scheduler
    }

    func observe(
        _ snapshots: [QuotaSnapshot],
        intervalPercent requestedInterval: Int = HUDSettings.defaultUsageAlertIntervalPercent
    ) {
        guard !isStopped else { return }
        if requestedInterval != intervalPercent {
            intervalPercent = requestedInterval
            tracker = UsageLimitThresholdTracker(stepPercent: requestedInterval)
        }
        let events = tracker.events(for: snapshots)
        let shouldPrepare = !hasPrepared && !snapshots.isEmpty
        if shouldPrepare { hasPrepared = true }
        guard shouldPrepare || !events.isEmpty else { return }

        preparationQueued = preparationQueued || shouldPrepare
        queuedEvents.append(contentsOf: events)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await self?.deliverQueuedNotifications()
        }
    }

    func stop() {
        isStopped = true
        preparationQueued = false
        queuedEvents.removeAll()
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func deliverQueuedNotifications() async {
        if preparationQueued {
            preparationQueued = false
            await scheduler.prepare()
        }

        while !Task.isCancelled, !isStopped, !queuedEvents.isEmpty {
            let event = queuedEvents.removeFirst()
            await scheduler.schedule(event)
        }
        deliveryTask = nil
    }
}
