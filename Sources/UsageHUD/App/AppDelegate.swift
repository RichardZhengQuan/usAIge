import AppKit
import Combine
import Carbon
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate {
    let settings: HUDSettings
    let store: UsageStore
    let agentStore: CodexAgentStore
    let liveWork: LiveWorkMonitor
    let launchAtLogin: LaunchAtLoginController
    let updateController: UpdateController
    let usageLimitNotifications: UsageLimitNotificationController
    let relaySync: RelaySyncController
    let settingsNavigation: SettingsNavigation
    let localToolStatus: LocalToolStatusRegistry
    private var panel: HUDPanel?
    private var measuredRailSize: CGSize?
    let screenState = PanelScreenState()
    private let magnet: MagnetController
    private var magnetSettingsObserver: AnyCancellable?
    private var iconSettingsObserver: AnyCancellable?
    private var dockIconTransition: AnyCancellable?
    private lazy var menuBarIcon = MenuBarIconController(
        hoverChanged: { [weak self] inside in
            guard let self else { return }
            if inside {
                // The native status item owns the click on the current display.
                // The rail is already ordered on every Space and only needs to slide out.
                self.magnet.reveal()
            } else if self.magnet.isRevealed {
                // Give the pointer time to travel from the menu bar to the rail.
                self.magnet.showBriefly(for: 0.65)
            }
        },
        openWindow: { [weak self] in self?.showMainWindow() },
        showPanel: { [weak self] in self?.showLimits() },
        openSettings: { [weak self] in self?.showSettings() }
    )
    private var screenObserver: NSObjectProtocol?
    private var whatsNewWindowController: WhatsNewWindowController?
    private var branchesWindowController: NSWindowController?
    private var codexAttentionMonitor: CodexAttentionMonitor?
    var settingsSceneOpener: @MainActor () -> Void = SettingsScenePresenter.open
    var settingsPageOpener: (@MainActor () -> Void)?
    var mainWindowOpener: (@MainActor () -> Void)?
    private var isTerminationPending = false
    private var hasRepliedToTermination = false
    private var relaySettingsObserver: AnyCancellable?
    private var relayAgentObserver: AnyCancellable?
    private var liveWorkObserver: AnyCancellable?
    private var manualRefreshTask: Task<Void, Never>?
    private var workspaceRefreshTask: Task<Void, Never>?
    private var interfaceStyleObserver: NSObjectProtocol?
    private var railStyle = InterfaceStyle.current()
    private var restoredSettingsObserver: NSObjectProtocol?
    /// The pairing steps the main window's Usage page shows, with their own
    /// navigation so pairing a tool there doesn't move Settings.
    private let toolsNavigation = SettingsNavigation()
    private let syncNavigation = SettingsNavigation()

    override init() {
        let configuredSettings = HUDSettings()
        settings = configuredSettings
        magnet = MagnetController()
        let configuredRelaySync = RelaySyncController()
        relaySync = configuredRelaySync
        settingsNavigation = SettingsNavigation()
        let configuredLocalToolStatus = LocalToolStatusRegistry()
        localToolStatus = configuredLocalToolStatus
        let localProvider: any CodexUsageProviding
        let agentProvider: any CodexAgentProviding
        if CodexExecutableResolver.resolve() != nil {
            // Resolve again on every app-server start: a ChatGPT app update
            // can move or replace its bundled CLI while usAIge is running.
            // When nothing resolves, the start fails as a disconnect and the
            // next refresh looks again.
            let currentExecutable: @Sendable () -> URL? = { CodexExecutableResolver.resolve() }
            let transport = ProcessLineTransport(executableURL: currentExecutable)
            let connection = JSONRPCConnection(transport: transport)
            localProvider = CodexUsageProvider(rpc: connection)
            let agentTransport = ProcessLineTransport(executableURL: currentExecutable)
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
            throttled: LocalToolProviders.make(statusRegistry: configuredLocalToolStatus),
            remote: remoteProvider
        ))
        // Every rail row gets a session light: Codex through its app-server,
        // Claude Code, Cursor, and Grok Build through the files they keep.
        let configuredAgentStore = CodexAgentStore(sources: [
            .init(toolID: .chatGPT, provider: agentProvider),
            .init(toolID: .claude, provider: ClaudeCodeAgentProvider()),
            .init(toolID: .cursor, provider: CursorAgentProvider()),
            .init(toolID: .grok, provider: GrokBuildAgentProvider()),
        ])
        agentStore = configuredAgentStore
        liveWork = LiveWorkMonitor(currentTasks: { configuredAgentStore.currentTasks() })
        launchAtLogin = LaunchAtLoginController()
        updateController = UpdateController()
        usageLimitNotifications = UsageLimitNotificationController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyIconVisibility()
        iconSettingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyIconVisibility() }
        }
        closeRestoredSettingsWindow()
        DispatchQueue.main.async { [weak self] in
            self?.installWhatsNewMenuItem()
        }
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
        let pointerIsOnDetail: () -> Bool
        if #available(macOS 14.0, *) {
            let quotaDetail = QuotaDetailPanelController(rail: { [weak self] in self?.panel })
            quotaDetail.onVisibilityChanged = { [weak liveWork] isShown in
                liveWork?.detailVisibilityChanged(isShown)
            }
            liveWorkObserver = liveWork.$summary.combineLatest(liveWork.$memoryUsage, liveWork.$diskSpace)
                .sink { [weak quotaDetail] summary, memory, disk in
                    quotaDetail?.update(liveWork: summary, memory: memory)
                    quotaDetail?.update(disk: disk)
                }
            quotaDetail.openBranches = { [weak self] front in self?.showBranches(front: front) }
            quotaDetail.openCPU = { [weak self] in self?.presentMainWindow(destination: .thisMac) }
            pointerIsOnDetail = { [weak quotaDetail] in quotaDetail?.isPointerOnCard ?? false }
            content = AnyView(HUDView(
                store: store,
                agentStore: agentStore,
                settings: settings,
                updateController: updateController,
                openTool: AIToolLauncher.open,
                openCodex: AIToolLauncher.openCodex,
                openSettings: { [weak self] in self?.showSettings() },
                resizePanel: { [weak self] size in self?.resizePanel(to: size) },
                screenState: screenState,
                quotaDetail: quotaDetail,
                liveWork: liveWork,
                openBranches: { [weak self] in self?.showBranches() },
                openResourcePaperweight: { [weak self] front in self?.showBranches(front: front) },
                openThisMac: { [weak self] in self?.presentMainWindow(destination: .thisMac) }
            ))
        } else {
            pointerIsOnDetail = { false }
            content = AnyView(LegacyHUDView(
                store: store,
                settings: settings,
                updateController: updateController,
                screenState: screenState,
                liveWork: liveWork,
                openTool: AIToolLauncher.open,
                openSettings: { [weak self] in self?.showSettings() },
                resizePanel: { [weak self] size in self?.resizePanel(to: size) }
            ))
        }
        let panel = HUDPanel(contentView: NSHostingView(rootView: content.appLanguageEnvironment()))
        panel.delegate = self
        self.panel = panel
        magnet.attach(to: panel)
        magnet.keepsRevealed = { [weak self] in
            self?.menuBarIcon.containsPointer == true || pointerIsOnDetail()
        }
        magnet.onDockingChanged = { [weak self] edge, frame, screen in
            guard let self else { return }
            self.settings.setPosition(frame.origin, edge: edge, for: Self.displayKey(for: screen))
            if self.usesEdgeRail, let edge { self.screenState.railEdge = edge }
        }
        panel.onDragStateChanged = { [weak self] isDragging in
            guard let self else { return }
            if isDragging {
                self.magnet.dragDidBegin()
            } else if self.usesEdgeRail {
                self.magnet.dragDidEndWithoutDocking()
                self.snapEdgeRailAfterDrag()
            } else {
                self.magnet.dragDidEnd()
            }
        }
        applyRailStyle()
        interfaceStyleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, InterfaceStyle.current() != self.railStyle else { return }
                self.railStyle = InterfaceStyle.current()
                self.applyRailStyle()
                if let panel = self.panel {
                    self.magnet.undock()
                    self.positionPanel(panel, on: panel.screen ?? NSScreen.main)
                }
            }
        }
        var railLook = (opacity: settings.opacity, scale: settings.scale, textSize: settings.textSize)
        magnetSettingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // A docked rail is usually out of sight while its look is
                // changed in Settings, so it slides out to show the change.
                let look = (opacity: self.settings.opacity, scale: self.settings.scale, textSize: self.settings.textSize)
                if look != railLook {
                    railLook = look
                    if self.magnet.isDocked { self.magnet.showBriefly() }
                }
            }
        }
        positionPanel(panel, on: launchScreen())
        screenState.update(for: panel)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.screenState.update(for: panel)
                self.magnet.screenParametersDidChange()
                if self.usesEdgeRail, !self.magnet.isDocked, let screen = panel.screen ?? NSScreen.main {
                    self.placeEdgeRail(panel, on: screen, edge: self.screenState.railEdge ?? .right, animated: false)
                }
            }
        }
        panel.orderFrontRegardless()
        // Claude updates arrive through the store's local file polling and
        // its optional background extension. Never navigate Claude's UI to
        // refresh usage or resume a paused collector.
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
        relayAgentObserver = agentStore.$aggregatesByTool
            .map { aggregates in aggregates.mapValues(\.phase) }
            .removeDuplicates()
            .sink { [weak relaySync] phases in
                for (toolID, phase) in phases {
                    relaySync?.observeSession(phase, for: toolID)
                }
            }
        agentStore.start()
        liveWork.start(includingProcesses: Self.branchesAreAvailable)
        let codexAttentionMonitor = CodexAttentionMonitor { [weak self] toolID in
            self?.agentStore.acknowledgeAttentionStates(for: toolID)
        }
        codexAttentionMonitor.start()
        self.codexAttentionMonitor = codexAttentionMonitor
        updateController.start()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-branches") {
            showBranches()
        } else if arguments.contains("--show-cleanup") {
            showCleanup()
        } else if Self.shouldShowMainWindow(arguments: arguments,
                                           launchEvent: NSAppleEventManager.shared().currentAppleEvent) {
            showMainWindow()
        }
        if updateController.shouldPresentWhatsNewAfterLaunch
            || ProcessInfo.processInfo.arguments.contains("--show-whats-new") {
            showWhatsNew()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    private func applyIconVisibility() {
        menuBarIcon.setVisible(settings.showsMenuBarIcon)
        let policy: NSApplication.ActivationPolicy = settings.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        dockIconTransition = nil
        let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard NSApp.isActive, let window = keyWindow?.sheetParent ?? keyWindow,
              window.isVisible, !window.isMiniaturized else {
            NSApp.setActivationPolicy(policy)
            return
        }

        // Removing a Dock tile can deactivate the app several times, even
        // after setActivationPolicy returns. Keep the open window on screen.
        let wasHideable = window.canHide
        window.canHide = false
        let started = ProcessInfo.processInfo.systemUptime
        let deactivation = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification, object: NSApp)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] _ in
                guard let window, window.isVisible, !window.isMiniaturized, NSApp.activationPolicy() == policy else { return }
                // A new click or keystroke can deliberately move focus elsewhere.
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard [CGEventType.leftMouseDown, .rightMouseDown, .keyDown].allSatisfy({
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= elapsed
                }) else { return }
                if NSApp.isHidden { NSApp.unhideWithoutActivation() }
                NSApp.activate(ignoringOtherApps: true)
                (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
            }
        let transition = AnyCancellable { [weak window] in
            deactivation.cancel()
            window?.canHide = wasHideable
        }
        dockIconTransition = transition
        guard NSApp.setActivationPolicy(policy) else { dockIconTransition = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak transition] in
            guard let self, let transition, self.dockIconTransition === transition else { return }
            self.dockIconTransition = nil
        }
    }

    /// Login and service launches keep the rail available without opening a
    /// foreground window. Explicit app-window arguments still take precedence.
    static func shouldShowMainWindow(arguments: [String], launchEvent: NSAppleEventDescriptor?) -> Bool {
        if arguments.contains("--show-main") { return true }
        if arguments.contains("--background") { return false }
        guard launchEvent?.eventID == kAEOpenApplication else { return true }
        let source = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return source != keyAELaunchedAsLogInItem && source != keyAELaunchedAsServiceItem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspaceRefreshTask?.cancel()
        if updateController.isReplacementPrepared {
            updateController.stop()
            liveWork.stop()
            usageLimitNotifications.stop()
            codexAttentionMonitor?.stop()
            return .terminateNow
        }

        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true
        updateController.stop()
        liveWork.stop()
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
        screenState.update(for: panel)
        // A docked rail's position is recorded by Magnet itself, and its own
        // slide animations must not be mistaken for the user moving it.
        guard !magnet.isMovingPanel, !magnet.isDocked else { return }
        settings.setPosition(panel.frame.origin, for: Self.displayKey(for: screen))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel else { return }
        screenState.update(for: panel)
    }

    /// The display to place the rail on at launch: the one it was last parked
    /// on when that display is still attached, otherwise the main display.
    private func launchScreen() -> NSScreen? {
        if let key = settings.lastDisplayKey,
           let screen = NSScreen.screens.first(where: { Self.displayKey(for: $0) == key }) {
            return screen
        }
        return NSScreen.main
    }

    /// From macOS 14 Settings is a page of the main window. macOS can still
    /// reopen the standalone Settings window an earlier run left open, so
    /// close it once restoring finishes and Settings keeps one home.
    private func closeRestoredSettingsWindow() {
        guard #available(macOS 14.0, *) else { return }
        DispatchQueue.main.async { [weak self] in self?.closeSettingsSceneWindows() }
        restoredSettingsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.closeSettingsSceneWindows()
                if let observer = self.restoredSettingsObserver { NotificationCenter.default.removeObserver(observer) }
                self.restoredSettingsObserver = nil
            }
        }
    }

    private func closeSettingsSceneWindows() {
        let identifier = SettingsScenePresenter.settingsSceneIdentifier
        for window in NSApp.windows where window.identifier?.rawValue == identifier {
            window.close()
        }
    }

    func resetPanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let key = Self.displayKey(for: screen)
        magnet.undock()
        settings.resetPosition(for: key)
        positionPanel(panel, on: screen)
    }

    func showSettings() {
        launchAtLogin.refresh()
        settingsNavigation.showMainPage()
        if #available(macOS 14.0, *) {
            if let settingsPageOpener { settingsPageOpener() }
            else { presentMainWindow(destination: .settings) }
        } else {
            settingsSceneOpener()
        }
    }

    func showWhatsNew() {
        let controller: WhatsNewWindowController
        if let whatsNewWindowController {
            controller = whatsNewWindowController
        } else {
            controller = WhatsNewWindowController(updateController: updateController)
            whatsNewWindowController = controller
        }
        updateController.markWhatsNewPresented()
        controller.present()
    }

    @objc func showWhatsNewWindow(_ sender: Any?) {
        showWhatsNew()
    }

    private func installWhatsNewMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
        !appMenu.items.contains(where: { $0.action == #selector(showWhatsNewWindow(_:)) }) else {
            return
        }
        let item = NSMenuItem(
            title: AppLanguage.text("What’s New in usAIge"),
            action: #selector(showWhatsNewWindow(_:)),
            keyEquivalent: ""
        )
        item.target = self
        appMenu.insertItem(item, at: min(1, appMenu.items.count))
    }

    static var branchesAreAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// A Dock click restores the current destination; a new main window starts
    /// at Overview. Settings is an explicit page in the same window.
    func showMainWindow() {
        if let mainWindowOpener {
            mainWindowOpener()
            return
        }
        guard #available(macOS 14.0, *) else {
            showSettings()
            return
        }
        presentMainWindow()
    }

    func showBranches(front: PaperweightID? = nil) {
        guard #available(macOS 14.0, *) else { return }
        presentMainWindow(destination: front == nil ? .worktrees : .resources, front: front)
    }

    func showCleanup() {
        guard #available(macOS 14.0, *) else { return }
        presentMainWindow(destination: .cleanup)
    }

    func showResources() {
        guard #available(macOS 14.0, *) else { return }
        presentMainWindow(destination: .resources)
    }

    /// Settings can re-read workspace data without opening a main window or
    /// starting the window's visibility-driven polling.
    func refreshWorkspace() {
        guard #available(macOS 14.0, *) else { return }
        if let controller = branchesWindowController as? BranchesWindowController {
            // Reuse the operation owner even when hidden. Its store defers
            // refresh commands while an authorized cleanup is running.
            controller.refresh()
            return
        }
        guard workspaceRefreshTask == nil else { return }
        let addedFoldersKey = BranchesStore.addedFoldersKey
        let scanner = BranchesScanner(environment: .live(addedFolders: {
            UserDefaults.standard.stringArray(forKey: addedFoldersKey) ?? []
        }))
        workspaceRefreshTask = Task { [weak self] in
            defer { self?.workspaceRefreshTask = nil }
            await scanner.scan(force: true) { _ in }
            if !Task.isCancelled { _ = await scanner.toolStorage(force: true) }
            await scanner.saveAndStop()
        }
    }

    func addWorkspaceFolder() {
        guard #available(macOS 14.0, *), let path = WorkspaceFolderAccess.shared.chooseFolder() else { return }
        if let controller = branchesWindowController as? BranchesWindowController {
            controller.addSelectedFolder(path)
        } else {
            var folders = UserDefaults.standard.stringArray(forKey: BranchesStore.addedFoldersKey) ?? []
            if !folders.contains(path) {
                folders.append(path)
                UserDefaults.standard.set(folders, forKey: BranchesStore.addedFoldersKey)
            }
            refreshWorkspace()
        }
    }

    /// Refresh app-wide readings and any visible workspace without opening a
    /// window. Repeated key presses share the in-flight request.
    func refresh() {
        guard manualRefreshTask == nil else { return }
        if #available(macOS 14.0, *),
           let controller = branchesWindowController as? BranchesWindowController,
           controller.window?.isVisible == true {
            controller.refresh()
        }
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.manualRefreshTask = nil }
            async let usageRefresh: Void = self.store.refresh()
            async let agentRefresh: Void = self.agentStore.refresh()
            async let resourceRefresh: Void = self.liveWork.refresh()
            _ = await (usageRefresh, agentRefresh, resourceRefresh)
        }
    }

    @available(macOS 14.0, *)
    private func presentMainWindow(destination: MainPageDestination? = nil, front: PaperweightID? = nil) {
        workspaceRefreshTask?.cancel()
        if let existing = branchesWindowController as? BranchesWindowController {
            existing.present(destination: destination, front: front)
            return
        }
        let controller = BranchesWindowController(
            liveWork: liveWork, agentStore: agentStore, usageStore: store, settings: settings,
            settingsContent: AnyView(HUDSettingsRootView(
                settings: settings, store: store, launchAtLogin: launchAtLogin,
                updateController: updateController, relaySync: relaySync,
                localToolStatus: localToolStatus, navigation: settingsNavigation,
                refreshWorkspace: { [weak self] in self?.refreshWorkspace() },
                addWorkspaceFolder: { [weak self] in self?.addWorkspaceFolder() },
                layout: .page
            )),
            connectContent: AnyView(HUDSettingsRootView(
                settings: settings, store: store, launchAtLogin: launchAtLogin,
                updateController: updateController, relaySync: relaySync,
                localToolStatus: localToolStatus, navigation: toolsNavigation,
                layout: .page, rootDestination: .remoteToolPairing
            )),
            syncContent: AnyView(ModernDevicesPage(relaySync: relaySync)),
            localToolStatus: localToolStatus, updateController: updateController,
            openSettings: { [weak self] in self?.showSettings() }
        ) { [weak self] in
            self?.branchesWindowController = nil
        }
        branchesWindowController = controller
        controller.present(destination: destination, front: front)
    }

    func showLimits() {
        guard let panel else {
            showSettings()
            return
        }
        panel.orderFrontRegardless()
        magnet.showBriefly()
    }

    /// Modern's rail runs the full height of the display at one side.
    /// Before macOS 14 the rail is the legacy view, which always floats.
    private var usesEdgeRail: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return railStyle == .modern
    }

    private func applyRailStyle() {
        panel?.dragsHorizontallyOnly = usesEdgeRail
        magnet.isEdgeRail = usesEdgeRail
        if !usesEdgeRail { screenState.railEdge = nil }
    }

    /// The side a full-height rail goes to on `screen`: where it was last,
    /// otherwise the side its last floating position was nearer, otherwise
    /// the right, where the floating rail starts.
    private func preferredEdge(on screen: NSScreen) -> MagnetEdge {
        let key = Self.displayKey(for: screen)
        if let edge = settings.magnetEdge(for: key) { return edge }
        if let saved = settings.position(for: key) {
            return saved.x + edgeRailWidth / 2 < screen.visibleFrame.midX ? .left : .right
        }
        return .right
    }

    private var edgeRailWidth: CGFloat {
        measuredRailSize?.width ?? HUDMetrics.railWidth(for: settings.textSize) * settings.scale
    }

    private func placeEdgeRail(_ panel: NSPanel, on screen: NSScreen, edge: MagnetEdge, animated: Bool) {
        screenState.railEdge = edge
        let frame = MagnetGeometry.edgeRailFrame(
            width: edgeRailWidth,
            edge: edge,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        if panel.frame.size != frame.size { panel.setFrame(frame, display: true, animate: false) }
        magnet.dock(to: edge, y: frame.minY, on: screen, animated: animated)
    }

    /// A full-height rail always belongs at a side. A short flick toward
    /// the other side sends it there; a small wobble puts it back.
    private func snapEdgeRailAfterDrag() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let current = screenState.railEdge ?? MagnetGeometry.nearestEdge(to: panel.frame, in: screen.visibleFrame)
        let edge = MagnetGeometry.edgeAfterDrag(from: current, horizontalTranslation: panel.lastDragTranslation.width)
        placeEdgeRail(panel, on: screen, edge: edge, animated: true)
    }

    private func positionPanel(_ panel: NSPanel, on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        if usesEdgeRail {
            placeEdgeRail(panel, on: screen, edge: preferredEdge(on: screen), animated: false)
            return
        }
        let key = Self.displayKey(for: screen)
        let contentSize = measuredRailSize ?? panel.frame.size
        if let edge = settings.magnetEdge(for: key),
           let saved = settings.position(for: key) {
            if panel.frame.size != contentSize { panel.setContentSize(contentSize) }
            magnet.dock(to: edge, y: saved.y, on: screen, animated: false)
            return
        }
        let frame = PanelPositioner.frame(
            panelSize: contentSize,
            visibleFrame: screen.visibleFrame,
            savedOrigin: settings.position(for: key)
        )
        panel.setFrame(frame, display: true)
    }

    private func resizePanel(to size: CGSize) {
        measuredRailSize = size
        guard let panel,
              abs(panel.frame.width - size.width) > 0.5
                || abs(panel.frame.height - size.height) > 0.5 else { return }
        if magnet.isDocked {
            magnet.panelDidResize(to: size)
            return
        }
        if usesEdgeRail, let screen = panel.screen ?? NSScreen.main {
            let edge = screenState.railEdge ?? MagnetGeometry.nearestEdge(to: panel.frame, in: screen.visibleFrame)
            screenState.railEdge = edge
            panel.setFrame(
                MagnetGeometry.edgeRailFrame(width: size.width, edge: edge,
                                             screenFrame: screen.frame, visibleFrame: screen.visibleFrame),
                display: true, animate: false
            )
            return
        }

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
            case .whatsNew:
                self?.showWhatsNew()
            }
        }
    }

}

