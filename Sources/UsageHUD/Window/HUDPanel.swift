import AppKit

final class HUDPanel: NSPanel {
    private static let dragThreshold: CGFloat = 3
    private var dragStartPointerLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var isDraggingContent = false

    init(contentView: NSView) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 292, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        level = .floating
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartPointerLocation = screenLocation(for: event)
            dragStartWindowOrigin = frame.origin
            isDraggingContent = false

        case .leftMouseDragged:
            guard let pointerStart = dragStartPointerLocation,
                  let windowStart = dragStartWindowOrigin else {
                break
            }

            let pointerLocation = screenLocation(for: event)
            let translation = CGSize(
                width: pointerLocation.x - pointerStart.x,
                height: pointerLocation.y - pointerStart.y
            )
            if !isDraggingContent {
                isDraggingContent = hypot(translation.width, translation.height) >= Self.dragThreshold
            }
            if isDraggingContent {
                setFrameOrigin(
                    PanelPositioner.draggedOrigin(
                        startingAt: windowStart,
                        translation: translation
                    )
                )
                return
            }

        case .leftMouseUp:
            defer {
                dragStartPointerLocation = nil
                dragStartWindowOrigin = nil
                isDraggingContent = false
            }
            if isDraggingContent {
                return
            }

        default:
            break
        }

        super.sendEvent(event)
    }

    private func screenLocation(for event: NSEvent) -> CGPoint {
        convertPoint(toScreen: event.locationInWindow)
    }
}
