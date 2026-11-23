import AppKit

/// The status button keeps its native click and accessibility behavior while
/// the tracking area can reveal the rail without taking focus from another app.
@MainActor
final class MenuBarIconController: NSResponder {
    struct Item {
        let button: NSButton
        let remove: @MainActor () -> Void
    }
    private var item: Item?
    private var trackingArea: NSTrackingArea?
    private(set) var containsPointer = false
    private let hoverChanged: (Bool) -> Void
    private let openWindow: () -> Void
    private let makeItem: @MainActor () -> Item?

    init(hoverChanged: @escaping (Bool) -> Void, openWindow: @escaping () -> Void,
         makeItem: @escaping @MainActor () -> Item? = MenuBarIconController.systemItem) {
        self.hoverChanged = hoverChanged
        self.openWindow = openWindow
        self.makeItem = makeItem
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func systemItem() -> Item? {
        let bar = NSStatusBar.system
        let statusItem = bar.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            bar.removeStatusItem(statusItem)
            return nil
        }
        return Item(button: button, remove: { bar.removeStatusItem(statusItem) })
    }

    func setVisible(_ visible: Bool) {
        guard visible != (item != nil) else { return }
        if !visible {
            if let trackingArea { item?.button.removeTrackingArea(trackingArea) }
            trackingArea = nil
            item?.button.target = nil
            item?.button.action = nil
            item?.remove()
            item = nil
            setHover(false)
            return
        }

        guard let item = makeItem() else { return }
        self.item = item
        let button = item.button
        button.image = Self.gaugeImage
        button.imagePosition = .imageOnly
        button.toolTip = "Hover to show usage. Click to open usAIge."
        button.setAccessibilityLabel("usAIge")
        button.setAccessibilityHelp(button.toolTip)
        button.target = self
        button.action = #selector(openMainWindow)
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        trackingArea = area
        button.addTrackingArea(area)
    }

    @objc private func openMainWindow() { openWindow() }

    override func mouseEntered(with event: NSEvent) {
        if item != nil { setHover(true) }
    }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ inside: Bool) {
        guard inside != containsPointer else { return }
        containsPointer = inside
        hoverChanged(inside)
    }

    /// A monochrome rendering of the app icon's usage arc, needle and limit.
    private static let gaugeImage: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.lineCapStyle = .round
            arc.lineWidth = 3.1
            arc.move(to: NSPoint(x: 2.3, y: 11.2))
            arc.curve(to: NSPoint(x: 13, y: 4.8),
                      controlPoint1: NSPoint(x: 3, y: 5.8), controlPoint2: NSPoint(x: 7.8, y: 2.8))
            arc.stroke()

            let limit = NSBezierPath()
            limit.lineCapStyle = .round
            limit.lineWidth = 2.8
            limit.move(to: NSPoint(x: 17.2, y: 9.7))
            limit.curve(to: NSPoint(x: 17.2, y: 14.7),
                        controlPoint1: NSPoint(x: 17.8, y: 11.3), controlPoint2: NSPoint(x: 17.8, y: 13.1))
            limit.stroke()

            NSColor.black.setFill()
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: 12.4, y: 8.3))
            needle.line(to: NSPoint(x: 11.7, y: 13.1))
            needle.curve(to: NSPoint(x: 9.1, y: 12),
                         controlPoint1: NSPoint(x: 11.3, y: 15), controlPoint2: NSPoint(x: 8.1, y: 13.9))
            needle.close()
            needle.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
