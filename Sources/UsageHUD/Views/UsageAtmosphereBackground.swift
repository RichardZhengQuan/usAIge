import AppKit
import MetalKit
import SwiftUI

private struct UsageSceneFrozenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usageSceneFrozen: Bool {
        get { self[UsageSceneFrozenKey.self] }
        set { self[UsageSceneFrozenKey.self] = newValue }
    }
}

/// A sailing scene shared by the resource window and rail.
/// Its small drawing clock belongs to the native view, so a covered or closed
/// window does not keep SwiftUI, SceneKit, or an animation task awake.
@available(macOS 14.0, *)
struct UsageAtmosphereBackground: NSViewRepresentable {
    var isActive = true
    var compact = false
    var weather: CruiseWeather = .sunny
    var ship: PaperweightShipKind = .galleon
    var showsShip = true
    var command: PaperweightSceneCommand? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.usageSceneFrozen) private var frozen

    func makeNSView(context: Context) -> UsageAtmosphereView {
        let view = UsageAtmosphereView()
        configure(view)
        return view
    }

    func updateNSView(_ view: UsageAtmosphereView, context: Context) { configure(view) }

    static func dismantleNSView(_ view: UsageAtmosphereView, coordinator: ()) { view.stop() }

    private func configure(_ view: UsageAtmosphereView) {
        view.configure(active: isActive, compact: compact, weather: weather, ship: ship,
                       showsShip: showsShip, dark: colorScheme == .dark,
                       reduced: reduceMotion || frozen, capturesWeather: frozen, command: command)
    }
}

@available(macOS 14.0, *)
@MainActor
final class UsageAtmosphereView: NSView {
    private var active = false
    private var compact = false
    private var dark = false
    private var reduced = false
    private var capturesWeather = false
    private var weatherPreference = CruiseWeather.sunny
    private(set) var weatherTransition = CruiseWeatherTransition(from: .sunny, to: .sunny, progress: 0)
    private(set) var seaProfile = CruiseWeather.sunny.seaProfile
    private(set) var weatherMix = CruiseWeatherMix(transition: .init(from: .sunny, to: .sunny, progress: 0))
    private var weather: CruiseWeather { weatherTransition.current }
    var weatherCycle = CruiseWeatherCycle.shared
    var weatherNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var hasWeatherSample = false
    private var lastWeatherSampleTime: TimeInterval?
    private var weatherRecovery: (from: CruiseWeatherMix, start: TimeInterval)?
    private var resourceNeedsWeatherBlend = false
    private var ship = PaperweightShipKind.galleon
    private var showsShip = true
    private var shipSnapshot: CGImage?
    private var snapshotKey: String?
    private let sea = SailingSeaSimulation()
    private var phase: TimeInterval { sea.time }
    private var lastCommandID: Int?
    private var lastWindowOrigin: CGPoint?
    private var lastTick = 0.0
    private var timer: Timer?
    private lazy var tickTarget = AtmosphereTickTarget(owner: self)
    private var weatherRenderer: CruiseWeatherRenderer?
    private var weatherView: MTKView?
    private var shipOverlay: AtmosphereShipOverlay?
    private(set) var resourceConfiguration: PaperweightConfiguration?
    private var selectedResourceLayerID = ""
    private var resourceSelection: ((String) -> Void)?
    private var resourceAccessibilityTargets: [ResourceOceanAccessibilityTarget] = []
    private var resourceLabelTexts: [String: NSAttributedString] = [:]
    private var resourceLabelSizes: [String: CGSize] = [:]
    private var pointerDown: CGPoint?
    private var draggedOcean = false

    var animationTime: TimeInterval { sea.time }
    var isAnimating: Bool { timer != nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        if let renderer = CruiseWeatherRenderer() {
            let metal = MTKView(frame: bounds)
            renderer.attach(to: metal)
            metal.autoresizingMask = [.width, .height]
            let overlay = AtmosphereShipOverlay(frame: bounds)
            overlay.owner = self
            overlay.autoresizingMask = [.width, .height]
            addSubview(metal)
            addSubview(overlay)
            weatherRenderer = renderer
            weatherView = metal
            shipOverlay = overlay
        }
    }

    required init?(coder: NSCoder) { nil }

    func configureOcean(configuration: PaperweightConfiguration, selectedLayerID: String,
                        onSelect: @escaping (String) -> Void) {
        let changed = resourceConfiguration != configuration || selectedResourceLayerID != selectedLayerID
        resourceConfiguration = configuration
        selectedResourceLayerID = selectedLayerID
        resourceSelection = onSelect
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let title = configuration.id == .memory ? "Memory" : "Storage"
        setAccessibilityLabel("\(title) ocean")
        setAccessibilityHelp("Select an ocean layer to explore it. Drag the water to make waves.")
        let layers = configuration.layers + [configuration.freeLayer]
        let selected = layers.first { $0.id == selectedLayerID }
        setAccessibilityValue(selected.map { "Selected \($0.title), \($0.isMeasuring ? "Measuring" : BoardText.bytes($0.bytes))" })
        resourceAccessibilityTargets = layers.map { layer in
            ResourceOceanAccessibilityTarget(name: "Show \(layer.title), \(layer.isMeasuring ? "Measuring" : BoardText.bytes(layer.bytes))") {
                onSelect(layer.id)
            }
        }
        setAccessibilityCustomActions(resourceAccessibilityTargets.map(\.action))
        if changed {
            prepareResourceLabels(configuration)
            invalidateFrame()
        }
    }

