import AppKit
import Combine

/// The display the floating rail currently sits on. Views size the rail from
/// this instead of `NSScreen.main`, so a panel parked on a shorter secondary
/// display never grows past that display's visible area.
@MainActor
final class PanelScreenState: ObservableObject {
    @Published private(set) var visibleHeight: CGFloat
    /// The whole display's height, which a full-height rail fills.
    @Published private(set) var screenHeight: CGFloat
    /// How far the menu bar and a bottom Dock reach into the display, so a
    /// full-height rail keeps its content clear of them inside its glass.
    @Published private(set) var safeTop: CGFloat
    @Published private(set) var safeBottom: CGFloat
    /// The display side a full-height rail sits on, so the rail can draw its
    /// edge line on the side facing the windows. Nil for a floating rail.
    @Published var railEdge: MagnetEdge?

    init(visibleHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900,
         screenHeight: CGFloat? = nil, safeTop: CGFloat? = nil, safeBottom: CGFloat? = nil) {
        let screen = NSScreen.main
        self.visibleHeight = visibleHeight
        self.screenHeight = screenHeight ?? screen?.frame.height ?? visibleHeight
        self.safeTop = safeTop ?? screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        self.safeBottom = safeBottom ?? screen.map { $0.visibleFrame.minY - $0.frame.minY } ?? 0
    }

    func update(for panel: NSWindow) {
        update(screen: panel.screen ?? NSScreen.main)
    }

    func update(screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let values = (
            visible: screen.visibleFrame.height,
            full: screen.frame.height,
            top: max(0, screen.frame.maxY - screen.visibleFrame.maxY),
            bottom: max(0, screen.visibleFrame.minY - screen.frame.minY)
        )
        if abs(values.visible - visibleHeight) > 0.5 { visibleHeight = values.visible }
        if abs(values.full - screenHeight) > 0.5 { screenHeight = values.full }
        if abs(values.top - safeTop) > 0.5 { safeTop = values.top }
        if abs(values.bottom - safeBottom) > 0.5 { safeBottom = values.bottom }
    }
}