@MainActor
/// Bringing a tool's own app to the front counts as seeing its attention
/// states, so the rail light for that tool settles.
private final class CodexAttentionMonitor {
    private static let toolsByBundleIdentifier: [String: AIToolID] = {
        var tools: [String: AIToolID] = [:]
        for descriptor in AIToolDescriptor.all {
            for bundleIdentifier in descriptor.bundleIdentifiers { tools[bundleIdentifier] = descriptor.id }
        }
        tools["com.openai.codex"] = .chatGPT
        tools["com.openai.chat"] = .chatGPT
        return tools
    }()

    private let acknowledge: (AIToolID) -> Void
    private var activationObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    init(acknowledge: @escaping (AIToolID) -> Void) {
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
              let toolID = Self.toolsByBundleIdentifier[bundleIdentifier]
        else { return }
        acknowledge(toolID)
    }
}

@MainActor
enum SettingsScenePresenter {
    /// The identifier SwiftUI gives its standalone Settings window.
    static let settingsSceneIdentifier = "com_apple_SwiftUI_Settings_window"

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
            for _ in 0..<40 {
                if let window = settingsWindow(in: NSApp.windows) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    /// The SwiftUI Settings window, never the What's New window: both are
    /// titled, non-panel windows, and What's New stays alive after it is
    /// closed, so a loose match used to bring it back on every Settings open.
    static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        let candidates = windows.filter(isSettingsWindow)
        return candidates.first(where: looksLikeSettingsScene) ?? candidates.first
    }

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && window.identifier != WhatsNewWindowController.windowIdentifier
            && window.identifier != AppWindowIdentifiers.branches
    }

    private static func looksLikeSettingsScene(_ window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue ?? ""
        return identifier.localizedCaseInsensitiveContains("settings")
            || window.title.localizedCaseInsensitiveContains("settings")
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
