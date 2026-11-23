import SwiftUI

@main
struct UsAIgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system

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
                        navigation: appDelegate.settingsNavigation,
                        refreshWorkspace: { appDelegate.refreshWorkspace() },
                        addWorkspaceFolder: { appDelegate.addWorkspaceFolder() }
                    )
                } else {
                    LegacyHUDSettingsRootView(
                        settings: appDelegate.settings,
                        store: appDelegate.store,
                        launchAtLogin: appDelegate.launchAtLogin,
                        updateController: appDelegate.updateController,
                        relaySync: appDelegate.relaySync,
                        liveWork: appDelegate.liveWork
                    )
                    .frame(width: 520, height: 580)
                }
            }
            .appLanguageEnvironment()
        }
        .commands {
            settingsCommands
            // A menu item added through AppKit at launch doesn't survive
            // SwiftUI rebuilding the menu bar, so this one is declared here.
            CommandGroup(after: .appInfo) {
                Button(AppLanguage.text("Open usAIge", locale: language.locale)) { appDelegate.showMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(AppLanguage.text("Open usAIge", locale: language.locale)) { appDelegate.showMainWindow() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(AppLanguage.text("Refresh", locale: language.locale)) { appDelegate.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(AppLanguage.text("Branches and Worktrees…", locale: language.locale)) { appDelegate.showBranches() }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
                Button(AppLanguage.text("Memory…", locale: language.locale)) { appDelegate.showBranches(front: .memory) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
                Button(AppLanguage.text("Storage…", locale: language.locale)) { appDelegate.showBranches(front: .storage) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(!AppDelegate.branchesAreAvailable)
            }
        }
    }

    // Both branches have the same command type. Older systems keep SwiftUI's
    // native Settings item; an empty additive group leaves it untouched.
    private var settingsCommands: some Commands {
        if #available(macOS 14.0, *) {
            return CommandGroup(replacing: .appSettings) { settingsCommandContent }
        } else {
            return CommandGroup(after: .appSettings) { settingsCommandContent }
        }
    }

    @ViewBuilder
    private var settingsCommandContent: some View {
        if #available(macOS 14.0, *) {
            Button(AppLanguage.text("Settings…", locale: language.locale)) { appDelegate.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
