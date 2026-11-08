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
                Button("Open usAIge") { appDelegate.showAppWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open usAIge") { appDelegate.showAppWindow() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { appDelegate.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Branches and Worktrees…") { appDelegate.showBranches() }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
                Button("Memory…") { appDelegate.showBranches(front: .memory) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
                Button("Storage…") { appDelegate.showBranches(front: .storage) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
            }
        }
    }
}
