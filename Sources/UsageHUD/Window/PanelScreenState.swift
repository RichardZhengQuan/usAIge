import AppKit
import Combine

/// The display the floating rail currently sits on. Views size the rail from
/// this instead of `NSScreen.main`, so a panel parked on a shorter secondary
/// display never grows past that display's visible area.
@MainActor
final class PanelScreenState: ObservableObject {
    @Published private(set) var visibleHeight: CGFloat

    init(visibleHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900) {
        self.visibleHeight = visibleHeight
    }

    func update(for panel: NSWindow) {
        update(screen: panel.screen ?? NSScreen.main)
    }

    func update(screen: NSScreen?) {
        let height = screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        guard abs(height - visibleHeight) > 0.5 else { return }
        visibleHeight = height
    }
}