    func configure(active: Bool, compact: Bool, weather: CruiseWeather, ship: PaperweightShipKind, showsShip: Bool,
                   dark: Bool, reduced: Bool, capturesWeather: Bool = false,
                   command: PaperweightSceneCommand? = nil) {
        let changed = self.active != active || self.compact != compact || self.dark != dark || self.reduced != reduced
            || self.weatherPreference != weather || self.ship != ship || self.showsShip != showsShip
            || self.capturesWeather != capturesWeather
        let cadenceChanged = self.compact != compact
        let commandChanged = command.map { $0.id != lastCommandID } ?? false
        self.active = active
        self.compact = compact
        self.dark = dark
        self.reduced = reduced
        self.capturesWeather = capturesWeather
        weatherView?.isHidden = capturesWeather
        if resourceConfiguration != nil, hasWeatherSample {
            let preferenceChanged = weatherPreference != weather
            weatherPreference = weather
            if !active || reduced || capturesWeather {
                // A status update may arrive while animation is stopped. Hold
                // the exact displayed mixture and ease into the latest status
                // only after the scene resumes its existing native clock.
                if preferenceChanged || weatherRecovery != nil { resourceNeedsWeatherBlend = true }
                weatherRecovery = nil
            } else if preferenceChanged || resourceNeedsWeatherBlend {
                resourceNeedsWeatherBlend = false
                weatherRecovery = (weatherMix, weatherNow())
                sampleWeather()
            }
        } else if !hasWeatherSample || weatherPreference != weather {
            weatherPreference = weather
            weatherRecovery = nil
            lastWeatherSampleTime = nil
            sampleWeather()
        }
        self.ship = ship
        self.showsShip = showsShip
        sea.configure(size: bounds.size, compact: compact, weather: self.weather, profile: seaProfile)
        if reduced || capturesWeather { sea.settle() }
        if let command, command.id != lastCommandID {
            lastCommandID = command.id
            if active && !reduced && !capturesWeather {
                switch command.kind {
                case .shake: sea.shake()
                case .shipDrop: sea.shake(amplitude: 0.45)
                case .preview: sea.shake(amplitude: 0.3)
                case .reset: sea.settle()
                }
            }
        }
        updateShipSnapshot()
        if cadenceChanged { stopClock() }
        if changed || commandChanged { invalidateFrame() }
        updateVisibility()
    }

    private func updateShipSnapshot() {
        guard showsShip else {
            snapshotKey = nil
            shipSnapshot = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // A strip is created only after the native clock has started in a
        // visible window. Hidden, paused and frozen scenes use the rest pose.
        let frame = isAnimating && active && !reduced && !capturesWeather && isSceneVisible
            ? RailPaperweightShipTiming.frameIndex(at: phase) : nil
        let key = "\(ship.rawValue)-\(compact)-\(scale)-\(frame.map { String($0) } ?? "rest")"
        guard key != snapshotKey else { return }
        snapshotKey = key
        let size = compact ? CGSize(width: 72, height: 48) : CGSize(width: 360, height: 240)
        let animationTime = frame.map { Double($0) * RailPaperweightShipTiming.frameDuration }
        let image = PaperweightShipImageCache.shared.image(for: ship, size: size, scale: scale,
                                                          animationTime: animationTime)
        var rect = CGRect(origin: .zero, size: size)
        shipSnapshot = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastWindowOrigin = window?.frame.origin
        updateShipSnapshot()
        NotificationCenter.default.removeObserver(self)
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMoveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
        updateVisibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateVisibility()
    }

    override func layout() {
        super.layout()
        sea.configure(size: bounds.size, compact: compact, weather: self.weather, profile: seaProfile)
        if reduced || capturesWeather { sea.settle() }
        let limit: CGFloat = compact ? 240 : 960
        let scale = min(1, limit / max(1, max(bounds.width, bounds.height)))
        weatherView?.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        invalidateFrame()
        updateVisibility()
    }

    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    /// The rail background passes through clicks; a resource ocean owns its
    /// water so the exact drawn wave boundaries also define layer selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return resourceConfiguration != nil && bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pointerDown = convert(event.locationInWindow, from: nil)
        draggedOcean = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pointerDown else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !draggedOcean, hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        draggedOcean = true
        shakeResourceOcean()
    }

    override func mouseUp(with event: NSEvent) {
        defer { pointerDown = nil; draggedOcean = false }
        guard pointerDown != nil, !draggedOcean else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let layer = resourceLayer(at: point) { resourceSelection?(layer.id) }
        else { shakeResourceOcean() }
    }

    func resourceLayer(at point: CGPoint) -> PaperweightLayer? {
        guard let configuration = resourceConfiguration else { return nil }
        // Thin strata may put their readable text over a neighboring depth.
        // A visible name still selects the category it names.
        if let label = resourceLabelPlacements.first(where: { $0.frame.contains(point) }) {
            return (configuration.layers + [configuration.freeLayer]).first { $0.id == label.layerID }
        }
        return ResourceOceanLayout(configuration: configuration).layer(at: point, size: bounds.size,
                                                                       surface: sea.surface(at: point.x))
    }

