import AppKit
import Metal
import SceneKit
import SwiftUI

struct PaperweightSceneCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case shake, preview, shipDrop, reset }
    let id: Int
    let kind: Kind
}

@available(macOS 14.0, *)
struct PaperweightSceneView: NSViewRepresentable {
    let configurations: [PaperweightConfiguration]
    let front: PaperweightID
    let selectedLayerID: String?
    let ships: [PaperweightID: PaperweightShipKind]
    let command: PaperweightSceneCommand?
    let onSelect: (PaperweightID, String) -> Void
    let onSwap: (PaperweightID) -> Void
    let onMovingChanged: (Bool) -> Void
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> PaperweightSceneHost { PaperweightSceneHost() }

    func updateNSView(_ view: PaperweightSceneHost, context: Context) {
        view.update(configurations: configurations, front: front, selectedLayerID: selectedLayerID,
                    ships: ships, command: command, reduceMotion: reduceMotionOverride ?? reduceMotion, isDark: colorScheme == .dark,
                    onSelect: onSelect, onSwap: onSwap, onMovingChanged: onMovingChanged)
    }

    static func dismantleNSView(_ view: PaperweightSceneHost, coordinator: ()) { view.stop() }
}

/// AppKit owns gestures and visibility. The scene has no SwiftUI frame clock.
@available(macOS 14.0, *)
@MainActor
final class PaperweightSceneHost: NSView {
    private var sceneView: SCNView?
    private var renderer: PaperweightSceneRenderer?
    private var mouseStart: NSPoint?
    private var previousMouse: NSPoint?
    private var dragged = false
    private var consumedDoubleClick = false
    private var accessibilityTargets: [PaperweightAccessibilityTarget] = []
    private var fallbackMenu: NSPopUpButton?
    private var fallbackFront = PaperweightID.storage
    private var fallbackSelect: (PaperweightID, String) -> Void = { _, _ in }
    private var fallbackSwap: (PaperweightID) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // SceneKit draws the child, but this host owns every camera gesture.
        return sceneView == nil ? hit : self
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Memory and Storage liquid paperweights")
        // Some test and remote sessions have no Metal device. Creating an
        // SCNView there can abort before the app can show a useful fallback.
        guard MTLCreateSystemDefaultDevice() != nil else {
            let label = NSTextField(wrappingLabelWithString: "3D paperweights need a graphics device.")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.target = self
            popup.action = #selector(selectFallbackLayer)
            popup.setAccessibilityLabel("Select a paperweight layer")
            fallbackMenu = popup
            let stack = NSStackView(views: [label, popup])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                         stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)])
            return
        }
        let view = SCNView(frame: bounds, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityElement(false)
        addSubview(view)
        sceneView = view
        renderer = PaperweightSceneRenderer(view: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(configurations: [PaperweightConfiguration], front: PaperweightID, selectedLayerID: String?,
                ships: [PaperweightID: PaperweightShipKind], command: PaperweightSceneCommand?,
                reduceMotion: Bool, isDark: Bool, onSelect: @escaping (PaperweightID, String) -> Void,
                onSwap: @escaping (PaperweightID) -> Void, onMovingChanged: @escaping (Bool) -> Void) {
        renderer?.update(configurations: configurations, front: front, selectedLayerID: selectedLayerID,
                         ships: ships, command: command, reduceMotion: reduceMotion, isDark: isDark,
                         onSelect: onSelect, onSwap: onSwap, onMovingChanged: onMovingChanged)
        fallbackFront = front
        fallbackSelect = onSelect
        fallbackSwap = onSwap
        fallbackMenu?.removeAllItems()
        let values = configurations.map { configuration in
            let title = configuration.id == .memory ? "Memory" : "Storage"
            let percent = configuration.capacityBytes > 0 && configuration.freeBytes != nil
                ? LiveWorkText.percent(Double(configuration.usedBytes) / Double(configuration.capacityBytes)) : "–"
            let available = configuration.freeBytes.map(BoardText.bytes) ?? "–"
            let used = configuration.capacityBytes > 0 && configuration.freeBytes != nil ? BoardText.bytes(configuration.usedBytes) : "–"
            return "\(title): \(percent) used, \(used) in use, \(available) \(configuration.id == .memory ? "other memory" : "free")"
        }
        var selectedText = "No layer selected"
        accessibilityTargets = configurations.flatMap { configuration in
            ([configuration.freeLayer] + configuration.layers).map { layer in
                let title = configuration.id == .memory ? "Memory" : "Storage"
                let amount = layer.isMeasuring ? "Measuring" : BoardText.bytes(layer.bytes)
                let selected = configuration.id == front && layer.id == selectedLayerID
                if selected { selectedText = "Selected \(title) layer: \(layer.title), \(amount)" }
                let item = NSMenuItem(title: "\(title) · \(layer.title) — \(amount)", action: nil, keyEquivalent: "")
                item.representedObject = PaperweightFallbackChoice(paperweight: configuration.id, layer: layer.id)
                fallbackMenu?.menu?.addItem(item)
                if selected { fallbackMenu?.select(item) }
                return PaperweightAccessibilityTarget(name: "Show \(layer.title), \(amount), in \(title)\(selected ? ", selected" : "")") {
                    if configuration.id != front { onSwap(configuration.id) }
                    onSelect(configuration.id, layer.id)
                }
            }
        }
        fallbackMenu?.isEnabled = !configurations.isEmpty
        setAccessibilityValue((values + [selectedText]).joined(separator: ". "))
        accessibilityTargets.append(PaperweightAccessibilityTarget(name: "Bring the other paperweight forward") {
            onSwap(front == .memory ? .storage : .memory)
        })
        accessibilityTargets.append(PaperweightAccessibilityTarget(name: "Reset the camera") { [weak self] in
            self?.renderer?.resetCamera()
        })
        setAccessibilityCustomActions(accessibilityTargets.map(\.action))
        updateVisibility()
    }

    /// Gallery rendering can composite this image over AppKit's cached display.
    func snapshot() -> NSImage? { sceneView?.snapshot() }
    func stop() {
        renderer?.setVisible(false)
        PaperweightSceneAssets.releaseCaches()
    }

    override func layout() {
        super.layout()
        renderer?.resize(bounds.size)
        updateVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installVisibilityObservers()
        updateVisibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installVisibilityObservers()
        updateVisibility()
    }

    private func installVisibilityObservers() {
        NotificationCenter.default.removeObserver(self)
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
    }

    @objc private func visibilityChanged(_ notification: Notification) { updateVisibility() }

    @objc private func selectFallbackLayer() {
        guard let choice = fallbackMenu?.selectedItem?.representedObject as? PaperweightFallbackChoice else { return }
        if choice.paperweight != fallbackFront { fallbackSwap(choice.paperweight) }
        fallbackSelect(choice.paperweight, choice.layer)
    }

    private func updateVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        renderer?.setVisible(visible && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && !NSApp.isHidden)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        consumedDoubleClick = event.clickCount > 1 && renderer?.hit(at: point) == nil
        if consumedDoubleClick { renderer?.resetCamera(); return }
        mouseStart = point
        previousMouse = point
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !consumedDoubleClick, let start = mouseStart, let previous = previousMouse else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) > 4 { dragged = true }
        if dragged { renderer?.dragCamera(dx: point.x - previous.x, dy: point.y - previous.y) }
        previousMouse = point
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseStart = nil; previousMouse = nil; consumedDoubleClick = false }
        guard !consumedDoubleClick else { return }
        if dragged { renderer?.endDragging() }
        else { renderer?.click(at: convert(event.locationInWindow, from: nil)) }
    }

    override func scrollWheel(with event: NSEvent) { renderer?.zoom(by: Double(event.scrollingDeltaY) * 0.012) }
    override func magnify(with event: NSEvent) { renderer?.zoom(by: -Double(event.magnification)) }
}

@available(macOS 14.0, *)
@MainActor
private final class PaperweightAccessibilityTarget: NSObject {
    let name: String
    let perform: () -> Void
    init(name: String, perform: @escaping () -> Void) { self.name = name; self.perform = perform }
    var action: NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name, target: self, selector: #selector(invoke))
    }
    @objc private func invoke() -> Bool { perform(); return true }
}

private final class PaperweightFallbackChoice: NSObject {
    let paperweight: PaperweightID
    let layer: String
    init(paperweight: PaperweightID, layer: String) { self.paperweight = paperweight; self.layer = layer }
}
