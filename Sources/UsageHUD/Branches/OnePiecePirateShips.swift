import AppKit
import SceneKit

/// Handmade fan miniatures with curved hulls, layered cloth, stepped cabins,
/// and sculpted figureheads. All geometry and textures are generated locally.
@available(macOS 14.0, *)
extension PaperweightShipFactory {
    static func onePiecePirateShip(_ kind: PaperweightShipKind) -> SCNNode {
        switch kind {
        case .goingMerry: pirateMerry()
        case .thousandSunny: pirateSunny()
        case .oroJackson: pirateJackson()
        case .mobyDick: pirateMoby()
        case .redForce: pirateRedForce()
        case .saberOfXebec: pirateXebec()
        case .bigTop: pirateCircus(blaster: false)
        case .bigTopBlaster: pirateCircus(blaster: true)
        case .victoriaPunk: piratePunk()
        case .jewelryMargherita: pirateMargherita()
        case .grudgeDolph: pirateDolph()
        case .liberalHind: pirateHind()
        case .stayTune: pirateTune()
        case .hanjomaru: pirateHanjomaru()
        case .numanciaFlamingo: pirateFlamingo()
        case .dreadnaughtSabre: pirateSabre()
        case .sharkSuperb: pirateShark()
        case .greatEirik: pirateLongship(naglfar: false)
        case .naglfar: pirateLongship(naglfar: true)
        case .goingLuffySenpai: pirateLuffy()
        case .sleepingWhiteHorse: pirateHorse()
        case .yontaMaria: pirateMaria()
        case .usoland: pirateUsoland()
        case .pieceOfSpadille: pirateSpadille()
        default: preconditionFailure("Not a pirate fleet miniature: \(kind)")
        }
    }

    // MARK: Small fleet-building parts

    private enum PirateEmblem {
        case skull, strawHat, roger, whitebeard, redHair, blackbeard, buggy, kid
        case bonney, hawkins, drake, apoo, urouge, flamingo, krieg, arlong, giant, spade
    }

    private static func pirateHull(_ group: SCNNode, _ hex: String, trim: String = "#e6b955",
                                   length: Double = 29, width: Double = 10, stern: Double = 8) {
        craftedHull(group, length: length, width: width, deck: 4, keel: -4, stern: stern, color: hex, trim: trim)
        // Raised quarterdeck, a useful hatch, and a stepped route up from the
        // main deck make the hull read as a vessel rather than an extruded slab.
        let wood = material("#95663d"), rail = material(trim)
        for step in 0..<4 {
            let progress = Double(step + 1) / 4
            box(group, 0.9, 0.35, 2.6, wood, -length * 0.18 - progress * 3.4, 4.5 + (stern - 4.5) * progress)
        }
        box(group, 3.7, 0.35, 2.6, material("#634c37"), 3, 4.5, -1.2)
        for z in [-2.15, -1.5, -0.85, -0.2] { box(group, 3.1, 0.12, 0.15, rail, 3, 4.75, z) }
        for x in [-length * 0.25, length * 0.26] {
            cylinder(group, 0.28, 0.42, 1.1, material("#6b5943"), x, 4.9, width * 0.24)
            cylinder(group, 0.65, 0.65, 0.22, rail, x, 5.5, width * 0.24)
        }
        for side in [-1.0, 1] {
            for x in [-length * 0.24, -length * 0.08, length * 0.08, length * 0.24] {
                let p = craftedHullPoint(x: x, fraction: 0.62, side: side, length: length, width: width, deck: 4, keel: -4, stern: stern)
                piratePorthole(group, x: Double(p.x), y: Double(p.y), z: Double(p.z) + side * 0.13, radius: 0.48)
            }
        }
    }

    private static func pirateBelt(_ group: SCNNode, length: Double, width: Double, stern: Double,
                                   lower: Double, upper: Double, color hex: String) {
        for side in [-1.0, 1] {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
            for step in 0...30 {
                let t = Double(step) / 30, x = -length / 2 + 0.15 + t * (length - 0.15)
                for fraction in [lower, upper] {
                    var point = craftedHullPoint(x: x, fraction: fraction, side: side, length: length, width: width, deck: 4, keel: -4, stern: stern)
                    point.z += CGFloat(side * 0.045)
                    vertices.append(point); normals.append(vector(0, 0, side)); uv.append(CGPoint(x: t * 3, y: fraction))
                }
                if step < 30 {
                    let a = Int32(step * 2), b = a + 1, c = a + 2, d = a + 3
                    indices.append(contentsOf: side > 0 ? [a, c, b, b, c, d] : [a, b, c, b, d, c])
                }
            }
            put(group, mesh(vertices, normals, uv, indices), plankedWood(hex))
        }
    }

    private static func pirateRig(_ group: SCNNode, _ masts: [(Double, Double)], cloth: String = "#f5ead5",
                                  stripe: String? = nil, strawHat: Bool = false, rows: Int = 2,
                                  emblem: PirateEmblem? = .skull, span: Double? = nil) {
        let wood = material("#61432d"), ropeColor = "#786752"
        let mainIndex = (masts.count - 1) / 2
        for (index, pair) in masts.enumerated() {
            let (x, height) = pair
            mast(group, x, 4.5, height, wood)
            let lowerWidth = span ?? (masts.count > 2 ? 8.6 : (rows == 1 ? 12.3 : 11.0))
            for row in 0..<rows {
                let width = lowerWidth - Double(row) * (rows == 3 ? 1.5 : 2.2)
                let sailHeight = height * (rows == 1 ? 0.49 : (rows == 3 ? 0.22 : (row == 0 ? 0.35 : 0.25)))
                let y = 5.8 + height * (rows == 1 ? 0.48 : (rows == 3 ? 0.19 + Double(row) * 0.27 : (row == 0 ? 0.30 : 0.69)))
                let crest: PirateEmblem? = index == mainIndex && row == 0 ? (strawHat ? .strawHat : emblem) : nil
                let sailMaterial = textured(pirateCanvas(cloth, stripe: stripe, emblem: crest), roughness: 0.82)
                // Square yards cross the beam. The complete sail/yard/sling
                // assembly is braced twenty degrees, not placed along the keel.
                let squareRig = SCNNode()
                squareRig.name = "pirate-square-rig-\(index)-\(row)"
                squareRig.position = vector(x, y, 0)
                squareRig.eulerAngles.y = CGFloat.pi / 2 - 0.35
                group.addChildNode(squareRig)
                craftedSail(squareRig, x: 0, y: 0, width: width, height: sailHeight,
                            material: sailMaterial, bulge: width * 0.10)
                let yardY = sailHeight / 2
                cylinder(squareRig, 0.12, 0.19, width + 0.8, wood, 0, yardY, rz: .pi / 2)
                squareRig.childNodes.last?.name = "pirate-square-yard"
                detailedRope(squareRig, from: vector(0, yardY + 1.0, 0), to: vector(-width * 0.49, yardY, 0.15), radius: 0.055, color: ropeColor)
                detailedRope(squareRig, from: vector(0, yardY + 1.0, 0), to: vector(width * 0.49, yardY, 0.15), radius: 0.055, color: ropeColor)
            }
            let nestY = 4.5 + height * 0.78
            cylinder(group, 1.4, 1.05, 0.65, wood, x, nestY)
            torus(group, 1.35, 0.13, rings: 18, sides: 6, wood, x, nestY + 0.32, rx: .pi / 2)
            for side in [-1.0, 1] {
                for dx in [-1.6, 1.6] {
                    detailedRope(group, from: vector(x, 4.5 + height * 0.83, 0), to: vector(x + dx, 4.5, side * 4.2), radius: 0.055, color: ropeColor)
                }
                for rung in 1...3 {
                    let fraction = Double(rung) / 4
                    detailedRope(group, from: vector(x - 1.6 * (1 - fraction), 4.5 + height * 0.65 * fraction, side * 4.2 * (1 - fraction)),
                                 to: vector(x + 1.6 * (1 - fraction), 4.5 + height * 0.65 * fraction, side * 4.2 * (1 - fraction)), radius: 0.045, color: ropeColor)
                }
            }
            let anchorX = index == 0 ? -13.0 : masts[index - 1].0
            detailedRope(group, from: vector(x, 4.5 + height * 0.92, 0), to: vector(anchorX, 5.0, 0), radius: 0.06, color: ropeColor)
            if index == masts.count - 1 {
                detailedRope(group, from: vector(x, 4.5 + height * 0.88, 0), to: vector(13.5, 6.0, 0), radius: 0.06, color: ropeColor)
            }
            plane(group, 2.7, 1.7, textured(pirateFlag), x + 1.35, 4.5 + height, 0.1)
        }
    }

