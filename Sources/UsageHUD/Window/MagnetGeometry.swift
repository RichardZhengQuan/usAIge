import CoreGraphics

/// A screen edge the rail can dock to.
enum MagnetEdge: String, Codable, Equatable, Sendable {
    case left
    case right
}

/// Pure geometry for Magnet: deciding when a drop docks the rail, where a
/// docked rail sits, where it goes when it slides away, and when the pointer
/// should bring it back. All coordinates are AppKit screen coordinates.
enum MagnetGeometry {
    /// A drop this close to a visible-frame edge docks the rail there.
    static let snapDistance: CGFloat = 32
    /// How much of a hidden rail stays on screen so it never fully disappears.
    static let hiddenPeek: CGFloat = 2
    /// How close to the physical screen edge the pointer must be to reveal.
    static let revealDistance: CGFloat = 1
    /// The pointer must be this far outside a revealed rail before it hides.
    static let hideMargin: CGFloat = 24

    /// The side of the display the rail's middle is on: where a full-height
    /// rail goes when it is dropped anywhere.
    static func nearestEdge(to frame: CGRect, in visibleFrame: CGRect) -> MagnetEdge {
        frame.midX < visibleFrame.midX ? .left : .right
    }

    /// A full-height rail flush against `edge`: it runs the display's whole
    /// height, behind the menu bar and a bottom Dock, and keeps its content
    /// clear of them inside. A Dock on that side still pushes it inward.
    static func edgeRailFrame(width: CGFloat, edge: MagnetEdge, screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: edge == .left ? visibleFrame.minX : visibleFrame.maxX - width,
            y: screenFrame.minY,
            width: width,
            height: screenFrame.height
        )
    }

    /// Which side a full-height rail goes to after a drag: a short flick
    /// toward the other side is enough, and a small wobble keeps it put.
    static let flickDistance: CGFloat = 24

    static func edgeAfterDrag(from edge: MagnetEdge, horizontalTranslation dx: CGFloat) -> MagnetEdge {
        if dx >= flickDistance { return .right }
        if dx <= -flickDistance { return .left }
        return edge
    }

    static func edge(toSnap frame: CGRect, in visibleFrame: CGRect) -> MagnetEdge? {
        let leftGap = frame.minX - visibleFrame.minX
        let rightGap = visibleFrame.maxX - frame.maxX
        if leftGap <= snapDistance, leftGap <= rightGap { return .left }
        if rightGap <= snapDistance { return .right }
        return nil
    }

    /// The rail flush against `edge`, keeping `y` where the user dropped it
    /// but never leaving the visible frame.
    static func dockedFrame(
        size: CGSize,
        edge: MagnetEdge,
        y: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let x = edge == .left ? visibleFrame.minX : visibleFrame.maxX - size.width
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let clampedY = min(maxY, max(visibleFrame.minY, y))
        return CGRect(origin: CGPoint(x: x, y: clampedY), size: size)
    }

    /// The docked rail slid past the physical screen edge, leaving `hiddenPeek`
    /// points visible.
    static func hiddenFrame(
        from dockedFrame: CGRect,
        edge: MagnetEdge,
        screenFrame: CGRect
    ) -> CGRect {
        var frame = dockedFrame
        switch edge {
        case .left: frame.origin.x = screenFrame.minX - dockedFrame.width + hiddenPeek
        case .right: frame.origin.x = screenFrame.maxX - hiddenPeek
        }
        return frame
    }

    /// Whether a pointer at `pointer` is pushing against the docked edge, the
    /// way the Dock is summoned.
    static func pointerReveals(
        pointer: CGPoint,
        edge: MagnetEdge,
        screenFrame: CGRect
    ) -> Bool {
        guard pointer.y >= screenFrame.minY, pointer.y <= screenFrame.maxY else { return false }
        switch edge {
        case .left: return pointer.x <= screenFrame.minX + revealDistance
        case .right: return pointer.x >= screenFrame.maxX - revealDistance
        }
    }

    /// Whether the pointer has moved far enough from a revealed rail to hide it.
    static func pointerIsClear(of frame: CGRect, pointer: CGPoint) -> Bool {
        !frame.insetBy(dx: -hideMargin, dy: -hideMargin).contains(pointer)
    }
}
