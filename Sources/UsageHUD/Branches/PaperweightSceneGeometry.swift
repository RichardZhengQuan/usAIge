import AppKit
import SceneKit

@available(macOS 14.0, *)
@MainActor
enum PaperweightSceneAssets {
    static let labels = NSCache<NSString, NSImage>()

    static func vector(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
        SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
    }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static func ink(dark: Bool) -> NSColor {
        var result = NSColor.labelColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return result
    }

    static func material(_ color: NSColor, opacity: CGFloat = 1, roughness: CGFloat = 0.12,
                         constant: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = constant ? .constant : .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = 0
        material.specular.contents = NSColor.white
        setOpacity(opacity, of: material)
        material.isDoubleSided = true
        material.writesToDepthBuffer = opacity >= 1
        material.blendMode = .alpha
        return material
    }

    /// Physically based materials ignore `transparency` and render nearly
    /// opaque (glass at 7% came out white), so opacity goes through the
    /// `transparent` channel, which they do honour.
    static func setOpacity(_ opacity: CGFloat, of material: SCNMaterial) {
        material.transparency = 1
        material.transparencyMode = .aOne
        material.transparent.contents = NSColor(white: 1, alpha: opacity)
    }

    /// Textures are drawn at exactly their pixel size. `NSImage.lockFocus`
    /// drew them at the screen's 2x scale, four times the memory SceneKit
    /// needs, and every size change during a scan added another one.
    static func image(key: String, size: NSSize, draw: () -> Void) -> NSImage {
        if let existing = labels.object(forKey: key as NSString) { return existing }
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        labels.countLimit = 24
        labels.totalCostLimit = 24 * 1024 * 1024
        labels.setObject(image, forKey: key as NSString, cost: width * height * 4)
        return image
    }

    /// Nothing drawn for the window outlives it.
    static func releaseCaches() {
        labels.removeAllObjects()
    }

    static func layerTexture(_ layer: PaperweightLayer, thickness: Double, selected: Bool, dark: Bool) -> NSImage {
        let height = max(48, Int((1024 * thickness / PaperweightConstants.textureWidth).rounded()))
        let key = "layer-gradient|\(layer.id)|\(layer.title)|\(layer.bytes)|\(layer.isMeasuring)|\(layer.colorHex)|\(layer.inkHex)|\(height)|\(selected)|\(dark)"
        return image(key: key, size: NSSize(width: 1024, height: CGFloat(height))) {
            let top = color(layer.colorHex)
            let bottom = top.blended(withFraction: 0.26, of: .black) ?? top
            NSGradient(starting: bottom, ending: top)?
                .draw(in: NSRect(x: 0, y: 0, width: 1024, height: CGFloat(height)), angle: 90)
            let text = "\(layer.title)   \(layer.isMeasuring ? "Measuring…" : BoardText.bytes(layer.bytes))"
            let font = NSFont.systemFont(ofSize: 1024 * 15 / 440, weight: selected ? .semibold : .medium)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(layer.inkHex), .paragraphStyle: style]
            let textHeight = font.ascender - font.descender
            (text as NSString).draw(in: NSRect(x: 1024 * 20 / 440, y: (CGFloat(height) - textHeight) / 2,
                                              width: 920, height: textHeight + 4), withAttributes: attributes)
        }
    }

    static func textTexture(_ text: String, width: Double, height: Double, size: Double, dark: Bool) -> NSImage {
        image(key: "text|\(text)|\(width)|\(height)|\(size)|\(dark)", size: NSSize(width: width * 256, height: height * 256)) {
            let font = NSFont.systemFont(ofSize: size * 256)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in: NSRect(x: 2, y: (height * 256 - Double(font.ascender - font.descender)) / 2,
                                              width: width * 256 - 4, height: height * 256),
                                     withAttributes: [.font: font, .foregroundColor: ink(dark: dark).withAlphaComponent(0.75), .paragraphStyle: style])
        }
    }

    static func shadowTexture() -> NSImage {
        image(key: "contact-shadow", size: NSSize(width: 128, height: 128)) {
            NSGradient(starting: .black.withAlphaComponent(0.55), ending: .clear)?
                .draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 128, height: 128)), relativeCenterPosition: .zero)
        }
    }

    static func environmentTexture() -> NSImage {
        // Reflections are blurred light panels, so half resolution looks the same.
        image(key: "studio-reflections", size: NSSize(width: 512, height: 256)) {
            NSColor(calibratedWhite: 0.23, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 512, height: 256).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            for rect in [NSRect(x: 50, y: 125, width: 110, height: 45), NSRect(x: 315, y: 110, width: 55, height: 80),
                         NSRect(x: 180, y: 210, width: 170, height: 20), NSRect(x: 430, y: 80, width: 33, height: 90)] { rect.fill() }
        }
    }
}

