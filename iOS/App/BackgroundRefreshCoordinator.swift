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
    static let taskIdentifier = "com.richardq.usaige.ios.refresh"
    private static let logger = Logger(
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

            let work = Task { @MainActor in
                guard let model else {
                    refreshTask.setTaskCompleted(success: false)
                    return
                }
                await model.start()
                let succeeded = await model.refreshDueTools(forceWhenCacheIsEmpty: true)
                schedule(afterMinutes: model.minimumRefreshIntervalMinutes)
                refreshTask.setTaskCompleted(success: succeeded)
            }
            refreshTask.expirationHandler = {
                work.cancel()
                Task { @MainActor in
                    model?.cancelRefresh()
                }
            }
        }
    }

    static func schedule(afterMinutes minutes: Int) {
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