    private func shakeResourceOcean() {
        guard active, !reduced, !capturesWeather else { return }
        sea.shake()
        invalidateFrame()
    }

    func stop() {
        active = false
        stopClock()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.didMoveNotification, notification.object as? NSWindow === window,
           let origin = window?.frame.origin {
            if let previous = lastWindowOrigin, active, !reduced, !capturesWeather, showsShip {
                let distance = hypot(origin.x - previous.x, origin.y - previous.y)
                if distance > 2 {
                    sea.shake(amplitude: min(1, distance / 120))
                    invalidateFrame()
                }
            }
            lastWindowOrigin = origin
        }
        if notification.name == NSWindow.willCloseNotification, notification.object as? NSWindow === window {
            stopClock()
            return
        }
        updateVisibility()
    }

    private var isSceneVisible: Bool {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        return visible && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    private func updateVisibility() {
        guard active, !reduced, !capturesWeather, isSceneVisible else {
            stopClock()
            return
        }
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: compact ? 1.0 / 12 : 1.0 / 24,
                          target: tickTarget, selector: #selector(AtmosphereTickTarget.tick(_:)),
                          userInfo: nil, repeats: true)
        timer.tolerance = compact ? 0.025 : 0.012
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopClock() {
        let wasAnimating = isAnimating
        timer?.invalidate()
        timer = nil
        if wasAnimating {
            updateShipSnapshot()
            needsDisplay = true
            shipOverlay?.needsDisplay = true
        }
    }

    fileprivate func tick() {
        updateVisibility()
        guard timer != nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let interval = min(0.25, max(0, time - lastTick))
        lastTick = time
        advanceAnimation(by: interval)
    }

    /// Advances the same frame for the native clock and deterministic exports.
    /// Visibility gates the clock above; explicit exports can run offscreen.
    func advanceAnimation(by interval: TimeInterval) {
        guard active, !reduced, !capturesWeather, interval.isFinite, interval > 0 else { return }
        sampleWeather()
        sea.configure(size: bounds.size, compact: compact, weather: weather, profile: seaProfile)
        sea.step(dt: interval)
        invalidateFrame()
    }

    private func sampleWeather() {
        let now = weatherNow()
        let target = weatherPreference == .automatic
            ? weatherCycle.sample(at: now)
            : CruiseWeatherTransition(from: weatherPreference, to: weatherPreference, progress: 0)
        if hasWeatherSample, weatherPreference == .automatic || (resourceConfiguration != nil && weatherRecovery != nil),
           let previousTime = lastWeatherSampleTime, now.isFinite, now - previousTime > 1,
           (target != weatherTransition || weatherRecovery != nil) {
            // A paused/hidden scene holds its own look. Rejoin the shared
            // cycle gradually when its visible clock resumes.
            weatherRecovery = (weatherMix, now)
        }
        if let recovery = weatherRecovery {
            let linear = min(1, max(0, (now - recovery.start) / CruiseWeatherCycle.transitionDuration))
            let blend = linear * linear * (3 - 2 * linear)
            weatherMix = recovery.from.interpolated(to: CruiseWeatherMix(transition: target), progress: blend)
            if linear >= 1 { weatherRecovery = nil }
        } else {
            weatherMix = CruiseWeatherMix(transition: target)
        }
        weatherTransition = target
        seaProfile = weatherMix.seaProfile
        hasWeatherSample = true
        lastWeatherSampleTime = now.isFinite ? now : lastWeatherSampleTime
    }

    private func invalidateFrame() {
        // This key changes only at sprite-frame edges; weather and buoyancy
        // can advance more frequently without rendering another ship model.
        updateShipSnapshot()
        needsDisplay = true
        shipOverlay?.needsDisplay = true
        guard !capturesWeather, let weatherRenderer, let weatherView else { return }
        weatherRenderer.configure(time: phase, weather: weather, dark: dark, compact: compact,
                                  lightningEnabled: active && !reduced && !capturesWeather,
                                  transition: weatherTransition, seaProfile: seaProfile, oceanTime: sea.oceanTime, mix: weatherMix,
                                  resourceOcean: resourceOceanRenderData)
        weatherView.draw()
    }

    fileprivate func drawShipOverlay(_ context: CGContext) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The same text pass serves live Metal, CPU fallback and snapshots.
        // It sits after the hull/wake and outside their above-water clip.
        defer { drawResourceLabels(context) }
        guard showsShip else { return }
        let width = bounds.width
        // Keep the keel under the shared buoyancy surface without painting
        // the CPU fallback ocean over the GPU weather. In flipped coordinates
        // this polygon includes only the space above the sampled surface.
        let aboveWater = CGMutablePath()
        aboveWater.move(to: .zero)
        aboveWater.addLine(to: CGPoint(x: width, y: 0))
        let samples = compact ? 48 : 144
        for index in stride(from: samples, through: 0, by: -1) {
            let x = Double(index) / Double(samples) * Double(width)
            aboveWater.addLine(to: CGPoint(x: x, y: sea.surface(at: x)))
        }
        aboveWater.closeSubpath()
        context.saveGState()
        context.addPath(aboveWater)
        context.clip()
        drawCruisingShip(context, time: phase, width: width, height: bounds.height)
        context.restoreGState()
        drawWake(context, time: phase)
    }