/// Each strip keeps its topology and material. Only the deformed positions
/// and normals are replaced while the simulation is moving.
@available(macOS 14.0, *)
@MainActor
final class PaperweightSlab {
    let front = SCNNode()
    let back = SCNNode()
    let surface = SCNNode()
    let line = SCNNode()
    var layer: PaperweightLayer
    private let frontMaterial: SCNMaterial
    private let backMaterial: SCNMaterial
    private let surfaceMaterial: SCNMaterial
    private let lineMaterial: SCNMaterial
    private let elements: [SCNGeometryElement]
    private let reverseElements: [SCNGeometryElement]
    private let textureCoordinates: SCNGeometrySource
    private var labelKey = ""
    private var selected = false
    private var isTopLayer = false

    init(layer: PaperweightLayer) {
        self.layer = layer
        frontMaterial = PaperweightSceneAssets.material(.white, opacity: 0.8)
        backMaterial = PaperweightSceneAssets.material(PaperweightSceneAssets.color(layer.colorHex), opacity: 0.6)
        surfaceMaterial = PaperweightSceneAssets.material(PaperweightSceneAssets.color(layer.colorHex), opacity: 0.72)
        lineMaterial = PaperweightSceneAssets.material(.white, opacity: 0.3, constant: true)
        var indices: [Int32] = []
        var reverse: [Int32] = []
        var uv: [CGPoint] = []
        // SceneKit reads images from the top, so the bottom edge of each
        // strip takes v = 1 or the label prints upside down.
        for index in 0..<PaperweightConstants.sampleCount {
            uv += [CGPoint(x: Double(index) / Double(PaperweightConstants.sampleCount - 1), y: 1),
                   CGPoint(x: Double(index) / Double(PaperweightConstants.sampleCount - 1), y: 0)]
            if index < PaperweightConstants.sampleCount - 1 {
                let a = Int32(index * 2)
                indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
                reverse += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            }
        }
        elements = [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        reverseElements = [SCNGeometryElement(indices: reverse, primitiveType: .triangles)]
        textureCoordinates = SCNGeometrySource(textureCoordinates: uv)
        for node in [front, back, surface, line] { node.categoryBitMask = 2 }
    }

    func attach(to node: SCNNode) { [front, back, surface, line].forEach(node.addChildNode) }
    func remove() { [front, back, surface, line].forEach { $0.removeFromParentNode() } }

    func updateLabel(thickness: Double, selected: Bool, dark: Bool) {
        self.selected = selected
        updateEdge()
        let key = "\(layer)|\(Int(thickness.rounded()))|\(selected)|\(dark)"
        guard key != labelKey else { return }
        labelKey = key
        frontMaterial.diffuse.contents = PaperweightSceneAssets.layerTexture(layer, thickness: thickness, selected: selected, dark: dark)
        frontMaterial.emission.contents = selected ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor.black
    }

    func updateGeometry(simulation: PaperweightSimulation, index: Int) {
        var fronts: [SCNVector3] = [], backs: [SCNVector3] = [], tops: [SCNVector3] = [], normals: [SCNVector3] = [], rim: [SCNVector3] = []
        let count = PaperweightConstants.sampleCount
        for sample in 0..<count {
            let x = PaperweightConstants.X0 + Double(sample) * PaperweightConstants.dx * PaperweightConstants.unitsPerPixel
            let lower = PaperweightConstants.Y0 + simulation.curve(layer: index - 1, sample: sample) * PaperweightConstants.unitsPerPixel
            let upper = PaperweightConstants.Y0 + simulation.curve(layer: index, sample: sample) * PaperweightConstants.unitsPerPixel
            fronts += [PaperweightSceneAssets.vector(x, lower, PaperweightConstants.ZF), PaperweightSceneAssets.vector(x, upper, PaperweightConstants.ZF)]
            backs += [PaperweightSceneAssets.vector(x, lower, PaperweightConstants.ZB), PaperweightSceneAssets.vector(x, upper, PaperweightConstants.ZB)]
            tops += [PaperweightSceneAssets.vector(x, upper, PaperweightConstants.ZF), PaperweightSceneAssets.vector(x, upper, PaperweightConstants.ZB)]
            let left = simulation.curve(layer: index, sample: max(0, sample - 1))
            let right = simulation.curve(layer: index, sample: min(count - 1, sample + 1))
            let slope = (right - left) / (PaperweightConstants.dx * (sample == 0 || sample == count - 1 ? 1 : 2))
            let scale = sqrt(1 + slope * slope)
            normals += [PaperweightSceneAssets.vector(-slope / scale, 1 / scale, 0), PaperweightSceneAssets.vector(-slope / scale, 1 / scale, 0)]
            rim.append(PaperweightSceneAssets.vector(x, upper, PaperweightConstants.ZF + 0.002))
        }
        front.geometry = strip(fronts, normals: Array(repeating: PaperweightSceneAssets.vector(0, 0, 1), count: count * 2), material: frontMaterial)
        back.geometry = strip(backs, normals: Array(repeating: PaperweightSceneAssets.vector(0, 0, -1), count: count * 2), material: backMaterial, reverse: true)
        surface.geometry = strip(tops, normals: normals, material: surfaceMaterial)
        let segments = (0..<count - 1).flatMap { [Int32($0), Int32($0 + 1)] }
        line.geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: rim)], elements: [SCNGeometryElement(indices: segments, primitiveType: .line)])
        line.geometry?.materials = [lineMaterial]
    }

    private func strip(_ vertices: [SCNVector3], normals: [SCNVector3], material: SCNMaterial, reverse: Bool = false) -> SCNGeometry {
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), textureCoordinates],
                                   elements: reverse ? reverseElements : elements)
        geometry.materials = [material]
        return geometry
    }

    func setOrder(_ order: Int, isTop: Bool) {
        [front, back, surface].forEach { $0.renderingOrder = order + 2 }
        line.renderingOrder = order + 3
        isTopLayer = isTop
        updateEdge()
    }

    private func updateEdge() {
        PaperweightSceneAssets.setOpacity(selected ? 1 : isTopLayer ? 0.75 : 0.3, of: lineMaterial)
        lineMaterial.emission.contents = selected ? NSColor.white.withAlphaComponent(0.15) : NSColor.black
    }
}

