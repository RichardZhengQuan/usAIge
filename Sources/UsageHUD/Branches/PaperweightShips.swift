import AppKit
import SceneKit

/// The prototype's ships keep their own small coordinate system, so changing
/// a ship leaves the water's position and spring motion alone.
@available(macOS 14.0, *)
@MainActor
enum PaperweightShipFactory {
    static func make(_ kind: PaperweightShipKind) -> SCNNode {
        let ship: SCNNode
        switch kind {
        case .sailboat: ship = sailboat()
        case .liner: ship = liner()
        case .sub: ship = submarine()
        case .galleon: ship = galleon()
        case .ghost: ship = ghost()
        case .victory: ship = victory()
        case .treasure: ship = treasure()
        case .carrier: ship = carrier()
        case .cartoon: ship = cartoonPirate()
        case .viking: ship = viking()
        case .steamer: ship = steamer()
        case .tug: ship = tugboat()
        case .goingMerry, .thousandSunny, .oroJackson, .mobyDick,
             .redForce, .saberOfXebec, .bigTop, .bigTopBlaster,
             .victoriaPunk, .jewelryMargherita, .grudgeDolph, .liberalHind,
             .stayTune, .hanjomaru, .numanciaFlamingo, .dreadnaughtSabre,
             .sharkSuperb, .greatEirik, .naglfar, .goingLuffySenpai,
             .sleepingWhiteHorse, .yontaMaria, .usoland, .pieceOfSpadille:
            ship = onePiecePirateShip(kind)
        case .miniMerry, .sharkSubmerge, .queenMamaChanter, .polarTang,
             .nostraCastello, .perfumeYuda, .thrillerBark, .hitsugibune,
             .missLoveDuck, .bezanBlack, .baratie, .sexyFoxy,
             .mammoth, .snapperHead, .arkMaxim, .onePieceFlyingDutchman,
             .noah, .striker, .windGranma, .germa66,
             .garpWarship, .marineWarship, .blackbeardRaft:
            ship = onePieceSpecialShip(kind)
        }
        ship.name = kind.rawValue
        let scale = fittedFleetScale(ship)
        ship.scale = SCNVector3(scale, scale, scale)
        return ship
    }