    private func prepareResourceLabels(_ configuration: PaperweightConfiguration) {
        resourceLabelTexts.removeAll(keepingCapacity: true)
        resourceLabelSizes.removeAll(keepingCapacity: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        for band in ResourceOceanLayout(configuration: configuration).bands {
            let layer = band.layer
            let selected = layer.id == selectedResourceLayerID
            let amount = layer.isMeasuring ? "Measuring…" : BoardText.bytes(layer.bytes)
            let text = NSAttributedString(string: "\(layer.title) · \(amount)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(selected ? 1 : 0.92),
                .paragraphStyle: paragraph,
                .shadow: shadow
            ])
            resourceLabelTexts[layer.id] = text
            resourceLabelSizes[layer.id] = text.size()
        }
    }

    var resourceLabelPlacements: [ResourceOceanLabelLayout.Placement] {
        guard let configuration = resourceConfiguration else { return [] }
        return ResourceOceanLabelLayout(ocean: ResourceOceanLayout(configuration: configuration),
                                        size: bounds.size, textSizes: resourceLabelSizes,
                                        selectedLayerID: selectedResourceLayerID,
                                        surface: { sea.surface(at: $0) }).placements
    }

    private func drawResourceLabels(_ context: CGContext) {
        guard resourceConfiguration != nil else { return }
        context.saveGState()
        context.clip(to: bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for placement in resourceLabelPlacements {
            resourceLabelTexts[placement.layerID]?.draw(in: placement.frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private var resourceOceanRenderData: ResourceOceanRenderData? {
        resourceConfiguration.map {
            ResourceOceanRenderData(configuration: $0, size: bounds.size, surface: { sea.surface(at: $0) })
        }
    }

    /// AppKit cached display omits Metal layers. The gallery composites this
    /// explicit readback only while exporting; live frames stay on the GPU.
    func snapshot() -> CGImage? {
        guard let weatherRenderer, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = min(2_048, max(1, Int(bounds.width * scale)))
        let height = min(2_048, max(1, Int(bounds.height * scale)))
        guard let background = weatherRenderer.snapshot(size: CGSize(width: width, height: height),
                                                        time: phase, weather: weather, dark: dark, compact: compact,
                                                        lightningEnabled: active && !reduced && !capturesWeather,
                                                        transition: weatherTransition, seaProfile: seaProfile,
                                                        oceanTime: sea.oceanTime, mix: weatherMix,
                                                        resourceOcean: resourceOceanRenderData),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / bounds.height)
        drawShipOverlay(context)
        return context.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let weatherRenderer {
            if capturesWeather, let context = NSGraphicsContext.current?.cgContext,
               let image = weatherRenderer.snapshot(size: bounds.size, time: phase, weather: weather, dark: dark, compact: compact,
                                                    lightningEnabled: false, transition: weatherTransition,
                                                    seaProfile: seaProfile, oceanTime: sea.oceanTime, mix: weatherMix,
                                                    resourceOcean: resourceOceanRenderData) {
                context.saveGState()
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: bounds)
                context.restoreGState()
            }
            return
        }
        guard bounds.width > 0, bounds.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        var accumulated = 0.0
        for index in CruiseWeatherMix.conditions.indices {
            let weight = weatherMix.weights[index]
            guard weight > 0 else { continue }
            context.saveGState()
            context.setAlpha(weight / (accumulated + weight))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawFallbackBackground(context, weather: CruiseWeatherMix.conditions[index])
            context.endTransparencyLayer()
            context.restoreGState()
            accumulated += weight
        }
        // Composite one ship above the same sampled waterline as Metal.
        drawShipOverlay(context)
        for index in CruiseWeatherMix.conditions.indices {
            drawFallbackPrecipitation(context, weather: CruiseWeatherMix.conditions[index],
                                      opacity: weatherMix.weights[index])
        }
    }

    private func drawFallbackBackground(_ context: CGContext, weather: CruiseWeather) {
        let width = bounds.width, height = bounds.height
        let time = sea.time
        let horizon = resourceConfiguration == nil ? height * (compact ? 0.58 : 0.40) : sea.surface(at: width * 0.5)
        let palette = scenePalette(for: weather)
        let space = CGColorSpaceCreateDeviceRGB()
        gradient(context, colors: [palette.sky, palette.horizon], from: .zero,
                 to: CGPoint(x: 0, y: horizon + height * 0.12), space: space)
        drawCelestialBody(context, time: time, width: width, height: height, space: space, weather: weather)
        drawClouds(context, time: time, width: width, height: height, space: space, weather: weather)
        context.saveGState()
        if let configuration = resourceConfiguration {
            drawResourceWater(context, configuration: configuration, palette: palette, space: space)
        } else {
            context.clip(to: CGRect(x: 0, y: horizon, width: width, height: height - horizon))
            gradient(context, colors: [palette.sea, palette.deep], from: CGPoint(x: 0, y: horizon),
                     to: CGPoint(x: 0, y: height), space: space)
        }
        drawOcean(context, time: time, width: width, height: height, horizon: horizon, weather: weather)
        context.restoreGState()
    }

    private func drawFallbackPrecipitation(_ context: CGContext, weather: CruiseWeather, opacity: Double) {
        guard opacity > 0 else { return }
        context.saveGState()
        context.setAlpha(opacity)
        let width = bounds.width, height = bounds.height
        let horizon = resourceConfiguration == nil ? height * (compact ? 0.58 : 0.40) : sea.surface(at: width * 0.5)
        drawPrecipitation(context, time: phase, width: width, height: height,
                          horizon: horizon, weather: weather)
        drawLightning(context, time: phase, width: width, height: height, weather: weather)
        context.restoreGState()
    }

    private func scenePalette(for weather: CruiseWeather) -> (sky: CGColor, horizon: CGColor, sea: CGColor, deep: CGColor) {
        switch weather {
        case .automatic, .sunny:
            return dark
                ? (rgb(0.055, 0.20, 0.35), rgb(0.24, 0.47, 0.59), rgb(0.12, 0.42, 0.52), rgb(0.035, 0.20, 0.31))
                : (rgb(0.44, 0.73, 0.93), rgb(0.83, 0.93, 0.96), rgb(0.43, 0.73, 0.81), rgb(0.25, 0.58, 0.72))
        case .cloudy:
            return dark
                ? (rgb(0.08, 0.16, 0.26), rgb(0.25, 0.39, 0.47), rgb(0.19, 0.36, 0.44), rgb(0.055, 0.19, 0.28))
                : (rgb(0.59, 0.72, 0.81), rgb(0.84, 0.90, 0.93), rgb(0.50, 0.70, 0.76), rgb(0.32, 0.57, 0.66))
        case .rain, .thunder, .storm:
            return dark
                ? (rgb(0.045, 0.085, 0.16), rgb(0.18, 0.28, 0.36), rgb(0.12, 0.27, 0.35), rgb(0.035, 0.12, 0.22))
                : (rgb(0.50, 0.61, 0.72), rgb(0.72, 0.80, 0.86), rgb(0.41, 0.59, 0.68), rgb(0.29, 0.48, 0.60))
        case .typhoon:
            return dark
                ? (rgb(0.025, 0.045, 0.08), rgb(0.12, 0.20, 0.25), rgb(0.07, 0.17, 0.22), rgb(0.02, 0.06, 0.12))
                : (rgb(0.15, 0.23, 0.30), rgb(0.37, 0.46, 0.50), rgb(0.23, 0.39, 0.43), rgb(0.08, 0.20, 0.28))
        case .snow:
            return dark
                ? (rgb(0.14, 0.21, 0.31), rgb(0.39, 0.48, 0.56), rgb(0.24, 0.40, 0.49), rgb(0.10, 0.24, 0.35))
                : (rgb(0.65, 0.76, 0.85), rgb(0.91, 0.94, 0.97), rgb(0.59, 0.76, 0.82), rgb(0.37, 0.61, 0.74))
        case .night:
            return dark
                ? (rgb(0.025, 0.06, 0.16), rgb(0.14, 0.24, 0.37), rgb(0.10, 0.24, 0.36), rgb(0.025, 0.09, 0.21))
                : (rgb(0.43, 0.54, 0.73), rgb(0.70, 0.77, 0.89), rgb(0.41, 0.58, 0.75), rgb(0.27, 0.44, 0.65))
        }
    }

    private func drawCelestialBody(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat, space: CGColorSpace, weather: CruiseWeather) {
        guard weather == .sunny || weather == .night else { return }
        let center = CGPoint(x: width * 0.81, y: height * (compact ? 0.17 : 0.16))
        let radius = compact ? min(12, width * 0.16) : min(48, max(28, width * 0.037))
        let moon = weather == .night
        glow(context, color: moon ? rgb(0.77, 0.88, 1, 0.20) : rgb(1, 0.91, 0.58, dark ? 0.30 : 0.48),
             center: center, radius: CGSize(width: radius * 4.4, height: radius * 4.4), space: space)
        context.setFillColor(moon ? rgb(0.93, 0.96, 1, 0.96) : rgb(1, 0.95, 0.72, 0.98))
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if moon {
            let crescent = CGMutablePath()
            crescent.addEllipse(in: disc)
            crescent.addEllipse(in: disc.offsetBy(dx: radius * 0.66, dy: -radius * 0.30))
            context.saveGState()
            context.addEllipse(in: disc)
            context.clip()
            context.addPath(crescent)
            context.drawPath(using: .eoFill)
            context.restoreGState()
            for index in 0..<(compact ? 12 : 48) {
                let seed = Double(index)
                let x = sample(seed, 1) * width
                let y = sample(seed, 2) * height * 0.34
                let size = compact ? 1.0 : 1.2 + sample(seed, 3) * 1.3
                context.setFillColor(rgb(0.97, 0.98, 1, 0.28 + 0.32 * (0.5 + 0.5 * sin(time * 0.3 + sample(seed, 4) * .pi * 2))))
                context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            }
        } else {
            context.fillEllipse(in: disc)
        }
    }

    private func drawClouds(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat, space: CGColorSpace, weather: CruiseWeather) {
        let count = compact ? (weather == .sunny ? 2 : 4) : (weather == .sunny || weather == .night ? 3 : 8)
        let stormy = [.rain, .thunder, .storm, .typhoon].contains(weather)
        for index in 0..<count {
            let seed = Double(index)
            let cloudWidth = compact ? width * (0.70 + 0.2 * sample(seed, 5)) : width * (0.24 + 0.11 * sample(seed, 5))
            let cloudHeight = compact ? max(11, height * 0.045) : max(34, height * (0.055 + 0.02 * sample(seed, 6)))
            let speed = (stormy ? 0.010 : 0.004) * (0.7 + sample(seed, 7))
            let x = fraction(sample(seed, 8) + time * speed) * (width + cloudWidth) - cloudWidth
            let y = height * (0.055 + sample(seed, 9) * (compact ? 0.28 : 0.23))
            let shape = CGMutablePath()
            shape.addRoundedRect(in: CGRect(x: x, y: y + cloudHeight * 0.45, width: cloudWidth, height: cloudHeight * 0.50), cornerWidth: cloudHeight * 0.3, cornerHeight: cloudHeight * 0.3)
            for lump in 0..<5 {
                let amount = Double(lump) / 4
                let size = cloudHeight * (0.72 + 0.33 * sin(amount * .pi))
                shape.addEllipse(in: CGRect(x: x + amount * cloudWidth * 0.76, y: y + cloudHeight * (0.4 - 0.32 * sin(amount * .pi)), width: size * 1.8, height: size))
            }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: cloudHeight * 0.09), blur: compact ? 4 : 12,
                              color: rgb(0.16, 0.25, 0.36, 0.14))
            context.addPath(shape)
            context.setFillColor(dark ? rgb(0.41, 0.52, 0.64, stormy ? 0.56 : 0.30) : rgb(1, 1, 1, stormy ? 0.36 : 0.66))
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(shape)
            context.clip()
            let top = dark ? rgb(0.48, 0.59, 0.72, 0.38) : rgb(1, 1, 1, stormy ? 0.30 : 0.74)
            let bottom = dark ? rgb(0.17, 0.25, 0.36, 0.42) : rgb(0.62, 0.73, 0.83, stormy ? 0.46 : 0.24)
            gradient(context, colors: [top, bottom], from: CGPoint(x: 0, y: y),
                     to: CGPoint(x: 0, y: y + cloudHeight), space: space)
            context.restoreGState()
        }
    }

