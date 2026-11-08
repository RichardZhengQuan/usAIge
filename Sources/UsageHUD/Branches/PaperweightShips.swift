import AppKit
import SceneKit
import simd

enum PaperweightShipKind: String, CaseIterable, Identifiable, Sendable {
    case sailboat, liner, sub, galleon, ghost, victory, treasure, carrier, cartoon, viking, steamer, tug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sailboat: "Sailboat"
        case .liner: "Titanic"
        case .sub: "Submarine"
        case .galleon: "Pirate galleon"
        case .ghost: "Flying Dutchman"
        case .victory: "HMS Victory"
        case .treasure: "Zheng He treasure ship"
        case .carrier: "Aircraft carrier"
        case .cartoon: "Cartoon pirate ship"
        case .viking: "Viking longship"
        case .steamer: "Paddle steamer"
        case .tug: "Tugboat"
        }
    }
}

/// The prototype's ships keep their own small coordinate system, so changing
/// a ship leaves the water's position and spring motion alone.
@available(macOS 14.0, *)
@MainActor
enum PaperweightShipFactory {
    static func make(_ kind: PaperweightShipKind) -> SCNNode {
        let ship: SCNNode
        switch kind {
        case .sailboat: ship = sailboat()
        case .liner: ship = detailedLiner()
        case .sub: ship = detailedSubmarine()
        case .galleon: ship = detailedGalleon()
        case .ghost: ship = detailedGhost()
        case .victory: ship = detailedVictory()
        case .treasure: ship = detailedTreasure()
        case .carrier: ship = detailedCarrier()
        case .cartoon: ship = cartoonPirate()
        case .viking: ship = detailedViking()
        case .steamer: ship = detailedSteamer()
        case .tug: ship = detailedTugboat()
        }
        ship.name = kind.rawValue
        let nominalScale = PaperweightConstants.unitsPerPixel * PaperweightConstants.boatScale
        let scale = CGFloat(nominalScale * clearanceScale(for: ship, nominalScale: nominalScale))
        ship.scale = SCNVector3(scale, scale, scale)
        return ship
    }