    private static func pirateCanvas(_ base: String, stripe: String?, emblem: PirateEmblem?) -> NSImage {
        canvas(256, 224) { context, width, height in
            fill(context, base, CGRect(x: 0, y: 0, width: width, height: height))
            if let stripe {
                for index in 0..<4 {
                    fill(context, stripe, CGRect(x: CGFloat(index) * 64, y: 0, width: 32, height: height))
                }
            }
            // Broad cloth panels carry visible seams and a restrained edge hem.
            context.setStrokeColor(color("#776a55").withAlphaComponent(0.19).cgColor)
            context.setLineWidth(1.4)
            for x in stride(from: 0, through: 256, by: 32) {
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: 224))
            }
            context.strokePath()
            context.setStrokeColor(color("#776a55").withAlphaComponent(0.45).cgColor)
            context.setLineWidth(4)
            context.stroke(CGRect(x: 4, y: 4, width: width - 8, height: height - 8))
            guard let emblem else { return }
            context.saveGState()
            context.translateBy(x: 128, y: 112)
            let ink = color("#25262d").cgColor, bone = color("#fff4d8").cgColor
            context.setLineCap(.round); context.setLineJoin(.round)
            func stroke(_ points: [CGPoint], width: CGFloat, color: CGColor) {
                guard let first = points.first else { return }
                context.setStrokeColor(color); context.setLineWidth(width); context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
            func skull(_ center: CGPoint, size: CGFloat) {
                context.setFillColor(bone); context.setStrokeColor(ink); context.setLineWidth(4)
                context.fillEllipse(in: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 1.8))
                context.strokeEllipse(in: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 1.8))
                context.fill(CGRect(x: center.x - size * 0.56, y: center.y + size * 0.46, width: size * 1.12, height: size * 0.67))
                context.stroke(CGRect(x: center.x - size * 0.56, y: center.y + size * 0.46, width: size * 1.12, height: size * 0.67))
                context.setFillColor(ink)
                for side in [-1.0, 1] {
                    context.fillEllipse(in: CGRect(x: center.x + CGFloat(side) * size * 0.43 - size * 0.22,
                                                  y: center.y - size * 0.20, width: size * 0.44, height: size * 0.48))
                }
                for x in [-0.28, 0, 0.28] {
                    stroke([CGPoint(x: center.x + CGFloat(x) * size, y: center.y + size * 0.54),
                            CGPoint(x: center.x + CGFloat(x) * size, y: center.y + size * 1.06)], width: 2, color: ink)
                }
            }
            if emblem == .flamingo {
                context.setFillColor(color("#e5bd4e").cgColor); context.fillEllipse(in: CGRect(x: -57, y: -57, width: 114, height: 114))
                context.setStrokeColor(ink); context.setLineWidth(7); context.strokeEllipse(in: CGRect(x: -57, y: -57, width: 114, height: 114))
                context.setFillColor(ink)
                for x in [-24, 17] { context.fillEllipse(in: CGRect(x: x, y: -19, width: 11, height: 16)) }
                context.addArc(center: CGPoint(x: 0, y: 0), radius: 37, startAngle: 0.2, endAngle: .pi - 0.2, clockwise: false)
                context.strokePath()
                stroke([CGPoint(x: -61, y: -64), CGPoint(x: 61, y: 64)], width: 12, color: color("#a82e37").cgColor)
            } else if emblem == .drake {
                for side in [-1.0, 1] {
                    stroke([CGPoint(x: -56, y: CGFloat(side) * 56), CGPoint(x: 56, y: CGFloat(-side) * 56)], width: 17, color: ink)
                    stroke([CGPoint(x: -55, y: CGFloat(side) * 55), CGPoint(x: 55, y: CGFloat(-side) * 55)], width: 8, color: bone)
                }
            } else if emblem == .spade {
                context.setFillColor(ink)
                context.move(to: CGPoint(x: 0, y: -64)); context.addCurve(to: CGPoint(x: -55, y: 8), control1: CGPoint(x: -18, y: -38), control2: CGPoint(x: -59, y: -17))
                context.addCurve(to: CGPoint(x: 0, y: 37), control1: CGPoint(x: -55, y: 44), control2: CGPoint(x: -15, y: 46))
                context.addCurve(to: CGPoint(x: 55, y: 8), control1: CGPoint(x: 15, y: 46), control2: CGPoint(x: 55, y: 44))
                context.addCurve(to: CGPoint(x: 0, y: -64), control1: CGPoint(x: 59, y: -17), control2: CGPoint(x: 18, y: -38))
                context.fillPath(); context.fill(CGRect(x: -9, y: 18, width: 18, height: 46))
            } else {
                for side in [-1.0, 1] {
                    let points = [CGPoint(x: -66, y: CGFloat(side) * 43), CGPoint(x: 66, y: CGFloat(-side) * 43)]
                    stroke(points, width: 17, color: ink); stroke(points, width: 9, color: bone)
                }
                if emblem == .blackbeard {
                    skull(CGPoint(x: -43, y: -8), size: 24); skull(CGPoint(x: 43, y: -8), size: 24); skull(.zero, size: 30)
                } else {
                    skull(.zero, size: 39)
                }
                if emblem == .strawHat {
                    fill(context, "#deb650", CGRect(x: -39, y: -57, width: 78, height: 29))
                    fill(context, "#c4443d", CGRect(x: -39, y: -39, width: 78, height: 10))
                    fill(context, "#deb650", CGRect(x: -58, y: -29, width: 116, height: 10))
                } else if emblem == .whitebeard || emblem == .roger {
                    context.setStrokeColor(emblem == .whitebeard ? bone : ink); context.setLineWidth(emblem == .whitebeard ? 12 : 8)
                    context.move(to: CGPoint(x: -54, y: 8)); context.addCurve(to: CGPoint(x: 54, y: 8), control1: CGPoint(x: -28, y: 66), control2: CGPoint(x: 28, y: 66)); context.strokePath()
                } else if emblem == .redHair {
                    for offset in [-9.0, 2, 13] {
                        stroke([CGPoint(x: offset - 16, y: -43), CGPoint(x: offset + 11, y: 30)], width: 5, color: color("#ad323e").cgColor)
                    }
                } else if emblem == .buggy {
                    context.setFillColor(color("#d93b4d").cgColor); context.fillEllipse(in: CGRect(x: -12, y: -2, width: 24, height: 24))
                    for side in [-1.0, 1] {
                        context.setFillColor(color("#5b99bc").cgColor); context.fillEllipse(in: CGRect(x: CGFloat(side) * 35 - 14, y: -30, width: 28, height: 42))
                    }
                } else if emblem == .kid {
                    stroke([CGPoint(x: -39, y: -34), CGPoint(x: 39, y: -34)], width: 13, color: color("#a64239").cgColor)
                    for x in [-23, 23] { context.setStrokeColor(ink); context.setLineWidth(6); context.strokeEllipse(in: CGRect(x: x - 14, y: -19, width: 28, height: 25)) }
                } else if emblem == .giant {
                    for side in [-1.0, 1] { stroke([CGPoint(x: CGFloat(side) * 29, y: -32), CGPoint(x: CGFloat(side) * 57, y: -55), CGPoint(x: CGFloat(side) * 52, y: -75)], width: 11, color: bone) }
                } else if emblem == .apoo {
                    for side in [-1.0, 1] { stroke([CGPoint(x: CGFloat(side) * 52, y: -24), CGPoint(x: CGFloat(side) * 52, y: 43), CGPoint(x: CGFloat(side) * 68, y: 39)], width: 7, color: ink) }
                } else if emblem == .hawkins {
                    for offset in [-18.0, 0, 18] { stroke([CGPoint(x: -46, y: offset), CGPoint(x: 46, y: offset)], width: 3, color: ink) }
                }
            }
            context.restoreGState()
        }
    }

    @discardableResult
    private static func pirateEllipsoid(_ group: SCNNode, _ radius: Double, _ hex: String,
                                       _ x: Double, _ y: Double, _ z: Double = 0,
                                       scale: SCNVector3 = SCNVector3(1, 1, 1)) -> SCNNode {
        let node = sphere(group, radius, 14, material(hex), x, y, z)
        node.scale = scale
        return node
    }

    private static func pirateEyes(_ group: SCNNode, x: Double, y: Double, z: Double, large: Bool = false) {
        for side in [-1.0, 1] {
            disc(group, large ? 0.85 : 0.55, 12, material("#fff9e8"), x, y, z * side, ry: side < 0 ? .pi : 0)
            disc(group, large ? 0.4 : 0.25, 10, material("#182430"), x + 0.12, y, (z + 0.025) * side, ry: side < 0 ? .pi : 0)
        }
    }

    /// Human/mask faces look along the keel, unlike an animal's lateral eyes.
    /// Mirroring this helper onto the stern reverses only the gaze along X.
    private static func pirateForwardEyes(_ group: SCNNode, x: Double, y: Double, spacing: Double,
                                          radius: Double = 0.50, facing: Double = 1, sockets: Bool = false,
                                          name: String? = nil) {
        for side in [-1.0, 1] {
            let eye = SCNNode()
            eye.position = vector(x, y, side * spacing)
            if let name { eye.name = "\(name)-\(side < 0 ? "left" : "right")" }
            group.addChildNode(eye)
            pirateEllipsoid(eye, radius, sockets ? "#27272a" : "#fff8e2", 0, 0,
                            scale: vector(0.26, 1.05, 0.72))
            if !sockets {
                pirateEllipsoid(eye, radius * 0.50, "#20272b", facing * radius * 0.25, 0,
                                scale: vector(0.35, 1.1, 0.72))
            }
        }
    }

    private static func piratePorthole(_ group: SCNNode, x: Double, y: Double, z: Double, radius: Double = 0.56) {
        let side = z < 0 ? -1.0 : 1.0
        disc(group, radius, 18, material("#173f4f", roughness: 0.22), x, y, z, ry: side < 0 ? .pi : 0)
        torus(group, radius, 0.11, rings: 20, sides: 6, material("#d2ad62", roughness: 0.34, metalness: 0.4), x, y, z + side * 0.035)
        disc(group, radius * 0.18, 10, material("#bad3cd"), x - radius * 0.23, y + radius * 0.27, z + side * 0.05, ry: side < 0 ? .pi : 0)
    }

    private static func pirateArchedRoof(_ group: SCNNode, x: Double, y: Double, width: Double, depth: Double, color hex: String) {
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -width / 2 - 0.35, y: 0))
        outline.curve(to: NSPoint(x: width / 2 + 0.35, y: 0), controlPoint1: NSPoint(x: -width / 2, y: 2.8), controlPoint2: NSPoint(x: width / 2, y: 2.8))
        outline.close()
        let roof = extrude(group, outline, depth + 0.8, material(hex), bevel: 0.16)
        roof.position.x = CGFloat(x); roof.position.y = CGFloat(y)
        for side in [-1.0, 1] { box(group, width + 1, 0.23, 0.2, material("#d2ac6c"), x, y + 0.05, side * (depth / 2 + 0.42)) }
    }

    private static func pirateCabin(_ group: SCNNode, x: Double = -9, y: Double = 7,
                                   color hex: String = "#f3e4c5", roof: String = "#b33a32", width: Double = 7) {
        let body = material(hex), trim = material("#c19a60"), glass = material("#235267", roughness: 0.22)
        put(group, SCNBox(width: width, height: 3.6, length: 7, chamferRadius: 0.25), body, x, y)
        box(group, width + 0.5, 0.35, 7.5, trim, x, y - 1.65)
        box(group, width + 0.5, 0.32, 7.5, trim, x, y + 1.65)
        pirateArchedRoof(group, x: x, y: y + 1.85, width: width, depth: 7.2, color: roof)
        for side in [-1.0, 1] {
            for dx in [-width * 0.28, 0, width * 0.28] {
                box(group, 1.25, 1.55, 0.17, trim, x + dx, y + 0.15, side * 3.57)
                box(group, 0.93, 1.23, 0.2, glass, x + dx, y + 0.15, side * 3.67)
                box(group, 0.09, 1.23, 0.21, trim, x + dx, y + 0.15, side * 3.69)
            }
            for dx in [-width / 2 + 0.15, width / 2 - 0.15] { box(group, 0.25, 3.4, 0.24, trim, x + dx, y, side * 3.63) }
        }
        // An actual forward door and stern gallery break up the superstructure.
        box(group, 0.18, 2.5, 1.35, material("#765234"), x + width / 2 + 0.07, y - 0.3)
        for z in [-2.0, 0, 2] {
            box(group, 0.18, 1.35, 1.25, trim, x - width / 2 - 0.08, y + 0.15, z)
            box(group, 0.2, 1.03, 0.94, glass, x - width / 2 - 0.14, y + 0.15, z)
        }
    }

    private static func pirateCannons(_ group: SCNNode, count: Int = 4, y: Double = 2.5,
                                     length: Double = 29, width: Double = 10, stern: Double = 8, portTrim: String = "#b79357") {
        let iron = material("#343b3c", roughness: 0.34, metalness: 0.45)
        for side in [-1.0, 1] {
            for index in 0..<count {
                let x = -length * 0.28 + Double(index) * length * 0.56 / Double(max(1, count - 1))
                let p = craftedHullPoint(x: x, fraction: 0.80, side: side, length: length, width: width, deck: 4, keel: -4, stern: stern)
                let centerY = Double(p.y) + y - 2.5, z = Double(p.z) + side * 0.10
                box(group, 1.65, 1.5, 0.18, material(portTrim), x, centerY, z)
                box(group, 1.25, 1.12, 0.22, material("#191e20"), x, centerY, z + side * 0.08)
                put(group, SCNBox(width: 1.6, height: 1.25, length: 0.15, chamferRadius: 0.04), material("#765236"), x, centerY + 1.05, z + side * 0.35, rx: side * 0.65)
                cylinder(group, 0.40, 0.57, 2.5, iron, x, centerY, z + side * 0.75, rx: side * .pi / 2)
                disc(group, 0.29, 14, material("#101618"), x, centerY, z + side * 2.02, ry: side < 0 ? .pi : 0)
                torus(group, 0.39, 0.08, rings: 14, sides: 6, iron, x, centerY, z + side * 2.03)
            }
        }
    }

    private static func pirateSpiralHorn(_ group: SCNNode, x: Double, y: Double, z: Double, radius: Double = 1.25, color hex: String = "#bd965c") {
        var outer: [(Double, Double)] = [], inner: [(Double, Double)] = []
        for index in 0...36 {
            let progress = Double(index) / 36, angle = progress * .pi * 3.1
            let r = radius * (1 - progress * 0.83)
            outer.append((x + cos(angle) * (r + 0.15), y + sin(angle) * (r + 0.15)))
            inner.append((x + cos(angle) * max(0.03, r - 0.15), y + sin(angle) * max(0.03, r - 0.15)))
        }
        let horn = profile(group, outer + inner.reversed(), 0.35, material(hex), bevel: 0.08)
        horn.position.z = CGFloat(z)
    }

    private static func pirateHorn(_ group: SCNNode, _ x: Double, _ y: Double, _ z: Double,
                                  length: Double = 3, rz: Double = -0.5, hex: String = "#f7e9c6") {
        cylinder(group, 0, 0.7, length, material(hex), x, y, z, rz: rz)
    }

    /// Reparent a just-built assembly around its mechanical joint, preserving
    /// every child's original transform before the animation engine captures it.
    private static func pirateJoint(_ group: SCNNode, since index: Int, at pivot: SCNVector3) -> SCNNode {
        let parts = Array(group.childNodes.dropFirst(index))
        let joint = SCNNode()
        joint.position = pivot
        for part in parts {
            let position = part.position
            part.removeFromParentNode()
            joint.addChildNode(part)
            part.position = SCNVector3(position.x - pivot.x, position.y - pivot.y, position.z - pivot.z)
        }
        group.addChildNode(joint)
        return joint
    }

    private static func pirateFigurehead(_ group: SCNNode, since index: Int, at pivot: SCNVector3) {
        PaperweightShipAnimation.tag(pirateJoint(group, since: index, at: pivot), as: .figurehead)
    }

    // MARK: Straw Hats, Roger, and the Emperors

    private static func pirateMerry() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#ad713e", trim: "#f6e8c6", length: 25, width: 9, stern: 7)
        pirateBelt(g, length: 25, width: 9, stern: 7, lower: 0.56, upper: 0.86, color: "#303745")
        pirateRig(g, [(2, 18)], strawHat: true, rows: 1, span: 11.3)
        pirateRig(g, [(-8, 12)], cloth: "#f8ead2", stripe: "#b6463e", rows: 1, emblem: nil, span: 6.8)
        pirateCabin(g, x: -8.3, y: 7.6, color: "#eadcb7", roof: "#a94135", width: 5.6)
        for side in [-1.0, 1] {
            for x in [-9.0, -5, -1, 3, 7] {
                let low = craftedHullPoint(x: x, fraction: 0.45, side: side, length: 25, width: 9, deck: 4, keel: -4, stern: 7)
                let high = craftedHullPoint(x: x, fraction: 0.94, side: side, length: 25, width: 9, deck: 4, keel: -4, stern: 7)
                detailedRope(g, from: vector(x, Double(low.y), Double(low.z) + side * 0.08),
                             to: vector(x, Double(high.y), Double(high.z) + side * 0.08), radius: 0.12, color: "#e4dbc1")
            }
            let scroll = profile(g, [(7, 5.8), (10, 6.1), (12, 8.8), (14.2, 9.1), (14.6, 7.7),
                                     (13.4, 7.1), (12.8, 8.0), (11.8, 7.0), (10.4, 5.0), (7, 5.0)],
                                 0.38, material("#efe7d0"), bevel: 0.15)
            scroll.position.z = CGFloat(side * 3.9)
        }
        let bowStart = g.childNodes.count
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: 10.5, y: 3)); neck.curve(to: NSPoint(x: 15.1, y: 9), controlPoint1: NSPoint(x: 13.8, y: 3.2), controlPoint2: NSPoint(x: 12.6, y: 8.7))
        neck.line(to: NSPoint(x: 16.6, y: 8.2)); neck.curve(to: NSPoint(x: 12.0, y: 2.4), controlPoint1: NSPoint(x: 15.5, y: 5), controlPoint2: NSPoint(x: 15.0, y: 2.6)); neck.close()
        extrude(g, neck, 2.2, material("#f1e6c7"), bevel: 0.35)
        pirateEllipsoid(g, 1.95, "#f8efcf", 15.7, 9.0, scale: vector(1.18, 0.92, 0.88))
        pirateEllipsoid(g, 1.1, "#e8d6af", 17.4, 8.35, scale: vector(1.1, 0.72, 0.9))
        pirateEyes(g, x: 16.2, y: 9.45, z: 1.63)
        for side in [-1.0, 1] {
            pirateSpiralHorn(g, x: 14.5, y: 9.35, z: side * 1.8, radius: 1.3)
            disc(g, 0.19, 12, material("#8b7658"), 17.9, 8.6, side * 0.9, ry: side < 0 ? .pi : 0)
        }
        pirateFigurehead(g, since: bowStart, at: vector(12.6, 5, 0))
        for (x, z) in [(-10.0, -2.3), (-7.8, -2.5), (-9, 2.2)] {
            cylinder(g, 0.18, 0.3, 2.2, material("#88643b"), x, 10.3, z)
            pirateEllipsoid(g, 1.25, "#4b863c", x, 11.8, z, scale: vector(1.1, 0.9, 1))
            for (dx, dz) in [(-0.65, 0.3), (0.45, 0.65), (0.3, -0.55)] { sphere(g, 0.32, 12, material("#e89c32"), x + dx, 12, z + dz) }
        }
        return g
    }

    private static func pirateSunny() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#6f422b", trim: "#efdfb5", length: 29, width: 12, stern: 9)
        pirateBelt(g, length: 29, width: 12, stern: 9, lower: 0.78, upper: 1.0, color: "#ad3c2c")
        pirateRig(g, [(2, 20), (-9, 13)], strawHat: true)
        box(g, 12, 0.5, 8.5, material("#66954a"), -5, 7.5)
        pirateCabin(g, x: -10, y: 8.5, color: "#f0e1b8", roof: "#d65c35", width: 6)
        // A red-white stern gallery and the green upper deck are primary forms.
        box(g, 7.2, 0.45, 8.4, material("#f0dfb9"), -10, 11)
        for side in [-1.0, 1] {
            box(g, 7.5, 0.35, 0.3, material("#b43b2e"), -10, 12, side * 4.1)
            for x in [-13.0, -11.5, -10, -8.5, -7] { box(g, 0.18, 1, 0.18, material("#eee3c5"), x, 11.5, side * 4.1) }
        }
        cylinder(g, 1.55, 1.4, 1.5, material("#c44831"), 2, 20.6)
        cylinder(g, 1.63, 1.63, 0.24, material("#efc34d"), 2, 21.4)
        let face = SCNNode()
        face.name = "sunny-lion-assembly"
        face.position = vector(15.8, 7.2, 0)
        g.addChildNode(face)
        // Only the mane's own XY profile is turned into the YZ plane. The
        // assembly remains unrotated: every facial feature projects along +X.
        var mane: [(Double, Double)] = []
        for index in 0..<32 {
            let angle = Double(index) / 32 * 2 * .pi, r = index.isMultiple(of: 2) ? 3.65 : 2.75
            mane.append((cos(angle) * r, sin(angle) * r))
        }
        let maneNode = profile(face, mane, 1.15, material("#dc8d29"), bevel: 0.22)
        maneNode.name = "sunny-mane"
        maneNode.eulerAngles.y = .pi / 2
        maneNode.position = vector(-1.15 / 2, 0, 0)
        let dome = pirateEllipsoid(face, 2.6, "#f6d16a", 1.00, 0.10, scale: vector(0.52, 1, 1))
        dome.name = "sunny-face"
        let muzzle = pirateEllipsoid(face, 0.85, "#f6dda0", 2.33, -0.30, 0, scale: vector(0.80, 0.78, 1.25))
        muzzle.name = "sunny-muzzle"
        for side in [-1.0, 1] {
            pirateEllipsoid(face, 0.60, "#f6dda0", 2.42, -0.30, side * 0.54, scale: vector(0.72, 0.75, 0.93))
        }
        let nose = pirateEllipsoid(face, 0.43, "#71502d", 3.15, -0.03, 0, scale: vector(0.67, 0.58, 1.08))
        nose.name = "sunny-nose"
        pirateForwardEyes(face, x: 2.21, y: 0.86, spacing: 1.02, radius: 0.47, name: "sunny-eye")
        let smile = profile(face, [(-1.02, -0.70), (-0.52, -0.95), (0, -1.03), (0.52, -0.95),
                                   (1.02, -0.70), (0.64, -1.43), (0, -1.60), (-0.64, -1.43)],
                            0.08, material("#886334"), bevel: 0.03)
        smile.name = "sunny-mouth"
        smile.eulerAngles.y = .pi / 2
        smile.position = vector(2.30 - 0.08 / 2, 0, 0)
        let teeth = profile(face, [(-0.70, -1.03), (0, -1.17), (0.70, -1.03), (0.42, -1.36),
                                   (0, -1.43), (-0.42, -1.36)], 0.09, material("#fff1cd"), bevel: 0.02)
        teeth.eulerAngles.y = .pi / 2
        teeth.position = vector(2.36 - 0.09 / 2, 0, 0)
        PaperweightShipAnimation.tag(face, as: .figurehead)
        for (x, z) in [(-9.0, -2.4), (-5.4, -2.9), (-2.3, -2.4)] {
            cylinder(g, 0.16, 0.28, 1.8, material("#7b5938"), x, 9, z)
            pirateEllipsoid(g, 1.15, "#48813d", x, 10.4, z)
            for dz in [-0.65, 0.65] { sphere(g, 0.3, 12, material("#e5a335"), x + 0.4, 10.6, z + dz) }
        }
        for side in [-1.0, 1] {
            disc(g, 2.7, 32, material("#26282a"), -4, 1.4, side * 5.5, ry: side < 0 ? .pi : 0)
            torus(g, 2.65, 0.24, rings: 32, sides: 8, material("#dfb54a"), -4, 1.4, side * 5.55)
            disc(g, 2.15, 28, material("#b6432e"), -4, 1.4, side * 5.61, ry: side < 0 ? .pi : 0)
            box(g, 0.55, 3.7, 0.15, material("#e5bb4d"), -4, 1.4, side * 5.66)
            box(g, 3.7, 0.55, 0.15, material("#e5bb4d"), -4, 1.4, side * 5.67)
            for x in [2.0, 6, 9] { piratePorthole(g, x: x, y: 4.0, z: side * (x > 6 ? 4.4 : 5.5), radius: 0.55) }
        }
        torus(g, 2.25, 0.3, rings: 28, sides: 8, material("#d4b47c"), -14.3, 3, 0, ry: .pi / 2)
        disc(g, 1.85, 24, material("#29333b"), -14.35, 3, 0, ry: -.pi / 2)
        return g
    }

    private static func pirateJackson() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#8e302d", trim: "#d6b461", length: 31, width: 10, stern: 10)
        pirateBelt(g, length: 31, width: 10, stern: 10, lower: 0.65, upper: 0.84, color: "#c5a05a")
        pirateRig(g, [(-2, 21), (8, 17)], cloth: "#e9d5b6", stripe: "#a72f37", emblem: .roger)
        pirateCabin(g, x: -11.0, y: 8.9, color: "#ead7ae", roof: "#9b3d32", width: 7.5)
        pirateEllipsoid(g, 3.1, "#eee9d3", -9.5, 13.0, scale: vector(1, 1.3, 0.92))
        for side in [-1.0, 1] {
            for (x, y) in [(-10.7, 13.8), (-8.8, 11.9), (-9.0, 15.6)] {
                disc(g, 0.45, 16, material("#a24238"), x, y, side * 2.68, ry: side < 0 ? .pi : 0)
            }
        }
        let bowStart = g.childNodes.count
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 12, y: 3)); tail.curve(to: NSPoint(x: 17, y: 8), controlPoint1: NSPoint(x: 18, y: 2.5), controlPoint2: NSPoint(x: 14.3, y: 6))
        tail.line(to: NSPoint(x: 18.2, y: 8.7)); tail.curve(to: NSPoint(x: 12, y: 4.2), controlPoint1: NSPoint(x: 17, y: 3), controlPoint2: NSPoint(x: 18, y: 3)); tail.close()
        extrude(g, tail, 2.3, material("#d7ad58"), bevel: 0.35)
        pirateEllipsoid(g, 1.25, "#e4bf72", 17, 9.2, scale: vector(0.65, 1.5, 0.7))
        pirateEllipsoid(g, 1.1, "#edce8e", 17.7, 11.5, scale: vector(0.9, 1, 0.85))
        for side in [-1.0, 1] {
            let wing = profile(g, [(14, 7), (13, 10), (14.3, 13), (16, 12), (15, 9), (17, 7)], 0.48, material("#d2a451"), bevel: 0.2)
            wing.position.z = CGFloat(side * 1.7)
            detailedRope(g, from: vector(17, 9.8, side * 0.7), to: vector(19.1, 11.5, side * 1.2), radius: 0.23, color: "#d7ad58")
            pirateSpiralHorn(g, x: 13.2, y: 5.2, z: side * 1.8, radius: 1.0, color: "#d2a451")
        }
        pirateFigurehead(g, since: bowStart, at: vector(14, 5, 0))
        pirateCannons(g, length: 31, width: 10, stern: 10)
        return g
    }

    private static func pirateMoby() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#ece8d4", trim: "#e8e1c7", length: 31, width: 12, stern: 9)
        pirateBelt(g, length: 31, width: 12, stern: 9, lower: 0.08, upper: 0.38, color: "#547d96")
        pirateBelt(g, length: 31, width: 12, stern: 9, lower: 0.75, upper: 0.92, color: "#353c43")
        pirateRig(g, [(-8, 17), (0, 20), (8, 17)], cloth: "#f4ead2", rows: 3, emblem: nil, span: 9.1)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.2, "#f0edda", 13.5, 2.9, scale: vector(1.95, 0.87, 1.60))
        for side in [-1.0, 1] {
            disc(g, 0.34, 16, material("#344954"), 16.1, 4.5, side * 4.15, ry: side < 0 ? .pi : 0)
            for x in stride(from: 10.0, through: 18.0, by: 0.85) {
                let offset = (x - 13.5) / 6.24, span = sqrt(max(0.05, 1 - offset * offset)) * 4.9
                detailedRope(g, from: vector(x, 0.8, side * span * 0.87), to: vector(x, 3.6, side * span), radius: 0.07, color: "#657d88")
            }
            detailedRope(g, from: vector(10.2, 4.1, side * 4.8), to: vector(17.9, 3.6, side * 3.8), radius: 0.085, color: "#526a77")
        }
        pirateFigurehead(g, since: bowStart, at: vector(12, 3, 0))
        pirateCabin(g, x: -11.0, y: 9, color: "#e8e7d3", roof: "#4f7893", width: 7)
        pirateCabin(g, x: -11.2, y: 12.6, color: "#e8e7d3", roof: "#4f7893", width: 4.8)
        pirateCannons(g, count: 5, length: 31, width: 12, stern: 9, portTrim: "#e1dcc7")
        return g
    }

    private static func pirateRedForce() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#7f302d", trim: "#caa55d", length: 30, width: 10, stern: 10)
        pirateBelt(g, length: 30, width: 10, stern: 10, lower: 0.50, upper: 0.72, color: "#3d3432")
        pirateRig(g, [(-8, 17), (0, 21), (8, 17)], cloth: "#eadcc1", stripe: "#a83a3b", emblem: .redHair)
        pirateCabin(g, x: -11, y: 10, color: "#b74e3c", roof: "#d2aa5c", width: 7.5)
        let bowStart = g.childNodes.count
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: 11.7, y: 2.5)); neck.curve(to: NSPoint(x: 16.5, y: 9.0), controlPoint1: NSPoint(x: 18, y: 2), controlPoint2: NSPoint(x: 13.5, y: 7))
        neck.curve(to: NSPoint(x: 19, y: 11.6), controlPoint1: NSPoint(x: 17, y: 11.1), controlPoint2: NSPoint(x: 16.7, y: 11.7))
        neck.line(to: NSPoint(x: 19.3, y: 9.4)); neck.curve(to: NSPoint(x: 12, y: 4), controlPoint1: NSPoint(x: 16.3, y: 9), controlPoint2: NSPoint(x: 19, y: 2.6)); neck.close()
        extrude(g, neck, 2.6, material("#ab3c2f"), bevel: 0.32)
        pirateEllipsoid(g, 1.75, "#b34931", 19, 11.0, scale: vector(1.55, 0.74, 0.85))
        pirateEllipsoid(g, 1.25, "#8b3029", 21, 10.5, scale: vector(1.2, 0.55, 0.9))
        for side in [-1.0, 1] {
            pirateSpiralHorn(g, x: 17.4, y: 12.5, z: side * 1.1, radius: 1.05, color: "#d0a45f")
            disc(g, 0.40, 16, material("#e4c15b"), 19.3, 11.6, side * 1.32, ry: side < 0 ? .pi : 0)
            disc(g, 0.17, 12, material("#202a2b"), 19.4, 11.6, side * 1.36, ry: side < 0 ? .pi : 0)
            for x in [19.0, 20, 21] { pirateHorn(g, x, 9.9, side * 0.7, length: 0.85, rz: .pi, hex: "#e9dfc6") }
            let mane = profile(g, [(13, 4), (12.6, 8), (14.2, 7.2), (13.7, 10.2), (15.8, 9.1), (15, 12), (17, 10), (16, 5)],
                               0.45, material("#bd8e49"), bevel: 0.14)
            mane.position.z = CGFloat(side * 1.45)
        }
        pirateFigurehead(g, since: bowStart, at: vector(14, 4, 0))
        pirateCannons(g, length: 30, width: 10, stern: 10)
        return g
    }

    private static func pirateXebec() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#30272c", trim: "#b59751", length: 34, width: 11, stern: 11)
        pirateRig(g, [(-10, 16), (-2, 19), (7, 17)], cloth: "#7f2d32", stripe: "#30272c", emblem: .blackbeard)
        pirateCabin(g, x: -12, y: 11, color: "#352e38", roof: "#9c3c43")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.1, "#d1c4a4", 18, 7, scale: vector(1.1, 1.2, 1))
        pirateForwardEyes(g, x: 20.87, y: 7.8, spacing: 1.17, radius: 0.92, sockets: true, name: "xebec-skull-eye")
        for side in [-1.0, 1] {
            pirateHorn(g, 16.3, 10.5, side * 2, length: 3.5, rz: side * 0.5)
        }
        box(g, 1.3, 0.8, 3.8, material("#d1c4a4"), 20.2, 4.3)
        for z in [-1.3, -0.43, 0.43, 1.3] { box(g, 0.9, 1.65, 0.66, material("#d1c4a4"), 20.8, 4.7, z) }
        pirateFigurehead(g, since: bowStart, at: vector(16, 5, 0))
        pirateCannons(g, count: 6, length: 34, width: 11, stern: 11)
        return g
    }

    private static func pirateCircus(blaster: Bool) -> SCNNode {
        let g = SCNNode()
        pirateHull(g, blaster ? "#ab3f60" : "#ba4439", trim: "#f1d06a", width: 12, stern: 8)
        pirateRig(g, [(1, 18)], cloth: "#fff2da", stripe: "#e65158", emblem: .buggy)
        cylinder(g, 0, 5, 7, textured(pirateCanvas("#f5e8cf", stripe: "#d44450", emblem: nil)), -8, 11)
        for side in [-1.0, 1] {
            box(g, 7, 4, 0.4, material("#faf2d4"), -8, 7, side * 3.8)
            box(g, 1.2, 4, 0.5, material("#e34950"), -8, 7, side * 4.1)
        }
        let bowStart = g.childNodes.count
        if blaster {
            pirateEllipsoid(g, 4, "#f3dbc2", 15, 7)
            pirateEllipsoid(g, 1.4, "#e93847", 18.5, 7.5)
            for side in [-1.0, 1] {
                pirateEllipsoid(g, 1.8, "#6cb2cf", 14, 8, side * 3.3)
                box(g, 9, 0.55, 0.7, material("#e8e5d9", metalness: 0.35), 14, 3, side * 4, rz: side * 0.6)
            }
            cylinder(g, 1.5, 3.6, 3, material("#e94359"), 14, 12)
            pirateForwardEyes(g, x: 18.4, y: 8.5, spacing: 1.35, radius: 0.62, name: "buggy-clown-eye")
            let grin = profile(g, [(-1.8, 5.9), (0, 5.3), (1.8, 5.9), (1.3, 4.7), (0, 4.4), (-1.3, 4.7)],
                               0.12, material("#9b3448"), bevel: 0.1)
            grin.eulerAngles.y = .pi / 2
            grin.position = vector(18.69, 0, 0)
            box(g, 0.15, 0.45, 2.2, material("#f1ead4"), 18.83, 5.2, 0)
        } else {
            pirateEllipsoid(g, 3.2, "#93b4c4", 14, 6)
            cylinder(g, 0.8, 1.2, 6, material("#93b4c4"), 16, 3.5, rz: 0.25)
            for side in [-1.0, 1] {
                pirateEllipsoid(g, 2.2, "#93b4c4", 12.8, 6.6, side * 3.2, scale: vector(0.6, 1.1, 1))
                pirateHorn(g, 17, 4.5, side * 1.4, length: 3.3, rz: -1)
            }
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        return g
    }

    private static func piratePunk() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#7a2b36", trim: "#d6b969", width: 11, stern: 9)
        pirateRig(g, [(-5, 19), (5, 15)], cloth: "#ddd3bc", stripe: "#6b3139", emblem: .kid)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.5, "#e8dfc4", 16, 7, scale: vector(1.7, 0.85, 0.9))
        for side in [-1.0, 1] {
            disc(g, 1.15, 20, material("#2b2929"), 15.5, 8.2, side * 2.9, ry: side < 0 ? .pi : 0)
            disc(g, 0.55, 16, material("#2b2929"), 19.8, 6.9, side * 1.9, ry: side < 0 ? .pi : 0)
        }
        profile(g, [(13.5, 4.6), (20, 4.7), (20.7, 4.1), (17.8, 3.5), (13.5, 3.9)], 4.1, material("#e8dfc4"), bevel: 0.23)
        for x in [15.0, 17, 19] {
            for side in [-1.0, 1] { pirateHorn(g, x, 4.6, side * 2, length: 1.6, rz: .pi) }
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        for x in [-11.0, -7, -3, 1, 5, 9] {
            for side in [-1.0, 1] { pirateHorn(g, x, 6, side * 5.6, length: 3, rz: side * 0.6) }
        }
        return g
    }

    // MARK: Supernovas and rival crews

    private static func pirateMargherita() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#cf6f7f", trim: "#fff0cb", width: 12, stern: 7)
        pirateRig(g, [(1, 18)], cloth: "#f3a3bc", stripe: "#f9e9d9", emblem: .bonney)
        cylinder(g, 5, 5, 3, material("#e7a34c"), -8, 7)
        cylinder(g, 5.3, 5.3, 0.7, material("#f5d26c"), -8, 8.8)
        for x in [-10.0, -6] {
            for side in [-1.0, 1] {
                pirateEllipsoid(g, 1.5, "#e84653", x, 10, side * 2.5, scale: vector(1, 1.2, 1))
                cylinder(g, 0, 1, 0.8, material("#57944b"), x, 11.7, side * 2.5)
            }
        }
        for side in [-1.0, 1] {
            for x in [-9.0, -3, 3, 9] { disc(g, 0.8, 12, material("#fff2cf"), x, 0.5, side * 6.15, ry: side < 0 ? .pi : 0) }
        }
        PaperweightShipAnimation.tag(pirateEllipsoid(g, 2.5, "#f0c271", 15, 4, scale: vector(1.3, 0.7, 1)), as: .figurehead)
        return g
    }

    private static func pirateDolph() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#7d6045", trim: "#b49b64", stern: 8)
        pirateRig(g, [(-4, 16), (5, 13)], cloth: "#343139", emblem: .hawkins)
        pirateCabin(g, x: -10, y: 8, color: "#69523b", roof: "#c8ad67")
        cylinder(g, 0.8, 0.8, 3, material("#e9d5aa"), -4, 23)
        PaperweightShipAnimation.tag(pirateEllipsoid(g, 0.6, "#f4ad42", -4, 25, scale: vector(0.7, 1.6, 0.7)), as: .pulse)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.1, "#cbb47c", 15, 8, scale: vector(0.8, 1.2, 0.8))
        box(g, 1.4, 5, 1.5, material("#cbb47c"), 15, 4.3)
        box(g, 1.2, 0.9, 7, material("#cbb47c"), 15, 5.8)
        cylinder(g, 0.15, 0.3, 5, material("#6c7378", metalness: 0.5), 15.4, 10.8, rz: -0.35)
        for side in [-1.0, 1] {
            for angle in [-0.65, 0.65] {
                put(g, SCNBox(width: 0.13, height: 0.90, length: 0.17, chamferRadius: 0.03),
                    material("#443a31"), 16.58, 8.3, side * 0.61, rx: angle)
            }
        }
        pirateFigurehead(g, since: bowStart, at: vector(14, 4, 0))
        return g
    }

    private static func pirateHind() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#447388", trim: "#e7e4cb", length: 32, width: 11, stern: 10)
        pirateRig(g, [(-7, 16), (3, 19)], cloth: "#dddcc8", emblem: .drake)
        pirateCabin(g, x: -11, y: 10, color: "#eee9d5", roof: "#4a7a8c")
        pirateCannons(g, count: 6, length: 32, width: 11, stern: 10)
        let flagStart = g.childNodes.count
        box(g, 5, 3.2, 0.25, material("#a63d3e"), 5.2, 23)
        for angle in [-0.6, 0.6] { box(g, 3, 0.25, 0.3, material("#efeadc"), 5.2, 23, 0.2, rz: angle) }
        PaperweightShipAnimation.tag(pirateJoint(g, since: flagStart, at: vector(3, 23, 0)), as: .flag)
        return g
    }

    private static func pirateTune() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#62483e", trim: "#e4b966", width: 11, stern: 7)
        pirateRig(g, [(-6, 17), (4, 19)], cloth: "#ece6ce", stripe: "#6e5e72", emblem: .apoo)
        pirateCabin(g, x: -10, y: 8, color: "#d2af72", roof: "#a14c59")
        let hornStart = g.childNodes.count
        cylinder(g, 2.8, 0.9, 6, material("#d9b05e", metalness: 0.25), 16, 7, rz: -.pi / 2)
        disc(g, 2.35, 24, material("#544735"), 19.05, 7, 0, ry: .pi / 2)
        torus(g, 2.7, 0.18, rings: 28, sides: 8, material("#e5bf6a", metalness: 0.4), 19.12, 7, 0, ry: .pi / 2)
        cylinder(g, 0.35, 0.75, 1.7, material("#bb9550", metalness: 0.3), 14, 7, rz: .pi / 2)
        PaperweightShipAnimation.tag(pirateJoint(g, since: hornStart, at: vector(16, 7, 0)), as: .pulse)
        for side in [-1.0, 1] {
            torus(g, 1.5, 0.35, rings: 16, sides: 6, material("#d9b05e"), -8, 4, side * 5.7)
            box(g, 0.5, 4.5, 0.5, material("#d9b05e"), -6.5, 6, side * 5.7)
        }
        return g
    }

    private static func pirateHanjomaru() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#6e4a86", trim: "#bd9663", width: 12, stern: 9)
        pirateRig(g, [(0, 19)], cloth: "#efe0c7", stripe: "#795099", emblem: .urouge)
        pirateCabin(g, x: -10, y: 9, color: "#ba6b54", roof: "#4e5368", width: 8)
        pirateCabin(g, x: -10, y: 13, color: "#d3b490", roof: "#4e5368", width: 5)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.2, "#bd594b", 15, 7, scale: vector(0.75, 1.2, 1))
        pirateForwardEyes(g, x: 17.15, y: 8.1, spacing: 1.15, radius: 0.55, name: "hannya-mask-eye")
        for side in [-1.0, 1] {
            pirateHorn(g, 15, 11, side * 1.8, length: 3.5, rz: side * 0.25)
            for index in 0..<4 { pirateEllipsoid(g, 0.75, "#f3dfab", 12, 6 + Double(index), side * 3.7) }
            profile(g, [(10, 5), (13, 9), (9, 8), (7, 6)], 0.5, material("#cdb07b")).position.z = CGFloat(side * 4.2)
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        return g
    }

    private static func pirateFlamingo() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#c14a76", trim: "#f0c87d", width: 11, stern: 8)
        pirateRig(g, [(-5, 16), (4, 19)], cloth: "#f6d4dd", stripe: "#cd598d", emblem: .flamingo)
        pirateCabin(g, x: -10, y: 8, color: "#f6c2cd", roof: "#8c3d65")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 1.6, "#e78eac", 13.7, 5.0, scale: vector(1.35, 1, 1.1))
        var previous = vector(14, 5.5, 0)
        for index in 1...18 {
            let t = Double(index) / 18, a = 1 - t
            let x = a * a * a * 14 + 3 * a * a * t * 17 + 3 * a * t * t * 12.8 + t * t * t * 17.2
            let y = a * a * a * 5.5 + 3 * a * a * t * 8.8 + 3 * a * t * t * 18.7 + t * t * t * 17
            let point = vector(x, y, 0)
            detailedRope(g, from: previous, to: point, radius: 0.76 - t * 0.21, color: "#e793ae")
            previous = point
        }
        pirateEllipsoid(g, 1.7, "#ef9abc", 17.2, 17, scale: vector(1.1, 0.9, 0.75))
        cylinder(g, 0.4, 0.9, 3, material("#252931"), 19, 16.6, rz: -1.1)
        pirateEyes(g, x: 17.5, y: 17.5, z: 1.2)
        pirateFigurehead(g, since: bowStart, at: vector(14, 5, 0))
        return g
    }

    private static func pirateSabre() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#4f4f63", trim: "#d1b957", length: 34, width: 12, stern: 12)
        pirateRig(g, [(-10, 15), (-2, 20), (7, 17)], cloth: "#e4dbc1", emblem: .krieg)
        pirateCabin(g, x: -12, y: 12, color: "#53566c", roof: "#b49a57")
        pirateCabin(g, x: -12, y: 16, color: "#e2d6b7", roof: "#a88b4a", width: 5)
        pirateCannons(g, count: 6, length: 34, width: 12, stern: 12)
        for side in [-1.0, 1] {
            box(g, 25, 1, 0.3, material("#ccb14e"), -1, -0.8, side * 6.1)
            profile(g, [(13, 6), (18, 12), (17, 5)], 0.8, material("#dadacb")).position.z = CGFloat(side * 1.8)
        }
        return g
    }

    private static func pirateShark() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#7b8194", trim: "#ced4d9", width: 12, stern: 8)
        pirateRig(g, [(-5, 16), (5, 18)], cloth: "#e6e0cc", stripe: "#65758d", emblem: .arlong)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.4, "#9ba9b4", 14, 4.3, scale: vector(1.8, 0.9, 1.2))
        pirateEyes(g, x: 15.5, y: 5.5, z: 3.4)
        box(g, 8.5, 0.6, 1, material("#aebcc1"), 21, 5.1)
        for x in [18.0, 20, 22, 24] {
            for side in [-1.0, 1] {
                cylinder(g, 0, 0.5, 1.8, material("#e8e5d0"), x, 5.1, side * 1.1, rx: side * .pi / 2)
            }
        }
        for side in [-1.0, 1] {
            box(g, 7, 0.5, 0.2, material("#34404c"), 16, 3.5, side * 3.5)
            for x in [14.0, 16, 18] { pirateHorn(g, x, 3.5, side * 3.65, length: 1.3, rz: .pi) }
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 4.3, 0))
        profile(g, [(0, 5), (3, 10), (5, 5)], 1.2, material("#8c9dab"))
        pirateCabin(g, x: -10, y: 8, color: "#a5b1b5", roof: "#526879")
        return g
    }

    // MARK: Giants and the Grand Fleet

    private static func pirateLongship(naglfar: Bool) -> SCNNode {
        let g = SCNNode()
        craftedHull(g, length: 31, width: 9, deck: 3.4, keel: -3, stern: 5.2,
                    color: naglfar ? "#795839" : "#8d5138", trim: "#c8a06b")
        profile(g, [(-16, 2), (-17, 8), (-15.4, 9), (-14.8, 5), (-13, 3.8)], 1.7, material("#a87743"), bevel: 0.24)
        profile(g, [(13, 3), (15.0, 5), (16.1, 11), (17.6, 12), (18.1, 10.5), (17, 7), (16, 2)],
                2.0, material("#a87743"), bevel: 0.24)
        pirateRig(g, naglfar ? [(-5, 18), (6, 15)] : [(0, 20)], cloth: "#f3e0bb", stripe: naglfar ? "#9d4b3a" : "#ad3540", rows: 1, emblem: .giant)
        for side in [-1.0, 1] {
            for (index, x) in [-11.0, -7, -3, 1, 5, 9].enumerated() {
                disc(g, 1.55, 14, material(index.isMultiple(of: 2) ? "#b7453d" : "#dcb95f"), x, 3.3, side * 4.8, ry: side < 0 ? .pi : 0)
                disc(g, 0.45, 10, material("#c2bda4", metalness: 0.25), x, 3.3, side * 4.85, ry: side < 0 ? .pi : 0)
                let oarStart = g.childNodes.count
                cylinder(g, 0.2, 0.25, 10, material("#6b4b32"), x, 0.5, side * 7, rx: side * 1.05)
                PaperweightShipAnimation.tag(pirateJoint(g, since: oarStart, at: vector(x, 3, side * 4.5)), as: .oar)
            }
        }
        if naglfar {
            pirateCabin(g, x: -9, y: 9, color: "#886c49", roof: "#b49c61", width: 8)
            let bowStart = g.childNodes.count
            for index in -3...3 {
                let feather = profile(g, [(15, 6), (14.6, 10.3), (16, 13), (17.0, 9.8), (16.2, 6)],
                                      0.6, material(index.isMultiple(of: 2) ? "#c9a060" : "#e2bd79"), bevel: 0.18)
                feather.position.z = CGFloat(Double(index) * 0.9)
                feather.eulerAngles.x = CGFloat(Double(index) * 0.16)
            }
            pirateEllipsoid(g, 2.4, "#e8ddbf", 17.5, 9, scale: vector(0.7, 1.3, 1))
            for side in [-1.0, 1] { pirateHorn(g, 17.5, 11.5, side * 2.4, length: 5, rz: side * 0.8) }
            pirateEyes(g, x: 18, y: 9.6, z: 2)
            pirateFigurehead(g, since: bowStart, at: vector(16, 7, 0))
        } else {
            let bowStart = g.childNodes.count
            pirateEllipsoid(g, 1.8, "#b88449", 17, 12, scale: vector(1.5, 0.8, 0.8))
            pirateEyes(g, x: 17.5, y: 12.5, z: 1.1)
            pirateHorn(g, 15.5, 14, 0, length: 2.5)
            pirateFigurehead(g, since: bowStart, at: vector(16, 11, 0))
        }
        return g
    }

    private static func pirateLuffy() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#b54c38", trim: "#efd16e", width: 11, stern: 8)
        pirateRig(g, [(-4, 18), (6, 14)], cloth: "#b63842", strawHat: true)
        pirateCabin(g, x: -10, y: 8, color: "#e6cba0", roof: "#d1463a")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.4, "#f1c9a1", 16, 8, scale: vector(0.9, 1.2, 1))
        cylinder(g, 2.6, 2.8, 1.4, material("#edc95d"), 16, 10.7)
        cylinder(g, 3.7, 3.7, 0.35, material("#edc95d"), 16, 10.2)
        cylinder(g, 2.7, 2.7, 0.45, material("#ce433d"), 16, 10.1)
        box(g, 2.7, 4, 3.2, material("#d94636"), 14.6, 4.4)
        pirateForwardEyes(g, x: 17.85, y: 8.5, spacing: 0.88, radius: 0.48, name: "luffy-bow-eye")
        pirateFigurehead(g, since: bowStart, at: vector(14.6, 5, 0))
        let sternStart = g.childNodes.count
        // The Chopper stern and antlers remain legible opposite the Luffy bow.
        pirateEllipsoid(g, 2.1, "#c18f65", -15, 8)
        cylinder(g, 2.3, 2.3, 1.8, material("#d55c84"), -15, 10)
        for side in [-1.0, 1] {
            cylinder(g, 0.25, 0.4, 4, material("#886547"), -15, 11, side * 3, rz: side * 0.5)
            cylinder(g, 0.2, 0.25, 2, material("#886547"), -15, 12, side * 4, rz: -side * 0.6)
        }
        box(g, 0.2, 0.3, 1.4, material("#f9efda"), -17.35, 10, 0)
        box(g, 0.2, 1.4, 0.3, material("#f9efda"), -17.35, 10, 0)
        pirateForwardEyes(g, x: -16.8, y: 8.45, spacing: 0.74, radius: 0.40, facing: -1, name: "chopper-stern-eye")
        pirateEllipsoid(g, 0.32, "#477c9c", -17.20, 7.9, 0, scale: vector(0.7, 0.7, 1))
        pirateFigurehead(g, since: sternStart, at: vector(-15, 7, 0))
        return g
    }

    private static func pirateHorse() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#cdd6cf", trim: "#dfbd68", width: 10, stern: 9)
        pirateRig(g, [(4, 19)], cloth: "#f6f0db", stripe: "#b6c8c2")
        for side in [-1.0, 1] {
            let rig = SCNNode(); rig.position.z = CGFloat(side * 3.2); g.addChildNode(rig)
            pirateRig(rig, [(-7, 15)], cloth: "#f6f0db", stripe: "#b6c8c2", rows: 1)
        }
        pirateCabin(g, x: -10, y: 9, color: "#e9e5ce", roof: "#7ea194")
        cylinder(g, 3.3, 3.3, 2.2, material("#dfbd68"), -13, 12)
        for z in [-2.5, 0, 2.5] { pirateHorn(g, -13, 14, z, length: 2.3, rz: 0, hex: "#dfbd68") }
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2, "#f5efdc", 15, 8, scale: vector(0.7, 1.8, 0.9))
        pirateEllipsoid(g, 2, "#f5efdc", 17, 11.2, scale: vector(1.6, 0.8, 0.75))
        pirateEyes(g, x: 17.2, y: 11.8, z: 1.4)
        for side in [-1.0, 1] { pirateHorn(g, 15.7, 13.5, side * 0.9, length: 2.3, rz: 0.3, hex: "#f5efdc") }
        for y in [8.0, 10, 12] { pirateEllipsoid(g, 0.9, "#bdc7bb", 13.8, y, scale: vector(0.7, 1, 1.6)) }
        pirateFigurehead(g, since: bowStart, at: vector(14.5, 6, 0))
        return g
    }

    private static func pirateMaria() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#3f5a6c", trim: "#e5c977", length: 36, width: 12, stern: 11)
        pirateRig(g, [(-10, 16), (0, 21), (10, 17)], cloth: "#e9e0c8", stripe: "#4e798d")
        pirateCabin(g, x: -13, y: 11, color: "#d5cead", roof: "#477085")
        pirateCabin(g, x: -13, y: 15, color: "#d5cead", roof: "#477085", width: 5)
        pirateCannons(g, count: 7, length: 36, width: 12, stern: 11)
        for side in [-1.0, 1] { box(g, 31, 0.7, 0.2, material("#e3c16c"), 0, -1, side * 6.1) }
        cylinder(g, 0.3, 0.4, 8, material("#bc9c58"), 19, 8, rz: -1.1)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 1.2, "#e4c783", 18.5, 10.5)
        cylinder(g, 0.8, 1.3, 4, material("#e4c783"), 17, 7.5, rz: -0.4)
        for side in [-1.0, 1] {
            let wing = profile(g, [(15, 8), (15, 13), (20, 15), (18, 10)], 0.45, material("#e4c783"))
            wing.position.z = CGFloat(side * 2.4)
            wing.eulerAngles.x = CGFloat(side * 0.5)
        }
        pirateFigurehead(g, since: bowStart, at: vector(16, 6, 0))
        return g
    }

    private static func pirateUsoland() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#a97d43", trim: "#7f9c4a", length: 25, width: 11, stern: 6)
        pirateRig(g, [(0, 17)], cloth: "#f5e2b8", stripe: "#8dab57", rows: 1)
        for (x, z) in [(-8.0, -2.5), (-8, 2.5), (-3, 0)] {
            cylinder(g, 1.5, 1.7, 3, material("#e2c68c"), x, 7, z)
            cylinder(g, 0, 2.7, 2.2, material("#b47a44"), x, 9, z)
        }
        cylinder(g, 2, 2, 1.2, material("#d6ba65"), 0, 19)
        for angle in stride(from: 0.0, to: .pi * 2, by: .pi / 3) {
            pirateHorn(g, cos(angle) * 1.7, 20.1, sin(angle) * 1.7, length: 1.6, rz: 0, hex: "#d6ba65")
        }
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.2, "#d7aa7a", 14, 6)
        cylinder(g, 0.55, 0.65, 5, material("#d7aa7a"), 17, 6.8, rz: -.pi / 2)
        pirateForwardEyes(g, x: 15.85, y: 7.1, spacing: 0.82, radius: 0.60, name: "usopp-bow-eye")
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        return g
    }

    private static func pirateSpadille() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#71513c", trim: "#d8a95d", length: 25, width: 9, stern: 7)
        pirateRig(g, [(0, 18)], cloth: "#e8d6b7", stripe: "#b27a46", rows: 1, emblem: .spade)
        pirateCabin(g, x: -8, y: 7, color: "#d1ad76", roof: "#87523b", width: 5)
        // Ace's bow is a flaming horse skull; its unknown stern is interpreted
        // as a modest wooden cabin rather than copied from merchandise.
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.1, "#e8dfc7", 14, 7, scale: vector(0.75, 1.2, 0.9))
        pirateEllipsoid(g, 1.8, "#e8dfc7", 16, 6, scale: vector(1.5, 0.7, 0.7))
        for side in [-1.0, 1] {
            disc(g, 0.8, 12, material("#302c2c"), 14.7, 7.5, side * 1.7, ry: side < 0 ? .pi : 0)
            for index in 0..<4 {
                torus(g, 0.55, 0.16, rings: 10, sides: 5, material("#535b60", metalness: 0.4),
                      11.2 + Double(index), 4 + Double(index) * 0.5, side * 2.4)
            }
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        let flameStart = g.childNodes.count
        for index in 0..<5 {
            let x = 12 + Double(index) * 0.9
            profile(g, [(x - 1, 8), (x - 0.5, 12.5 + Double(index % 2)), (x + 0.6, 10), (x + 1, 8)],
                    1, material(index.isMultiple(of: 2) ? "#ef7736" : "#f2ba49"))
        }
        PaperweightShipAnimation.tag(pirateJoint(g, since: flameStart, at: vector(14, 10, 0)), as: .pulse)
        return g
    }
}
