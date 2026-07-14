import BackgroundTasks
import OSLog
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshCoordinator.register()
        return true
    }
}

@MainActor
enum BackgroundRefreshCoordinator {
    static let taskIdentifier = "com.richardq.usaige.ios.refresh"
    private static let logger = Logger(
        subsystem: "com.richardq.usaige",
        category: "BackgroundRefresh"
    )
    private static weak var model: AppModel?

    static func attach(_ appModel: AppModel) {
        model = appModel
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