    /// The fallback paints pigment as the water base, then shares the same
    /// wave highlights and weather across every depth. There is no band overlay.
    private func drawResourceWater(_ context: CGContext, configuration: PaperweightConfiguration,
                                   palette: (sky: CGColor, horizon: CGColor, sea: CGColor, deep: CGColor),
                                   space: CGColorSpace) {
        let width = bounds.width, bottom = bounds.height
        let layout = ResourceOceanLayout(configuration: configuration)
        func waterColor(_ layer: PaperweightLayer, depth: Double) -> CGColor {
            let hex = ResourceOceanRenderData.pigmentHex(for: layer)
            let pigment = [Double((hex >> 16) & 255) / 255,
                           Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255]
            let base = NSColor(cgColor: depth < 0.5 ? palette.sea : palette.deep)?.usingColorSpace(.deviceRGB)
            let shade = (1 - depth * 0.16) * (dark ? 0.62 : 0.94)
            return rgb((pigment[0] * 0.62 + Double(base?.redComponent ?? 0.1) * 0.38) * shade,
                       (pigment[1] * 0.62 + Double(base?.greenComponent ?? 0.3) * 0.38) * shade,
                       (pigment[2] * 0.62 + Double(base?.blueComponent ?? 0.4) * 0.38) * shade)
        }
        let ocean = CGMutablePath()
        ocean.move(to: CGPoint(x: 0, y: bottom))
        for index in 0...112 {
            let x = Double(index) / 112 * width
            ocean.addLine(to: CGPoint(x: x, y: sea.surface(at: x)))
        }
        ocean.addLine(to: CGPoint(x: width, y: bottom))
        ocean.closeSubpath()
        context.addPath(ocean)
        context.clip()
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for band in layout.bands {
            let softEdge = min(0.012, (band.end - band.start) * 0.20)
            let start = band.start == 0 ? 0 : band.start + softEdge
            let end = band.end == 1 ? 1 : band.end - softEdge
            colors.append(waterColor(band.layer, depth: start))
            locations.append(CGFloat(start))
            colors.append(waterColor(band.layer, depth: end))
            locations.append(CGFloat(end))
        }
        guard let water = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
        // Sample columns follow the shared wave. Pigments blend at depth
        // boundaries before the same crests and reflections light the water.
        context.setShouldAntialias(false)
        for column in 0..<64 {
            let left = width * Double(column) / 64
            let right = width * Double(column + 1) / 64
            let surface = sea.surface(at: (left + right) * 0.5)
            context.saveGState()
            context.clip(to: CGRect(x: left, y: 0, width: right - left, height: bottom))
            context.drawLinearGradient(water, start: CGPoint(x: left, y: surface),
                                       end: CGPoint(x: left, y: bottom), options: [])
            context.restoreGState()
        }
        context.setShouldAntialias(true)
    }

