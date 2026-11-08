import AppKit
import Combine
import SwiftUI

enum AppWindowIdentifiers {
    /// Marks the main window so the Settings opener never mistakes it for Settings.
    static let branches = NSUserInterfaceItemIdentifier("usAIge.branches")
}

enum MainPageDestination: String, CaseIterable, Identifiable {
    case overview, worktrees, cleanup, resources, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .worktrees: "Branches"
        case .cleanup: "Cleanup"
        case .resources: "Overview"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .worktrees: "point.3.connected.trianglepath.dotted"
        case .cleanup: "sparkles"
        case .resources: "chart.pie"
        case .settings: "gearshape"
        }
    }
}

enum OverviewSection: String, Hashable {
    case overview, resources, branches, settings
}

/// Main-window navigation is independent of the resource ocean's selected layer.
@available(macOS 14.0, *)
@MainActor
final class BranchesPaperweightPresentation: ObservableObject {
    struct FocusRequest: Identifiable {
        let id = UUID()
        let section: OverviewSection
    }

    struct Request: Equatable {
        let id = UUID()
        let front: PaperweightID

        func selectedLayer(in configuration: PaperweightConfiguration,
                           currentFront: PaperweightID, currentLayer: String) -> String {
            if front == currentFront { return currentLayer }
            if front == .storage, configuration.layers.contains(where: { $0.id == "wt" }) { return "wt" }
            return configuration.layers.first?.id ?? configuration.freeLayer.id
        }
    }

    @Published var destination: MainPageDestination = .overview
    @Published private(set) var request: Request?
    @Published private(set) var focusRequest: FocusRequest?
    @Published private(set) var selectedSection: OverviewSection = .overview
    @Published var showsCleanupProgress = false
    var isReviewingCleanup = false
    let worktreePage = BranchesPageState()
    let resourcePage = BranchesPageState()

    func navigate(to destination: MainPageDestination) {
        self.destination = .overview
        switch destination {
        case .overview: focus(.overview)
        case .worktrees: focus(.branches)
        case .cleanup:
            show(.storage)
        case .resources: focus(.resources)
        case .settings: focus(.settings)
        }
    }

    func focus(_ section: OverviewSection) {
        selectedSection = section
        focusRequest = FocusRequest(section: section)
    }

    func show(_ front: PaperweightID) {
        request = Request(front: front)
        destination = .overview
        focus(.resources)
    }
}

/// Detaches its views and stops scanning when closed. An authorized cleanup
/// keeps its state until the window is reopened, so its result remains reachable.
@available(macOS 14.0, *)
@MainActor
final class BranchesWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "BranchesWindow"
    private let store: BranchesStore
    let presentation = BranchesPaperweightPresentation()
    private let liveWork: LiveWorkMonitor?
    private let agentStore: CodexAgentStore?
    private let usageStore: UsageStore?
    private let settings: HUDSettings?
    private let openSettings: () -> Void
    private let settingsContent: AnyView?
    private let updateController: UpdateController?
    private let onClose: () -> Void

    /// `liveWork` is the rail's monitor, so both surfaces share one reading.
    init(store: BranchesStore = BranchesStore(), liveWork: LiveWorkMonitor? = nil,
         agentStore: CodexAgentStore? = nil, usageStore: UsageStore? = nil, settings: HUDSettings? = nil,
         settingsContent: AnyView? = nil, updateController: UpdateController? = nil,
         openSettings: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.store = store
        self.liveWork = liveWork
        self.agentStore = agentStore
        self.usageStore = usageStore
        self.settings = settings
        self.openSettings = openSettings
        self.settingsContent = settingsContent
        self.updateController = updateController
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "usAIge"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.identifier = AppWindowIdentifiers.branches
        window.minSize = NSSize(width: 1000, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
        window.delegate = self
        window.contentView = nil
        attachContentIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(destination: MainPageDestination? = nil, front: PaperweightID? = nil) {
        guard let window else { return }
        if let destination { presentation.navigate(to: destination) }
        if destination == .cleanup, store.cleanupProgress != nil || store.resultMessage != nil {
            presentation.showsCleanupProgress = true
        }
        if let front { presentation.show(front) }
        attachContentIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible, !window.setFrameUsingName(Self.frameName) { window.center() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        store.windowOpened()
    }

    func refresh() {
        store.refresh()
        store.loadToolStorage(force: true)
        store.readDiskSpace()
    }

    func addFolder(_ path: String) {
        store.addFolder(path)
    }

    private func attachContentIfNeeded() {
        guard let window, window.contentView == nil else { return }
        window.contentView = NSHostingView(rootView: MainRootView(
            store: store, liveWork: liveWork, agentStore: agentStore, usageStore: usageStore, settings: settings,
            presentation: presentation, settingsContent: settingsContent,
            updateController: updateController, openSettings: openSettings
        ))
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.windowBecameKey()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        store.setVisible(window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        let cleanupNeedsReopening = store.isDeleting || store.resultMessage != nil
        store.windowClosed()
        presentation.isReviewingCleanup = false
        presentation.showsCleanupProgress = false
        window?.contentView = nil
        // The app retains this controller through the operation and its result.
        // Reopening rebuilds only the views, using the same operation state.
        if !cleanupNeedsReopening { onClose() }
    }
}
