import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate {
    let settings: HUDSettings
    let store: UsageStore
    let agentStore: CodexAgentStore
    let launchAtLogin: LaunchAtLoginController
    let updateController: UpdateController
    let usageLimitNotifications: UsageLimitNotificationController
    let relaySync: RelaySyncController
    private var panel: HUDPanel?
    private var codexAttentionMonitor: CodexAttentionMonitor?
    var settingsSceneOpener: @MainActor () -> Void = SettingsScenePresenter.open
    private var isTerminationPending = false
    private var hasRepliedToTermination = false
    private var relaySettingsObserver: AnyCancellable?

    override init() {
        let configuredSettings = HUDSettings()
        settings = configuredSettings
        let configuredRelaySync = RelaySyncController()
        relaySync = configuredRelaySync
        let localProvider: any CodexUsageProviding
        let agentProvider: any CodexAgentProviding
        if let executable = CodexExecutableResolver.resolve() {
            let transport = ProcessLineTransport(executableURL: executable)
            let connection = JSONRPCConnection(transport: transport)
            localProvider = CodexUsageProvider(rpc: connection)
            let agentTransport = ProcessLineTransport(executableURL: executable)
            let agentConnection = JSONRPCConnection(transport: agentTransport)
            agentProvider = CodexAgentProvider(rpc: agentConnection)
        } else {
            localProvider = MissingCodexProvider()
            agentProvider = MissingCodexAgentProvider()
        }
        let remoteProvider = RemoteUsageProvider {
            try await configuredRelaySync.refreshRemoteTools()
        }
        store = UsageStore(provider: CompositeUsageProvider(
            local: localProvider,
            remote: remoteProvider
        ))
        agentStore = CodexAgentStore(provider: agentProvider)
        launchAtLogin = LaunchAtLoginController()
        updateController = UpdateController()
        usageLimitNotifications = UsageLimitNotificationController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories(AppNotificationCategories.all)
        store.onSnapshotsChanged = { [settings, usageLimitNotifications, relaySync] snapshots in
            let visible = settings.ordered(snapshots)
            usageLimitNotifications.observe(
                visible,
                intervalPercent: settings.usageAlertIntervalPercent
            )
            relaySync.observe(visible)
        }
        let content: AnyView
        if #available(macOS 14.0, *) {
            content = AnyView(HUDView(
                store: store,
                agentStore: agentStore,
                settings: settings,
                updateController: updateController,
                openTool: AIToolLauncher.open,
                openCodex: AIToolLauncher.openCodex,
                openSettings: { [weak self] in self?.showSettings() },
                resizePanel: { [weak self] size in self?.resizePanel(to: size) }
            ))
        } else {
            content = AnyView(LegacyHUDView(
                store: store,
                settings: settings,
                updateController: updateController,
                openTool: AIToolLauncher.open,
                openSettings: { [weak self] in self?.showSettings() },
                resizePanel: { [weak self] size in self?.resizePanel(to: size) }
            ))
        }
        let panel = HUDPanel(contentView: NSHostingView(rootView: content))
        panel.delegate = self
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
        store.start()
        relaySync.start()
        relaySettingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.relaySync.observe(self.settings.ordered(self.store.visibleSnapshots))
            }
        }
        agentStore.onAttentionEvent = { [weak relaySync] task in
            relaySync?.sendSessionEvent(for: task)
        }
        agentStore.start()
        let codexAttentionMonitor = CodexAttentionMonitor { [weak self] in
            self?.agentStore.acknowledgeAttentionStates()
        }
        codexAttentionMonitor.start()
        self.codexAttentionMonitor = codexAttentionMonitor
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
            updateController.stop()
            usageLimitNotifications.stop()
            codexAttentionMonitor?.stop()
            return .terminateNow
        }

        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true
        updateController.stop()
        usageLimitNotifications.stop()
        codexAttentionMonitor?.stop()
        Task { [weak self] in
            guard let self else { return }
            async let usageShutdown: Void = self.store.shutdown()
            async let agentShutdown: Void = self.agentStore.shutdown()
            _ = await (usageShutdown, agentShutdown)
            self.finishTermination(sender)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
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
        launchAtLogin.refresh()
        settingsSceneOpener()
    }

    func showLimits() {
        guard let panel else {
            showSettings()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
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
        let destination = AppNotificationRouter.destination(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier
        )
        completionHandler()
        guard let destination else { return }
        Task { @MainActor [weak self] in
            switch destination {
            case .settings:
                self?.showSettings()
            case .limits:
                self?.showLimits()
            }
        }
    }

}

@MainActor
private final class CodexAttentionMonitor {
    private static let bundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
    ]

    private let acknowledge: () -> Void
    private var activationObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    init(acknowledge: @escaping () -> Void) {
        self.acknowledge = acknowledge
    }

    func start() {
        guard activationObserver == nil, clickMonitor == nil else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.acknowledgeIfCodex(application)
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let application = NSWorkspace.shared.frontmostApplication else { return }
                self?.acknowledgeIfCodex(application)
            }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func acknowledgeIfCodex(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.bundleIdentifiers.contains(bundleIdentifier)
        else { return }
        acknowledge()
    }
}

@MainActor
enum SettingsScenePresenter {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let item = settingsMenuItem(in: NSApp.mainMenu),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        focusSettingsWindowWhenReady()
    }

    private static func focusSettingsWindowWhenReady() {
        Task { @MainActor in
            for _ in 0..<12 {
                if let window = NSApp.windows.first(where: isSettingsWindow) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    static func settingsMenuItem(in mainMenu: NSMenu?) -> NSMenuItem? {
        mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .first {
                $0.keyEquivalent == ","
                    && $0.keyEquivalentModifierMask.contains(.command)
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
