import SwiftUI

@main
struct UsAIgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Group {
                if #available(macOS 14.0, *) {
                    HUDSettingsView(
                        settings: appDelegate.settings,
                        snapshots: appDelegate.store.visibleSnapshots,
                        launchAtLogin: appDelegate.launchAtLogin,
                        updateController: appDelegate.updateController,
                        refreshUsage: { await appDelegate.store.refresh() }
                    )
                } else {
                    LegacyHUDSettingsRootView(
                        settings: appDelegate.settings,
                        store: appDelegate.store,
                        launchAtLogin: appDelegate.launchAtLogin,
                        updateController: appDelegate.updateController
                    )
                }
            }
            .frame(width: 520, height: 680)
        }
    }
}
