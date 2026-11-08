import AppKit
import SceneKit

/// Handmade, low-poly fan miniatures. Each vessel is built locally; no model
/// downloads, remote textures, or continuously running miniature renderers.
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

    private static func pirateHull(_ group: SCNNode, _ hex: String, trim: String = "#e6b955",
                                   length: Double = 29, width: Double = 10, stern: Double = 8) {
        let half = length / 2
        profile(group, [(-half, stern), (-half + 5, stern), (-half + 5, 4), (half - 3, 4),
                        (half + 1, 6), (half - 1, 0), (half - 5, -4), (-half + 4, -4), (-half, 0)],
                width, material(hex), bevel: 0.7)
        box(group, length - 3, 0.7, width + 1.2, material(trim), 0, 4.1)
        let wood = material("#a87540")
        box(group, length - 8, 0.5, width - 0.6, wood, 0, 4.7)
        for side in [-1.0, 1] {
            box(group, length - 5, 0.45, 0.45, material(trim), 0, 5.4, side * (width / 2 + 0.3))
            for x in [-8.0, -4, 0, 4, 8] {
                disc(group, 0.6, 10, material("#29333c"), x, 1.2, side * (width / 2 + 0.08), ry: side < 0 ? .pi : 0)
            }
        }
        box(group, 7, max(1, stern - 4), width - 1, material(hex), -half + 4, 4 + max(1, stern - 4) / 2)
    }

    private static func pirateRig(_ group: SCNNode, _ masts: [(Double, Double)], cloth: String = "#f5ead5",
                                  stripe: String? = nil, strawHat: Bool = false, rows: Int = 2) {
        let wood = material("#563b2c")
        for (index, pair) in masts.enumerated() {
            let (x, height) = pair
            mast(group, x, 4.5, height, wood)
            for row in 0..<rows {
                let width = (masts.count > 2 ? 7.0 : 10.0) - Double(row) * 1.8
                let sailHeight = height * (rows == 1 ? 0.49 : 0.29)
                let y = 6 + height * (rows == 1 ? 0.5 : 0.34 + Double(row) * 0.36)
                let sailMaterial = textured(pirateCanvas(cloth, stripe: stripe, strawHat: strawHat && index == masts.count / 2 && row == 0), roughness: 0.85)
                sail(group, x, y, width, sailHeight, sailMaterial, brace: 0.13, bulge: 0.7)
                box(group, width + 0.8, 0.32, 0.32, wood, x, y + sailHeight / 2)
            }
            plane(group, 2.7, 1.7, textured(pirateFlag), x + 1.35, 4.5 + height, 0.1)
        }
    }

    private static func pirateCanvas(_ base: String, stripe: String?, strawHat: Bool = false) -> NSImage {
        canvas(128, 112) { context, width, height in
            fill(context, base, CGRect(x: 0, y: 0, width: width, height: height))
            if let stripe {
                for index in 0..<4 {
                    fill(context, stripe, CGRect(x: CGFloat(index) * 32, y: 0, width: 16, height: height))
                }
            }
            guard strawHat else { return }
            context.setStrokeColor(color("#22262b").cgColor)
            context.setLineWidth(5)
            context.move(to: CGPoint(x: 36, y: 80)); context.addLine(to: CGPoint(x: 94, y: 99))
            context.move(to: CGPoint(x: 94, y: 80)); context.addLine(to: CGPoint(x: 36, y: 99))
            context.strokePath()
            context.setFillColor(color("#faf7e8").cgColor)
            context.fillEllipse(in: CGRect(x: 42, y: 37, width: 45, height: 43))
            context.fill(CGRect(x: 53, y: 70, width: 24, height: 14))
            context.setFillColor(color("#22262b").cgColor)
            context.fillEllipse(in: CGRect(x: 49, y: 52, width: 11, height: 13))
            context.fillEllipse(in: CGRect(x: 70, y: 52, width: 11, height: 13))
            fill(context, "#e4b144", CGRect(x: 44, y: 28, width: 41, height: 15))
            fill(context, "#c83d37", CGRect(x: 44, y: 38, width: 41, height: 5))
            fill(context, "#e4b144", CGRect(x: 32, y: 42, width: 65, height: 6))
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

    private static func pirateCabin(_ group: SCNNode, x: Double = -9, y: Double = 7,
                                   color hex: String = "#f3e4c5", roof: String = "#b33a32", width: Double = 7) {
        box(group, width, 4, 7, material(hex), x, y)
        put(group, SCNPyramid(width: width + 1.5, height: 2.5, length: 8.5), material(roof), x, y + 2)
        for side in [-1.0, 1] {
            for dx in [-1.6, 1.6] { box(group, 1, 1.5, 0.12, material("#2a6777"), x + dx, y + 0.1, side * 3.55) }
        }
    }

    private static func pirateCannons(_ group: SCNNode, count: Int = 4, y: Double = 2.5) {
        for side in [-1.0, 1] {
            for index in 0..<count {
                let x = -8 + Double(index) * 16 / Double(max(1, count - 1))
                cylinder(group, 0.45, 0.65, 2, material("#31383d", metalness: 0.25), x, y, side * 5.5, rx: .pi / 2)
            }
        }
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
        pirateHull(g, "#a96939", trim: "#f8e8bd", length: 25, width: 9, stern: 7)
        pirateRig(g, [(-1, 17)], strawHat: true, rows: 1)
        pirateCabin(g, x: -8, y: 7, roof: "#b75441", width: 5)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.2, "#f7efcf", 14, 6, scale: vector(1.2, 1, 1))
        pirateEllipsoid(g, 1.2, "#e5d5a9", 15.7, 5.4)
        pirateEyes(g, x: 14.3, y: 6.7, z: 1.9)
        for side in [-1.0, 1] {
            torus(g, 1.2, 0.42, rings: 14, sides: 6, material("#b38c58"), 12.5, 6.6, side * 1.6)
        }
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        // Merry's curved forward rail and orange tree distinguish her from a brig.
        pirateEllipsoid(g, 1.3, "#448a3b", -9, 11, -2)
        sphere(g, 0.35, 8, material("#ec9b35"), -8.4, 11.2, -1.1)
        return g
    }

    private static func pirateSunny() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#b8522b", trim: "#f1c84e", width: 12, stern: 9)
        pirateRig(g, [(1, 19), (-9, 13)], strawHat: true)
        box(g, 13, 0.6, 10, material("#5e9e45"), -5, 7)
        pirateCabin(g, x: -10, y: 8, color: "#f7f0d6", roof: "#db6639", width: 6)
        let face = SCNNode(); face.position = vector(16, 6.8, 0); g.addChildNode(face)
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi
            pirateEllipsoid(face, 0.8, "#e89a2c", sin(angle) * 2.7, cos(angle) * 2.7, scale: vector(0.65, 1.4, 1))
        }
        pirateEllipsoid(face, 2.5, "#ffd567", 0, 0)
        pirateEllipsoid(face, 0.9, "#f4b341", 1.9, -0.2, scale: vector(1, 0.7, 1))
        pirateEyes(face, x: 0.8, y: 0.6, z: 2.15, large: true)
        PaperweightShipAnimation.tag(face, as: .figurehead)
        for x in [-10.0, -6, -2] { pirateEllipsoid(g, 1.15, "#488e3e", x, 10, -3) }
        for side in [-1.0, 1] { disc(g, 2, 18, material("#f4eee0"), -6, 1, side * 6.2, ry: side < 0 ? .pi : 0) }
        return g
    }

    private static func pirateJackson() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#a82e2c", trim: "#dfbb55", stern: 10)
        pirateRig(g, [(-7, 17), (1, 20), (9, 16)], cloth: "#e8cead", stripe: "#a62932")
        pirateCabin(g, x: -10, y: 10, color: "#e9d8ba", roof: "#aa3936")
        let bowStart = g.childNodes.count
        profile(g, [(13, 4), (16, 7), (18, 11), (20, 12), (20, 10), (18, 8), (17, 3)], 3, material("#e9b95e"))
        pirateEllipsoid(g, 1.5, "#e9b95e", 18, 11.5)
        for side in [-1.0, 1] {
            profile(g, [(12, 8), (17, 12), (17, 9), (13, 5)], 0.6, material("#d8994e")).position.z = CGFloat(side * 2.5)
        }
        pirateFigurehead(g, since: bowStart, at: vector(14, 5, 0))
        pirateCannons(g)
        return g
    }

    private static func pirateMoby() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#e8e9d8", trim: "#547f9a", length: 31, width: 12, stern: 9)
        pirateRig(g, [(-8, 17), (0, 19), (8, 15)], cloth: "#f4eee1")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 4.2, "#f2f2df", 14, 3.8, scale: vector(1.5, 0.9, 1))
        pirateEyes(g, x: 15.5, y: 5.5, z: 3.5, large: true)
        pirateFigurehead(g, since: bowStart, at: vector(12, 3.8, 0))
        for side in [-1.0, 1] {
            box(g, 12, 0.5, 0.5, material("#687b8e"), 9, 2.9, side * 4)
            profile(g, [(-10, 1), (-13, 4), (-15, 3), (-13, -1)], 0.6, material("#b8d0cf")).position.z = CGFloat(side * 6)
        }
        pirateCabin(g, x: -10, y: 9, roof: "#4e7d8e")
        return g
    }

    private static func pirateRedForce() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#8b252b", trim: "#cda559", length: 30, width: 10, stern: 10)
        pirateRig(g, [(-8, 16), (0, 19), (8, 16)], cloth: "#eee1c5", stripe: "#a83a3b")
        pirateCabin(g, x: -11, y: 10, color: "#ac3430", roof: "#d4b069")
        let bowStart = g.childNodes.count
        profile(g, [(12, 3), (16, 4), (17, 10), (20, 12), (21, 10), (18, 8), (18, 3)], 2.3, material("#b3312e"))
        pirateEllipsoid(g, 1.7, "#bf3a2e", 19.5, 11, scale: vector(1.5, 0.75, 0.8))
        pirateHorn(g, 18.2, 13, -0.8, length: 2.8)
        pirateHorn(g, 18.2, 13, 0.8, length: 2.8)
        pirateEyes(g, x: 19.5, y: 11.5, z: 1.1)
        pirateFigurehead(g, since: bowStart, at: vector(14, 4, 0))
        pirateCannons(g)
        return g
    }

    private static func pirateXebec() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#30272c", trim: "#b59751", length: 34, width: 11, stern: 11)
        pirateRig(g, [(-10, 16), (-2, 19), (7, 17)], cloth: "#7f2d32", stripe: "#30272c")
        pirateCabin(g, x: -12, y: 11, color: "#352e38", roof: "#9c3c43")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.1, "#d1c4a4", 18, 7, scale: vector(1.1, 1.2, 1))
        for side in [-1.0, 1] {
            disc(g, 1, 12, material("#28222b"), 18.2, 7.8, side * 2.8, ry: side < 0 ? .pi : 0)
            pirateHorn(g, 16.3, 10.5, side * 2, length: 3.5, rz: side * 0.5)
        }
        for x in [16.5, 17.8, 19.1] { box(g, 0.7, 1.8, 4, material("#d1c4a4"), x, 4.2) }
        pirateFigurehead(g, since: bowStart, at: vector(16, 5, 0))
        pirateCannons(g, count: 6)
        return g
    }

    private static func pirateCircus(blaster: Bool) -> SCNNode {
        let g = SCNNode()
        pirateHull(g, blaster ? "#ab3f60" : "#ba4439", trim: "#f1d06a", width: 12, stern: 8)
        pirateRig(g, [(1, 18)], cloth: "#fff2da", stripe: "#e65158")
        cylinder(g, 0, 5, 7, material("#e34950"), -8, 11)
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
        pirateRig(g, [(-5, 19), (5, 15)], cloth: "#ddd3bc", stripe: "#6b3139")
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.5, "#e8dfc4", 16, 7, scale: vector(1.7, 0.85, 0.9))
        pirateEllipsoid(g, 2, "#30292b", 15.5, 8.2, 2.6)
        pirateEllipsoid(g, 2, "#30292b", 15.5, 8.2, -2.6)
        box(g, 6.5, 0.8, 4, material("#e8dfc4"), 17, 4.3)
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
        pirateRig(g, [(1, 18)], cloth: "#f3a3bc", stripe: "#f9e9d9")
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
        pirateRig(g, [(-4, 16), (5, 13)], cloth: "#343139")
        pirateCabin(g, x: -10, y: 8, color: "#69523b", roof: "#c8ad67")
        cylinder(g, 0.8, 0.8, 3, material("#e9d5aa"), -4, 23)
        PaperweightShipAnimation.tag(pirateEllipsoid(g, 0.6, "#f4ad42", -4, 25, scale: vector(0.7, 1.6, 0.7)), as: .pulse)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 2.1, "#cbb47c", 15, 8, scale: vector(0.8, 1.2, 0.8))
        box(g, 1.4, 5, 1.5, material("#cbb47c"), 15, 4.3)
        box(g, 1.2, 0.9, 7, material("#cbb47c"), 15, 5.8)
        cylinder(g, 0.15, 0.3, 5, material("#6c7378", metalness: 0.5), 15.4, 10.8, rz: -0.35)
        for side in [-1.0, 1] { box(g, 0.4, 1, 0.2, material("#443a31"), 15.6, 8, side * 1.6, rz: 0.65) }
        pirateFigurehead(g, since: bowStart, at: vector(14, 4, 0))
        return g
    }

    private static func pirateHind() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#447388", trim: "#e7e4cb", length: 32, width: 11, stern: 10)
        pirateRig(g, [(-7, 16), (3, 19)], cloth: "#dddcc8")
        pirateCabin(g, x: -11, y: 10, color: "#eee9d5", roof: "#4a7a8c")
        pirateCannons(g, count: 6)
        let flagStart = g.childNodes.count
        box(g, 5, 3.2, 0.25, material("#a63d3e"), 5.2, 23)
        for angle in [-0.6, 0.6] { box(g, 3, 0.25, 0.3, material("#efeadc"), 5.2, 23, 0.2, rz: angle) }
        PaperweightShipAnimation.tag(pirateJoint(g, since: flagStart, at: vector(3, 23, 0)), as: .flag)
        return g
    }

    private static func pirateTune() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#62483e", trim: "#e4b966", width: 11, stern: 7)
        pirateRig(g, [(-6, 17), (4, 19)], cloth: "#ece6ce", stripe: "#6e5e72")
        pirateCabin(g, x: -10, y: 8, color: "#d2af72", roof: "#a14c59")
        let hornStart = g.childNodes.count
        cylinder(g, 2.8, 0.9, 6, material("#d9b05e", metalness: 0.25), 16, 7, rz: -.pi / 2)
        disc(g, 2.1, 14, material("#41372e"), 19.05, 7, 0, ry: .pi / 2)
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
        pirateRig(g, [(0, 19)], cloth: "#efe0c7", stripe: "#795099")
        pirateCabin(g, x: -10, y: 9, color: "#ba6b54", roof: "#4e5368", width: 8)
        pirateCabin(g, x: -10, y: 13, color: "#d3b490", roof: "#4e5368", width: 5)
        let bowStart = g.childNodes.count
        pirateEllipsoid(g, 3.2, "#bd594b", 15, 7, scale: vector(0.75, 1.2, 1))
        pirateEyes(g, x: 15.5, y: 8, z: 2.6)
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
        pirateRig(g, [(-5, 16), (4, 19)], cloth: "#f6d4dd", stripe: "#cd598d")
        pirateCabin(g, x: -10, y: 8, color: "#f6c2cd", roof: "#8c3d65")
        let bowStart = g.childNodes.count
        profile(g, [(13, 3), (16, 4), (16, 14), (18, 17), (17, 18.5), (14, 16), (14, 7), (12, 6)], 2, material("#ed8bae"))
        pirateEllipsoid(g, 1.7, "#ef9abc", 17.2, 17, scale: vector(1.1, 0.9, 0.75))
        cylinder(g, 0.4, 0.9, 3, material("#252931"), 19, 16.6, rz: -1.1)
        pirateEyes(g, x: 17.5, y: 17.5, z: 1.2)
        pirateFigurehead(g, since: bowStart, at: vector(14, 5, 0))
        return g
    }

    private static func pirateSabre() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#4f4f63", trim: "#d1b957", length: 34, width: 12, stern: 12)
        pirateRig(g, [(-10, 15), (-2, 20), (7, 17)], cloth: "#e4dbc1")
        pirateCabin(g, x: -12, y: 12, color: "#53566c", roof: "#b49a57")
        pirateCabin(g, x: -12, y: 16, color: "#e2d6b7", roof: "#a88b4a", width: 5)
        pirateCannons(g, count: 6)
        for side in [-1.0, 1] {
            box(g, 25, 1, 0.3, material("#ccb14e"), -1, -0.8, side * 6.1)
            profile(g, [(13, 6), (18, 12), (17, 5)], 0.8, material("#dadacb")).position.z = CGFloat(side * 1.8)
        }
        return g
    }

    private static func pirateShark() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#7b8194", trim: "#ced4d9", width: 12, stern: 8)
        pirateRig(g, [(-5, 16), (5, 18)], cloth: "#e6e0cc", stripe: "#65758d")
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
        profile(g, [(-17, 8), (-15, 3), (-12, -3), (11, -3), (16, 3), (18, 11), (16, 12),
                    (14, 6), (11, 4), (-12, 4), (-15, 9)], 9, material(naglfar ? "#795839" : "#8d5138"))
        pirateRig(g, naglfar ? [(-5, 18), (6, 15)] : [(0, 20)], cloth: "#f3e0bb", stripe: naglfar ? "#9d4b3a" : "#ad3540", rows: 1)
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
                box(g, 0.6, 6, 1.1, material("#cfaa67"), 16, 9, Double(index), rz: Double(index) * 0.2)
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
        pirateEyes(g, x: 17, y: 8.4, z: 2)
        pirateFigurehead(g, since: bowStart, at: vector(14.6, 5, 0))
        let sternStart = g.childNodes.count
        // The Chopper stern and antlers remain legible opposite the Luffy bow.
        pirateEllipsoid(g, 2.1, "#c18f65", -15, 8)
        cylinder(g, 2.3, 2.3, 1.8, material("#d55c84"), -15, 10)
        for side in [-1.0, 1] {
            cylinder(g, 0.25, 0.4, 4, material("#886547"), -15, 11, side * 3, rz: side * 0.5)
            cylinder(g, 0.2, 0.25, 2, material("#886547"), -15, 12, side * 4, rz: -side * 0.6)
        }
        box(g, 1.4, 0.3, 0.2, material("#f9efda"), -15, 10, 2.35)
        box(g, 0.3, 1.4, 0.2, material("#f9efda"), -15, 10, 2.35)
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
        pirateCannons(g, count: 7)
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
        pirateEyes(g, x: 14.6, y: 7.1, z: 1.9, large: true)
        pirateFigurehead(g, since: bowStart, at: vector(13, 5, 0))
        return g
    }

    private static func pirateSpadille() -> SCNNode {
        let g = SCNNode()
        pirateHull(g, "#71513c", trim: "#d8a95d", length: 25, width: 9, stern: 7)
        pirateRig(g, [(0, 18)], cloth: "#e8d6b7", stripe: "#b27a46", rows: 1)
        pirateCabin(g, x: -8, y: 7, color: "#d1ad76", roof: "#87523b", width: 5)
        // A large spade on the sail identifies Ace's original crew at miniature scale.
        let ink = material("#392e2c")
        pirateEllipsoid(g, 1.4, "#392e2c", -0.8, 14, 1.1)
        pirateEllipsoid(g, 1.4, "#392e2c", 0.8, 14, 1.1)
        profile(g, [(-2, 14), (0, 17), (2, 14)], 0.2, ink).position.z = 1.1
        box(g, 0.7, 2.7, 0.25, ink, 0, 12.7, 1.1)
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
