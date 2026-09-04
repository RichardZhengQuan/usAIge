import AppKit

/// Magnet: drop the rail near the left or right edge of a display and it
/// docks flush there. A docked rail slides off screen when the pointer leaves
/// it and slides back when the pointer pushes against that edge, like the
/// Dock. Docking is per display and survives relaunch.
@MainActor
final class MagnetController {
    static let hideDelay: TimeInterval = 0.6
    static let animationDuration: TimeInterval = 0.2
    private static let pollInterval: TimeInterval = 0.08

    /// Called when the rail docks, undocks, or is dragged while docked, with
    /// the edge (nil when undocked), the docked frame, and the display.
    var onDockingChanged: ((MagnetEdge?, CGRect, NSScreen) -> Void)?

    private(set) var edge: MagnetEdge?
    private(set) var isRevealed = true
    /// True while this controller moves the panel, so a window delegate can
    /// tell its own animations apart from the user dragging.
    private(set) var isMovingPanel = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            undock()
        }
    }

    private weak var panel: NSPanel?
    private var pointerLocation: () -> CGPoint
    private var dockedFrame: CGRect = .zero
    private var isDragging = false
    private var hideTask: Task<Void, Never>?
    private var pollTimer: Timer?

    init(
        isEnabled: Bool,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.isEnabled = isEnabled
        self.pointerLocation = pointerLocation
    }

    func attach(to panel: NSPanel) {
        self.panel = panel
    }

    var isDocked: Bool { edge != nil }

    // MARK: Docking

    /// Docks the rail to `edge` on `screen` at vertical position `y`.
    func dock(to edge: MagnetEdge, y: CGFloat, on screen: NSScreen, animated: Bool) {
        guard let panel, isEnabled else { return }
        self.edge = edge
        dockedFrame = MagnetGeometry.dockedFrame(
            size: panel.frame.size,
            edge: edge,
            y: y,
            visibleFrame: screen.visibleFrame
        )
        isRevealed = true
        move(panel, to: dockedFrame, animated: animated)
        onDockingChanged?(edge, dockedFrame, screen)
        startPolling()
        scheduleHide()
    }

    /// Leaves the rail where it is and stops the docking behaviour.
    func undock() {
        guard edge != nil else { return }
        let wasHidden = !isRevealed
        edge = nil
        hideTask?.cancel()
        hideTask = nil
        stopPolling()
        if let panel {
            if wasHidden { move(panel, to: dockedFrame, animated: true) }
            isRevealed = true
            if let screen = panel.screen ?? NSScreen.main {
                onDockingChanged?(nil, dockedFrame, screen)
            }
        }
    }

    // MARK: Drag lifecycle from the panel

    func dragDidBegin() {
        isDragging = true
        hideTask?.cancel()
        hideTask = nil
    }

    func dragDidEnd() {
        isDragging = false
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        guard isEnabled,
              let snapEdge = MagnetGeometry.edge(toSnap: panel.frame, in: screen.visibleFrame) else {
            if edge != nil {
                edge = nil
                stopPolling()
                onDockingChanged?(nil, panel.frame, screen)
            }
            return
        }
        dock(to: snapEdge, y: panel.frame.minY, on: screen, animated: true)
    }

    /// Re-lays out a docked rail after its size or display changed, keeping
    /// it flush and keeping it hidden if it was hidden.
    func panelDidResize(to size: CGSize) {
        guard let panel, let edge, let screen = panel.screen ?? NSScreen.main else { return }
        dockedFrame = MagnetGeometry.dockedFrame(
            size: size,
            edge: edge,
            y: dockedFrame.minY,
            visibleFrame: screen.visibleFrame
        )
        let target = isRevealed
            ? dockedFrame
            : MagnetGeometry.hiddenFrame(from: dockedFrame, edge: edge, screenFrame: screen.frame)
        isMovingPanel = true
        panel.setFrame(target, display: true, animate: false)
        isMovingPanel = false
        onDockingChanged?(edge, dockedFrame, screen)
    }

    func screenParametersDidChange() {
        guard let panel else { return }
        panelDidResize(to: panel.frame.size)
    }

    // MARK: Reveal and hide

    func reveal() {
        guard let panel, edge != nil, !isRevealed else { return }
        isRevealed = true
        move(panel, to: dockedFrame, animated: true)
        scheduleHide()
    }

    func hide() {
        guard let panel, let edge, isRevealed, !isDragging,
              let screen = panel.screen ?? NSScreen.main else { return }
        guard MagnetGeometry.pointerIsClear(of: dockedFrame, pointer: pointerLocation()) else {
            scheduleHide()
            return
        }
        isRevealed = false
        move(panel, to: MagnetGeometry.hiddenFrame(from: dockedFrame, edge: edge, screenFrame: screen.frame), animated: true)
    }

    /// One step of the pointer watch; exposed for tests.
    func handlePointer(at pointer: CGPoint) {
        guard let edge, let panel, let screen = panel.screen ?? NSScreen.main else { return }
        if !isRevealed {
            if MagnetGeometry.pointerReveals(pointer: pointer, edge: edge, screenFrame: screen.frame) {
                reveal()
            }
        } else if MagnetGeometry.pointerIsClear(of: dockedFrame, pointer: pointer) {
            if hideTask == nil { scheduleHide() }
        } else {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hideDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.hide()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handlePointer(at: self.pointerLocation())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func move(_ panel: NSPanel, to frame: CGRect, animated: Bool) {
        isMovingPanel = true
        guard animated else {
            panel.setFrame(frame, display: true, animate: false)
            isMovingPanel = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in self?.isMovingPanel = false }
        })
    }
}
