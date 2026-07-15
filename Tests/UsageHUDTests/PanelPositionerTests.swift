import CoreGraphics
import Testing
@testable import UsageHUD

@Test func defaultsToBottomRightWithSixteenPointInset() {
    let visible = CGRect(x: 0, y: 25, width: 1_440, height: 875)
    let size = CGSize(width: 260, height: 220)

    let frame = PanelPositioner.frame(panelSize: size, visibleFrame: visible, savedOrigin: nil)

    #expect(frame.origin == CGPoint(x: 1_164, y: 41))
}

@Test func clampsSavedFrameCompletelyInsideVisibleScreen() {
    let visible = CGRect(x: 0, y: 25, width: 1_440, height: 875)
    let size = CGSize(width: 260, height: 220)

    let frame = PanelPositioner.frame(
        panelSize: size,
        visibleFrame: visible,
        savedOrigin: CGPoint(x: 5_000, y: -5_000)
    )

    #expect(frame.minX >= visible.minX + 16)
    #expect(frame.maxX <= visible.maxX - 16)
    #expect(frame.minY >= visible.minY + 16)
    #expect(frame.maxY <= visible.maxY - 16)
}

@Test func translatesWindowOriginWithPointerDrag() {
    let origin = PanelPositioner.draggedOrigin(
        startingAt: CGPoint(x: 100, y: 200),
        translation: CGSize(width: 24, height: 36)
    )

    #expect(origin == CGPoint(x: 124, y: 236))
}
