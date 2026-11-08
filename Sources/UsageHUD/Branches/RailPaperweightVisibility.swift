import AppKit
import SwiftUI

/// A hosting panel can become occluded without sending SwiftUI onDisappear or
/// a pointer-exit event. Observe its real visibility before keeping a hover clock.
@available(macOS 14.0, *)
struct RailPaperweightVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> RailPaperweightVisibilityView {
        let view = RailPaperweightVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RailPaperweightVisibilityView, context: Context) {
        view.onChange = onChange
        view.refresh()
    }

    static func dismantleNSView(_ view: RailPaperweightVisibilityView, coordinator: ()) {
        view.stop()
    }
}

@available(macOS 14.0, *)
@MainActor
final class RailPaperweightVisibilityView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var pendingVisibility: Bool?
    private var deliveredVisibility: Bool?
    private var deliveryGeneration = 0
    private var stopped = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        postsFrameChangedNotifications = true
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification,
           let closing = notification.object as? NSWindow, closing === window {
            publish(false)
        } else {
            refresh()
        }
    }

    func refresh() {
        guard !stopped else { publish(false); return }
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        publish(visible && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && !NSApp.isHidden)
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        publish(false)
    }

    private func publish(_ visible: Bool) {
        guard pendingVisibility != visible else { return }
        pendingVisibility = visible
        deliveryGeneration += 1
        let generation = deliveryGeneration
        // Representable updates and AppKit layout can run inside a SwiftUI
        // update. Deliver only the newest visibility edge after that update.
        Task { @MainActor [weak self] in
            guard let self, self.deliveryGeneration == generation,
                  self.deliveredVisibility != visible else { return }
            self.deliveredVisibility = visible
            self.onChange(visible)
        }
    }
}
