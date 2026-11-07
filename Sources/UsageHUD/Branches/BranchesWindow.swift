import AppKit
import SwiftUI

enum AppWindowIdentifiers {
    /// Marks the window so the Settings opener never mistakes it for Settings.
    static let branches = NSUserInterfaceItemIdentifier("usAIge.branches")
}

/// Owns the Branches window and its store. Closing it lets both go, so an
/// unused feature costs no memory and no background work.
@available(macOS 14.0, *)
@MainActor
final class BranchesWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "BranchesWindow"
    private let store: BranchesStore
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
        window.contentView = NSHostingView(rootView: BranchesRootView(store: store, liveWork: liveWork))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
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
