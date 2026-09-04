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