@available(macOS 14.0, *)
@MainActor
final class PaperweightBottle {
    let group = SCNNode()
    let inner = SCNNode()
    let glass: SCNNode
    let simulation: PaperweightSimulation
    let shadow: SCNNode
    let caption: SCNNode
    private let back: SCNNode
    private let freeLabel: SCNNode
    private var outlines: [SCNNode] = []
    private var slabs: [PaperweightSlab] = []
    private var bubbles: [Bubble] = []
    private(set) var ship: SCNNode
    private(set) var shipKind: PaperweightShipKind
    private var order = -1
    private var dark = false

    private struct Bubble {
        let node: SCNNode
        var x: Double
        var fraction: Double
        let z: Double
        let speed: Double
        var phase: Double
    }

    init(configuration: PaperweightConfiguration, shipKind: PaperweightShipKind) {
        self.simulation = PaperweightSimulation(configuration: configuration)
        self.shipKind = shipKind
        ship = PaperweightShipFactory.make(shipKind)
        let path = NSBezierPath(roundedRect: NSRect(x: -2, y: -0.95, width: 4, height: 1.9), xRadius: 0.22, yRadius: 0.22)
        path.flatness = 0.01
        let shape = SCNShape(path: path, extrusionDepth: 0.98)
        shape.chamferRadius = 0.06
        // Five sampled segments reproduce the prototype's rounded bevel.
        let profile = NSBezierPath()
        for index in 0...5 {
            let angle = CGFloat(index) / 5 * .pi / 2
            let point = NSPoint(x: 1 - cos(angle), y: 1 - sin(angle))
            if index == 0 { profile.move(to: point) } else { profile.line(to: point) }
        }
        shape.chamferProfile = profile
        let frontMaterial = PaperweightSceneAssets.material(.white, opacity: 0.07, roughness: 0.02)
        frontMaterial.isDoubleSided = false
        frontMaterial.cullMode = .back
        let backMaterial = PaperweightSceneAssets.material(.white, opacity: 0.05, roughness: 0.05)
        backMaterial.isDoubleSided = false
        backMaterial.cullMode = .front
        glass = SCNNode(geometry: shape)
        glass.geometry?.materials = [frontMaterial]
        back = SCNNode(geometry: shape.copy() as? SCNGeometry)
        back.geometry?.materials = [backMaterial]
        glass.categoryBitMask = 1
        back.categoryBitMask = 2
        shadow = SCNNode(geometry: SCNPlane(width: 4.6, height: 2.09))
        let shadowMaterial = PaperweightSceneAssets.material(.white, opacity: 0.28, constant: true)
        shadowMaterial.diffuse.contents = PaperweightSceneAssets.shadowTexture()
        shadow.geometry?.materials = [shadowMaterial]
        shadow.eulerAngles.x = -.pi / 2
        shadow.position.y = -1.01 + 0.002
        caption = SCNNode(geometry: SCNPlane(width: 2.6, height: 0.34))
        caption.eulerAngles.x = -.pi / 2
        caption.position = PaperweightSceneAssets.vector(0, -1.01 + 0.004, 1.0)
        caption.geometry?.materials = [PaperweightSceneAssets.material(.white, opacity: 0.95, constant: true)]
        freeLabel = SCNNode(geometry: SCNPlane(width: 1.7, height: 0.22))
        freeLabel.position = PaperweightSceneAssets.vector(-1.1, 0.71, PaperweightConstants.ZF + 0.003)
        freeLabel.geometry?.materials = [PaperweightSceneAssets.material(.white, opacity: 0.95, constant: true)]
        group.addChildNode(inner)
        [back, glass, freeLabel, ship].forEach(inner.addChildNode)
        group.addChildNode(shadow)
        group.addChildNode(caption)
        outlines = [outline(z: 0.51, opacity: 0.42), outline(z: -0.51, opacity: 0.16)]
        outlines.forEach(inner.addChildNode)
        createBubbles()
        rebuildSlabs()
        refreshLabels(selected: nil, dark: false)
        updateVisuals(dt: 0, moving: false, geometryChanged: true)
    }

