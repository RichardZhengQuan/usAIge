import AppKit
import SceneKit
import simd

/// Small, handmade interpretations of the series' more unusual vessels.
/// Geometry is local and deterministic; picking a boat never needs a download.
@available(macOS 14.0, *)
extension PaperweightShipFactory {
    static func onePieceSpecialShip(_ kind: PaperweightShipKind) -> SCNNode {
        switch kind {
        case .miniMerry: specialMiniMerry()
        case .sharkSubmerge: specialSubmarine(shark: true)
        case .queenMamaChanter: specialQueenMama()
        case .polarTang: specialSubmarine(shark: false)
        case .nostraCastello: specialNostraCastello()
        case .perfumeYuda: specialPerfumeYuda()
        case .thrillerBark: specialThrillerBark()
        case .hitsugibune: specialCoffin()
        case .missLoveDuck: specialLoveDuck()
        case .bezanBlack: specialBezanBlack()
        case .baratie: specialBaratie()
        case .sexyFoxy: specialSexyFoxy()
        case .mammoth: specialMammoth()
        case .snapperHead: specialSnapperHead()
        case .arkMaxim: specialArkMaxim()
        case .onePieceFlyingDutchman: specialDutchman()
        case .noah: specialNoah()
        case .striker: specialStriker()
        case .windGranma: specialWindGranma()
        case .germa66: specialGerma()
        case .garpWarship: specialMarine(garp: true)
        case .marineWarship: specialMarine(garp: false)
        case .blackbeardRaft: specialRaft()
        default: preconditionFailure("Not a special One Piece ship: \(kind)")
        }
    }

    private static func specialHull(_ group: SCNNode, color hex: String, width: Double = 11,
                                    length: Double = 28, rail: String = "#E8C57B") {
        craftedHull(group, length: length, width: width, deck: 5, keel: -4, stern: 8,
                    color: hex, trim: rail)
        // Raised aft deck and a real companionway give even the smaller
        // vessels a readable working silhouette above the curved planking.
        for step in 0..<4 {
            box(group, 0.75, 0.35, 2.7, material("#BC945E"), -length * 0.25 + Double(step) * 0.7,
                7.1 - Double(step) * 0.5, -width * 0.15)
        }
        cylinder(group, 0.45, 0.45, 1.7, material("#80674B"), length * 0.27, 6)
        cylinder(group, 0.85, 0.85, 0.5, material(rail, metalness: 0.15), length * 0.27, 6.8)
    }

    private static func specialRig(_ group: SCNNode, x: Double = -2, height: Double = 18,
                                   sailColor: String = "#F6EAD3", width: Double = 12) {
        let wood = material("#68462E")
        mast(group, x, 5, height, wood)
        cylinder(group, 1.25, 1.05, 1.2, material("#9B7550"), x, 5 + height * 0.78)
        cylinder(group, 1.4, 1.4, 0.25, material("#D2B374"), x, 5.6 + height * 0.78)
        let squareRig = specialSquareRig(group, x: x)
        sail(squareRig, 0, 5 + height * 0.56, width, height * 0.48,
             material(sailColor, roughness: 0.85, doubleSided: true), brace: 0)
        box(squareRig, width + 0.8, 0.4, 0.4, wood, 0, 5 + height * 0.80)
        plane(group, 3.5, 2.1, textured(pirateFlag), x + 1.7, 5 + height)
        for side in [-1.0, 1] {
            for dx in [-5.5, 5.5] {
                detailedRope(group, from: vector(x, 5 + height * 0.87, 0),
                             to: vector(x + dx, 5.5, side * 4.2), radius: 0.055)
            }
            detailedRope(squareRig, from: vector(-width * 0.52, 5 + height * 0.80, 0),
                         to: vector(4, 5.6, side * 3.7), radius: 0.045)
        }
    }

    /// Square yards span the beam (+/-Z), with a modest brace to the wind.
    /// Their cloth normal therefore points mostly toward the +X bow. Flags
    /// and Striker's fore-and-aft triangular sail intentionally do not use it.
    private static func specialSquareRig(_ group: SCNNode, x: Double) -> SCNNode {
        let rig = SCNNode()
        rig.name = "special-square-rig"
        rig.position.x = CGFloat(x)
        rig.eulerAngles.y = CGFloat(Double.pi / 2 - 0.35)
        group.addChildNode(rig)
        return rig
    }

    private static func specialEyes(_ group: SCNNode, _ x: Double, _ y: Double, _ z: Double,
                                    spacing: Double = 1.7, radius: Double = 0.75) {
        for side in [-1.0, 1] {
            sphere(group, radius, 10, material("#FDF9EA"), x, y, z + side * spacing)
            sphere(group, radius * 0.47, 8, material("#171920"), x + radius * 0.65, y,
                   z + side * spacing)
        }
    }

    private static func specialPortholes(_ group: SCNNode, xs: [Double], y: Double,
                                        z: Double, color hex: String = "#253F55") {
        for side in [-1.0, 1] {
            for x in xs {
                disc(group, 0.8, 12, material("#E8C879", metalness: 0.25), x, y, side * z,
                     ry: side > 0 ? 0 : .pi)
                disc(group, 0.5, 12, material(hex), x, y, side * (z + 0.05),
                     ry: side > 0 ? 0 : .pi)
            }
        }
    }

    private static func specialTurret(_ group: SCNNode, x: Double, y: Double, z: Double,
                                     height: Double, radius: Double, wall: SCNMaterial,
                                     roof: SCNMaterial) {
        let tower = SCNCone(topRadius: radius * 0.93, bottomRadius: radius, height: height)
        tower.radialSegmentCount = 24
        put(group, tower, wall, x, y + height / 2, z)
        for level in [0.1, 0.7, 0.97] {
            cylinder(group, radius * 1.05, radius * 1.05, 0.35, wall, x, y + height * level, z)
        }
        let spire = SCNCone(topRadius: 0, bottomRadius: radius * 1.45, height: radius * 2.7)
        spire.radialSegmentCount = 24
        put(group, spire, roof, x, y + height + radius * 1.35, z)
        cylinder(group, 0.06, 0.09, radius * 0.8, roof, x, y + height + radius * 3, z)
        for side in [-1.0, 1] {
            box(group, 0.65, 1.5, 0.16, material("#29243C"), x, y + height * 0.65,
                z + side * (radius + 0.04))
        }
    }

    /// A continuous tube follows a drawn centreline: animal necks, tusks,
    /// piping and shell spirals have curved volume instead of stacked balls.
    private static func specialTube(_ group: SCNNode, points: [SCNVector3], radii: [Double],
                                    surface: SCNMaterial, sides: Int = 14) {
        guard points.count > 1, points.count == radii.count else { return }
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var uv: [CGPoint] = [], indices: [Int32] = []
        func p(_ index: Int) -> SIMD3<Double> {
            let value = points[index]
            return SIMD3(Double(value.x), Double(value.y), Double(value.z))
        }
        for index in points.indices {
            let tangent = simd_normalize(p(min(points.count - 1, index + 1)) - p(max(0, index - 1)))
            let reference = abs(tangent.y) > 0.85 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let side = simd_normalize(simd_cross(tangent, reference))
            let up = simd_cross(side, tangent)
            for segment in 0...sides {
                let angle = Double(segment) * 2 * .pi / Double(sides)
                let normal = side * cos(angle) + up * sin(angle)
                let position = p(index) + normal * radii[index]
                vertices.append(vector(position.x, position.y, position.z))
                normals.append(vector(normal.x, normal.y, normal.z))
                uv.append(CGPoint(x: Double(segment) / Double(sides), y: Double(index) / Double(points.count - 1)))
                if index < points.count - 1, segment < sides {
                    let a = Int32(index * (sides + 1) + segment), b = a + 1
                    let c = a + Int32(sides + 1), d = c + 1
                    indices += [a, c, b, b, c, d]
                }
            }
        }
        surface.isDoubleSided = true
        put(group, mesh(vertices, normals, uv, indices), surface)
    }

    private static func specialRoundHull(_ group: SCNNode, sections: [(Double, Double)], y: Double,
                                         upper: SCNMaterial, lower: SCNMaterial, depthScale: Double = 1) {
        // Two half-lofts preserve an actual lower-hull paint boundary.
        for half in 0..<2 {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = []
            var indices: [Int32] = []
            let segments = 18
            for index in sections.indices {
                let previous = sections[max(0, index - 1)], next = sections[min(sections.count - 1, index + 1)]
                let slope = (next.1 - previous.1) / max(0.01, next.0 - previous.0)
                for ring in 0...segments {
                    let angle = Double(half) * .pi + Double(ring) * .pi / Double(segments)
                    vertices.append(vector(sections[index].0, y + sin(angle) * sections[index].1,
                                           cos(angle) * sections[index].1))
                    let length = sqrt(1 + slope * slope)
                    normals.append(vector(-slope / length, sin(angle) / length, cos(angle) / length))
                    uv.append(CGPoint(x: Double(index) / Double(sections.count - 1), y: Double(ring) / Double(segments)))
                    if index < sections.count - 1, ring < segments {
                        let a = Int32(index * (segments + 1) + ring), b = a + 1
                        let c = a + Int32(segments + 1), d = c + 1
                        indices += [a, c, b, b, c, d]
                    }
                }
            }
            put(group, mesh(vertices, normals, uv, indices), half == 0 ? upper : lower).scale.z = CGFloat(depthScale)
        }
    }

