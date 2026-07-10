import SwiftUI

@main
struct UsAIgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            HUDSettingsView(
                settings: appDelegate.settings,
                snapshots: appDelegate.store.visibleSnapshots
            )
            .frame(width: 440, height: 520)
        }
    }
}