    func update(configuration: PaperweightConfiguration, selected: String?, dark: Bool, reduceMotion: Bool) {
        let oldIDs = simulation.configuration.layers.map(\.id)
        let oldLevels = simulation.currentLevels
        simulation.update(configuration: configuration)
        if reduceMotion { simulation.settle() }
        if oldIDs != configuration.layers.map(\.id) { rebuildSlabs() }
        else { for (index, layer) in configuration.layers.enumerated() { slabs[index].layer = layer } }
        refreshLabels(selected: selected, dark: dark)
        updateVisuals(dt: 0, moving: false, geometryChanged: oldIDs != configuration.layers.map(\.id) || oldLevels != simulation.currentLevels)
    }

    func refreshLabels(selected: String?, dark: Bool) {
        self.dark = dark
        let configuration = simulation.configuration
        for (index, slab) in slabs.enumerated() {
            let bottom = index > 0 ? simulation.targetLevels[index - 1] : 0
            slab.updateLabel(thickness: simulation.targetLevels[index] - bottom, selected: slab.layer.id == selected, dark: dark)
        }
        let free = configuration.freeBytes.map { BoardText.bytes($0) + (configuration.id == .memory ? " other memory" : " free") } ?? "Not read"
        freeLabel.geometry?.firstMaterial?.diffuse.contents = PaperweightSceneAssets.textTexture(free, width: 1.7, height: 0.22, size: 0.13, dark: dark)
        let share = configuration.capacityBytes > 0 ? Double(configuration.usedBytes) / Double(configuration.capacityBytes) : 0
        let percent = configuration.capacityBytes > 0 && configuration.freeBytes != nil ? LiveWorkText.percent(share) : "–"
        let title = configuration.id == .memory ? "Memory · \(percent)" : "Storage · \(percent) used"
        caption.geometry?.firstMaterial?.diffuse.contents = PaperweightSceneAssets.textTexture(title, width: 2.6, height: 0.34, size: 0.2, dark: dark)
        for (index, outline) in outlines.enumerated() {
            outline.geometry?.firstMaterial?.diffuse.contents = PaperweightSceneAssets.ink(dark: dark)
            if let material = outline.geometry?.firstMaterial {
                PaperweightSceneAssets.setOpacity(index == 0 ? 0.42 : 0.16, of: material)
            }
        }
    }

    func setShip(_ kind: PaperweightShipKind) {
        guard kind != shipKind else { return }
        ship.removeFromParentNode()
        ship = PaperweightShipFactory.make(kind)
        shipKind = kind
        inner.addChildNode(ship)
        let previous = order
        order = -1
        setOrder(previous)
    }