    private static func specialBalcony(_ group: SCNNode, x: Double, y: Double, width: Double,
                                       depth: Double, tint: SCNMaterial) {
        box(group, width, 0.45, depth, tint, x, y)
        for side in [-1.0, 1] {
            box(group, width, 0.2, 0.2, tint, x, y + 1.55, side * depth / 2)
            for offset in stride(from: -width / 2, through: width / 2, by: 1.5) {
                cylinder(group, 0.09, 0.09, 1.4, tint, x + offset, y + 0.8, side * depth / 2)
            }
        }
    }

    /// Put existing detail geometry around its physical hinge without moving it.
    /// Hulls, decks and buildings remain outside these animation groups.
    private static func specialMovingPart(_ root: SCNNode, from index: Int,
                                          pivot: SCNVector3, name: String? = nil) -> SCNNode {
        let children = Array(root.childNodes.dropFirst(index))
        let part = SCNNode()
        part.name = name
        part.position = pivot
        for child in children {
            child.removeFromParentNode()
            child.position = SCNVector3(child.position.x - pivot.x, child.position.y - pivot.y,
                                       child.position.z - pivot.z)
            part.addChildNode(child)
        }
        root.addChildNode(part)
        return part
    }

    private static func specialScrew(_ group: SCNNode, x: Double, y: Double, radius: Double,
                                     color hex: String = "#C2A461") {
        let rotor = SCNNode(), bronze = material(hex, metalness: 0.45)
        rotor.name = "aft-propeller-axis-x"
        rotor.position = vector(x, y, 0)
        sphere(rotor, 0.55, 20, bronze, 0, 0).scale = vector(1.5, 1, 1)
        for index in 0..<3 {
            let blade = SCNNode()
            blade.eulerAngles.x = CGFloat(Double(index) * 2 * .pi / 3)
            rotor.addChildNode(blade)
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 0, y: 0.2))
            outline.curve(to: NSPoint(x: radius * 0.42, y: radius),
                          controlPoint1: NSPoint(x: -radius * 0.2, y: radius * 0.6),
                          controlPoint2: NSPoint(x: radius * 0.1, y: radius * 1.08))
            outline.curve(to: NSPoint(x: radius * 0.48, y: radius * 0.45),
                          controlPoint1: NSPoint(x: radius * 0.9, y: radius),
                          controlPoint2: NSPoint(x: radius * 0.82, y: radius * 0.6))
            outline.close()
            let leaf = extrude(blade, outline, 0.18, bronze, bevel: 0.04)
            leaf.eulerAngles.y = .pi / 2
        }
        group.addChildNode(rotor)
        PaperweightShipAnimation.tag(rotor, as: .propeller)
    }

    private static func specialMiniMerry() -> SCNNode {
        let group = SCNNode(), cream = material("#FFF4DA"), gold = material("#E4AB48")
        specialHull(group, color: "#DCA066", width: 8, length: 20, rail: "#FDF2DB")
        for x in [-5.5, 0.5] { box(group, 2.2, 0.6, 6.6, plankedWood("#B66F3C"), x, 6) }
        put(group, SCNBox(width: 3, height: 2.5, length: 3.5, chamferRadius: 0.35),
            material("#A74633"), -3, 6.4)
        torus(group, 1, 0.14, rings: 24, sides: 6, material("#D6AE57"), 0.4, 7.4)
        for angle in [0.0, .pi / 3, 2 * .pi / 3] {
            box(group, 2, 0.11, 0.11, material("#86592F"), 0.4, 7.4, rz: angle)
        }
        let figureStart = group.childNodes.count
        sphere(group, 3.2, 14, cream, 11, 6).scale = vector(1.1, 1, 0.9)
        cylinder(group, 1.5, 1.8, 3, cream, 10, 4)
        for side in [-1.0, 1] {
            torus(group, 1.1, 0.35, rings: 14, sides: 6, gold, 10, 7, side * 2.5)
            sphere(group, 0.5, 8, material("#252020"), 12.7, 6.5, side * 1.5)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: figureStart,
                                                       pivot: vector(10, 4, 0), name: "bow-sheep-head-facing-positive-x"), as: .figurehead)
        box(group, 3.3, 3.7, 3, material("#456C83"), -11, 2)
        cylinder(group, 0.4, 0.4, 5, material("#444950"), -11, -0.6, rz: .pi / 2)
        torus(group, 1.2, 0.3, rings: 12, sides: 6, material("#777D83"), -13.5, -0.6, ry: .pi / 2)
        specialScrew(group, x: -13.5, y: -0.6, radius: 1.2, color: "#777D83")
        return group
    }

    private static func specialSubmarine(shark: Bool) -> SCNNode {
        let group = SCNNode(), hull = material(shark ? "#427FAD" : "#EAC52E", roughness: 0.38)
        let dark = material(shark ? "#263D59" : "#333A42")
        let sections: [(Double, Double)] = [(-16, 0.15), (-14, 2.5), (-10, 4.1), (-5, 4.6),
                                             (4, 4.6), (10, 4.15), (14, 2.8), (16.6, 0.15)]
        specialRoundHull(group, sections: sections, y: 0.7, upper: hull,
                         lower: shark ? dark : material("#F2E8CC"))
        for (x, radius) in [(-10.0, 4.15), (-4, 4.65), (4, 4.65), (10, 4.2)] {
            torus(group, radius, 0.085, rings: 32, sides: 6,
                  material(shark ? "#83A9BD" : "#B99436", metalness: 0.3), x, 0.7, ry: .pi / 2)
        }
        specialPortholes(group, xs: [-8, -3, 2, 7], y: 1.2, z: 4.55)
        for side in [-1.0, 1] {
            detailedRope(group, from: vector(-9, 3.4, side * 3.1),
                         to: vector(8, 3.4, side * 3.1), radius: 0.14,
                         color: shark ? "#8BB1C4" : "#E3BE35")
            for x in [-8.0, -3, 2, 7] {
                torus(group, 0.79, 0.13, rings: 20, sides: 6,
                      material(shark ? "#ABBFC6" : "#B69739", metalness: 0.6), x, 1.2, side * 4.66)
            }
        }
        if shark {
            let fin = NSBezierPath()
            fin.move(to: NSPoint(x: -4, y: 4.5))
            fin.curve(to: NSPoint(x: -4.2, y: 11), controlPoint1: NSPoint(x: -4.5, y: 7),
                      controlPoint2: NSPoint(x: -5.6, y: 9))
            fin.curve(to: NSPoint(x: 3.5, y: 4.7), controlPoint1: NSPoint(x: -1.4, y: 10),
                      controlPoint2: NSPoint(x: -0.7, y: 5.3))
            fin.close()
            extrude(group, fin, 1.1, dark, bevel: 0.2)
            profile(group, [(-13, 1), (-18, 6), (-16.4, 0.5), (-18, -4.3), (-13, -1)], 1, hull, bevel: 0.2)
            cylinder(group, 2, 2, 0.55, dark, 6, 4.6)
            sphere(group, 1.8, 24, material("#8BC0D0", roughness: 0.16, metalness: 0.35), 6, 4.8)
            for side in [-1.0, 1] {
                let fin = profile(group, [(-3, 1), (2, 0.3), (-1, -0.6), (-5, -0.3)], 4, hull, bevel: 0.18)
                fin.position.z = CGFloat(side * 4.5)
                fin.eulerAngles.y = CGFloat(side * 0.25)
                disc(group, 1.05, 24, material("#F2F5F4"), 11.7, 2.35, side * 3.65,
                     ry: side > 0 ? 0 : .pi)
                disc(group, 0.45, 18, dark, 11.95, 2.35, side * 3.72,
                     ry: side > 0 ? 0 : .pi)
                specialTube(group, points: [vector(7.5, -0.2, side * 3.9), vector(11, -0.55, side * 3.65),
                                            vector(14, -0.1, side * 2.4)],
                            radii: [0.22, 0.25, 0.12], surface: dark, sides: 10)
                for x in stride(from: 8.0, through: 14, by: 1.5) {
                    cylinder(group, 0.4, 0, 0.9, material("#FFF5DD"), x, -0.45,
                             side * (4.3 - max(0, x - 9) * 0.26))
                }
            }
        } else {
            put(group, SCNBox(width: 8.5, height: 4.5, length: 5.8, chamferRadius: 1), hull, -2, 6.2)
            box(group, 9.2, 0.45, 6.6, dark, -2, 8.5)
            for side in [-1.0, 1] {
                for x in [-4.8, -2.7, -0.6, 1.5] {
                    box(group, 1.1, 1.25, 0.15, material("#1E4E67", roughness: 0.18), x, 7.1, side * 2.95)
                }
            }
            specialBalcony(group, x: -2, y: 8.8, width: 8.8, depth: 6.4, tint: material("#D3AE38"))
            let upperBridge = profile(group, [(-5, 8.9), (1.5, 8.9), (0.2, 12.3), (-4.7, 12.3)],
                                      4.6, hull, bevel: 0.45)
            upperBridge.name = "polar-tang-raised-bridge"
            for side in [-1.0, 1] {
                for x in [-3.7, -1.8, 0.1] {
                    box(group, 1.3, 1.3, 0.15, material("#1B536D", roughness: 0.15), x, 11, side * 2.37)
                }
            }
            specialBalcony(group, x: -2, y: 12.5, width: 6.7, depth: 5.3, tint: material("#D3AE38"))
            cylinder(group, 1.8, 1.8, 0.55, hull, 7, 5)
            torus(group, 1.5, 0.15, rings: 24, sides: 6, dark, 7, 5.35, rx: .pi / 2)
            cylinder(group, 0.24, 0.34, 11, hull, -3.8, 18.2)
            cylinder(group, 0.2, 0.3, 8.5, hull, -0.5, 16.9)
            cylinder(group, 0.29, 0.29, 0.8, dark, -3.8, 23.7)
            box(group, 4, 0.65, 9, hull, -14.5, 1)
            box(group, 2.2, 5, 0.7, hull, -14.5, 1)
            box(group, 0.45, 0.7, 9.2, material("#EFE6CF"), -16.3, 1)
            for x in [-6.0, -3, 0, 3] {
                cylinder(group, 0.6, 0.6, 3.8, dark, x, -2.7, -1.8, rz: .pi / 2)
            }
            for side in [-1.0, 1] {
                disc(group, 1.6, 24, material("#191D25"), -2, 1.3, side * 4.77,
                     ry: side > 0 ? 0 : .pi)
                torus(group, 1, 0.15, rings: 24, sides: 6, hull, -2, 1.3, side * 4.83)
                // The Heart Pirates' circular smiling mark is modelled into
                // the paintwork rather than left as an unmarked yellow tube.
                for dx in [-0.38, 0.38] { disc(group, 0.13, 10, hull, -2 + dx, 1.65, side * 4.85) }
                specialTube(group, points: [vector(-2.55, 1.12, side * 4.86), vector(-2, 0.72, side * 4.86),
                                            vector(-1.45, 1.12, side * 4.86)],
                            radii: [0.1, 0.1, 0.1], surface: hull, sides: 8)
            }
        }
        specialScrew(group, x: shark ? -16.7 : -16.2, y: 0.7, radius: 2.2)
        return group
    }

    private static func specialQueenMama() -> SCNNode {
        let group = SCNNode(), pink = material("#EA86AB"), icing = material("#FFF0C9")
        // The repeated sub-pixel icing drops need a bounded, explicit mesh.
        // SceneKit primitive spheres can retain a much denser generated mesh
        // than their requested segment count when their elements are queried.
        let columns = 12, rows = 6
        var dropVertices: [SCNVector3] = [], dropNormals: [SCNVector3] = []
        var dropUV: [CGPoint] = [], dropFaces: [Int32] = []
        for row in 0...rows {
            let latitude = Double(row) * .pi / Double(rows)
            for column in 0...columns {
                let longitude = Double(column) * 2 * .pi / Double(columns)
                let normal = vector(sin(latitude) * cos(longitude), cos(latitude),
                                    sin(latitude) * sin(longitude))
                dropNormals.append(normal)
                dropVertices.append(SCNVector3(normal.x * 0.42, normal.y * 0.42, normal.z * 0.42))
                dropUV.append(CGPoint(x: Double(column) / Double(columns), y: Double(row) / Double(rows)))
                if row < rows, column < columns {
                    let a = Int32(row * (columns + 1) + column), b = a + 1
                    let c = a + Int32(columns + 1), d = c + 1
                    dropFaces += [a, b, c, b, d, c]
                }
            }
        }
        let icingDrop = mesh(dropVertices, dropNormals, dropUV, dropFaces)
        specialHull(group, color: "#CB4C80", width: 13, rail: "#FAD0D8")
        for (x, y, radius, height) in [(-6.0, 5.4, 5.0, 5.0), (-6, 10.4, 3.5, 4),
                                       (-6, 14.4, 2.2, 3), (3, 5.4, 4, 5)] {
            let cake = SCNCylinder(radius: radius, height: height)
            cake.radialSegmentCount = 32
            put(group, cake, pink, x, y + height / 2)
            cylinder(group, radius + 0.3, radius + 0.3, 0.6, icing, x, y + height)
            torus(group, radius + 0.12, 0.23, rings: 32, sides: 8, icing, x, y + height - 0.35, rx: .pi / 2)
            for index in 0..<12 {
                let angle = Double(index) * 2 * .pi / 12
                let px = x + cos(angle) * (radius + 0.1), pz = sin(angle) * (radius + 0.1)
                put(group, icingDrop, icing, px, y + height - 0.8, pz).scale = vector(0.7, 1.5, 0.7)
                if index.isMultiple(of: 2) {
                    sphere(group, 0.6, 14, material("#CF3558"), px, y + height + 0.65, pz)
                }
            }
        }
        cylinder(group, 0, 2.5, 4, material("#EBB56E"), -6, 19.3)
        sphere(group, 0.8, 16, material("#D64D78"), -6, 21.7)
        specialBalcony(group, x: -1.5, y: 6.1, width: 20, depth: 13.2, tint: material("#FADEC9"))
        for side in [-1.0, 1] {
            for x in [-8.0, -2, 4, 9] {
                torus(group, 1.1, 0.3, rings: 20, sides: 8, material("#F7D680"), x, 2.4, side * 6.6)
                sphere(group, 0.52, 14, pink, x, 2.4, side * 6.7)
            }
        }
        mast(group, -1, 5, 21, material("#9F4D6B"))
        let squareRig = specialSquareRig(group, x: -1)
        sail(squareRig, 0, 21, 12, 7, material("#F4B5C8", doubleSided: true), brace: 0)
        box(squareRig, 12.7, 0.4, 0.4, material("#9F4D6B"), 0, 24.5)
        for side in [-1.0, 1] {
            cylinder(group, 0, 0.7, 4, icing, 5, 13, side * 3)
        }
        let figureStart = group.childNodes.count
        sphere(group, 4.1, 32, icing, 14, 6.5).scale = vector(0.65, 1, 1)
        sphere(group, 1.1, 10, material("#D9506C"), 17, 6.5)
        specialEyes(group, 16.3, 8, 0, spacing: 1.6, radius: 0.7)
        for side in [-1.0, 1] {
            sphere(group, 1.4, 10, pink, 14.5, 6, side * 3.4)
        }
        for z in [-1.2, 0, 1.2] {
            cylinder(group, 0, 0.5, 2, material("#EFC257"), 14, 11, z)
        }
        box(group, 0.3, 0.6, 3.6, material("#A83461"), 16.8, 5.3)
        specialTube(group, points: [vector(16.2, 6.2, -2), vector(16.9, 4.8, 0), vector(16.2, 6.2, 2)],
                    radii: [0.22, 0.3, 0.22], surface: material("#AA3C67"))
        PaperweightShipAnimation.tag(specialMovingPart(group, from: figureStart,
                                                       pivot: vector(13, 5, 0), name: "bow-cake-face-facing-positive-x"), as: .figurehead)
        return group
    }

    private static func specialNostraCastello() -> SCNNode {
        let group = SCNNode(), stone = material("#C9B48C"), roof = material("#4A6B77")
        specialHull(group, color: "#425D75", width: 13, rail: "#D3B266")
        box(group, 18, 6, 11, stone, -2, 8.5)
        for x in [-10.0, 7] {
            for z in [-4.7, 4.7] {
                specialTurret(group, x: x, y: 5, z: z, height: 10, radius: 2.2, wall: stone, roof: roof)
            }
        }
        box(group, 7, 4, 8, stone, -2, 13.5)
        box(group, 8, 1, 9, roof, -2, 16)
        specialBalcony(group, x: -2, y: 11.7, width: 17, depth: 11.6, tint: stone)
        for x in stride(from: -10.0, through: 6, by: 2) {
            for side in [-1.0, 1] { box(group, 1, 1.4, 0.8, stone, x, 12, side * 5.6) }
        }
        // A deep arched front portal and four turrets make the hull read as
        // Bege's mobile fortress instead of a box carrying cones.
        box(group, 0.5, 3.8, 3.8, material("#273446"), 7.3, 7.7)
        for z in [-1.6, -0.8, 0, 0.8, 1.6] {
            box(group, 0.6, 3.5, 0.15, roof, 7.7, 7.7, z)
        }
        for side in [-1.0, 1] {
            box(group, 24, 2.4, 1.6, material("#252B2C"), -1, 0.8, side * 6.8)
            for x in stride(from: -10.0, through: 9, by: 3.2) {
                disc(group, 1, 10, material("#8F8E7D"), x, 0.8, side * 7.7,
                     ry: side > 0 ? 0 : .pi)
            }
            for x in [-6.0, -2, 2] { box(group, 1, 2, 0.2, material("#243141"), x, 9, side * 5.6) }
        }
        // The castle stays still while a small lookout pennant catches the wind.
        mast(group, -2, 16, 4, material("#73664C"))
        plane(group, 3.2, 1.7, textured(pirateFlag), -0.4, 19.2)
        specialScrew(group, x: -14, y: -0.7, radius: 1.7)
        return group
    }

    private static func specialPerfumeYuda() -> SCNNode {
        let group = SCNNode(), red = material("#AA3341"), green = material("#518D61")
        specialHull(group, color: "#A72C3A", width: 11, length: 24, rail: "#D8AF60")
        for (y, width, height) in [(7.0, 14.0, 3.0), (11, 11, 3), (15, 8, 2.5)] {
            box(group, width - 3, height, width * 0.65, red, -4, y)
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: -width / 2, y: y + height / 2 + 1.1))
            roof.curve(to: NSPoint(x: 0, y: y + height / 2 + 3),
                       controlPoint1: NSPoint(x: -width * 0.4, y: y + height / 2 - 0.5),
                       controlPoint2: NSPoint(x: -width * 0.16, y: y + height / 2 + 2.7))
            roof.curve(to: NSPoint(x: width / 2, y: y + height / 2 + 1.1),
                       controlPoint1: NSPoint(x: width * 0.16, y: y + height / 2 + 2.7),
                       controlPoint2: NSPoint(x: width * 0.4, y: y + height / 2 - 0.5))
            roof.line(to: NSPoint(x: width / 2, y: y + height / 2 + 0.3))
            roof.line(to: NSPoint(x: -width / 2, y: y + height / 2 + 0.3))
            roof.close()
            extrude(group, roof, width * 0.85, material("#273F38"), bevel: 0.15).position.x = -4
            specialBalcony(group, x: -4, y: y - height / 2, width: width - 1,
                           depth: width * 0.75, tint: material("#D2AD62"))
            for side in [-1.0, 1] {
                for x in stride(from: -width * 0.3, through: width * 0.3, by: 1.4) {
                    cylinder(group, 0.12, 0.12, height, material("#E1BD72"), x - 4, y,
                             side * width * 0.33)
                }
            }
        }
        cylinder(group, 0, 0.8, 3.4, material("#D8B860", metalness: 0.3), -4, 21.3)
        for side in [-1.0, 1] {
            let serpentStart = group.childNodes.count
            let body = (0..<12).map { index -> SCNVector3 in
                let t = Double(index) / 11
                return vector(7 + t * 13, 2 + sin(t * .pi * 1.7) * 1.2 + t * 2.4,
                              side * (4.2 + t * 1.3))
            }
            specialTube(group, points: body, radii: (0..<12).map { 1.1 + Double($0) * 0.065 },
                        surface: green, sides: 20)
            for index in stride(from: 1, through: 9, by: 2) {
                let point = body[index]
                sphere(group, 1, 18, material("#96AD76"), Double(point.x), Double(point.y) - 0.95,
                       Double(point.z)).scale = vector(1.3, 0.35, 0.9)
            }
            sphere(group, 2.5, 28, green, 20, 5.2, side * 5.5).scale = vector(1.4, 0.85, 0.9)
            sphere(group, 1.8, 24, material("#97AC72"), 21.7, 4.7, side * 5.5).scale = vector(1.3, 0.4, 1)
            sphere(group, 0.65, 18, material("#F8EBC5"), 21.5, 6, side * 6.9)
            sphere(group, 0.3, 14, material("#161B20"), 21.5, 6, side * 7.3)
            for x in [21.0, 22.4] {
                cylinder(group, 0.12, 0.4, 1.5, material("#F7EAC5"), x, 3.5, side * 6.7)
            }
            box(group, 2, 0.3, 0.5, material("#D83C47"), 23.6, 4.9, side * 5.5)
            PaperweightShipAnimation.tag(specialMovingPart(group, from: serpentStart,
                                                           pivot: vector(8, 2, side * 4.2), name: "bow-serpent-facing-positive-x"), as: .serpent)
        }
        return group
    }

    private static func specialThrillerBark() -> SCNNode {
        let group = SCNNode(), dark = material("#423D53"), stone = material("#81758B")
        cylinder(group, 14, 12, 5, material("#66513E"), 0, -0.5)
        cylinder(group, 13.5, 13.5, 0.7, material("#485246"), 0, 2.3)
        let wall = SCNTube(innerRadius: 12.3, outerRadius: 13.4, height: 4)
        wall.radialSegmentCount = 32
        put(group, wall, dark, 0, 4.3)
        for index in 0..<16 {
            let angle = Double(index) * .pi / 8
            box(group, 1.7, 1.2, 1.3, dark, cos(angle) * 12.8, 6.7, sin(angle) * 12.8,
                ry: -angle)
        }
        box(group, 8, 8, 7, stone, -1, 6.7)
        let chapelRoof = profile(group, [(-5.5, 10.5), (-1, 16), (3.5, 10.5)], 8,
                                 material("#493257"), bevel: 0.18)
        chapelRoof.name = "thriller-bark-gothic-chapel"
        for side in [-1.0, 1] {
            for x in [-3.5, -1.0, 1.5] {
                box(group, 0.8, 3.1, 0.18, material("#D4AB74"), x, 8.3, side * 3.6)
                cylinder(group, 0, 0.65, 1.1, material("#D4AB74"), x, 10.35, side * 3.6)
                box(group, 0.16, 3.5, 0.24, dark, x, 8.4, side * 3.72)
            }
            profile(group, [(5, 3), (8, 9), (8.8, 8.6), (7, 3)], 1.5, dark).position.z = CGFloat(side * 4.5)
            for x in [-9.0, -4, 1, 6, 10] {
                box(group, 1.8, 1.1, 0.2, material("#22232B"), x, -0.1, side * 12.1)
            }
        }
        // The island is a built-up wooden ship, with a huge arched gate and
        // castle rising from it, rather than a plain circular plinth.
        for y in [-1.7, -0.5, 0.8] {
            torus(group, 12.75, 0.14, rings: 48, sides: 6, material("#B18E68"), 0, y, rx: .pi / 2)
        }
        box(group, 2.2, 5.5, 5.8, dark, 12.3, 4.4)
        profile(group, [(11, 7.2), (12.3, 10.3), (13.6, 7.2)], 6, dark, bevel: 0.15)
        for z in [-1.8, -0.6, 0.6, 1.8] { box(group, 0.22, 4.3, 0.22, material("#A98D62"), 13.5, 4.4, z) }
        for (x, z, height) in [(-5.0, -3.5, 11.0), (-5, 3.5, 11), (3, -3, 15), (3, 3, 15)] {
            specialTurret(group, x: x, y: 3, z: z, height: height, radius: 1.8,
                          wall: stone, roof: material("#493257"))
        }
        mast(group, -7, 3, 21, material("#4B3C42"))
        let squareRig = specialSquareRig(group, x: -7)
        sail(squareRig, 0, 18, 10, 7, material("#C1A7C6", doubleSided: true), brace: 0)
        box(squareRig, 10.7, 0.4, 0.4, material("#4B3C42"), 0, 21.5)
        for x in [-7.0, 6, 9] {
            cylinder(group, 0.25, 0.6, 6, dark, x, 5, -5)
            sphere(group, 1.8, 10, material("#3C5149"), x, 8.3, -5)
        }
        return group
    }

    private static func specialCoffin() -> SCNNode {
        let group = SCNNode(), black = material("#26262D"), gold = material("#BC9B5A")
        let outline = path([(-11, -1.4), (-7, -3.3), (5, -3.3), (11, -1.5),
                            (11, 1.5), (5, 3.3), (-7, 3.3), (-11, 1.4)])
        let shell = SCNShape(path: outline, extrusionDepth: 2.5)
        shell.chamferRadius = 0.25
        put(group, shell, black, 0, -1.8, rx: -.pi / 2)
        let lining = SCNShape(path: outline, extrusionDepth: 0.25)
        let cushion = put(group, lining, material("#6D3549"), 0, 0.7, rx: -.pi / 2)
        cushion.scale = vector(0.86, 0.86, 1)
        let rim = [vector(-11, 1, 1.4), vector(-7, 1, 3.3), vector(5, 1, 3.3), vector(11, 1, 1.5),
                   vector(11, 1, -1.5), vector(5, 1, -3.3), vector(-7, 1, -3.3), vector(-11, 1, -1.4)]
        for index in rim.indices { detailedRope(group, from: rim[index], to: rim[(index + 1) % rim.count], radius: 0.13, color: "#BC9B5A") }
        box(group, 0.8, 21, 0.8, black, -3, 11)
        let squareRig = specialSquareRig(group, x: -3)
        box(squareRig, 10, 0.8, 0.8, black, 0, 17)
        sail(squareRig, 0, 12, 8, 7, material("#A5BC93", doubleSided: true), brace: 0)
        for z in [-2.6, 2.6] {
            specialTube(group, points: [vector(7, 1.4, z * 0.5), vector(7.7, 2, z), vector(8, 3, z)],
                        radii: [0.18, 0.15, 0.12], surface: gold)
            cylinder(group, 0.3, 0.3, 3, gold, 8, 3, z)
            let flame = material("#78D887")
            flame.emission.contents = color("#2D8E54")
            let candle = sphere(group, 0.55, 8, flame, 8, 4.8, z)
            candle.scale = vector(0.75, 1.7, 0.75)
            PaperweightShipAnimation.tag(candle, as: .pulse)
        }
        return group
    }

    private static func specialLoveDuck() -> SCNNode {
        let group = SCNNode(), pink = material("#E99CB5"), white = material("#F6EDE6")
        specialHull(group, color: "#D87B9C", rail: "#F3CAD5")
        specialRig(group, x: -3, height: 17, sailColor: "#F9DBE2", width: 13)
        box(group, 7, 4, 8, pink, -8, 7)
        let headStart = group.childNodes.count
        specialTube(group, points: [vector(11, 4.5, 0), vector(10.2, 7.2, 0), vector(11, 10.2, 0), vector(13.4, 12, 0)],
                    radii: [2.4, 1.8, 1.55, 2.2], surface: white, sides: 24)
        sphere(group, 3.6, 32, white, 14, 12.5)
        sphere(group, 1.8, 24, material("#E6AF4A"), 17, 11.9).scale = vector(1.7, 0.45, 1.15)
        sphere(group, 1.5, 24, material("#D49B3B"), 17.1, 11.4).scale = vector(1.65, 0.2, 1.2)
        specialEyes(group, 15.5, 13.4, 0, spacing: 2, radius: 0.6)
        sphere(group, 1, 10, pink, 14, 16)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(12.5, 5, 0), name: "bow-duck-head-facing-positive-x"), as: .figurehead)
        for side in [-1.0, 1] {
            for feather in 0..<4 {
                sphere(group, 2, 20, white, 3 + Double(feather) * 1.7, 4.8 - Double(feather) * 0.2,
                       side * 5.4).scale = vector(1.5, 0.55, 0.4)
            }
        }
        return group
    }

    private static func specialBezanBlack() -> SCNNode {
        let group = SCNNode(), dark = material("#252C32")
        specialHull(group, color: "#853B39", rail: "#252C32")
        box(group, 24, 1.7, 11.6, material("#76764C"), -1, -1.8)
        specialRig(group, x: -4, height: 19, width: 11)
        specialRig(group, x: 5, height: 14, width: 8)
        let headStart = group.childNodes.count
        sphere(group, 3.6, 12, dark, 13.8, 8)
        for z in [-2.0, 2] {
            cylinder(group, 0, 1.4, 4.3, dark, 13.5, 11.6, z)
            sphere(group, 0.6, 8, material("#E4C970"), 16.3, 8.6, z * 0.8)
            // A +X-facing cat's whiskers fan out across the face in ±Z.
            // Fore/aft X bars made the muzzle read as if it faced the camera.
            let side = z > 0 ? 1.0 : -1.0
            for rise in [-0.6, 0, 0.6] {
                detailedRope(group, from: vector(16.2, 7.2, side * 1.8),
                             to: vector(16.5 - abs(rise) * 1.1, 7.2 + rise, side * 4.6),
                             radius: 0.055, color: "#A9A9A3")
            }
        }
        sphere(group, 0.65, 8, material("#D38D94"), 17, 7.4)
        sphere(group, 1.4, 10, material("#141719"), 16.5, 5.9).scale = vector(0.6, 0.65, 1)
        for side in [-1.0, 1] {
            cylinder(group, 0, 0.32, 1.4, material("#F1E5CA"), 16.9, 6.4, side * 1.1)
            sphere(group, 1.4, 24, dark, 16, 7.2, side * 1.6).scale = vector(1.2, 0.6, 0.8)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(13, 5, 0), name: "bow-cat-head-facing-positive-x"), as: .figurehead)
        for side in [-1.0, 1] {
            sphere(group, 2, 10, dark, 10.5, 5.8, side * 5.3).scale = vector(1.4, 0.7, 1)
            for x in [9.1, 10.3, 11.5] {
                sphere(group, 0.5, 18, material("#D9CDB2"), x, 5.5, side * 6.4).scale = vector(1.2, 0.5, 0.7)
            }
            for x in [-9.0, -4, 1, 6] {
                box(group, 1.4, 1.4, 0.2, material("#1D2328"), x, 1.7, side * 5.7)
            }
        }
        return group
    }

    private static func specialBaratie() -> SCNNode {
        let group = SCNNode(), cream = material("#F5D9AB"), green = material("#4B8B75")
        specialRoundHull(group, sections: [(-17, 0.1), (-13, 2.5), (-8, 3.9), (2, 4.2),
                                           (9, 3.3), (13, 1.8), (15, 0.1)], y: 0.7,
                         upper: cream, lower: material("#B56848"), depthScale: 1.65)
        let deck = SCNCylinder(radius: 1, height: 0.6)
        deck.radialSegmentCount = 48
        put(group, deck, material("#CBAC73"), -1, 5).scale = vector(15, 1, 7.5)
        cylinder(group, 8, 8, 6, cream, -1, 8)
        cylinder(group, 8.7, 8.7, 0.8, green, -1, 11.5)
        cylinder(group, 5.5, 5.5, 4, cream, -1, 13.8)
        cylinder(group, 6.3, 6.3, 0.7, green, -1, 16)
        cylinder(group, 0, 6, 4, green, -1, 18.1)
        cylinder(group, 0.1, 0.4, 2.2, material("#DCB75F", metalness: 0.25), -1, 21)
        for level in [5.3, 11.6, 16.1] {
            let radius = level < 10 ? 8.5 : level < 14 ? 8.7 : 6.3
            torus(group, radius, 0.15, rings: 40, sides: 6, cream, -1, level + 1.1, rx: .pi / 2)
            for index in 0..<16 {
                let angle = Double(index) * .pi / 8
                cylinder(group, 0.09, 0.09, 1.1, cream, -1 + cos(angle) * radius,
                         level + 0.5, sin(angle) * radius)
            }
        }
        for side in [-1.0, 1] {
            for x in [-6.0, -2, 2, 6] { box(group, 1.2, 2.2, 0.2, material("#496375"), x, 8, side * 7.5) }
        }
        for side in [-1.0, 1] {
            for x in [-5.5, -2.5, 0.5, 3.5] {
                profile(group, [(x - 1.5, 11.5), (x + 1.5, 11.5), (x + 1.5, 10),
                                (x - 1.5, 10)], 1.7,
                        material(x < 0 ? "#568D78" : "#EADCB9"), bevel: 0.1).position.z = CGFloat(side * 7.7)
            }
            specialTube(group, points: [vector(10, 3.5, side * 4), vector(9, 5, side * 4.7),
                                        vector(10, 6.8, side * 4)], radii: [0.22, 0.3, 0.18],
                        surface: material("#AF6D50"))
        }
        let headStart = group.childNodes.count
        sphere(group, 4.2, 32, cream, 14, 5).scale = vector(1.3, 1, 1)
        specialEyes(group, 16.5, 6, 0, spacing: 2.6, radius: 0.8)
        torus(group, 1.6, 0.4, rings: 16, sides: 6, material("#A94E44"), 18, 4.8, ry: .pi / 2)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(12, 4, 0), name: "bow-fish-head-facing-positive-x"), as: .figurehead)
        let tailStart = group.childNodes.count
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: -14, y: 3))
        tail.curve(to: NSPoint(x: -21, y: 8), controlPoint1: NSPoint(x: -17, y: 4), controlPoint2: NSPoint(x: -19, y: 8))
        tail.curve(to: NSPoint(x: -18.5, y: 2.5), controlPoint1: NSPoint(x: -21, y: 5), controlPoint2: NSPoint(x: -19, y: 4))
        tail.curve(to: NSPoint(x: -21, y: -2), controlPoint1: NSPoint(x: -19, y: 1), controlPoint2: NSPoint(x: -21, y: 0))
        tail.curve(to: NSPoint(x: -14, y: 3), controlPoint1: NSPoint(x: -18, y: -1), controlPoint2: NSPoint(x: -17, y: 2))
        tail.close()
        extrude(group, tail, 2, green, bevel: 0.25)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-14, 3, 0)), as: .serpent)
        return group
    }

    private static func specialSexyFoxy() -> SCNNode {
        let group = SCNNode(), purple = material("#B16A9C"), wood = material("#9D503F")
        specialHull(group, color: "#9D503F", width: 13, rail: "#DAB34F")
        box(group, 11, 5, 11, purple, -6, 8)
        profile(group, [(-12.5, 10.5), (-6, 14.7), (0.5, 10.5)], 12,
                material("#7A435F"), bevel: 0.2)
        specialBalcony(group, x: -6, y: 7, width: 12, depth: 12.3, tint: material("#DAB34F"))
        specialRig(group, x: -2, height: 20, sailColor: "#EEE3CD", width: 13)
        sphere(group, 4, 32, wood, 14, 8).scale = vector(1.1, 1.1, 1)
        sphere(group, 1.8, 24, material("#E5B77C"), 17.5, 6.8).scale = vector(1.7, 0.8, 1)
        sphere(group, 0.7, 20, material("#33292B"), 20, 7.2)
        for side in [-1.0, 1] {
            cylinder(group, 0, 1.6, 6, wood, 14, 12.7, side * 2.5, rz: side * 0.15)
            profile(group, [(13, 11), (13.6, 15), (15.6, 11.4)], 0.3,
                    material("#E5B77C"), bevel: 0.05).position.z = CGFloat(side * 2.7)
            sphere(group, 0.65, 8, material("#242327"), 17, 9, side * 1.7)
            box(group, 5.5, 0.7, 1.8, material("#E9C48A"), -6, 11, side * 5.8)
        }
        cylinder(group, 0, 1.4, 5, purple, -10, 13)
        let tailStart = group.childNodes.count
        sphere(group, 3.4, 12, wood, -16, 7).scale = vector(1.2, 1.5, 0.7)
        sphere(group, 2, 10, material("#F0D8B0"), -17, 11).scale = vector(0.8, 1.2, 0.7)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-14, 5, 0)), as: .serpent)
        for side in [-1.0, 1] {
            cylinder(group, 0.18, 0.18, 3.5, material("#5B5C5A"), 12, 1.5, side * 5.4)
            sphere(group, 1.6, 10, material("#686C6D"), 12, -0.7, side * 5.4)
            for x in [10.8, 12, 13.2] {
                sphere(group, 0.6, 8, material("#686C6D"), x, -1.8, side * 5.4)
            }
        }
        return group
    }

    private static func specialMammoth() -> SCNNode {
        let group = SCNNode(), brown = material("#7A5644"), ivory = material("#F3E0B2")
        specialHull(group, color: "#715247", width: 13, rail: "#B28C62")
        specialRig(group, x: -5, height: 19, sailColor: "#E8D9C3", width: 13)
        specialRig(group, x: 5, height: 15, sailColor: "#D7C5A5", width: 8)
        sphere(group, 4.5, 32, brown, 13, 8)
        for side in [-1.0, 1] {
            sphere(group, 2.6, 24, brown, 11.6, 8, side * 3.6).scale = vector(0.5, 1.1, 1)
            specialTube(group, points: [vector(14.5, 5, side * 2.6), vector(17, 3.1, side * 3.3),
                                        vector(20.2, 3.9, side * 3.9), vector(21.7, 7.2, side * 4)],
                        radii: [0.95, 0.75, 0.45, 0.04], surface: ivory, sides: 20)
            sphere(group, 0.5, 8, material("#1C2024"), 16, 9.1, side * 1.7)
        }
        let trunkStart = group.childNodes.count
        specialTube(group, points: [vector(16, 6.7, 0), vector(17, 4.5, 0), vector(17.5, 2.2, 0),
                                    vector(19.4, 1.4, 0), vector(20.3, 2.8, 0)],
                    radii: [1.4, 1.2, 0.95, 0.75, 0.45], surface: brown, sides: 24)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: trunkStart,
                                                       pivot: vector(16, 6.7, 0)), as: .serpent)
        return group
    }

    private static func specialSnapperHead() -> SCNNode {
        let group = SCNNode(), blue = material("#537B8A"), cream = material("#ECD7A8")
        specialHull(group, color: "#425F71", width: 13, rail: "#CCAE75")
        specialRig(group, x: -5, height: 19, sailColor: "#4E8D9D", width: 12)
        specialRig(group, x: 5, height: 15, sailColor: "#6AABB2", width: 8)
        sphere(group, 4.2, 32, blue, 14, 6.5).scale = vector(1.25, 0.9, 1)
        sphere(group, 3.2, 24, cream, 16, 4.5).scale = vector(1.15, 0.45, 1.05)
        for side in [-1.0, 1] {
            sphere(group, 3, 24, blue, -4, 8, side * 3).scale = vector(2.3, 0.8, 0.65)
            profile(group, [(-3, 4), (3, 2), (-2, 1), (-6, 3)], 1.5,
                    material("#6495A0"), bevel: 0.2).position.z = CGFloat(side * 5.9)
            specialTube(group, points: [vector(9.5, 4.2, side * 4), vector(8.3, 6, side * 4.7),
                                        vector(9.5, 8.3, side * 4)],
                        radii: [0.2, 0.3, 0.15], surface: cream)
        }
        specialEyes(group, 16.5, 8.2, 0, spacing: 2.3, radius: 0.85)
        for z in [-2.0, 2] {
            cylinder(group, 0, 0.7, 2.4, cream, 15, 9.6, z)
        }
        let tailStart = group.childNodes.count
        profile(group, [(-13, 4), (-20, 9), (-18, 3), (-20, -2)], 1, blue)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-13, 4, 0)), as: .serpent)
        for z in [-5.5, 5.5] {
            for index in 0..<5 {
                let x = 6 + Double(index)
                cylinder(group, 0, 0.7, 3.6 - abs(2 - Double(index)) * 0.5,
                         material("#D4B568"), x, 7, z, rz: -0.4)
            }
        }
        return group
    }

    private static func specialArkMaxim() -> SCNNode {
        let group = SCNNode(), gold = material("#D9AE47", metalness: 0.5), dark = material("#655037")
        specialHull(group, color: "#A9843C", width: 12, length: 28, rail: "#F2D27B")
        cylinder(group, 5, 5, 6, gold, 1, 8)
        cylinder(group, 1.2, 6.4, 6, gold, 1, 14)
        for level in [6.5, 10.5, 11.4] {
            torus(group, level < 8 ? 5.2 : 5.7, 0.2, rings: 32, sides: 8, gold, 1, level, rx: .pi / 2)
        }
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let x = 1 + cos(angle) * 4.7, z = sin(angle) * 4.7
            cylinder(group, 0.23, 0.35, 5, material("#ECD18B", metalness: 0.4), x, 8, z)
            if index.isMultiple(of: 2) {
                specialTube(group, points: [vector(x, 11, z), vector(x * 0.65 + 0.35, 14, z * 0.6), vector(1, 17.2, 0)],
                            radii: [0.12, 0.15, 0.1], surface: material("#F0D78F", metalness: 0.5))
            }
        }
        box(group, 3, 1.8, 2.5, material("#6C5336"), 1, 7.1)
        box(group, 0.5, 4.5, 3.3, gold, -0.5, 8.2)
        cylinder(group, 0.2, 0.5, 3, gold, 1, 18.5)
        mast(group, -7, 5, 20, dark)
        for z in [-5.5, 5.5] {
            box(group, 23, 0.5, 2.2, gold, 0, 8, z)
            for x in [-10.0, 0, 10] {
                cylinder(group, 0.25, 0.25, 5, dark, x, 10, z)
                let rotor = SCNNode()
                rotor.name = "lifting-rotor-axis-y"
                rotor.position = vector(x, 12.6, z)
                sphere(rotor, 0.55, 20, gold, 0, 0.15)
                for bladeIndex in 0..<4 {
                    let blade = SCNNode()
                    blade.eulerAngles.y = CGFloat(Double(bladeIndex) * .pi / 2)
                    rotor.addChildNode(blade)
                    let leaf = profile(blade, [(0, 0), (1.2, 0.1), (3.7, 0.6), (3.8, 1.2),
                                               (2.8, 1.4), (0.5, 0.6)], 0.18, gold, bevel: 0.08)
                    leaf.eulerAngles.x = -.pi / 2
                }
                group.addChildNode(rotor)
                PaperweightShipAnimation.tag(rotor, as: .rotor)
            }
        }
        for index in 0..<4 {
            let angle = Double(index) * .pi / 2
            let x = -5 + cos(angle) * 4, y = 18 + sin(angle) * 4
            cylinder(group, 1.8, 1.8, 1.5, material("#EEDBB4"), x, y, -0.3, rx: .pi / 2)
            torus(group, 1.7, 0.25, rings: 12, sides: 6, dark, x, y, 0.55)
            for side in [-1.0, 1] {
                detailedRope(group, from: vector(-7, 13, 0), to: vector(x, y, side * 0.8),
                             radius: 0.11, color: "#DCBD6A")
            }
        }
        sphere(group, 2.6, 32, gold, 15, 8).scale = vector(0.75, 1.25, 1.05)
        sphere(group, 1.9, 24, gold, 15.8, 5.8).scale = vector(0.55, 0.7, 0.95)
        for z in [-1.1, 1.1] {
            sphere(group, 0.5, 8, dark, 17.2, 8.5, z)
        }
        box(group, 0.4, 0.45, 2.6, dark, 17.2, 6.9)
        cylinder(group, 0.45, 0.7, 1.6, gold, 17.5, 7.8, rz: .pi / 2)
        return group
    }

    private static func specialDutchman() -> SCNNode {
        let group = SCNNode(), moss = material("#6C7453"), dark = material("#514631")
        specialHull(group, color: "#726047", width: 12, rail: "#A49269")
        for (x, h) in [(-7.0, 17.0), (2, 21), (9, 15)] {
            mast(group, x, 5, h, dark)
            let cloth = material("#A5B19A", doubleSided: true)
            cloth.transparent.contents = tornSail
            cloth.transparencyMode = .aOne
            let squareRig = specialSquareRig(group, x: x)
            sail(squareRig, 0, 5 + h * 0.55, 8, h * 0.5, cloth, brace: 0)
            box(squareRig, 8.7, 0.35, 0.35, dark, 0, 5 + h * 0.8)
        }
        for x in [-10.0, -3, 4, 10] {
            cylinder(group, 0.4, 1.1, 3.5, moss, x, 5.4, 5.8)
            cylinder(group, 0.3, 0.9, 2.5, moss, x + 1, 5, -5.8)
        }
        // The wreck has missing upper planks, exposed ribs and an asymmetric
        // aft cabin; it is a physical wooden ghost ship, not translucent glass.
        for side in [-1.0, 1] {
            for x in [-11.0, -5, 1, 7] {
                profile(group, [(x - 0.3, 3), (x, 7.5), (x + 0.8, 6.3), (x + 0.6, 3)],
                        0.4, plankedWood("#61523D"), bevel: 0.05).position.z = CGFloat(side * 5.6)
            }
        }
        put(group, SCNBox(width: 6, height: 5, length: 7, chamferRadius: 0.3),
            plankedWood("#655844"), -10, 9)
        profile(group, [(-14, 11.4), (-10, 14), (-6, 11.4)], 8,
                plankedWood("#494B39"), bevel: 0.1)
        sphere(group, 2.8, 12, material("#DFD5AD"), 14, 8)
        for z in [-1.2, 1.2] { sphere(group, 0.65, 8, dark, 16, 8, z) }
        box(group, 2.4, 1.6, 2.8, material("#DFD5AD"), 14.3, 5.9)
        return group
    }

    private static func specialNoah() -> SCNNode {
        let group = SCNNode(), wood = plankedWood("#856244"), roof = plankedWood("#5C514B")
        specialHull(group, color: "#77543A", width: 15, length: 33, rail: "#C09C68")
        box(group, 27, 11, 13, wood, -1, 9.5)
        let roundedRoof = NSBezierPath()
        roundedRoof.move(to: NSPoint(x: -15, y: 15))
        roundedRoof.curve(to: NSPoint(x: 13, y: 15), controlPoint1: NSPoint(x: -13, y: 23),
                          controlPoint2: NSPoint(x: 11, y: 23))
        roundedRoof.close()
        extrude(group, roundedRoof, 14, roof, bevel: 0.4)
        for x in stride(from: -13.0, through: 11, by: 3) {
            // Broad external frames express the ark's enormous timber span.
            for side in [-1.0, 1] {
                box(group, 0.42, 11.5, 0.38, material("#B28F5E"), x, 9.7, side * 6.9)
            }
        }
        for y in [6.8, 9.4, 12, 14.7] { box(group, 27.3, 0.28, 13.7, material("#B28F5E"), -1, y) }
        torus(group, 2.5, 0.8, rings: 14, sides: 6, wood, 16.2, 5.3, ry: .pi / 2)
        for side in [-1.0, 1] {
            for x in stride(from: -11.0, through: 10, by: 3) {
                for y in [5.5, 8.1, 10.7, 13.3] {
                    box(group, 1.2, 1.6, 0.2, material("#2B302E"), x, y, side * 6.7)
                    box(group, 0.15, 1.6, 0.25, material("#B18D5E"), x, y, side * 6.8)
                }
                box(group, 0.3, 10, 0.3, material("#B18D5E"), x + 1.3, 9.5, side * 6.8)
            }
            // The ark's immense towing chains sway as a unit from their attachment.
            let chainStart = group.childNodes.count
            for index in 0..<5 {
                torus(group, 0.85, 0.22, rings: 10, sides: 6, material("#575E60", metalness: 0.5),
                      15 + Double(index) * 1.1, 4 - Double(index) * 0.5, side * 5,
                      ry: index.isMultiple(of: 2) ? 0 : .pi / 2)
            }
            PaperweightShipAnimation.tag(specialMovingPart(group, from: chainStart,
                                                           pivot: vector(15, 4, side * 5), name: "bow-towing-chain"), as: .serpent)
        }
        return group
    }

    private static func specialStriker() -> SCNNode {
        let group = SCNNode(), green = material("#477D69")
        // Ace's narrow one-person fire-powered craft has two side floats.
        for z in [-3.0, 3] {
            let float = SCNNode()
            float.position.z = CGFloat(z)
            group.addChildNode(float)
            specialRoundHull(float, sections: [(-13, 0.1), (-10, 1.2), (-3, 1.35),
                                               (7, 1.2), (13, 0.1)], y: 0,
                             upper: green, lower: material("#355F50"))
        }
        box(group, 13, 0.7, 6, plankedWood("#BB8751"), 0, 1.5)
        put(group, SCNBox(width: 3, height: 1.5, length: 3, chamferRadius: 0.5), material("#8D6849"), -1, 2.5)
        for x in [-5.5, 4.5] {
            detailedRope(group, from: vector(x, 1, -4.2), to: vector(x, 1, 4.2), radius: 0.18, color: "#A89467")
        }
        cylinder(group, 0.4, 0.4, 13, material("#534C42"), 3, 8)
        flat(group, [(3.4, 13.8), (3.4, 4), (10, 4)], material("#EEE2C1", doubleSided: true))
        detailedRope(group, from: vector(3, 14.5, 0), to: vector(-7, 1.6, 0), radius: 0.055)
        detailedRope(group, from: vector(3, 14.5, 0), to: vector(10, 1.6, 0), radius: 0.055)
        cylinder(group, 1.4, 1.4, 0.3, material("#68685A", metalness: 0.2), -7, 3.7)
        cylinder(group, 1.2, 1.8, 3, material("#605F56"), -7, 2.5, rz: .pi / 2)
        let flame = material("#F29A37")
        let fire = sphere(group, 1.3, 10, flame, -10, 2.5)
        fire.name = "aft-fire-exhaust-facing-negative-x"
        fire.scale = vector(2, 0.8, 0.8)
        PaperweightShipAnimation.tag(fire, as: .pulse)
        return group
    }

    private static func specialWindGranma() -> SCNNode {
        let group = SCNNode(), green = material("#4B7E68"), gold = material("#C2AC6E")
        specialHull(group, color: "#354A45", width: 12, rail: "#B4A16F")
        specialRig(group, x: -6, height: 20, sailColor: "#46524B", width: 11)
        specialRig(group, x: 4, height: 17, sailColor: "#46524B", width: 9)
        // Dragon-shaped bow with a curling neck and swept-back horns.
        let dragonStart = group.childNodes.count
        specialTube(group, points: [vector(11.5, 4.8, 0), vector(13, 7, 0), vector(13.4, 10, 0),
                                    vector(15.5, 12.4, 0)],
                    radii: [2, 1.7, 1.4, 1.9], surface: green, sides: 24)
        sphere(group, 2.6, 32, green, 16.7, 12.7).scale = vector(1.4, 0.8, 0.85)
        sphere(group, 1.7, 24, material("#89A17B"), 18.6, 11.9).scale = vector(1.4, 0.35, 1)
        for y in [7.0, 8.7, 10.4, 12.1] {
            cylinder(group, 0, 0.55, 1.8, gold, 12.2, y, rz: 0.8)
        }
        for z in [-1.5, 1.5] {
            cylinder(group, 0, 0.6, 4, gold, 14.5, 15, z, rz: 0.7)
            sphere(group, 0.45, 8, material("#EBD99B"), 18, 13.4, z)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: dragonStart,
                                                       pivot: vector(12.5, 6, 0), name: "bow-dragon-head-facing-positive-x"), as: .figurehead)
        let tailStart = group.childNodes.count
        profile(group, [(-13, 3), (-17, 7), (-19, 7.5), (-18, 5), (-15, 2)], 2, green)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-13, 3, 0)), as: .serpent)
        return group
    }

    private static func specialGerma() -> SCNNode {
        let group = SCNNode(), cream = material("#DDD4B9"), dark = material("#4D6975")
        // Germa's seagoing castle rides a gigantic Den Den Mushi.
        sphere(group, 9, 32, material("#A5AD8B"), 1, 0.5).scale = vector(1.65, 0.6, 0.85)
        sphere(group, 7, 32, dark, -4, 5).scale = vector(1.4, 1, 1.15)
        for side in [-1.0, 1] {
            let spiral = (0...60).map { index -> SCNVector3 in
                let progress = Double(index) / 60
                let radius = 0.4 + progress * 5.6, angle = progress * .pi * 4.5
                return vector(-4 + cos(angle) * radius, 5 + sin(angle) * radius,
                              side * (8.1 - progress * 0.45))
            }
            specialTube(group, points: spiral, radii: [Double](repeating: 0.4, count: spiral.count),
                        surface: material("#C9C3A8"), sides: 10)
            specialTube(group, points: [vector(-12, -1, side * 4.5), vector(-5, -2.9, side * 7.4),
                                        vector(6, -2.2, side * 6.7), vector(14, 0.4, side * 3.4)],
                        radii: [0.55, 0.65, 0.6, 0.2], surface: material("#88936F"), sides: 18)
        }
        specialBalcony(group, x: -4, y: 9, width: 17, depth: 13.3, tint: cream)
        box(group, 14, 5, 11, cream, -4, 11)
        box(group, 7, 4, 7, cream, -4, 15.3)
        profile(group, [(-8.5, 17.2), (-4, 21), (0.5, 17.2)], 8, material("#416A89"), bevel: 0.25)
        for side in [-1.0, 1] {
            for x in [-9.0, -6, -3, 0] {
                box(group, 1, 1.8, 0.15, material("#354959"), x, 11.5, side * 5.6)
                box(group, 1.2, 0.3, 0.3, material("#AC9D77"), x, 10.4, side * 5.7)
            }
        }
        for x in [-10.0, 2] {
            for z in [-4.5, 4.5] {
                specialTurret(group, x: x, y: 11, z: z, height: 6, radius: 1.7,
                              wall: cream, roof: material("#416A89"))
            }
        }
        let headStart = group.childNodes.count
        sphere(group, 3.6, 32, material("#A5AD8B"), 13, 2.7).scale = vector(1.3, 0.8, 1)
        for z in [-2.0, 2] {
            cylinder(group, 0.35, 0.5, 5, material("#A5AD8B"), 13, 7, z, rz: -0.1)
            sphere(group, 1.1, 12, cream, 13.3, 9.5, z)
            sphere(group, 0.5, 8, material("#202731"), 14.15, 9.5, z)
        }
        specialTube(group, points: [vector(15.8, 2.3, -1.8), vector(16.4, 1.9, 0), vector(15.8, 2.3, 1.8)],
                    radii: [0.15, 0.17, 0.15], surface: material("#68775D"))
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(10, 3, 0), name: "bow-snail-head-facing-positive-x"), as: .serpent)
        for x in [-8.0, 0] {
            mast(group, x, 13, 14, material("#252C37"))
            let squareRig = specialSquareRig(group, x: x)
            box(squareRig, 7.2, 0.35, 0.35, material("#252C37"), 0, 25.5)
            let numberedSail = craftedSail(squareRig, x: 0, y: 22.5, width: 6.5, height: 6,
                                           material: material("#272D37", doubleSided: true), bulge: 0.845)
            numberedSail.name = "germa-numbered-sail"
            PaperweightShipAnimation.tag(numberedSail, as: .sail)
            // Twin sixes on each black Germa sail.
            for digit in [-1.2, 1.2] {
                for side in [-1.0, 1] {
                    torus(numberedSail, 0.7, 0.19, rings: 12, sides: 6, cream,
                          digit, -0.5, side * 1.1)
                    // These are separately raised marks on the two faces,
                    // so each six's spine must be at the viewer's left. Keep
                    // the marks on their sail joint so they flutter with it.
                    box(numberedSail, 0.35, 1.5, 0.2, cream, digit - side * 0.55, 0.5, side * 1.1,
                        rz: -side * 0.25)
                }
            }
        }
        return group
    }

    private static func specialMarine(garp: Bool) -> SCNNode {
        let group = SCNNode(), blue = material("#3C6A8E"), white = material("#EFEADB")
        specialHull(group, color: "#47769A", width: 12, length: 31, rail: "#F0EEE0")
        put(group, SCNBox(width: 8, height: 6, length: 9.5, chamferRadius: 0.4), white, -10, 8)
        specialBalcony(group, x: -10, y: 8.5, width: 9, depth: 10.5, tint: white)
        box(group, 9, 0.5, 10.5, blue, -10, 11.3)
        for side in [-1.0, 1] {
            for x in [-12.0, -9.5, -7] {
                box(group, 1.4, 1.8, 0.15, material("#254B64"), x, 9, side * 4.85)
            }
        }
        let cloth = textured(canvas(192, 160) { context, width, height in
            fill(context, "#EFEADB", CGRect(x: 0, y: 0, width: width, height: height))
            context.setStrokeColor(color("#3C6A8E").cgColor)
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 34, y: 72))
            context.addCurve(to: CGPoint(x: 96, y: 87), control1: CGPoint(x: 61, y: 49), control2: CGPoint(x: 84, y: 56))
            context.addCurve(to: CGPoint(x: 158, y: 72), control1: CGPoint(x: 108, y: 56), control2: CGPoint(x: 131, y: 49))
            context.strokePath()
            context.move(to: CGPoint(x: 96, y: 86)); context.addLine(to: CGPoint(x: 96, y: 115))
            context.move(to: CGPoint(x: 78, y: 108)); context.addQuadCurve(to: CGPoint(x: 114, y: 108), control: CGPoint(x: 96, y: 132))
            context.strokePath()
        }, roughness: 0.85)
        for (x, height) in [(-6.0, 17.0), (2, 21), (9, 16)] {
            mast(group, x, 5, height, material("#806444"))
            let squareRig = specialSquareRig(group, x: x)
            sail(squareRig, 0, 5 + height * 0.55, 8, 7, cloth, brace: 0)
            sail(squareRig, 0, 5 + height * 0.83, 5.5, 3.2, white, brace: 0)
            box(squareRig, 8.7, 0.35, 0.35, material("#806444"), 0, 8.5 + height * 0.55)
            box(squareRig, 6.2, 0.3, 0.3, material("#806444"), 0, 6.6 + height * 0.83)
            for side in [-1.0, 1] {
                detailedRope(group, from: vector(x, 5 + height * 0.92, 0),
                             to: vector(x - 4.5, 5.4, side * 4.6), radius: 0.055)
                detailedRope(group, from: vector(x, 5 + height * 0.92, 0),
                             to: vector(x + 4.5, 5.4, side * 4.6), radius: 0.055)
            }
        }
        for side in [-1.0, 1] {
            for x in stride(from: -10.0, through: 10, by: 4) {
                for fraction in [0.42, 0.72] {
                    let point = craftedHullPoint(x: x, fraction: fraction, side: side,
                                                 length: 31, width: 12, deck: 5, keel: -4, stern: 8)
                    box(group, 1.5, 1.3, 0.25, material("#293344"), Double(point.x), Double(point.y), Double(point.z))
                    cylinder(group, 0.4, 0.5, 2.2, material("#4C5156", metalness: 0.3),
                             Double(point.x), Double(point.y), Double(point.z) + side * 0.8, rx: .pi / 2)
                }
            }
        }
        if garp {
            let headStart = group.childNodes.count
            sphere(group, 3.8, 32, material("#F4E9D6"), 15, 7)
            sphere(group, 2, 28, material("#D6B88C"), 18, 6.2).scale = vector(1.4, 0.8, 1)
            sphere(group, 0.9, 10, material("#29313A"), 20.3, 6.8)
            for z in [-2.7, 2.7] {
                sphere(group, 1.8, 10, material("#A98563"), 13.4, 8.3, z).scale = vector(0.6, 1.5, 0.8)
                sphere(group, 0.45, 8, material("#29313A"), 17.2, 8.3, z * 0.5)
            }
            // The dog's bone is visible even at miniature size.
            box(group, 0.8, 0.8, 8, white, 18.7, 5.7)
            for z in [-4.0, 4] { sphere(group, 0.8, 10, white, 18.7, 5.7, z) }
            torus(group, 3.2, 0.3, rings: 28, sides: 8, blue, 12.9, 6.8, ry: .pi / 2)
            PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                           pivot: vector(13, 5, 0), name: "bow-dog-head-facing-positive-x"), as: .figurehead)
        } else {
            profile(group, [(13, 5), (17, 11), (19, 10), (17, 4)], 2.5, white)
        }
        return group
    }

    private static func specialRaft() -> SCNNode {
        let group = SCNNode(), wood = plankedWood("#9A6A3C"), dark = material("#59412F")
        for z in stride(from: -6.0, through: 6, by: 3) {
            let log = SCNNode()
            log.position.z = CGFloat(z)
            group.addChildNode(log)
            specialRoundHull(log, sections: [(-15, 1.1), (-11, 1.55), (-2, 1.7),
                                             (8, 1.55), (14.7, 1.25)], y: -0.2,
                             upper: wood, lower: plankedWood("#82552F"))
            for x in [-14.6, 14.6] {
                disc(group, 1.25, 12, material("#CB9C61"), x, -0.2, z, ry: .pi / 2)
                torus(group, 0.75, 0.045, rings: 20, sides: 6, dark, x + (x > 0 ? 0.03 : -0.03), -0.2, z, ry: .pi / 2)
            }
        }
        for x in [-9.0, 8] { box(group, 1, 0.8, 16, dark, x, 1.4) }
        for x in [-9.0, 8] {
            let lash = (0...24).map { index -> SCNVector3 in
                let angle = Double(index) * .pi / 12
                return vector(x, -0.1 + cos(angle) * 1.95, sin(angle) * 7.85)
            }
            specialTube(group, points: lash, radii: [Double](repeating: 0.13, count: lash.count),
                        surface: material("#B29D70"), sides: 8)
        }
        mast(group, 0, 1.8, 20, dark)
        let cloth = textured(canvas(192, 140) { context, width, height in
            fill(context, "#EEE3C8", CGRect(x: 0, y: 0, width: width, height: height))
            context.setStrokeColor(color("#292929").cgColor)
            context.setLineWidth(7)
            for flip in [false, true] {
                context.move(to: CGPoint(x: 49, y: flip ? 118 : 102))
                context.addLine(to: CGPoint(x: 143, y: flip ? 102 : 118))
            }
            context.strokePath()
            for x in [51.0, 83, 115] {
                fill(context, "#292929", CGRect(x: x + 6, y: 78, width: 20, height: 16))
                context.setFillColor(color("#292929").cgColor)
                context.fillEllipse(in: CGRect(x: x, y: 45, width: 33, height: 38))
                context.setFillColor(color("#EEE3C8").cgColor)
                context.fillEllipse(in: CGRect(x: x + 6, y: 58, width: 8, height: 10))
                context.fillEllipse(in: CGRect(x: x + 20, y: 58, width: 8, height: 10))
            }
        }, roughness: 0.88)
        let squareRig = specialSquareRig(group, x: 0)
        sail(squareRig, 0, 13.5, 16, 10, cloth, brace: 0)
        box(squareRig, 16.8, 0.4, 0.4, dark, 0, 18.5)
        for side in [-1.0, 1] {
            detailedRope(squareRig, from: vector(side * 8, 18.5, 0),
                         to: vector(side * 3, 1.8, side * 5), radius: 0.055)
        }
        plane(group, 4.5, 2.8, textured(pirateFlag), 2.2, 22)
        for side in [-1.0, 1] {
            detailedRope(group, from: vector(0, 21.5, 0), to: vector(-10, 1.8, side * 6), radius: 0.065)
            detailedRope(group, from: vector(0, 21.5, 0), to: vector(11, 1.8, side * 6), radius: 0.065)
        }
        for z in [-4.0, 4] { box(group, 5, 3, 3, material("#826647"), -8, 3.4, z) }
        return group
    }
}
