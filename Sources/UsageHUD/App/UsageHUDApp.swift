import SwiftUI

@main
struct UsAIgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Group {
                if #available(macOS 14.0, *) {
                    HUDSettingsRootView(
                        settings: appDelegate.settings,
                        store: appDelegate.store,
                        launchAtLogin: appDelegate.launchAtLogin,
                        updateController: appDelegate.updateController,
                        relaySync: appDelegate.relaySync,
                        localToolStatus: appDelegate.localToolStatus,
                        navigation: appDelegate.settingsNavigation
                    )
                } else {
                    LegacyHUDSettingsRootView(
                        settings: appDelegate.settings,
                        store: appDelegate.store,
                        launchAtLogin: appDelegate.launchAtLogin,
                        updateController: appDelegate.updateController,
                        relaySync: appDelegate.relaySync
                    )
                    .frame(width: 520, height: 580)
                }
            }
        }
        .commands {
            // A menu item added through AppKit at launch doesn't survive
            // SwiftUI rebuilding the menu bar, so this one is declared here.
            CommandGroup(after: .appInfo) {
                Button("Branches and Worktrees…") { appDelegate.showBranches() }
                    .disabled(!AppDelegate.branchesAreAvailable)
            }
        }
    }
}
