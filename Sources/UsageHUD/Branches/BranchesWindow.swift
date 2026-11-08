import AppKit
import Combine
import SwiftUI

enum AppWindowIdentifiers {
    /// Marks the window so the Settings opener never mistakes it for Settings.
    static let branches = NSUserInterfaceItemIdentifier("usAIge.branches")
}

/// Rail clicks can bring a paperweight forward without replacing the window
/// or losing a search, review, or expanded row in it.
@available(macOS 14.0, *)
@MainActor
final class BranchesPaperweightPresentation: ObservableObject {
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

    @Published private(set) var request: Request?

    func show(_ front: PaperweightID) { request = Request(front: front) }
}

/// Owns the Branches window and its store. Closing it lets both go, so an
/// unused feature costs no memory and no background work.
@available(macOS 14.0, *)
@MainActor
final class BranchesWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "BranchesWindow"
    private let store: BranchesStore
    private let presentation = BranchesPaperweightPresentation()
    private let onClose: () -> Void

    /// `liveWork` is the rail's monitor, so the window's memory figure is the
    /// rail's, not a second reading of its own.
    init(store: BranchesStore = BranchesStore(), liveWork: LiveWorkMonitor? = nil, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Branches"
        window.identifier = AppWindowIdentifiers.branches
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: BranchesRootView(store: store, liveWork: liveWork, presentation: presentation))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(front: PaperweightID? = nil) {
        guard let window else { return }
        if let front { presentation.show(front) }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible, !window.setFrameUsingName(Self.frameName) { window.center() }
        window.makeKeyAndOrderFront(nil)
        store.windowOpened()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.windowBecameKey()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        store.setVisible(window.occlusionState.contains(.visible))
    }

    func windowWillClose(_ notification: Notification) {
        store.windowClosed()
        // SwiftUI holds the store until its hosting view goes.
        window?.contentView = nil
        onClose()
    }
}
