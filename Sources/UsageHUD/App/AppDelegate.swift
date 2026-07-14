import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate {
    let settings: HUDSettings
    let store: UsageStore
    let visibilityController: VisibilityController
    let launchAtLogin: LaunchAtLoginController
    let updateController: UpdateController
    private var panel: HUDPanel?
    private(set) var settingsWindow: NSWindow?
    private var isTerminationPending = false
    private var hasRepliedToTermination = false

    override init() {
        settings = HUDSettings()
        if let executable = CodexExecutableResolver.resolve() {
            let transport = ProcessLineTransport(executableURL: executable)
            let connection = JSONRPCConnection(transport: transport)
            store = UsageStore(provider: CodexUsageProvider(rpc: connection))
        } else {
            store = UsageStore(provider: MissingCodexProvider())
        }
        visibilityController = VisibilityController(settings: settings)
        launchAtLogin = LaunchAtLoginController()
        updateController = UpdateController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: UpdateController.notificationCategory,
                actions: [],
                intentIdentifiers: []
            ),
        ])
        let content = HUDView(
            store: store,
            settings: settings,
            updateController: updateController,
            openTool: AIToolLauncher.open,
            openSettings: { [weak self] in self?.showSettings() },
            resizePanel: { [weak self] size in self?.resizePanel(to: size) }
        )
        let panel = HUDPanel(contentView: NSHostingView(rootView: content))
        panel.delegate = self
        self.panel = panel
        visibilityController.onDecisionChange = { [weak self] decision in
            guard let panel = self?.panel else { return }
            switch decision {
            case .visible: panel.orderFrontRegardless()
            case .hidden: panel.orderOut(nil)
            }
        }
        positionPanel(panel)
        panel.orderFrontRegardless()
        store.start()
        visibilityController.start()
        updateController.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updateController.isReplacementPrepared {
            visibilityController.stop()
            updateController.stop()
            return .terminateNow
        }

        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true
        visibilityController.stop()
        updateController.stop()
        Task { [weak self] in
            guard let self else { return }
            await self.store.shutdown()
            self.finishTermination(sender)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, let screen = panel.screen else { return }
        settings.setPosition(panel.frame.origin, for: Self.displayKey(for: screen))
    }

    func resetPanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let key = Self.displayKey(for: screen)
        settings.resetPosition(for: key)
        positionPanel(panel, on: screen)
    }

    func showSettings() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            launchAtLogin.refresh()
            let content = HUDSettingsRootView(
                settings: settings,
                store: store,
                launchAtLogin: launchAtLogin,
                updateController: updateController
            )
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 680),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "usAIge Settings"
            window.contentView = NSHostingView(rootView: content)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setFrameAutosaveName("usAIgeSettingsWindow")
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func positionPanel(_ panel: NSPanel, on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        let key = Self.displayKey(for: screen)
        let frame = PanelPositioner.frame(
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            savedOrigin: settings.position(for: key)
        )
        panel.setFrame(frame, display: true)
    }

    private func resizePanel(to size: CGSize) {
        guard let panel,
              abs(panel.frame.width - size.width) > 0.5
                || abs(panel.frame.height - size.height) > 0.5 else { return }

        let anchoredOrigin = CGPoint(
            x: panel.frame.maxX - size.width,
            y: panel.frame.minY
        )
        let frame: CGRect
        if let screen = panel.screen ?? NSScreen.main {
            frame = PanelPositioner.frame(
                panelSize: size,
                visibleFrame: screen.visibleFrame,
                savedOrigin: anchoredOrigin
            )
        } else {
            frame = CGRect(origin: anchoredOrigin, size: size)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    static func displayKey(for screen: NSScreen) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[numberKey] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor [weak self] in
            self?.showSettings()
        }
    }

}

private enum CodexExecutableResolver {
    static func resolve() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for directory in pathEntries {
            let path = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

private actor MissingCodexProvider: CodexUsageProviding {
    func refresh() async throws -> AccountUsageResult {
        throw MissingCodexError.notInstalled
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

private enum MissingCodexError: Error {
    case notInstalled
}
