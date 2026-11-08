import AppKit
import SceneKit
import simd

/// Curved construction shared by the fleet. Detail is baked into small meshes,
/// so seams and planking do not require a renderer or a timer of their own.
@available(macOS 14.0, *)
@MainActor
extension PaperweightShipFactory {
    private static var plankTextures: [String: NSImage] = [:]

    static func plankedWood(_ hex: String) -> SCNMaterial {
        let image: NSImage
        if let cached = plankTextures[hex] { image = cached } else {
            image = canvas(256, 128) { context, width, height in
                fill(context, hex, CGRect(x: 0, y: 0, width: width, height: height))
                for row in 0..<8 {
                    let y = CGFloat(row) * 16
                    context.setFillColor(NSColor(white: row.isMultiple(of: 3) ? 1 : 0, alpha: 0.055).cgColor)
                    context.fill(CGRect(x: 0, y: y, width: width, height: 16))
                    context.setStrokeColor(NSColor(white: 0.12, alpha: 0.28).cgColor)
                    context.setLineWidth(0.85)
                    context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y))
                    context.strokePath()
                    for x in stride(from: row.isMultiple(of: 2) ? 28 : 87, through: 255, by: 118) {
                        context.move(to: CGPoint(x: CGFloat(x), y: y))
                        context.addLine(to: CGPoint(x: CGFloat(x), y: y + 16))
                        context.strokePath()
                    }
                }
                context.setLineWidth(0.35)
                context.setStrokeColor(NSColor(white: 0.10, alpha: 0.13).cgColor)
                for grain in 0..<48 {
                    let y = CGFloat(grain) * 2.7
                    context.move(to: CGPoint(x: 0, y: y))
                    context.addCurve(to: CGPoint(x: width, y: y + 0.8),
                                     control1: CGPoint(x: 85, y: y + sin(Double(grain)) * 1.8),
                                     control2: CGPoint(x: 175, y: y - 1.5))
                    context.strokePath()
                }
            }
            if plankTextures.count >= 32 { plankTextures.removeValue(forKey: plankTextures.keys.sorted().first!) }
            plankTextures[hex] = image
        }
        let result = textured(image, roughness: 0.76)
        result.diffuse.wrapS = .repeat
        result.diffuse.wrapT = .repeat
        return result
    }

    private static func hullSection(_ t: Double, length: Double, width: Double,
                                    deck: Double, keel: Double, stern: Double) -> (x: Double, top: Double, bottom: Double, beam: Double) {
        let t = min(1, max(0, t))
        let beam = t < 0.48 ? 0.68 + 0.32 * sin(t / 0.48 * .pi / 2)
            : 0.025 + 0.975 * pow(max(0, cos((t - 0.48) / 0.52 * .pi / 2)), 0.68)
        let sheer = max(0, stern - deck) * pow(max(0, 1 - t * 3.2), 2)
            + 1.5 * pow(max(0, (t - 0.70) / 0.30), 2)
        return (-length / 2 + t * (length + 1), deck + sheer,
                keel + 1.6 * pow(abs(t * 2 - 1), 3), width * 0.5 * beam)
    }

    static func craftedHullPoint(x: Double, fraction: Double, side: Double,
                                 length: Double, width: Double, deck: Double = 4,
                                 keel: Double = -4, stern: Double = 8) -> SCNVector3 {
        let section = hullSection((x + length / 2) / (length + 1), length: length, width: width,
                                  deck: deck, keel: keel, stern: stern)
        let f = min(1, max(0, fraction))
        let angle = asin(pow(1 - f, 1 / 0.85))
        return vector(section.x, section.bottom + (section.top - section.bottom) * f,
                      side * section.beam * cos(angle))
    }

    static func craftedHull(_ group: SCNNode, length: Double = 29, width: Double = 10,
                            deck: Double = 4, keel: Double = -4, stern: Double = 8,
                            color: String, trim: String,
                            hullMaterial: SCNMaterial? = nil, trimMaterial: SCNMaterial? = nil) {
        let sections = 28, rings = 18
        func point(_ t: Double, _ v: Double) -> SIMD3<Float> {
            let section = hullSection(t, length: length, width: width, deck: deck, keel: keel, stern: stern)
            let angle = v * .pi
            return SIMD3(Float(section.x), Float(section.top - (section.top - section.bottom) * pow(max(0, sin(angle)), 0.85)),
                         Float(section.beam * cos(angle)))
        }
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for station in 0...sections {
            let t = Double(station) / Double(sections)
            for ring in 0...rings {
                let v = Double(ring) / Double(rings)
                let p = point(t, v)
                let along = point(min(1, t + 0.002), v) - point(max(0, t - 0.002), v)
                let around = point(t, min(1, v + 0.002)) - point(t, max(0, v - 0.002))
                let n = simd_normalize(simd_cross(around, along))
                vertices.append(SCNVector3(p)); normals.append(SCNVector3(n))
                uv.append(CGPoint(x: t * 3, y: v * 1.5))
                if station < sections, ring < rings {
                    let a = Int32(station * (rings + 1) + ring), b = a + 1, c = a + Int32(rings + 1)
                    indices.append(contentsOf: [a, b, c, b, c + 1, c])
                }
            }
        }
        let hull = put(group, mesh(vertices, normals, uv, indices), hullMaterial ?? plankedWood(color))
        hull.name = "crafted-hull"
        // A planked deck follows the hull's sheer and tapered plan, rather
        // than overhanging as one long rectangular box.
        var deckVertices: [SCNVector3] = [], deckUV: [CGPoint] = [], deckIndices: [Int32] = []
        for station in 0...sections {
            let t = Double(station) / Double(sections)
            let s = hullSection(t, length: length, width: width, deck: deck, keel: keel, stern: stern)
            for side in [-1.0, 1] {
                deckVertices.append(vector(s.x, s.top + 0.04, side * s.beam))
                deckUV.append(CGPoint(x: t * 3, y: side < 0 ? 0 : 1))
            }
            if station < sections {
                let a = Int32(station * 2)
                deckIndices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        put(group, mesh(deckVertices, Array(repeating: vector(0, 1, 0), count: deckVertices.count), deckUV, deckIndices),
            hullMaterial == nil ? plankedWood("#b58a54") : hullMaterial!)
        // Close the transom and pointed stem with their own outward normals.
        for (station, normal) in [(0.0, -1.0), (1.0, 1.0)] {
            let s = hullSection(station, length: length, width: width, deck: deck, keel: keel, stern: stern)
            var cap = [vector(s.x, s.top, 0)]
            for ring in 0...rings { cap.append(SCNVector3(point(station, Double(ring) / Double(rings)))) }
            var faces: [Int32] = []
            for ring in 0..<rings {
                let a = Int32(ring + 1), b = a + 1
                faces += normal < 0 ? [0, b, a] : [0, a, b]
            }
            put(group, mesh(cap, Array(repeating: vector(normal, 0, 0), count: cap.count),
                            Array(repeating: .zero, count: cap.count), faces), hullMaterial ?? plankedWood(color))
        }
        // Continuous raised wales wrap around the form at three heights.
        for (fraction, thickness) in [(0.32, 0.032), (0.66, 0.035), (0.96, 0.045)] {
            var points: [SCNVector3] = [], ns: [SCNVector3] = [], coords: [CGPoint] = [], faces: [Int32] = []
            for side in [-1.0, 1] {
                let base = points.count
                for station in 0...sections {
                    let x = -length / 2 + Double(station) / Double(sections) * (length + 1)
                    for f in [fraction - thickness, fraction + thickness] {
                        var p = craftedHullPoint(x: x, fraction: f, side: side, length: length, width: width,
                                                 deck: deck, keel: keel, stern: stern)
                        p.z += CGFloat(side * 0.045)
                        points.append(p); ns.append(vector(0, 0.2, side)); coords.append(.zero)
                    }
                    if station < sections {
                        let a = Int32(base + station * 2)
                        faces += side > 0 ? [a, a + 2, a + 1, a + 1, a + 2, a + 3]
                            : [a, a + 1, a + 2, a + 1, a + 3, a + 2]
                    }
                }
            }
            let band = trimMaterial ?? material(trim, roughness: 0.50)
            band.isDoubleSided = true
            put(group, mesh(points, ns, coords, faces), band)
        }
        let rail = trimMaterial ?? material(trim, roughness: 0.48)
        for side in [-1.0, 1] {
            for elevation in [0.16, 1.35] {
                let points = (0...20).map { station -> SCNVector3 in
                    let s = hullSection(Double(station) / 20, length: length, width: width, deck: deck, keel: keel, stern: stern)
                    return vector(s.x, s.top + elevation, side * s.beam)
                }
                cable(group, points: points, radius: elevation < 1 ? 0.13 : 0.095, material: rail)
            }
            for station in 0...9 {
                let s = hullSection(Double(station) / 9, length: length, width: width, deck: deck, keel: keel, stern: stern)
                cylinder(group, 0.055, 0.07, 1.2, rail, s.x, s.top + 0.72, side * s.beam)
            }
        }
    }

    static func detailedRope(_ group: SCNNode, from: SCNVector3, to: SCNVector3,
                             radius: Double = 0.045, color: String = "#77634c") {
        cable(group, points: [from, to], radius: radius, material: material(color, roughness: 0.88))
    }

    private static func cable(_ group: SCNNode, points: [SCNVector3], radius: Double, material: SCNMaterial) {
        guard points.count >= 2 else { return }
        let sides = 5
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for index in points.indices {
            let p = SIMD3<Float>(points[index])
            let tangent = simd_normalize(SIMD3<Float>(points[min(points.count - 1, index + 1)]) - SIMD3<Float>(points[max(0, index - 1)]))
            let reference: SIMD3<Float> = abs(tangent.z) < 0.95 ? [0, 0, 1] : [0, 1, 0]
            let a = simd_normalize(simd_cross(tangent, reference)), b = simd_cross(tangent, a)
            for side in 0...sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let n = a * cos(angle) + b * sin(angle)
                vertices.append(SCNVector3(p + n * Float(radius))); normals.append(SCNVector3(n))
                uv.append(CGPoint(x: Double(index), y: Double(side) / Double(sides)))
                if index < points.count - 1, side < sides {
                    let start = Int32(index * (sides + 1) + side), next = start + Int32(sides + 1)
                    indices += [start, start + 1, next, start + 1, next + 1, next]
                }
            }
        }
        let node = put(group, mesh(vertices, normals, uv, indices), material)
        node.castsShadow = radius > 0.09
    }

    /// Square yards cross the beam. Keep the cloth, yard and running lines
    /// in one braced assembly while the mast's standing rig stays in place.
    @discardableResult
    static func riggedSquareSail(_ group: SCNNode, x: Double, y: Double,
                                 width: Double, height: Double, cloth: SCNMaterial,
                                 yard: SCNMaterial, yaw: Double = .pi / 2 - 0.35) -> SCNNode {
        let rig = SCNNode()
        rig.name = "classic-square-rig"
        rig.position = vector(x, y, 0)
        rig.eulerAngles.y = CGFloat(yaw)
        group.addChildNode(rig)
        craftedSail(rig, x: 0, y: 0, width: width, height: height,
                    material: cloth, bulge: width * 0.13)
        let sparGeometry = SCNCone(topRadius: 0.10, bottomRadius: 0.14, height: width + 0.6)
        sparGeometry.radialSegmentCount = 16
        let spar = put(rig, sparGeometry, yard, 0, height / 2, 0, rz: .pi / 2)
        spar.name = "square-yard"
        for side in [-1.0, 1] {
            cable(rig, points: [vector(0, height / 2 + 0.65, 0),
                                vector(side * width * 0.48, height / 2, 0.05)], radius: 0.04, material: yard)
        }
        return rig
    }

    @discardableResult
    static func craftedSail(_ group: SCNNode, x: Double, y: Double, width: Double, height: Double,
                            material cloth: SCNMaterial, bulge: Double = 0.8) -> SCNNode {
        let sail = SCNNode(); sail.position = vector(x, y, 0); group.addChildNode(sail)
        let columns = 12, rows = 8
        func point(_ u: Double, _ v: Double, offset: Double = 0) -> SIMD3<Float> {
            let edge = 0.84 + 0.16 * pow(max(0, sin(v * .pi)), 0.5)
            let foot = sin(u * .pi) * (1 - v) * height * 0.065
            let belly = sin(u * .pi) * sin((v * 0.86 + 0.07) * .pi) * bulge
            let fold = sin(u * .pi * 10) * sin(v * .pi) * width * 0.007
            return [Float((u - 0.5) * width * edge), Float((v - 0.5) * height + foot), Float(belly + fold + offset)]
        }
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], faces: [Int32] = []
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let du = point(min(1, u + 0.002), v) - point(max(0, u - 0.002), v)
                let dv = point(u, min(1, v + 0.002)) - point(u, max(0, v - 0.002))
                vertices.append(SCNVector3(point(u, v))); normals.append(SCNVector3(simd_normalize(simd_cross(du, dv))))
                // canvas() paints in top-left image coordinates, matching
                // SCNPlane. Geometric v=0 is the foot of this cloth mesh.
                uv.append(CGPoint(x: u, y: 1 - v))
                if row < rows, column < columns {
                    let a = Int32(row * (columns + 1) + column), next = a + Int32(columns + 1)
                    faces += [a, a + 1, next, a + 1, next + 1, next]
                }
            }
        }
        put(sail, mesh(vertices, normals, uv, faces), cloth)
        let rope = Self.material("#b7a07b", roughness: 0.85)
        rope.blendMode = cloth.blendMode
        rope.writesToDepthBuffer = cloth.writesToDepthBuffer
        if !cloth.writesToDepthBuffer {
            rope.diffuse.contents = Self.color("#9ccdb3")
            PaperweightSceneAssets.setOpacity(0.62, of: rope)
            rope.emission.contents = cloth.emission.contents
            rope.emission.intensity = cloth.emission.intensity
        } else {
            rope.transparent.contents = cloth.transparent.contents
            rope.transparencyMode = cloth.transparencyMode
        }
        for u in [0.0, 0.25, 0.5, 0.75, 1.0] {
            cable(sail, points: (0...8).map { SCNVector3(point(u, Double($0) / 8, offset: 0.022)) },
                  radius: u == 0 || u == 1 ? 0.035 : 0.016, material: rope)
        }
        for v in [0.0, 1.0] {
            cable(sail, points: (0...12).map { SCNVector3(point(Double($0) / 12, v, offset: 0.022)) }, radius: 0.035, material: rope)
        }
        PaperweightShipAnimation.tag(sail, as: .sail)
        return sail
    }
}
