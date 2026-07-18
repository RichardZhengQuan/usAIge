import SwiftUI

@main
struct UsAIgeIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RelayAppModel

    init() {
        let model = RelayAppModel()
        _model = State(initialValue: model)
        // Attach before application launch finishes so a background-task launch
        // never races the first WindowGroup view task.
        BackgroundRefreshCoordinator.attach(model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.start()
                    await model.refreshAll()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await model.refreshAll() }
                    case .background:
                        BackgroundRefreshCoordinator.schedule(
                            afterMinutes: model.minimumRefreshIntervalMinutes
                        )
                    default:
                        break
                    }
                }
        }
    }
}
