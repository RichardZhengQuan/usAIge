import BackgroundTasks
import OSLog
import UIKit
import UserNotifications

struct SessionNotificationDestination: Equatable {
    let channelID: UUID?
    let eventID: String
}

enum SessionNotificationRouter {
    static let categoryIdentifier = "USAGE_HUD_SESSION_EVENT"

    static func destination(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> SessionNotificationDestination? {
        guard categoryIdentifier == self.categoryIdentifier,
              let payload = userInfo["sessionEvent"] as? [String: Any],
              let eventID = payload["id"] as? String,
              !eventID.isEmpty else { return nil }
        let channelID = (payload["channelID"] as? String).flatMap(UUID.init(uuidString:))
        return SessionNotificationDestination(channelID: channelID, eventID: eventID)
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshCoordinator.register()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await BackgroundRefreshCoordinator.receiveAPNsToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let succeeded = await BackgroundRefreshCoordinator.handleBackgroundPush()
            completionHandler(succeeded ? .newData : .failed)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard let destination = SessionNotificationRouter.destination(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) else { return }
        await BackgroundRefreshCoordinator.openSessionNotifications(
            channelID: destination.channelID,
            eventID: destination.eventID
        )
    }
}

@MainActor
enum BackgroundRefreshCoordinator {
    nonisolated static let taskIdentifier = "com.richardq.usaige.ios.refresh"
    nonisolated static let defaultRefreshIntervalMinutes = 15
    private nonisolated static let logger = Logger(
        subsystem: "com.richardq.usaige",
        category: "BackgroundRefresh"
    )
    private static weak var model: RelayAppModel?

    static func attach(_ appModel: RelayAppModel) {
        model = appModel
    }

    static func receiveAPNsToken(_ token: Data) async {
        #if DEBUG
        await model?.receiveAPNsToken(token, environment: "sandbox")
        #else
        await model?.receiveAPNsToken(token, environment: "production")
        #endif
    }

    static func handleBackgroundPush() async -> Bool { await model?.handleBackgroundPush() ?? false }

    static func openSessionNotifications(channelID: UUID?, eventID: String?) async {
        await model?.openSessionNotifications(channelID: channelID, eventID: eventID)
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            // iOS may kill the process as soon as the expiration handler
            // returns, so the task must be completed there and then, and the
            // normal path must not complete it a second time.
            let completion = BackgroundTaskCompletion(refreshTask)
            let work = Task { @MainActor in
                guard let model else {
                    // Keep the chain alive even when there is no model to
                    // refresh with; otherwise background refresh silently
                    // stops until the app is next backgrounded by hand.
                    schedule(afterMinutes: defaultRefreshIntervalMinutes)
                    completion.complete(success: false)
                    return
                }
                await model.start()
                let succeeded = await model.refreshDueTools(forceWhenCacheIsEmpty: true)
                schedule(afterMinutes: model.minimumRefreshIntervalMinutes)
                completion.complete(success: succeeded)
            }
            refreshTask.expirationHandler = {
                work.cancel()
                // The next opportunity must already be booked before the
                // system takes this one away.
                schedule(afterMinutes: defaultRefreshIntervalMinutes)
                completion.complete(success: false)
                Task { @MainActor in
                    model?.cancelRefresh()
                }
            }
        }
    }

    /// Safe from any queue: the expiration handler runs on the scheduler's
    /// own queue, and BGTaskScheduler is thread-safe.
    nonisolated static func schedule(afterMinutes minutes: Int) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(TimeInterval(max(15, minutes) * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Could not schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Completes a background task exactly once, whichever of the refresh and
/// the expiration handler gets there first.
private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var isCompleted = false

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        let shouldComplete = !isCompleted
        isCompleted = true
        lock.unlock()
        guard shouldComplete else { return }
        task.setTaskCompleted(success: success)
    }
}