    private func drawOcean(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat, horizon: CGFloat, weather: CruiseWeather) {
        let rough = 0.5 + Double(seaProfile.roughness) * 2.2
        for index in 0..<6 {
            let amount = Double(index) / 5
            let level = horizon + (height - horizon) * (0.04 + amount * 0.9)
            let amplitude = (compact ? 1.5 : 4.0) * (0.3 + amount) * rough
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -1, y: height + 1))
            for step in 0...72 {
                let x = Double(step) / 72 * width
                let wave = sin(Double(step) / 72 * .pi * (4.5 - amount) + time * (0.45 + amount * 0.12) + Double(index))
                    + 0.35 * sin(Double(step) / 72 * .pi * 8 - time * 0.31)
                path.addLine(to: CGPoint(x: x, y: level + wave * amplitude))
            }
            path.addLine(to: CGPoint(x: width + 1, y: height + 1))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(dark ? rgb(0.37, 0.71, 0.81, 0.055) : rgb(0.78, 0.93, 0.97, 0.12))
            context.fillPath()
        }
        // Short wave crests grow towards the viewer, making the sea read as
        // depth rather than a striped rectangle.
        for index in 0..<(compact ? 24 : 100) {
            let seed = Double(index)
            let depth = fraction(sample(seed, 10) + time * 0.012)
            let y = horizon + pow(depth, 1.7) * (height - horizon)
            let x = fraction(sample(seed, 11) - time * (0.003 + depth * 0.003)) * width
            let length = (compact ? 3 : 10) + depth * (compact ? 11 : 44)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: y))
            path.addQuadCurve(to: CGPoint(x: x + length, y: y - depth * rough),
                              control: CGPoint(x: x + length * 0.5, y: y - depth * 2.8 * rough))
            context.addPath(path)
            context.setLineWidth(compact ? 0.6 : 0.8 + depth * 0.5)
            let sparkle = 0.5 + 0.5 * sin(time * 0.7 + sample(seed, 12) * .pi * 2)
            context.setStrokeColor(rgb(0.87, 0.98, 1, (dark ? 0.055 : 0.10) + sparkle * 0.12))
            context.strokePath()
        }
        if weather == .sunny || weather == .night {
            for index in 0..<16 {
                let depth = Double(index) / 16
                let y = horizon + (height - horizon) * depth
                let spread = width * (0.01 + depth * 0.10)
                let center = width * 0.81 + sin(time * 0.5 + depth * 9) * spread * 0.24
                context.setFillColor(weather == .sunny ? rgb(1, 0.96, 0.73, 0.17 - depth * 0.09) : rgb(0.84, 0.93, 1, 0.15 - depth * 0.08))
                context.fillEllipse(in: CGRect(x: center - spread, y: y, width: spread * 2, height: compact ? 1 : 2 + depth * 2))
            }
        }
    }

    private func drawCruisingShip(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat) {
        let size = sea.shipSize
        let x = CGFloat(sea.boat.x), waterline = CGFloat(sea.boat.y)
        context.saveGState()
        context.translateBy(x: x, y: waterline)
        context.rotate(by: CGFloat(sea.boat.angle))
        let fraction = CGFloat(sea.waterlineFraction)
        // Snapshot coordinates already put the model's real waterline at
        // this fraction. Raising it again would leave its keel in the air.
        let rect = CGRect(x: -size.width / 2, y: -size.height * fraction,
                          width: size.width, height: size.height)
        if let shipSnapshot {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(shipSnapshot, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        } else {
            drawFallbackShip(context, width: size.width, height: size.height)
        }
        context.restoreGState()
    }

    private func drawWake(_ context: CGContext, time: Double) {
        let x = sea.boat.x, shipWidth = Double(sea.shipSize.width)
        for index in 0..<5 {
            let distance = Double(index) * shipWidth * 0.18
            let pulse = 0.5 + 0.5 * sin(time * 1.8 - Double(index))
            let start = x - shipWidth * 0.34 - distance
            let end = x + shipWidth * 0.20
            let path = CGMutablePath()
            path.move(to: CGPoint(x: start, y: sea.surface(at: start) + 3 + distance * 0.12))
            path.addQuadCurve(to: CGPoint(x: end, y: sea.surface(at: end) + 4 + distance * 0.03),
                              control: CGPoint(x: x - distance * 0.3, y: sea.boat.y + 8 + distance * 0.14))
            context.addPath(path)
            context.setLineWidth(compact ? 0.7 : 1.2)
            context.setStrokeColor(rgb(0.94, 0.99, 1, (0.25 - Double(index) * 0.035) * (0.6 + pulse * 0.4)))
            context.strokePath()
        }
    }

    private func drawFallbackShip(_ context: CGContext, width: CGFloat, height: CGFloat) {
        context.setFillColor(rgb(0.18, 0.25, 0.31, 0.9))
        let hull = CGMutablePath()
        hull.move(to: CGPoint(x: -width * 0.45, y: -height * 0.10))
        hull.addLine(to: CGPoint(x: width * 0.48, y: -height * 0.10))
        hull.addLine(to: CGPoint(x: width * 0.33, y: height * 0.12))
        hull.addLine(to: CGPoint(x: -width * 0.30, y: height * 0.12))
        hull.closeSubpath()
        context.addPath(hull)
        context.fillPath()
        context.fill(CGRect(x: -width * 0.015, y: -height * 0.73, width: max(1, width * 0.025), height: height * 0.74))
        let sail = CGMutablePath()
        sail.move(to: CGPoint(x: -width * 0.04, y: -height * 0.69))
        sail.addLine(to: CGPoint(x: -width * 0.38, y: -height * 0.08))
        sail.addLine(to: CGPoint(x: -width * 0.04, y: -height * 0.08))
        sail.closeSubpath()
        context.addPath(sail)
        context.setFillColor(rgb(0.96, 0.92, 0.78, 0.95))
        context.fillPath()
    }

    private func drawPrecipitation(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat, horizon: CGFloat, weather: CruiseWeather) {
        guard [.rain, .thunder, .storm, .typhoon, .snow].contains(weather) else { return }
        let snow = weather == .snow
        let count = compact ? (snow ? 20 : weather == .typhoon ? 48 : 26) : (snow ? 110 : weather == .typhoon ? 240 : 150)
        for index in 0..<count {
            let seed = Double(index)
            let speed = snow ? 0.028 + sample(seed, 20) * 0.025 : (0.36 + sample(seed, 20) * 0.25) * (weather == .typhoon ? 1.7 : 1)
            let y = fraction(sample(seed, 21) + time * speed) * height
            let wind = weather == .typhoon ? 0.14 : weather == .storm ? 0.06 : weather == .thunder ? 0.045 : snow ? 0.008 : 0.022
            let x = fraction(sample(seed, 22) - time * wind + (snow ? sin(time * 0.4 + sample(seed, 23) * .pi * 2) * 0.018 : 0)) * width
            if snow {
                let size = (compact ? 1.2 : 1.6) + sample(seed, 24) * (compact ? 1.5 : 3)
                context.setFillColor(rgb(1, 1, 1, 0.43 + sample(seed, 25) * 0.45))
                context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            } else {
                let length = compact ? 7.0 : 12.0 + sample(seed, 26) * 12
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x - length * (weather == .typhoon ? 1.1 : weather == .storm ? 0.55 : 0.30), y: y + length))
                context.addPath(path)
                context.setLineWidth(compact ? 0.55 : 0.8)
                context.setStrokeColor(rgb(0.88, 0.95, 1, dark ? 0.35 : 0.47))
                context.strokePath()
                if y > horizon, index % 6 == 0 {
                    context.setStrokeColor(rgb(0.90, 0.98, 1, 0.21))
                    context.strokeEllipse(in: CGRect(x: x - 3, y: y + length, width: compact ? 4 : 8, height: 2))
                }
            }
        }
    }

    private func drawLightning(_ context: CGContext, time: Double, width: CGFloat, height: CGFloat, weather: CruiseWeather) {
        guard [.thunder, .storm, .typhoon].contains(weather), active, !reduced, !capturesWeather else { return }
        // One softly rising and falling flash every 28 seconds, with no
        // repeated pulses or whole-screen flashes.
        let position = time.truncatingRemainder(dividingBy: 28)
        guard position > 13, position < 15 else { return }
        let opacity = sin((position - 13) / 2 * .pi) * 0.42
        let path = CGMutablePath()
        path.move(to: CGPoint(x: width * 0.73, y: height * 0.14))
        path.addLine(to: CGPoint(x: width * 0.69, y: height * 0.24))
        path.addLine(to: CGPoint(x: width * 0.735, y: height * 0.23))
        path.addLine(to: CGPoint(x: width * 0.67, y: height * 0.36))
        context.saveGState()
        context.setShadow(offset: .zero, blur: compact ? 5 : 18, color: rgb(0.83, 0.89, 1, opacity))
        context.setLineJoin(.round)
        context.setLineWidth(compact ? 1.0 : 2.5)
        context.setStrokeColor(rgb(0.91, 0.95, 1, opacity))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func fraction(_ value: Double) -> Double { value - floor(value) }

    /// Independent deterministic channels avoid aligning particles into a
    /// diagonal when two repeated seed multipliers happen to complement.
    private func sample(_ seed: Double, _ salt: Double) -> Double {
        fraction(sin(seed * 127.1 + salt * 311.7) * 43_758.5453)
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func gradient(_ context: CGContext, colors: [CGColor], from start: CGPoint, to end: CGPoint, space: CGColorSpace) {
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func glow(_ context: CGContext, color: CGColor, center: CGPoint, radius: CGSize, space: CGColorSpace) {
        guard let clear = color.copy(alpha: 0),
              let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: radius.width, y: radius.height)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }

}

@available(macOS 14.0, *)
@MainActor
private final class AtmosphereShipOverlay: NSView {
    weak var owner: UsageAtmosphereView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        owner?.drawShipOverlay(context)
    }
}

@available(macOS 14.0, *)
@MainActor
private final class AtmosphereTickTarget: NSObject {
    weak var owner: UsageAtmosphereView?
    init(owner: UsageAtmosphereView) { self.owner = owner }
    @objc func tick(_ timer: Timer) {
        guard let owner else { timer.invalidate(); return }
        owner.tick()
    }
}

@MainActor
private final class ResourceOceanAccessibilityTarget: NSObject {
    let name: String
    let invokeAction: () -> Void
    init(name: String, action: @escaping () -> Void) {
        self.name = name
        invokeAction = action
    }
    var action: NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name, target: self, selector: #selector(invoke))
    }
    @objc private func invoke() -> Bool { invokeAction(); return true }
}
