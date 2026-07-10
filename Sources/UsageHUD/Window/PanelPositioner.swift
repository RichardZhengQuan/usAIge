import CoreGraphics

enum PanelPositioner {
    static let inset: CGFloat = 16

    static func frame(
        panelSize: CGSize,
        visibleFrame: CGRect,
        savedOrigin: CGPoint?
    ) -> CGRect {
        let defaultOrigin = CGPoint(
            x: visibleFrame.maxX - panelSize.width - inset,
            y: visibleFrame.minY + inset
        )
        let requested = savedOrigin ?? defaultOrigin
        let minX = visibleFrame.minX + inset
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - inset)
        let minY = visibleFrame.minY + inset
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - inset)
        return CGRect(
            origin: CGPoint(
                x: min(maxX, max(minX, requested.x)),
                y: min(maxY, max(minY, requested.y))
            ),
            size: panelSize
        )
    }
}