    func updateVisuals(dt: Double, moving: Bool, geometryChanged: Bool) {
        if geometryChanged {
            for (index, slab) in slabs.enumerated() { slab.updateGeometry(simulation: simulation, index: index) }
        }
        let boat = simulation.boat
        ship.isHidden = simulation.configuration.layers.isEmpty || simulation.configuration.usedBytes == 0
        ship.position = PaperweightSceneAssets.vector(PaperweightConstants.X0 + boat.x * PaperweightConstants.unitsPerPixel,
                                                      PaperweightConstants.Y0 + boat.y * PaperweightConstants.unitsPerPixel, 0)
        ship.eulerAngles.z = CGFloat(boat.angle)
        // Camera motion excites the liquid, while the glass stays on the table.
        inner.eulerAngles.z = 0
        if moving, let wheel = ship.childNode(withName: "paddle-wheel", recursively: true) {
            wheel.eulerAngles.z += CGFloat(dt * (1.6 + abs(boat.velocityX) * 0.02))
        }
        for index in bubbles.indices {
            if moving {
                bubbles[index].fraction += bubbles[index].speed * dt
                bubbles[index].phase += dt * 3
                if bubbles[index].fraction > 0.97 { bubbles[index].fraction = 0.2 }
            }
            let bubble = bubbles[index]
            let sample = min(PaperweightConstants.sampleCount - 1, Int((bubble.x / PaperweightConstants.dx).rounded()))
            let y = simulation.curve(layer: simulation.currentLevels.count - 1, sample: sample) * bubble.fraction
            bubble.node.isHidden = simulation.configuration.usedBytes == 0
            bubble.node.position = PaperweightSceneAssets.vector(PaperweightConstants.X0 + (bubble.x + sin(bubble.phase) * 3) * PaperweightConstants.unitsPerPixel,
                                                                 PaperweightConstants.Y0 + y * PaperweightConstants.unitsPerPixel, bubble.z)
        }
    }

    func setOrder(_ value: Int) {
        guard value != order else { return }
        order = value
        back.renderingOrder = value + 1
        glass.renderingOrder = value + 4
        freeLabel.renderingOrder = value + 5
        outlines.forEach { $0.renderingOrder = value + 4 }
        for (index, slab) in slabs.enumerated() { slab.setOrder(value, isTop: index == slabs.count - 1) }
        bubbles.forEach { $0.node.renderingOrder = value + 3 }
        ship.enumerateChildNodes { node, _ in node.renderingOrder = value + 3 }
    }

    private func rebuildSlabs() {
        slabs.forEach { $0.remove() }
        slabs = simulation.configuration.layers.map(PaperweightSlab.init)
        slabs.forEach { $0.attach(to: inner) }
        let previous = order
        order = -1
        setOrder(max(0, previous))
    }

    private func outline(z: Double, opacity: CGFloat) -> SCNNode {
        let width = 4.12, height = 2.02, radius = 0.28
        let centers = [(width / 2 - radius, height / 2 - radius), (-width / 2 + radius, height / 2 - radius),
                       (-width / 2 + radius, -height / 2 + radius), (width / 2 - radius, -height / 2 + radius)]
        var points: [SCNVector3] = []
        for (corner, center) in centers.enumerated() {
            for step in 0...8 {
                let angle = Double(corner) * .pi / 2 + Double(step) / 8 * .pi / 2
                points.append(PaperweightSceneAssets.vector(center.0 + cos(angle) * radius, center.1 + sin(angle) * radius, z))
            }
        }
        let indices = points.indices.flatMap { [Int32($0), Int32(($0 + 1) % points.count)] }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        geometry.materials = [PaperweightSceneAssets.material(PaperweightSceneAssets.ink(dark: dark), opacity: opacity, constant: true)]
        return SCNNode(geometry: geometry)
    }

    private func createBubbles() {
        let material = PaperweightSceneAssets.material(.white, opacity: 0.55, roughness: 0.05)
        for index in 0..<9 {
            let seed = Double((index * 37 + 11) % 97) / 97
            let sphere = SCNSphere(radius: 0.018 + seed * 0.03)
            sphere.segmentCount = 10
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.categoryBitMask = 2
            inner.addChildNode(node)
            bubbles.append(Bubble(node: node, x: 40 + seed * 360, fraction: 0.25 + seed * 0.6,
                                  z: PaperweightConstants.ZB + 0.06 + seed * (PaperweightConstants.ZF - PaperweightConstants.ZB - 0.12),
                                  speed: 0.02 + seed * 0.05, phase: seed * 6))
        }
    }
}