    /// Fit each miniature at its waterline, including the full roll envelope.
    /// Tall castles and wide rafts must obey the same motion limits as a caravel.
    private static func fittedFleetScale(_ ship: SCNNode) -> CGFloat {
        var side = 0.0, top = 0.0, bottom = 0.0, depth = 0.0
        ship.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let bounds = geometry.boundingBox
            for x in [bounds.min.x, bounds.max.x] {
                for y in [bounds.min.y, bounds.max.y] {
                    for z in [bounds.min.z, bounds.max.z] {
                        let point = node.convertPosition(SCNVector3(x, y, z), to: ship)
                        let px = Double(point.x), py = Double(point.y)
                        depth = max(depth, abs(Double(point.z)))
                        var angles = [-PaperweightConstants.maximumRoll, 0, PaperweightConstants.maximumRoll]
                        for base in [atan2(-py, px), atan2(px, py)] {
                            for turn in -2...2 {
                                let angle = base + Double(turn) * .pi
                                if abs(angle) <= PaperweightConstants.maximumRoll { angles.append(angle) }
                            }
                        }
                        for angle in angles {
                            let x = px * cos(angle) - py * sin(angle)
                            let y = px * sin(angle) + py * cos(angle)
                            side = max(side, abs(x))
                            top = max(top, y)
                            bottom = max(bottom, -y)
                        }
                    }
                }
            }
        }
        let unit = PaperweightConstants.unitsPerPixel
        let scales = [unit * PaperweightConstants.boatScale,
                      PaperweightConstants.boatMargin * unit / max(side * 1.12, 0.001),
                      PaperweightConstants.boatHeight * unit / max(top * 1.12, 0.001),
                      PaperweightConstants.boatDraft * unit / max(bottom * 1.12, 0.001),
                      PaperweightConstants.ZF / max(depth * 1.12, 0.001)]
        // Extra room covers flutter, nods, oars and rotating blade envelopes.
        return CGFloat((scales.min() ?? unit) * 0.98)
    }

    // MARK: Shared primitives

    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1
        )
    }

    static func material(
        _ hex: String, roughness: Double = 0.55, metalness: Double = 0,
        doubleSided: Bool = false
    ) -> SCNMaterial {
        let result = SCNMaterial()
        result.lightingModel = .physicallyBased
        result.diffuse.contents = color(hex)
        result.roughness.contents = roughness
        result.metalness.contents = metalness
        result.isDoubleSided = doubleSided
        return result
    }

    static func textured(_ image: NSImage, roughness: Double = 0.55) -> SCNMaterial {
        let result = material("#ffffff", roughness: roughness, doubleSided: true)
        result.diffuse.contents = image
        return result
    }

    static func vector(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
        SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
    }

    @discardableResult
    static func put(
        _ group: SCNNode, _ geometry: SCNGeometry, _ material: SCNMaterial,
        _ x: Double = 0, _ y: Double = 0, _ z: Double = 0,
        rx: Double = 0, ry: Double = 0, rz: Double = 0
    ) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = vector(x, y, z)
        node.eulerAngles = vector(rx, ry, rz)
        node.castsShadow = true
        group.addChildNode(node)
        return node
    }

    static func path(_ points: [(Double, Double)]) -> NSBezierPath {
        let result = NSBezierPath()
        guard let first = points.first else { return result }
        result.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { result.line(to: NSPoint(x: point.0, y: point.1)) }
        result.close()
        return result
    }

    @discardableResult
    static func profile(
        _ group: SCNNode, _ points: [(Double, Double)], _ width: Double,
        _ material: SCNMaterial, bevel: Double = 0.7
    ) -> SCNNode {
        extrude(group, path(points), width, material, bevel: bevel)
    }

    @discardableResult
    static func extrude(
        _ group: SCNNode, _ outline: NSBezierPath, _ width: Double,
        _ material: SCNMaterial, bevel: Double
    ) -> SCNNode {
        let geometry = SCNShape(path: outline, extrusionDepth: CGFloat(width))
        geometry.chamferRadius = CGFloat(bevel)
        geometry.chamferMode = .both
        let node = put(group, geometry, material)
        let bounds = geometry.boundingBox
        node.position.z = -(bounds.min.z + bounds.max.z) / 2
        return node
    }

    static func flat(
        _ group: SCNNode, _ points: [(Double, Double)], _ material: SCNMaterial,
        _ x: Double = 0, _ y: Double = 0, _ z: Double = 0
    ) {
        PaperweightShipAnimation.tag(put(group, SCNShape(path: path(points), extrusionDepth: 0), material, x, y, z), as: .sail)
    }

    @discardableResult
    static func box(
        _ group: SCNNode, _ width: Double, _ height: Double, _ depth: Double,
        _ material: SCNMaterial, _ x: Double, _ y: Double, _ z: Double = 0,
        ry: Double = 0, rz: Double = 0
    ) -> SCNNode {
        put(group, SCNBox(width: width, height: height, length: depth, chamferRadius: 0),
            material, x, y, z, ry: ry, rz: rz)
    }

    static func cylinder(
        _ group: SCNNode, _ top: Double, _ bottom: Double, _ height: Double,
        _ material: SCNMaterial, _ x: Double, _ y: Double, _ z: Double = 0,
        rz: Double = 0, rx: Double = 0
    ) {
        let geometry = SCNCone(topRadius: top, bottomRadius: bottom, height: height)
        geometry.radialSegmentCount = 14
        put(group, geometry, material, x, y, z, rx: rx, rz: rz)
    }

    static func mast(_ group: SCNNode, _ x: Double, _ bottom: Double, _ height: Double, _ material: SCNMaterial) {
        cylinder(group, 0.42, 0.52, height, material, x, bottom + height / 2)
    }

    @discardableResult
    static func sphere(
        _ group: SCNNode, _ radius: Double, _ segments: Int, _ material: SCNMaterial,
        _ x: Double, _ y: Double, _ z: Double = 0
    ) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.segmentCount = segments
        return put(group, geometry, material, x, y, z)
    }

    static func plane(
        _ group: SCNNode, _ width: Double, _ height: Double, _ material: SCNMaterial,
        _ x: Double, _ y: Double, _ z: Double = 0
    ) {
        PaperweightShipAnimation.tag(put(group, SCNPlane(width: width, height: height), material, x, y, z),
                                     as: height < 3 ? .flag : .sail)
    }

    static func mesh(
        _ vertices: [SCNVector3], _ normals: [SCNVector3], _ coordinates: [CGPoint], _ indices: [Int32]
    ) -> SCNGeometry {
        SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: coordinates),
        ], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    static func sail(
        _ group: SCNNode, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ material: SCNMaterial, brace: Double = 0.5, bulge: Double? = nil,
        columns: Int = 8, z: Double = 0
    ) {
        let bow = bulge ?? width * 0.13
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var coordinates: [CGPoint] = []
        var indices: [Int32] = []
        for row in 0...2 {
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let v = Double(row) / 2
                let across = u * 2 - 1
                vertices.append(vector((u - 0.5) * width, (v - 0.5) * height, (1 - across * across) * bow))
                let nx = 4 * bow * across / width
                let length = sqrt(nx * nx + 1)
                normals.append(vector(nx / length, 0, 1 / length))
                coordinates.append(CGPoint(x: u, y: v))
                if row < 2, column < columns {
                    let a = Int32(row * (columns + 1) + column)
                    let b = a + 1, c = a + Int32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        PaperweightShipAnimation.tag(put(group, mesh(vertices, normals, coordinates, indices), material, x, y, z, ry: brace), as: .sail)
    }

    static func disc(
        _ group: SCNNode, _ radius: Double, _ segments: Int, _ material: SCNMaterial,
        _ x: Double, _ y: Double, _ z: Double, ry: Double = 0
    ) {
        var vertices = [vector(0, 0, 0)]
        var coordinates = [CGPoint(x: 0.5, y: 0.5)]
        var indices: [Int32] = []
        for index in 0...segments {
            let angle = Double(index) / Double(segments) * 2 * .pi
            vertices.append(vector(cos(angle) * radius, sin(angle) * radius, 0))
            coordinates.append(CGPoint(x: 0.5 + cos(angle) / 2, y: 0.5 + sin(angle) / 2))
            if index < segments { indices.append(contentsOf: [0, Int32(index + 1), Int32(index + 2)]) }
        }
        put(group, mesh(vertices, Array(repeating: vector(0, 0, 1), count: vertices.count), coordinates, indices),
            material, x, y, z, ry: ry)
    }

    static func torus(
        _ group: SCNNode, _ radius: Double, _ tube: Double, rings: Int, sides: Int,
        _ material: SCNMaterial, _ x: Double, _ y: Double, _ z: Double = 0,
        rx: Double = 0, ry: Double = 0
    ) {
        // Three.js toruses face forward; SceneKit's built-in torus lies flat.
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var coordinates: [CGPoint] = [], indices: [Int32] = []
        for ring in 0...rings {
            let u = Double(ring) / Double(rings), angle = u * 2 * .pi
            for side in 0...sides {
                let v = Double(side) / Double(sides), around = v * 2 * .pi
                let r = radius + tube * cos(around)
                vertices.append(vector(r * cos(angle), r * sin(angle), tube * sin(around)))
                normals.append(vector(cos(around) * cos(angle), cos(around) * sin(angle), sin(around)))
                coordinates.append(CGPoint(x: u, y: v))
                if ring < rings, side < sides {
                    let a = Int32(ring * (sides + 1) + side), b = a + 1
                    let c = a + Int32(sides + 1), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        put(group, mesh(vertices, normals, coordinates, indices), material, x, y, z, rx: rx, ry: ry)
    }

    // MARK: Local canvas textures

    static func canvas(_ width: Int, _ height: Int, draw: (CGContext, CGFloat, CGFloat) -> Void) -> NSImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context, CGFloat(width), CGFloat(height))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    static func fill(_ context: CGContext, _ hex: String, _ rect: CGRect) {
        context.setFillColor(color(hex).cgColor)
        context.fill(rect)
    }

    static let pirateFlag = canvas(64, 40) { context, width, height in
        fill(context, "#111111", CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color("#eeeeee").cgColor)
        context.fillEllipse(in: CGRect(x: 24, y: 9, width: 16, height: 16))
        context.fill(CGRect(x: 27, y: 22, width: 10, height: 6))
    }

    static let skullSail = canvas(256, 200) { context, width, height in
        fill(context, "#f4ecd8", CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(color("#1a1a1a").cgColor)
        context.setLineWidth(16)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 70, y: 150)); context.addLine(to: CGPoint(x: 186, y: 190))
        context.move(to: CGPoint(x: 186, y: 150)); context.addLine(to: CGPoint(x: 70, y: 190))
        context.strokePath()
        context.setFillColor(color("#1a1a1a").cgColor)
        context.fillEllipse(in: CGRect(x: 82, y: 44, width: 92, height: 92))
        context.fill(CGRect(x: 102, y: 120, width: 52, height: 30))
        context.setFillColor(color("#f4ecd8").cgColor)
        context.fillEllipse(in: CGRect(x: 98, y: 76, width: 24, height: 24))
        context.fillEllipse(in: CGRect(x: 134, y: 76, width: 24, height: 24))
        context.fill(CGRect(x: 118, y: 128, width: 6, height: 14))
        context.fill(CGRect(x: 132, y: 128, width: 6, height: 14))
    }

    static let stripedSail = canvas(240, 170) { context, width, height in
        for stripe in 0..<8 {
            fill(context, stripe.isMultiple(of: 2) ? "#b3261e" : "#f3ece0",
                 CGRect(x: CGFloat(stripe) * width / 8, y: 0, width: width / 8 + 1, height: height))
        }
    }

    static let tornSail = canvas(128, 128) { context, width, height in
        fill(context, "#ffffff", CGRect(x: 0, y: 0, width: width, height: height))
        // Fixed tears keep the same handmade sail when a ship is chosen again.
        var seed: UInt64 = 0xD07C4
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return CGFloat(seed >> 32) / CGFloat(UInt32.max)
        }
        context.setBlendMode(.clear)
        for _ in 0..<14 {
            let x = next() * width, y = height * 0.55 + next() * height * 0.5
            let radius = 6 + next() * 14
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        context.move(to: CGPoint(x: 0, y: height))
        for x in stride(from: 0, through: 128, by: 12) {
            context.addLine(to: CGPoint(x: CGFloat(x), y: height - 8 - next() * 26))
        }
        context.addLine(to: CGPoint(x: width, y: height))
        context.closePath()
        context.fillPath()
    }

    private static func classicSmoke(_ group: SCNNode, x: Double, y: Double, z: Double = 0) {
        let puff = sphere(group, 1.15, 10, material("#c9d1da"), x, y, z)
        puff.opacity = 0.35
        PaperweightShipAnimation.tag(puff, as: .smoke)
    }

    // MARK: Ships

    private static func sailboat() -> SCNNode {
        let group = SCNNode()
        let cream = material("#F1EFE8", roughness: 0.6, doubleSided: true)
        let dark = material("#444441", roughness: 0.5)
        profile(group, [(-13, 2), (13, 2), (9, -4), (-9, -4)], 9,
                material("#D85A30", roughness: 0.45), bevel: 1)
        box(group, 26, 1.4, 10.5, cream, 0, 2.6)
        mast(group, 1, 2, 20, dark)
        flat(group, [(1.6, 21.5), (1.6, 5), (12.5, 5)], cream)
        sphere(group, 2.3, 16, dark, -6, 9.6)
        cylinder(group, 1.1, 1.4, 4.6, dark, -6, 5.4)
        return group
    }

    private static func liner() -> SCNNode {
        let group = SCNNode(), white = material("#f4f1ea"), buff = material("#d6a23e"), black = material("#161616")
        profile(group, [(-15, 4.5), (16, 4.5), (13.5, -3.5), (-14, -3.5)], 10, material("#1d1d1f"))
        box(group, 27.5, 2, 11.7, material("#8e2b22"), -0.2, -2.6)
        box(group, 31, 0.9, 11.7, white, 0.4, 4.7)
        box(group, 22, 3, 8, white, -0.5, 6.6)
        box(group, 16, 2.2, 7, material("#ebe5d8"), -0.5, 9.2)
        let window = material("#2b2b2b")
        for x in stride(from: -9.0, through: 8, by: 1.6) { box(group, 0.6, 0.6, 8.1, window, x, 7) }
        for x in [-7.0, -2.5, 2, 6.5] {
            cylinder(group, 1.3, 1.4, 6.6, buff, x, 13.4, rz: 0.12)
            cylinder(group, 1.33, 1.33, 1.3, black, x - 0.4, 16.6, rz: 0.12)
            classicSmoke(group, x: x - 0.6, y: 20.2)
        }
        let mastMaterial = material("#3a3a3a")
        cylinder(group, 0.22, 0.28, 15, mastMaterial, -13, 11)
        cylinder(group, 0.22, 0.28, 15, mastMaterial, 13.5, 11)
        return group
    }

    private static func submarine() -> SCNNode {
        let group = SCNNode(), hull = material("#36434f", roughness: 0.35, metalness: 0.2), dark = material("#222831")
        cylinder(group, 3.1, 3.1, 22, hull, 0, -0.6, rz: .pi / 2)
        sphere(group, 3.1, 18, hull, 11, -0.6).scale = vector(1.6, 1, 1)
        sphere(group, 3.1, 18, hull, -11, -0.6).scale = vector(1.9, 1, 1)
        box(group, 20, 0.4, 2.2, material("#4b5a67"), 0, 2.55)
        box(group, 6, 5, 2.8, hull, 2, 4.6)
        box(group, 3.8, 0.35, 7, hull, 2.2, 5.2)
        cylinder(group, 0.3, 0.3, 5, dark, 3.2, 9.4)
        box(group, 1.3, 0.3, 0.3, dark, 3.7, 11.8)
        box(group, 2.6, 4.2, 0.35, hull, -16.2, -0.4)
        box(group, 2.6, 0.35, 6, hull, -16, -0.6)
        torus(group, 1, 0.25, rings: 16, sides: 8, dark, -17.4, -0.6, ry: .pi / 2)
        let propeller = SCNNode()
        propeller.position = vector(-18, -0.6, 0)
        group.addChildNode(propeller)
        for angle in [0.0, .pi / 2] {
            box(propeller, 0.3, 4.1, 0.8, material("#b5a06b", metalness: 0.4), 0, 0, 0, rz: 0)
                .eulerAngles.x = CGFloat(angle)
        }
        PaperweightShipAnimation.tag(propeller, as: .propeller)
        let porthole = material("#f2c14e")
        porthole.emission.contents = color("#a07a10")
        for x in stride(from: -6.0, through: 8, by: 3.5) { disc(group, 0.55, 16, porthole, x, 0.4, 3.15) }
        return group
    }

    private static func galleonHull(_ group: SCNNode, _ hull: SCNMaterial, _ rail: SCNMaterial) {
        profile(group, [(-14, 9), (-9.5, 9), (-9.5, 5.5), (10, 5.5), (14.5, 7.5),
                        (12.5, 1), (9, -4), (-11, -4), (-14, 1)], 9.5, hull)
        box(group, 24, 0.6, 11.2, rail, 0, 5.6)
        cylinder(group, 0.28, 0.34, 9, rail, 15.4, 8.4, rz: -1.15)
    }

    private static func galleon() -> SCNNode {
        let group = SCNNode(), hull = material("#1b1b1d", roughness: 0.4), rail = material("#3a2a1c")
        let cloth = material("#262628", roughness: 0.8, doubleSided: true)
        galleonHull(group, hull, rail)
        box(group, 24, 0.7, 11.1, material("#7a5a2e"), 0, 3.4)
        for (x, height) in [(-5.0, 15.5), (1, 17.5), (7, 14.5)] {
            mast(group, x, 4.5, height, rail)
            sail(group, x, 4.5 + height * 0.42, 7, 4.6, cloth)
            sail(group, x, 4.5 + height * 0.76, 5.4, 3.4, cloth)
        }
        plane(group, 3, 1.9, textured(pirateFlag), 2.6, 21.2)
        return group
    }

    private static func ghost() -> SCNNode {
        let group = SCNNode()
        func glow(_ hex: String, _ opacity: CGFloat) -> SCNMaterial {
            let result = material(hex, doubleSided: true)
            PaperweightSceneAssets.setOpacity(opacity, of: result)
            result.emission.contents = color("#1f8a5f")
            result.emission.intensity = 0.7
            result.writesToDepthBuffer = false
            result.blendMode = .alpha
            return result
        }
        let hull = glow("#7fd1ad", 0.45), rail = glow("#5aa585", 0.6), cloth = glow("#cfe8d8", 0.62)
        cloth.transparent.contents = tornSail
        cloth.transparencyMode = .aOne
        galleonHull(group, hull, rail)
        for (x, height) in [(-5.0, 15.5), (1, 17.5), (7, 14.5)] {
            mast(group, x, 4.5, height, rail)
            sail(group, x, 4.5 + height * 0.42, 7, 4.6, cloth)
            sail(group, x, 4.5 + height * 0.76, 5.4, 3.4, cloth)
        }
        return group
    }

    private static func victory() -> SCNNode {
        let group = SCNNode(), black = material("#1b1b1b"), ochre = material("#d4a03a"), wood = material("#5b3d22")
        let cloth = material("#f2ede1", roughness: 0.8, doubleSided: true), port = material("#0d0d0d")
        profile(group, [(-14, 10), (-10, 10), (-10, 7.5), (11, 7.5), (14.5, 7),
                        (12.5, 1), (9, -4), (-11, -4), (-14, 1)], 10, black)
        for y in [1.6, 4.6] {
            box(group, 23.5, 1.1, 11.7, ochre, 0, y)
            for x in stride(from: -9.0, through: 9.5, by: 2.3) { box(group, 0.9, 0.75, 11.9, port, x, y) }
        }
        cylinder(group, 0.28, 0.34, 8, wood, 15.4, 9.6, rz: -1.1)
        for (x, height) in [(-6.0, 13.0), (0.5, 16), (7, 12.5)] {
            mast(group, x, 6, height, wood)
            sail(group, x, 6 + height * 0.35, 7.4, 3.3, cloth)
            sail(group, x, 6 + height * 0.62, 6.1, 2.8, cloth)
            sail(group, x, 6 + height * 0.86, 4.6, 2.1, cloth)
        }
        cylinder(group, 0.15, 0.15, 5, wood, -14.2, 12.5)
        PaperweightShipAnimation.tag(box(group, 2.8, 1.7, 0.1, material("#c8102e"), -12.7, 14.1), as: .flag)
        return group
    }

    private static func treasure() -> SCNNode {
        let group = SCNNode(), red = material("#8a3324"), gold = material("#d6a640", roughness: 0.4, metalness: 0.3)
        let cloth = material("#b5462f", roughness: 0.8, doubleSided: true), batten = material("#3b1f14")
        profile(group, [(-14, 6), (-15.5, 11), (-10.5, 10), (-10.5, 6.5), (11, 6.5),
                        (15, 9), (12.5, 2), (8, -4), (-11, -4), (-14, 0)], 11, red)
        box(group, 22, 0.7, 12.7, gold, 0, 6.6)
        for side in [1.0, -1] {
            disc(group, 1.15, 20, material("#f4f1ea"), 12.2, 4.2, side * 6.3, ry: side > 0 ? 0 : .pi)
            disc(group, 0.52, 16, material("#111111"), 12.4, 4.2, side * 6.35, ry: side > 0 ? 0 : .pi)
        }
        for (x, height) in [(-8.0, 12.0), (-3, 15), (2, 16), (7, 13.5), (11.5, 10)] {
            mast(group, x, 6.5, height, batten)
            let width = height * 0.42, sailHeight = height * 0.6, y = 6.5 + height * 0.52
            plane(group, width, sailHeight, cloth, x + width * 0.45, y, 0.6)
            for index in 0..<5 {
                box(group, width + 0.3, 0.22, 0.3, batten, x + width * 0.45,
                    y - sailHeight / 2 + sailHeight * (Double(index) + 0.5) / 5, 0.68)
            }
        }
        return group
    }

    private static func carrier() -> SCNNode {
        let group = SCNNode(), gray = material("#6d747d", roughness: 0.45), deck = material("#3c434b", roughness: 0.8)
        let white = material("#e9e9e9", roughness: 0.8), island = material("#7d858e"), aircraft = material("#a9b1ba")
        profile(group, [(-15, 3), (16.5, 3), (13, -3.5), (-13.5, -3.5)], 10, gray)
        box(group, 33, 0.9, 13, deck, 0.6, 3.9)
        box(group, 28, 0.06, 0.35, white, 0, 4.38)
        box(group, 15, 0.06, 0.35, white, -4, 4.38, 2.2, ry: -0.18)
        box(group, 4.4, 5, 2.4, island, 4, 6.8, -5)
        box(group, 3.4, 2, 2.2, island, 4.3, 10.2, -5)
        cylinder(group, 0.2, 0.25, 5, material("#444444"), 4.4, 13.6, -5)
        let radar = SCNNode()
        radar.position = vector(4.4, 16.4, -5)
        group.addChildNode(radar)
        box(radar, 4, 0.9, 0.35, material("#d6dfdf"), 0, 0)
        PaperweightShipAnimation.tag(radar, as: .radar)
        for (x, z) in [(-11.0, -2.5), (-7.5, 1.8), (9, 2.4), (12.5, -1.8), (-1.5, 3.6)] {
            box(group, 3.2, 0.55, 0.75, aircraft, x, 4.75, z)
            box(group, 1.1, 0.25, 3.6, aircraft, x + 0.2, 4.7, z)
            box(group, 0.8, 0.25, 1.7, aircraft, x - 1.4, 4.7, z)
        }
        return group
    }

    private static func cartoonPirate() -> SCNNode {
        let group = SCNNode(), outline = NSBezierPath()
        outline.move(to: NSPoint(x: -12, y: 5)); outline.line(to: NSPoint(x: 12, y: 5))
        outline.curve(to: NSPoint(x: 0, y: -5.5), controlPoint1: NSPoint(x: 12 + 1 / 3.0, y: -2),
                      controlPoint2: NSPoint(x: 25 / 3.0, y: -5.5))
        outline.curve(to: NSPoint(x: -12, y: 5), controlPoint1: NSPoint(x: -25 / 3.0, y: -5.5),
                      controlPoint2: NSPoint(x: -12 - 1 / 3.0, y: -2))
        outline.close()
        extrude(group, outline, 10, material("#a5612f"), bevel: 1.2)
        let brown = material("#5c3417")
        box(group, 24, 0.9, 12.7, material("#f2c14e"), 0, 3.3)
        box(group, 26, 0.8, 12.7, brown, 0, 5.3)
        mast(group, 0, 5, 16, brown)
        plane(group, 11, 8.5, textured(skullSail, roughness: 0.75), 0.2, 12.6, 0.5)
        box(group, 12.5, 0.45, 0.45, brown, 0.2, 17)
        cylinder(group, 1.6, 1.2, 1.4, brown, 0, 20.2)
        PaperweightShipAnimation.tag(box(group, 2.6, 1.5, 0.12, material("#111111"), 1.6, 21.6), as: .flag)
        sphere(group, 1.4, 16, material("#f2c14e", roughness: 0.35, metalness: 0.3), 13.6, 4.3)
        return group
    }

    private static func viking() -> SCNNode {
        let group = SCNNode(), wood = material("#8a5a34")
        profile(group, [(-10, -2), (10, -2), (12.8, 2), (13.6, 6), (14.6, 9.6), (13.4, 10.2),
                        (12.4, 6.4), (11.6, 3.4), (-11.6, 3.4), (-12.4, 6.4), (-13.4, 10.2),
                        (-14.6, 9.6), (-13.6, 6), (-12.8, 2)], 7, wood, bevel: 0.5)
        let shieldColors = ["#c0392b", "#f2c14e", "#2e6da4"]
        var shieldIndex = 0
        for x in stride(from: -9.0, through: 9.1, by: 2.25) {
            for side in [1.0, -1] {
                disc(group, 1.15, 18, material(shieldColors[shieldIndex % 3], doubleSided: true),
                     x, 3.1, side * 4.05, ry: side > 0 ? 0 : .pi)
                disc(group, 0.35, 10, material("#cfcfcf", metalness: 0.5),
                     x, 3.1, side * 4.1, ry: side > 0 ? 0 : .pi)
            }
            shieldIndex += 1
        }
        let darkWood = material("#5a3a20")
        mast(group, 0, 3.4, 16, darkWood)
        box(group, 13, 0.4, 0.4, darkWood, 0, 17)
        sail(group, 0, 12.6, 12, 8.5, textured(stripedSail, roughness: 0.8),
             brace: 0, bulge: 1.2, columns: 6, z: 0.4)
        for x in [-7.0, -3, 1, 5, 9] {
            for side in [-1.0, 1] {
                let oar = SCNNode()
                oar.position = vector(x, 2.4, side * 3.8)
                group.addChildNode(oar)
                box(oar, 0.25, 0.25, 4.3, darkWood, 0, -0.2, side * 1.7)
                box(oar, 0.7, 0.2, 1.8, wood, 0, -0.2, side * 4.2)
                PaperweightShipAnimation.tag(oar, as: .oar)
            }
        }
        let horn = SCNCone(topRadius: 0, bottomRadius: 0.7, height: 1.6)
        horn.radialSegmentCount = 10
        put(group, horn, material("#d6a640", metalness: 0.3), 14, 10.9, rz: -0.5)
        return group
    }

    private static func steamer() -> SCNNode {
        let group = SCNNode(), white = material("#f1efe8"), red = material("#b5332e"), black = material("#1e1e1e")
        profile(group, [(-11, 3), (13, 3), (11, -3), (-10, -3)], 9, white)
        box(group, 18, 3, 8, white, 1, 5.6)
        box(group, 11, 2.4, 6.5, material("#ebe6da"), 2, 8.3)
        box(group, 4, 2, 4, material("#e2dccd"), 5, 10.5)
        let window = material("#2a2f38")
        for x in stride(from: -6.0, through: 9, by: 1.5) { box(group, 0.55, 0.9, 8.1, window, x, 5.9) }
        for z in [-2.0, 2] {
            cylinder(group, 0.75, 0.85, 10, black, 8, 13, z)
            torus(group, 1, 0.25, rings: 12, sides: 6, black, 8, 18, z, rx: .pi / 2)
            classicSmoke(group, x: 8, y: 21.3, z: z)
        }
        let wheel = SCNNode()
        wheel.name = "paddle-wheel"
        PaperweightShipAnimation.tag(wheel, as: .wheel)
        wheel.position = vector(-13.6, 2.2, 0)
        group.addChildNode(wheel)
        for z in [-4.0, 4] { torus(wheel, 3.6, 0.32, rings: 28, sides: 8, red, 0, 0, z) }
        for index in 0..<10 {
            let angle = Double(index) / 10 * 2 * .pi
            for z in [-4.0, 4] { box(wheel, 0.3, 7.2, 0.22, red, 0, 0, z, rz: angle) }
            box(wheel, 0.28, 1.5, 8, red, cos(angle) * 3.3, sin(angle) * 3.3, rz: angle - .pi / 2)
        }
        cylinder(wheel, 0.45, 0.45, 8.6, black, 0, 0, rx: .pi / 2)
        return group
    }

    private static func tugboat() -> SCNNode {
        let group = SCNNode(), red = material("#c23b2c"), white = material("#f1efe8"), black = material("#1e1e1e")
        profile(group, [(-11, 3), (10, 4), (12, 4.6), (9.5, -3), (-10, -3)], 9, red)
        box(group, 22, 1, 10.7, black, 0, 2.6)
        box(group, 9, 4, 6.5, white, -1.5, 6.6)
        box(group, 5.5, 3.2, 5.5, white, 0.5, 10.2)
        let window = material("#24323d")
        for x in [-1.3, 0.5, 2.3] { box(group, 1.2, 1.1, 5.7, window, x, 10.6) }
        cylinder(group, 1.1, 1.2, 5, material("#f2c14e"), -5.5, 10.6)
        cylinder(group, 1.13, 1.13, 1, black, -5.5, 13.4)
        classicSmoke(group, x: -5.5, y: 17.1)
        cylinder(group, 0.14, 0.14, 4, material("#444444"), 0.5, 13.8)
        for x in stride(from: -8.0, through: 8, by: 4) { torus(group, 0.9, 0.35, rings: 16, sides: 8, black, x, 1.3, 5.35) }
        return group
    }
}