    /// Extra rigging and longer bows must still fit the toy at its full roll.
    /// Scale around the original waterline rather than moving the hull or
    /// changing the simulation's reserved mast, keel and side clearances.
    private static func clearanceScale(for ship: SCNNode, nominalScale: Double) -> Double {
        var fraction = 1.0
        let side = PaperweightConstants.boatMargin * PaperweightConstants.unitsPerPixel / nominalScale
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel / nominalScale
        let keel = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel / nominalScale
        let depth = PaperweightConstants.ZF / nominalScale
        let roll = PaperweightConstants.maximumRoll
        ship.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let bounds = geometry.boundingBox
            for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let point = node.convertPosition(SCNVector3(x, y, z), to: ship)
                    let px = Double(point.x), py = Double(point.y), pz = abs(Double(point.z))
                    if pz > 0 { fraction = min(fraction, depth / pz) }
                    var angles = [-roll, 0, roll]
                    for extremum in [atan2(-py, px), atan2(px, py)] {
                        for halfTurn in -2...2 {
                            let angle = extremum + Double(halfTurn) * .pi
                            if abs(angle) <= roll { angles.append(angle) }
                        }
                    }
                    for angle in angles {
                        let across = abs(px * cos(angle) - py * sin(angle))
                        let vertical = px * sin(angle) + py * cos(angle)
                        if across > 0 { fraction = min(fraction, side / across) }
                        if vertical > 0 { fraction = min(fraction, top / vertical) }
                        if vertical < 0 { fraction = min(fraction, keel / -vertical) }
                    }
                }
            } }
        }
        return fraction < 1 ? fraction * 0.998 : 1
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
        put(group, SCNShape(path: path(points), extrusionDepth: 0), material, x, y, z)
    }

    static func box(
        _ group: SCNNode, _ width: Double, _ height: Double, _ depth: Double,
        _ material: SCNMaterial, _ x: Double, _ y: Double, _ z: Double = 0,
        ry: Double = 0, rz: Double = 0
    ) {
        let geometry = SCNBox(width: width, height: height, length: depth,
                              chamferRadius: min(0.18, min(width, height, depth) * 0.12))
        geometry.chamferSegmentCount = 2
        put(group, geometry, material, x, y, z, ry: ry, rz: rz)
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
        put(group, SCNPlane(width: width, height: height), material, x, y, z)
    }

    static func mesh(
        _ vertices: [SCNVector3], _ normals: [SCNVector3], _ coordinates: [CGPoint], _ indices: [Int32]
    ) -> SCNGeometry {
        SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: coordinates),
        ], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Smooth shading follows the actual cloth/hull surface, including its
    /// curved outline, rather than lighting every vertex as a flat card.
    private static func smoothMesh(_ vertices: [SCNVector3], _ coordinates: [CGPoint],
                                   _ indices: [Int32]) -> SCNGeometry {
        var normals = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
        let positions = vertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[triangle]), b = Int(indices[triangle + 1]), c = Int(indices[triangle + 2])
            let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            for index in [a, b, c] { normals[index] += normal }
        }
        return mesh(vertices, normals.map {
            let normal = simd_length_squared($0) > 0.000001 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1)
            return vector(Double(normal.x), Double(normal.y), Double(normal.z))
        }, coordinates, indices)
    }

    /// Rounded bilges and a real bow taper give the small boats depth when
    /// they yaw. Stations are (length, sheer, keel, half beam), in toy units.
    private static func smallBoatHull(
        _ group: SCNNode, stations: [(Double, Double, Double, Double)],
        hull: SCNMaterial, deck: SCNMaterial
    ) {
        let sections = 18
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = [], indices: [Int32] = []
        for (index, station) in stations.enumerated() {
            for section in 0...sections {
                let angle = Double(section) / Double(sections) * .pi
                vertices.append(vector(station.0, station.1 - (station.1 - station.2) * sin(angle),
                                       station.3 * cos(angle)))
                coordinates.append(CGPoint(x: Double(index) / Double(stations.count - 1),
                                           y: Double(section) / Double(sections)))
                if index < stations.count - 1, section < sections {
                    let a = Int32(index * (sections + 1) + section), b = a + 1
                    let c = a + Int32(sections + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        put(group, smoothMesh(vertices, coordinates, indices), hull)
        // The deck follows the same tapered perimeter instead of overhanging
        // it with a rectangular slab at the bow and stern.
        var deckVertices: [SCNVector3] = [], deckUV: [CGPoint] = [], deckIndices: [Int32] = []
        for (index, station) in stations.enumerated() {
            for side in [-1.0, 1] {
                deckVertices.append(vector(station.0, station.1 + 0.04, side * station.3))
                deckUV.append(CGPoint(x: Double(index) / Double(stations.count - 1), y: (side + 1) / 2))
            }
            if index < stations.count - 1 {
                let a = Int32(index * 2)
                deckIndices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        put(group, smoothMesh(deckVertices, deckUV, deckIndices), deck)
        for (index, station) in stations.enumerated() where index == 0 || index == stations.count - 1 {
            var cap = [vector(station.0, station.1, 0)]
            for section in 0...sections {
                let angle = Double(section) / Double(sections) * .pi
                cap.append(vector(station.0, station.1 - (station.1 - station.2) * sin(angle), station.3 * cos(angle)))
            }
            var triangles: [Int32] = []
            for section in 1...sections {
                triangles.append(contentsOf: index == 0 ? [0, Int32(section + 1), Int32(section)]
                    : [0, Int32(section), Int32(section + 1)])
            }
            put(group, smoothMesh(cap, Array(repeating: .zero, count: cap.count), triangles), hull)
        }
    }

    static func sail(
        _ group: SCNNode, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ material: SCNMaterial, brace: Double = 0.5, bulge: Double? = nil,
        columns: Int = 12, z: Double = 0
    ) {
        let bow = bulge ?? width * 0.13
        var vertices: [SCNVector3] = []
        var coordinates: [CGPoint] = []
        var indices: [Int32] = []
        let rows = 6
        for row in 0...rows {
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let v = Double(row) / Double(rows)
                let across = u * 2 - 1
                let fullness = sin(.pi * (0.15 + v * 0.7))
                let foot = (1 - v) * height * 0.08 * across * across
                let taper = 0.92 + 0.08 * v - 0.07 * sin(.pi * v)
                vertices.append(vector((u - 0.5) * width * taper, (v - 0.5) * height + foot,
                                       (1 - across * across) * bow * fullness))
                coordinates.append(CGPoint(x: u, y: 1 - v))
                if row < rows, column < columns {
                    let a = Int32(row * (columns + 1) + column)
                    let b = a + 1, c = a + Int32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        put(group, smoothMesh(vertices, coordinates, indices), material, x, y, z, ry: brace)
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

    static func rail(_ group: SCNNode, from start: (Double, Double, Double),
                     to end: (Double, Double, Double), radius: Double = 0.08, material: SCNMaterial) {
        let a = SIMD3<Float>(Float(start.0), Float(start.1), Float(start.2))
        let b = SIMD3<Float>(Float(end.0), Float(end.1), Float(end.2))
        let direction = b - a
        let length = simd_length(direction)
        guard length > 0.0001 else { return }
        let geometry = SCNCylinder(radius: radius, height: Double(length))
        geometry.radialSegmentCount = 8
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction / length)
        node.castsShadow = false
        group.addChildNode(node)
    }

    static func railing(_ group: SCNNode, fromX: Double, toX: Double, y: Double, z: Double,
                        spacing: Double = 2, material: SCNMaterial) {
        guard toX > fromX else { return }
        let sections = max(1, Int(ceil((toX - fromX) / max(1, spacing))))
        for index in 0...sections {
            let x = fromX + (toX - fromX) * Double(index) / Double(sections)
            rail(group, from: (x, y, z), to: (x, y + 0.8, z), radius: 0.055, material: material)
        }
        for height in [0.4, 0.8] {
            rail(group, from: (fromX, y + height, z), to: (toX, y + height, z),
                 radius: 0.055, material: material)
        }
    }

    static func portholes(_ group: SCNNode, xs: [Double], y: Double, z: Double,
                         radius: Double = 0.22, material: SCNMaterial) {
        let rim = self.material("#B9A06E", roughness: 0.38, metalness: 0.55)
        let highlight = self.material("#A2C2CB", roughness: 0.25)
        let side = z < 0 ? -1.0 : 1.0
        for x in xs {
            disc(group, radius * 1.2, 16, rim, x, y, z, ry: side < 0 ? .pi : 0)
            disc(group, radius * 0.83, 16, material, x, y, z + side * 0.025, ry: side < 0 ? .pi : 0)
            rail(group, from: (x - radius * 0.4, y + radius * 0.4, z + side * 0.04),
                 to: (x + radius * 0.25, y + radius * 0.4, z + side * 0.04), radius: radius * 0.06,
                 material: highlight)
        }
    }

    private static let detailTextures: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    private static func detailTexture(key: String, width: Int, height: Int,
                                      draw: (CGContext, CGFloat, CGFloat) -> Void) -> NSImage {
        if let existing = detailTextures.object(forKey: key as NSString) { return existing }
        let image = canvas(width, height, draw: draw)
        detailTextures.setObject(image, forKey: key as NSString, cost: width * height * 4)
        return image
    }

    static func woodMaterial(hex: String) -> SCNMaterial {
        let image = detailTexture(key: "wood-\(hex)", width: 256, height: 128) { context, width, height in
            fill(context, hex, CGRect(x: 0, y: 0, width: width, height: height))
            for row in 0..<12 {
                let y = CGFloat(row) * height / 12
                context.setFillColor(NSColor.white.withAlphaComponent(row.isMultiple(of: 3) ? 0.08 : 0.025).cgColor)
                context.fill(CGRect(x: 0, y: y, width: width, height: height / 12 - 1))
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.26).cgColor)
                context.setLineWidth(0.9)
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
                let stagger = CGFloat((row * 37) % 74)
                for joint in 0..<4 {
                    let x = CGFloat(joint) * 74 + stagger
                    context.move(to: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x, y: y + height / 12))
                }
                context.strokePath()
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.07).cgColor)
                context.setLineWidth(0.6)
                for grain in 1...2 {
                    let line = y + CGFloat(grain) * 3
                    context.move(to: CGPoint(x: 0, y: line))
                    context.addCurve(to: CGPoint(x: width, y: line + 1), control1: CGPoint(x: width * 0.3, y: line - 2),
                                     control2: CGPoint(x: width * 0.7, y: line + 2))
                    context.strokePath()
                }
            }
        }
        return textured(image, roughness: 0.72)
    }

    static func metalHullMaterial(hex: String) -> SCNMaterial {
        let image = detailTexture(key: "steel-\(hex)", width: 256, height: 128) { context, width, height in
            fill(context, hex, CGRect(x: 0, y: 0, width: width, height: height))
            for row in 0..<6 {
                let y = CGFloat(row) * height / 6
                context.setFillColor(NSColor.white.withAlphaComponent(row.isMultiple(of: 2) ? 0.025 : 0.055).cgColor)
                context.fill(CGRect(x: 0, y: y, width: width, height: height / 6 - 1))
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.20).cgColor)
                context.setLineWidth(0.7)
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
                context.strokePath()
                for rivet in 0..<24 {
                    let x = CGFloat(rivet) * width / 24
                    context.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
                    context.fillEllipse(in: CGRect(x: x, y: y + 2, width: 1.1, height: 1.1))
                }
            }
        }
        let result = textured(image, roughness: 0.5)
        result.metalness.contents = 0.15
        return result
    }

    static func sailCloth(hex: String) -> SCNMaterial {
        let image = detailTexture(key: "cloth-\(hex)", width: 256, height: 192) { context, width, height in
            fill(context, hex, CGRect(x: 0, y: 0, width: width, height: height))
            let colors = [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.clear.cgColor,
                          NSColor.black.withAlphaComponent(0.12).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
            }
            context.setLineWidth(0.8)
            for panel in 1..<8 {
                let x = CGFloat(panel) * width / 8
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height)); context.strokePath()
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
                context.setLineDash(phase: 0, lengths: [2, 3])
                context.move(to: CGPoint(x: x + 2, y: 0)); context.addLine(to: CGPoint(x: x + 2, y: height)); context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        }
        return textured(image, roughness: 0.9)
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

    // MARK: Small sailing ships

    static func sailboat() -> SCNNode {
        let group = SCNNode()
        let ivory = material("#ECECE3", roughness: 0.52)
        let navy = metalHullMaterial(hex: "#2F4E65")
        let teak = woodMaterial(hex: "#AA8152")
        let steel = material("#9DA9AA", roughness: 0.34, metalness: 0.55)
        let rope = material("#75634C", roughness: 0.92)
        let glass = material("#274351", roughness: 0.24, metalness: 0.22)
        let stations: [(Double, Double, Double, Double)] = [
            (-13.8, 2.65, 0.1, 2.6), (-12, 2.65, -1.4, 3.55), (-9, 2.7, -2.8, 4.05),
            (-5, 2.8, -3.6, 4.35), (0, 2.95, -3.85, 4.4), (5, 3.15, -3.6, 3.95),
            (9, 3.4, -2.65, 2.8), (12.3, 3.65, -0.9, 1.25), (15, 3.9, 1.9, 0.06),
        ]
        smallBoatHull(group, stations: stations, hull: navy, deck: teak)
        let coachroof = NSBezierPath()
        coachroof.move(to: NSPoint(x: -6.5, y: 3.0))
        coachroof.line(to: NSPoint(x: 5.0, y: 3.15))
        coachroof.curve(to: NSPoint(x: 2.3, y: 5.2), controlPoint1: NSPoint(x: 4.5, y: 4.35), controlPoint2: NSPoint(x: 3.7, y: 5.2))
        coachroof.curve(to: NSPoint(x: -4.7, y: 5.15), controlPoint1: NSPoint(x: 0, y: 5.55), controlPoint2: NSPoint(x: -3.9, y: 5.45))
        coachroof.close()
        extrude(group, coachroof, 5.8, ivory, bevel: 0.24)
        for z in [-3.12, 3.12] {
            for x in [-4.3, -2.3, -0.3, 1.7] {
                box(group, 1.45, 0.65, 0.07, glass, x, 4.5, z > 0 ? 2.94 : -2.94, rz: 0.015)
            }
            let side = z > 0 ? 1.0 : -1.0
            for index in 0..<stations.count - 1 {
                let a = stations[index], b = stations[index + 1]
                for offset in [0.05, 0.95] {
                    rail(group, from: (a.0, a.1 + offset, side * a.3),
                         to: (b.0, b.1 + offset, side * b.3), radius: offset < 0.1 ? 0.09 : 0.042,
                         material: offset < 0.1 ? ivory : steel)
                }
                if index.isMultiple(of: 2) {
                    rail(group, from: (a.0, a.1, side * a.3), to: (a.0, a.1 + 0.95, side * a.3),
                         radius: 0.055, material: steel)
                }
            }
        }
        // An inset cockpit, raised coamings and a companionway read as an
        // inhabitable deck rather than another block on top of the hull.
        box(group, 4.3, 0.12, 3.1, material("#493F34"), -8.8, 2.92)
        for side in [-1.0, 1] { box(group, 4.8, 0.65, 0.48, ivory, -8.8, 3.15, side * 1.85) }
        box(group, 0.4, 0.9, 3.1, teak, -6.8, 3.4)
        box(group, 0.1, 0.7, 1.6, glass, -6.56, 3.85)
        box(group, 2.0, 0.16, 1.5, steel, -2.5, 5.44)
        box(group, 1.6, 0.18, 1.14, glass, -2.5, 5.55)
        torus(group, 0.67, 0.075, rings: 24, sides: 6, steel, -9, 4.5, 0.5)
        for index in 0..<6 {
            let angle = Double(index) / 6 * .pi * 2
            rail(group, from: (-9, 4.5, 0.5), to: (-9 + cos(angle) * 0.64, 4.5 + sin(angle) * 0.64, 0.5),
                 radius: 0.025, material: steel)
        }
        rail(group, from: (-9, 3.0, 0.3), to: (-9, 4.5, 0.5), radius: 0.10, material: steel)
        rail(group, from: (1.3, 3.6, 0), to: (1.3, 23.4, 0), radius: 0.16, material: steel)
        yachtSail(group, mastX: 1.55, top: 22.8, width: -12.0, height: 18.0,
                  cloth: sailCloth(hex: "#F3EEDD"), z: 0.42)
        yachtSail(group, mastX: 1.85, top: 20.8, width: 10.5, height: 15.8,
                  cloth: sailCloth(hex: "#DFE7E1"), z: -0.18)
        rail(group, from: (-10.4, 4.5, 0.3), to: (1.5, 4.8, 0.3), radius: 0.13, material: steel)
        for anchor in [(-13.0, 3.6, 0.0), (14.0, 3.8, 0.0), (0.0, 3.5, -4.0), (0.0, 3.5, 4.0)] {
            rail(group, from: (1.3, 23.3, 0), to: anchor, radius: 0.045, material: rope)
        }
        flat(group, [(1.4, 23.1), (4.0, 22.6), (1.4, 22.3)], material("#B44D35", doubleSided: true), 0, 0, 0.12)
        for x in [-11.5, 10.5] {
            for side in [-1.0, 1] {
                cylinder(group, 0.15, 0.2, 0.3, steel, x, 3.4, side * 2.2)
                rail(group, from: (x - 0.45, 3.6, side * 2.2), to: (x + 0.45, 3.6, side * 2.2),
                     radius: 0.075, material: steel)
            }
        }
        for side in [-1.0, 1] {
            cylinder(group, 0.28, 0.32, 0.6, steel, -5.8, 3.55, side * 3.1)
            rail(group, from: (-5.8, 3.9, side * 3.1), to: (-5.2, 3.9, side * 3.1), radius: 0.065, material: steel)
        }
        profile(group, [(-12.5, 0.6), (-11.0, 0.6), (-11.4, -3.3), (-12.4, -2.2)], 0.38, navy, bevel: 0.12)
        return group
    }

    private static func yachtSail(_ group: SCNNode, mastX: Double, top: Double, width: Double,
                                  height: Double, cloth: SCNMaterial, z: Double) {
        let subdivisions = 12
        var vertices: [SCNVector3] = []
        var coordinates: [CGPoint] = [], indices: [Int32] = []
        func point(_ u: Double, _ v: Double) -> SCNVector3 {
            let reach = v + sin(.pi * v) * 0.065
            let foot = pow(v, 8) * sin(.pi * u) * 0.45
            return vector(mastX + u * reach * width, top - v * height + foot,
                          z + sin(.pi * u) * sin(.pi * v * 0.87) * 1.3 + u * v * 0.22)
        }
        for row in 0...subdivisions {
            let v = Double(row) / Double(subdivisions)
            for column in 0...subdivisions {
                let u = Double(column) / Double(subdivisions)
                vertices.append(point(u, v))
                coordinates.append(CGPoint(x: u, y: v))
                if row < subdivisions, column < subdivisions {
                    let a = Int32(row * (subdivisions + 1) + column)
                    let b = a + 1, c = a + Int32(subdivisions + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        put(group, smoothMesh(vertices, coordinates, indices), cloth)
        let edging = material("#C3BBA2", roughness: 0.95)
        for edge in [0.0, 1] {
            for segment in 0..<subdivisions {
                let a = point(edge, Double(segment) / Double(subdivisions))
                let b = point(edge, Double(segment + 1) / Double(subdivisions))
                rail(group, from: (Double(a.x), Double(a.y), Double(a.z)),
                     to: (Double(b.x), Double(b.y), Double(b.z)), radius: 0.035, material: edging)
            }
        }
        for v in [0.68, 0.82] {
            for u in [0.25, 0.5, 0.75] {
                let p = point(u, v)
                rail(group, from: (Double(p.x), Double(p.y), Double(p.z) + 0.025),
                     to: (Double(p.x), Double(p.y) - 0.24, Double(p.z) + 0.025), radius: 0.025, material: edging)
            }
        }
    }

    static func cartoonPirate() -> SCNNode {
        let group = SCNNode()
        let timber = woodMaterial(hex: "#A16436"), darkWood = woodMaterial(hex: "#5F3B25")
        let brass = material("#D4AB55", roughness: 0.38, metalness: 0.45)
        let port = material("#27333A", roughness: 0.32)
        let stations: [(Double, Double, Double, Double)] = [
            (-11.7, 6.5, 0, 3.3), (-10.4, 5.8, -2.3, 4.3), (-7, 5.1, -4.5, 5.0),
            (-3, 4.9, -5.2, 5.2), (2, 5.0, -5.15, 5.15), (6.5, 5.3, -4.4, 4.6),
            (9.8, 6.2, -2.4, 3.25), (12.8, 7.2, 0.5, 0.4),
        ]
        smallBoatHull(group, stations: stations, hull: timber, deck: darkWood)
        for side in [-1.0, 1] {
            for index in 0..<stations.count - 1 {
                let a = stations[index], b = stations[index + 1]
                for (offset, radius, surface) in [(0.12, 0.17, darkWood), (-1.4, 0.12, brass), (0.95, 0.095, darkWood)] {
                    rail(group, from: (a.0, a.1 + offset, side * a.3),
                         to: (b.0, b.1 + offset, side * b.3), radius: radius, material: surface)
                }
                rail(group, from: (a.0, a.1, side * a.3), to: (a.0, a.1 + 0.95, side * a.3),
                     radius: 0.11, material: darkWood)
            }
            for (x, z) in [(-7.2, 4.55), (-3.0, 4.87), (1.4, 4.85), (5.7, 4.36)] {
                // Project the whole collar through the rounded hull. Flat
                // discs alone were occluded into crescents by the bilge.
                cylinder(group, 0.74, 0.74, 0.48, darkWood, x, 1.45, side * (z + 0.13), rx: .pi / 2)
                portholes(group, xs: [x], y: 1.45, z: side * (z + 0.38), radius: 0.63, material: port)
            }
        }
        profile(group, [(-10.4, 5.7), (-4.6, 5.2), (-4.6, 8.5), (-10.4, 8.8)], 8.2, timber, bevel: 0.26)
        let roof = NSBezierPath()
        roof.move(to: NSPoint(x: -11.0, y: 8.65))
        roof.curve(to: NSPoint(x: -4.0, y: 8.5), controlPoint1: NSPoint(x: -9.1, y: 9.8), controlPoint2: NSPoint(x: -5.8, y: 9.6))
        roof.line(to: NSPoint(x: -4.0, y: 8.15))
        roof.curve(to: NSPoint(x: -11.0, y: 8.3), controlPoint1: NSPoint(x: -5.8, y: 9.15), controlPoint2: NSPoint(x: -9.1, y: 9.35))
        roof.close()
        extrude(group, roof, 9.2, darkWood, bevel: 0.12)
        for side in [-1.0, 1] {
            for x in [-9, -7.5, -6] {
                box(group, 0.9, 1.15, 0.12, brass, x, 7.45, side * 4.15)
                box(group, 0.68, 0.91, 0.13, material("#59787A", roughness: 0.28), x, 7.45, side * 4.23)
                rail(group, from: (x, 7.0, side * 4.32), to: (x, 7.9, side * 4.32), radius: 0.045, material: brass)
                rail(group, from: (x - 0.34, 7.45, side * 4.32), to: (x + 0.34, 7.45, side * 4.32), radius: 0.045, material: brass)
            }
            for x in [-10, -5.2] {
                rail(group, from: (x, 5.1, side * 3.8), to: (x, 6.0, side * 4.6), radius: 0.14, material: brass)
            }
        }
        mast(group, 0, 5, 17.7, darkWood)
        sail(group, 0.2, 12.7, 11.4, 8.5, textured(skullSail, roughness: 0.8), brace: 0.12, bulge: 1.15, z: 0.35)
        rail(group, from: (-6.2, 17, 0), to: (6.5, 17, 0), radius: 0.18, material: darkWood)
        cylinder(group, 1.6, 1.15, 1.2, timber, 0, 20.0)
        torus(group, 1.6, 0.13, rings: 24, sides: 6, brass, 0, 20.6, rx: .pi / 2)
        // A rippled flag, instead of a rigid rectangular card.
        var flagVertices: [SCNVector3] = [], flagUV: [CGPoint] = [], flagIndices: [Int32] = []
        for row in 0...3 {
            for column in 0...12 {
                let u = Double(column) / 12, v = Double(row) / 3
                flagVertices.append(vector(0.4 + u * 3.0, 21.2 + v * 1.7 + sin(u * .pi * 2) * u * 0.13,
                                           0.2 + sin(u * .pi * 2.2) * u * 0.6))
                flagUV.append(CGPoint(x: u, y: 1 - v))
                if row < 3, column < 12 {
                    let a = Int32(row * 13 + column), c = a + 13
                    flagIndices.append(contentsOf: [a, a + 1, c, a + 1, c + 1, c])
                }
            }
        }
        put(group, smoothMesh(flagVertices, flagUV, flagIndices), textured(pirateFlag, roughness: 0.9))
        rail(group, from: (0, 22.2, 0), to: (-11, 6, -4.5), radius: 0.065, material: darkWood)
        rail(group, from: (0, 22.2, 0), to: (12, 5.7, 0), radius: 0.065, material: darkWood)
        rail(group, from: (-1.0, 6.3, 0), to: (17, 8.8, 0), radius: 0.20, material: darkWood)
        rail(group, from: (0, 19, 0), to: (16.7, 8.8, 0), radius: 0.055, material: darkWood)
        sphere(group, 1.0, 20, brass, 13.1, 5.9)
        for z in [-2.8, 2.8] {
            box(group, 1.1, 0.4, 1.1, darkWood, 7.0, 5.7, z)
        }
        // Chunky fittings preserve the playful silhouette at rail size.
        rail(group, from: (9.5, 4.4, 3.65), to: (9.5, 1.9, 3.65), radius: 0.14, material: brass)
        rail(group, from: (8.6, 4.0, 3.65), to: (10.4, 4.0, 3.65), radius: 0.13, material: brass)
        for side in [-1.0, 1] {
            rail(group, from: (9.5, 1.9, 3.65), to: (9.5 + side * 1.2, 2.65, 3.65), radius: 0.16, material: brass)
            sphere(group, 0.25, 12, brass, 9.5 + side * 1.2, 2.65, 3.65)
        }
        profile(group, [(-11.6, 1.3), (-13.0, 1.5), (-12.8, -2.7), (-11.1, -3.1)], 0.7, darkWood, bevel: 0.2)
        torus(group, 0.75, 0.12, rings: 20, sides: 6, brass, -3.3, 6.6, 0.2)
        for index in 0..<6 {
            let angle = Double(index) / 6 * .pi * 2
            rail(group, from: (-3.3, 6.6, 0.2), to: (-3.3 + cos(angle), 6.6 + sin(angle), 0.2),
                 radius: 0.07, material: darkWood)
        }
        return group
    }
}
