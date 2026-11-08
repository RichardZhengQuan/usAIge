import AppKit
import SceneKit

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
        let half = length / 2
        profile(group, [(-half, 5), (half - 2, 5), (half + 1, 7), (half - 1, 0),
                        (half - 5, -4), (-half + 3, -4)], width, material(hex))
        box(group, length - 1, 0.7, width + 1.4, material(rail), 0, 4.8)
        box(group, length - 3, 0.5, width - 1, material("#B88B57"), 0, 5.3)
    }

    private static func specialRig(_ group: SCNNode, x: Double = -2, height: Double = 18,
                                   sailColor: String = "#F6EAD3", width: Double = 12) {
        let wood = material("#68462E")
        mast(group, x, 5, height, wood)
        sail(group, x, 5 + height * 0.56, width, height * 0.48,
             material(sailColor, roughness: 0.85, doubleSided: true), brace: 0.18)
        box(group, width + 0.8, 0.4, 0.4, wood, x, 5 + height * 0.82)
        plane(group, 3.5, 2.1, textured(pirateFlag), x + 1.7, 5 + height)
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
        cylinder(group, radius, radius, height, wall, x, y + height / 2, z)
        cylinder(group, 0, radius * 1.45, radius * 2, roof, x, y + height + radius, z)
        for side in [-1.0, 1] {
            box(group, 0.65, 1.5, 0.16, material("#29243C"), x, y + height * 0.65,
                z + side * (radius + 0.04))
        }
    }

    /// Put existing detail geometry around its physical hinge without moving it.
    /// Hulls, decks and buildings remain outside these animation groups.
    private static func specialMovingPart(_ root: SCNNode, from index: Int,
                                          pivot: SCNVector3) -> SCNNode {
        let children = Array(root.childNodes.dropFirst(index))
        let part = SCNNode()
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
        rotor.position = vector(x, y, 0)
        sphere(rotor, 0.55, 10, bronze, 0, 0)
        box(rotor, 0.35, radius * 2, 0.75, bronze, 0, 0)
        box(rotor, 0.35, 0.75, radius * 2, bronze, 0, 0)
        group.addChildNode(rotor)
        PaperweightShipAnimation.tag(rotor, as: .propeller)
    }

    private static func specialMiniMerry() -> SCNNode {
        let group = SCNNode(), cream = material("#FFF4DA"), gold = material("#E4AB48")
        specialHull(group, color: "#DCA066", width: 8, length: 20, rail: "#FDF2DB")
        box(group, 4, 2, 7, material("#A74633"), -3, 6)
        let figureStart = group.childNodes.count
        sphere(group, 3.2, 14, cream, 11, 6).scale = vector(1.1, 1, 0.9)
        cylinder(group, 1.5, 1.8, 3, cream, 10, 4)
        for side in [-1.0, 1] {
            torus(group, 1.1, 0.35, rings: 14, sides: 6, gold, 10, 7, side * 2.5)
            sphere(group, 0.5, 8, material("#252020"), 12.7, 6.5, side * 1.5)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: figureStart,
                                                       pivot: vector(10, 4, 0)), as: .figurehead)
        box(group, 3.3, 3.7, 3, material("#456C83"), -11, 2)
        cylinder(group, 0.4, 0.4, 5, material("#444950"), -11, -0.6, rz: .pi / 2)
        torus(group, 1.2, 0.3, rings: 12, sides: 6, material("#777D83"), -13.5, -0.6, ry: .pi / 2)
        specialScrew(group, x: -13.5, y: -0.6, radius: 1.2, color: "#777D83")
        return group
    }

    private static func specialSubmarine(shark: Bool) -> SCNNode {
        let group = SCNNode(), hull = material(shark ? "#427FAD" : "#EAC52E", roughness: 0.38)
        let dark = material(shark ? "#263D59" : "#333A42")
        cylinder(group, 4.5, 4.5, 23, hull, 0, 0.7, rz: .pi / 2)
        sphere(group, 4.5, 16, hull, 11.5, 0.7).scale = vector(1.3, 1, 1)
        sphere(group, 4.5, 16, hull, -11.5, 0.7).scale = vector(0.8, 1, 1)
        specialPortholes(group, xs: [-7, -2, 3, 8], y: 1.2, z: 4.55)
        if shark {
            profile(group, [(-2, 4), (-5, 11), (3, 4)], 0.8, dark, bevel: 0.1)
            profile(group, [(-14, 0), (-19, 5), (-18, 0), (-19, -4)], 1, dark, bevel: 0.1)
            for side in [-1.0, 1] {
                box(group, 6, 0.6, 4, dark, -1, 0.5, side * 5.4, ry: side * 0.3)
                disc(group, 0.6, 12, material("#F2F5F4"), 12.5, 2.5, side * 3.7,
                     ry: side > 0 ? 0 : .pi)
                disc(group, 0.25, 10, dark, 12.7, 2.5, side * 3.77,
                     ry: side > 0 ? 0 : .pi)
                // A zigzag row of teeth under the shark's nose.
                for x in stride(from: 8.0, through: 14, by: 1.5) {
                    cylinder(group, 0.6, 0, 1.1, material("#FFF5DD"), x, -0.8,
                             side * 3.8)
                }
            }
        } else {
            box(group, 8, 4, 5, hull, -2, 6)
            cylinder(group, 0.35, 0.35, 6.5, dark, -1, 10)
            box(group, 2.5, 0.7, 0.7, dark, 0, 13)
            cylinder(group, 0.3, 0.3, 4, dark, -4, 9)
            box(group, 4, 0.65, 9, dark, -14.5, 1)
            box(group, 2.2, 5, 0.7, dark, -14.5, 1)
            for side in [-1.0, 1] {
                disc(group, 1.7, 18, material("#191D25"), -2, 6, side * 2.6,
                     ry: side > 0 ? 0 : .pi)
                torus(group, 1, 0.2, rings: 14, sides: 6, hull, -2, 6, side * 2.65)
            }
        }
        specialScrew(group, x: shark ? -16.7 : -16.2, y: 0.7, radius: 2.2)
        return group
    }

    private static func specialQueenMama() -> SCNNode {
        let group = SCNNode(), pink = material("#EA86AB"), icing = material("#FFF0C9")
        specialHull(group, color: "#CB4C80", width: 13, rail: "#FAD0D8")
        for (x, y, radius, height) in [(-6.0, 5.4, 5.0, 5.0), (-6, 10.4, 3.5, 4),
                                       (-6, 14.4, 2.2, 3), (3, 5.4, 4, 5)] {
            cylinder(group, radius, radius, height, pink, x, y + height / 2)
            cylinder(group, radius + 0.3, radius + 0.3, 0.6, icing, x, y + height)
            for z in [-radius * 0.7, radius * 0.7] {
                sphere(group, 0.65, 8, material("#D93252"), x, y + height + 0.6, z)
            }
        }
        mast(group, -1, 5, 21, material("#9F4D6B"))
        sail(group, -1, 21, 12, 7, material("#F4B5C8", doubleSided: true), brace: 0.15)
        for side in [-1.0, 1] {
            cylinder(group, 0, 0.7, 4, icing, 5, 13, side * 3)
        }
        let figureStart = group.childNodes.count
        sphere(group, 4.1, 16, icing, 14, 6.5).scale = vector(0.65, 1, 1)
        sphere(group, 1.1, 10, material("#D9506C"), 17, 6.5)
        specialEyes(group, 16.3, 8, 0, spacing: 1.6, radius: 0.7)
        for side in [-1.0, 1] {
            sphere(group, 1.4, 10, pink, 14.5, 6, side * 3.4)
        }
        for z in [-1.2, 0, 1.2] {
            cylinder(group, 0, 0.5, 2, material("#EFC257"), 14, 11, z)
        }
        box(group, 0.3, 0.6, 3.6, material("#A83461"), 16.8, 5.3)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: figureStart,
                                                       pivot: vector(13, 5, 0)), as: .figurehead)
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
            profile(group, [(-width / 2, y + height / 2), (0, y + height / 2 + 2),
                            (width / 2, y + height / 2)], width * 0.85,
                    material("#273F38"), bevel: 0.25).position.x = -4
        }
        for side in [-1.0, 1] {
            let serpentStart = group.childNodes.count
            for index in 0..<7 {
                let t = Double(index)
                sphere(group, 1.6, 10, green, 8 + t * 1.8, 2 + sin(t * 0.9) * 1.3,
                       side * (4.2 + t * 0.22))
            }
            sphere(group, 2.5, 12, green, 20, 5.2, side * 5.5).scale = vector(1.4, 0.85, 0.9)
            sphere(group, 0.5, 8, material("#F8EBC5"), 21.5, 6, side * 6.9)
            sphere(group, 0.22, 8, material("#161B20"), 21.5, 6, side * 7.25)
            box(group, 2, 0.3, 0.5, material("#D83C47"), 23.6, 4.9, side * 5.5)
            PaperweightShipAnimation.tag(specialMovingPart(group, from: serpentStart,
                                                           pivot: vector(8, 2, side * 4.2)), as: .serpent)
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
        for (x, z, height) in [(-5.0, -3.5, 11.0), (-5, 3.5, 11), (3, -3, 15), (3, 3, 15)] {
            specialTurret(group, x: x, y: 3, z: z, height: height, radius: 1.8,
                          wall: stone, roof: material("#493257"))
        }
        mast(group, -7, 3, 21, material("#4B3C42"))
        sail(group, -7, 18, 10, 7, material("#C1A7C6", doubleSided: true), brace: 0.1)
        for x in [-7.0, 6, 9] {
            cylinder(group, 0.25, 0.6, 6, dark, x, 5, -5)
            sphere(group, 1.8, 10, material("#3C5149"), x, 8.3, -5)
        }
        return group
    }

    private static func specialCoffin() -> SCNNode {
        let group = SCNNode(), black = material("#26262D"), gold = material("#BC9B5A")
        profile(group, [(-11, 1), (9, 1), (11, -0.5), (7, -2.2), (-8, -2.2)], 6, black, bevel: 0.25)
        box(group, 16, 0.4, 6.7, gold, -1, 1.2)
        box(group, 14, 0.5, 5.3, material("#5D3143"), -1, 1.5)
        box(group, 0.8, 21, 0.8, black, -3, 11)
        box(group, 10, 0.8, 0.8, black, -3, 17)
        sail(group, -3, 12, 8, 7, material("#A5BC93", doubleSided: true), brace: 0)
        for z in [-2.6, 2.6] {
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
        cylinder(group, 1.9, 2.7, 7, white, 12.5, 7.5, rz: -0.25)
        sphere(group, 3.6, 14, white, 14, 12.5)
        sphere(group, 1.8, 12, material("#E6AF4A"), 17, 11.9).scale = vector(1.7, 0.5, 1)
        specialEyes(group, 15.5, 13.4, 0, spacing: 2, radius: 0.6)
        sphere(group, 1, 10, pink, 14, 16)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(12.5, 5, 0)), as: .figurehead)
        for side in [-1.0, 1] {
            sphere(group, 3, 12, white, 5, 4.5, side * 5.7).scale = vector(1.4, 0.6, 0.35)
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
            for y in [7.0, 7.7] {
                box(group, 4, 0.15, 0.15, material("#A9A9A3"), 15.4, y, z * 1.5, ry: z * 0.15)
            }
        }
        sphere(group, 0.65, 8, material("#D38D94"), 17, 7.4)
        sphere(group, 1.4, 10, material("#141719"), 16.5, 5.9).scale = vector(0.6, 0.65, 1)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(13, 5, 0)), as: .figurehead)
        for side in [-1.0, 1] {
            sphere(group, 2, 10, dark, 10.5, 5.8, side * 5.3).scale = vector(1.4, 0.7, 1)
            for x in [-9.0, -4, 1, 6] {
                box(group, 1.4, 1.4, 0.2, material("#1D2328"), x, 1.7, side * 5.7)
            }
        }
        return group
    }

    private static func specialBaratie() -> SCNNode {
        let group = SCNNode(), cream = material("#F5D9AB"), green = material("#4B8B75")
        specialHull(group, color: "#B76B48", width: 14, length: 29, rail: "#E9C78E")
        cylinder(group, 8, 8, 6, cream, -1, 8)
        cylinder(group, 8.7, 8.7, 0.8, green, -1, 11.5)
        cylinder(group, 5.5, 5.5, 4, cream, -1, 13.8)
        cylinder(group, 6.3, 6.3, 0.7, green, -1, 16)
        cylinder(group, 0, 6, 4, green, -1, 18.1)
        for side in [-1.0, 1] {
            for x in [-6.0, -2, 2, 6] { box(group, 1.2, 2.2, 0.2, material("#496375"), x, 8, side * 7.5) }
        }
        let headStart = group.childNodes.count
        sphere(group, 4.2, 14, cream, 14, 5).scale = vector(1.3, 1, 1)
        specialEyes(group, 16.5, 6, 0, spacing: 2.6, radius: 0.8)
        torus(group, 1.6, 0.4, rings: 16, sides: 6, material("#A94E44"), 18, 4.8, ry: .pi / 2)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(12, 4, 0)), as: .figurehead)
        let tailStart = group.childNodes.count
        profile(group, [(-14, 3), (-20, 8), (-18, 2), (-20, -2)], 1.2, green)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-14, 3, 0)), as: .serpent)
        return group
    }

    private static func specialSexyFoxy() -> SCNNode {
        let group = SCNNode(), purple = material("#B16A9C"), wood = material("#9D503F")
        specialHull(group, color: "#9D503F", width: 13, rail: "#DAB34F")
        box(group, 11, 5, 11, purple, -6, 8)
        specialRig(group, x: -2, height: 20, sailColor: "#EEE3CD", width: 13)
        sphere(group, 4, 14, wood, 14, 8).scale = vector(1.1, 1.1, 1)
        sphere(group, 1.8, 10, material("#E5B77C"), 17.5, 6.8).scale = vector(1.7, 0.8, 1)
        for side in [-1.0, 1] {
            cylinder(group, 0, 1.6, 6, wood, 14, 12.7, side * 2.5, rz: side * 0.15)
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
        sphere(group, 4.5, 14, brown, 13, 8)
        for side in [-1.0, 1] {
            sphere(group, 2.6, 12, brown, 11.6, 8, side * 3.6).scale = vector(0.5, 1.1, 1)
            cylinder(group, 0.4, 1, 7, ivory, 16.5, 5, side * 2.5, rz: -0.7)
            sphere(group, 0.5, 8, material("#1C2024"), 16, 9.1, side * 1.7)
        }
        let trunkStart = group.childNodes.count
        for index in 0..<5 {
            let t = Double(index)
            sphere(group, 1.35 - t * 0.15, 10, brown, 16 + t * 0.55, 6.7 - t * 1.3)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: trunkStart,
                                                       pivot: vector(16, 6.7, 0)), as: .serpent)
        return group
    }

    private static func specialSnapperHead() -> SCNNode {
        let group = SCNNode(), blue = material("#537B8A"), cream = material("#ECD7A8")
        specialHull(group, color: "#425F71", width: 13, rail: "#CCAE75")
        specialRig(group, x: -5, height: 19, sailColor: "#4E8D9D", width: 12)
        specialRig(group, x: 5, height: 15, sailColor: "#6AABB2", width: 8)
        sphere(group, 4.2, 14, blue, 14, 6.5).scale = vector(1.25, 0.9, 1)
        sphere(group, 3.2, 12, cream, 16, 4.5).scale = vector(1.15, 0.45, 1.05)
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
        cylinder(group, 0, 6.4, 6, gold, 1, 14)
        mast(group, -7, 5, 20, dark)
        for z in [-5.5, 5.5] {
            box(group, 23, 0.5, 2.2, gold, 0, 8, z)
            for x in [-10.0, 0, 10] {
                cylinder(group, 0.25, 0.25, 5, dark, x, 10, z)
                let rotor = SCNNode()
                rotor.position = vector(x, 12.6, z)
                box(rotor, 7, 0.25, 0.8, gold, 0, 0)
                box(rotor, 0.8, 0.25, 7, gold, 0, 0.05)
                group.addChildNode(rotor)
                PaperweightShipAnimation.tag(rotor, as: .rotor)
            }
        }
        for index in 0..<4 {
            let angle = Double(index) * .pi / 2
            let x = -5 + cos(angle) * 4, y = 18 + sin(angle) * 4
            cylinder(group, 1.8, 1.8, 1.5, material("#EEDBB4"), x, y, -0.3, rx: .pi / 2)
            torus(group, 1.7, 0.25, rings: 12, sides: 6, dark, x, y, 0.55)
        }
        sphere(group, 2.6, 14, gold, 15, 8)
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
            sail(group, x, 5 + h * 0.55, 8, h * 0.5, cloth, brace: 0.2)
        }
        for x in [-10.0, -3, 4, 10] {
            cylinder(group, 0.4, 1.1, 3.5, moss, x, 5.4, 5.8)
            cylinder(group, 0.3, 0.9, 2.5, moss, x + 1, 5, -5.8)
        }
        sphere(group, 2.8, 12, material("#DFD5AD"), 14, 8)
        for z in [-1.2, 1.2] { sphere(group, 0.65, 8, dark, 16, 8, z) }
        box(group, 2.4, 1.6, 2.8, material("#DFD5AD"), 14.3, 5.9)
        return group
    }

    private static func specialNoah() -> SCNNode {
        let group = SCNNode(), wood = material("#856244"), roof = material("#5C514B")
        specialHull(group, color: "#77543A", width: 15, length: 33, rail: "#C09C68")
        box(group, 27, 11, 13, wood, -1, 9.5)
        let roundedRoof = NSBezierPath()
        roundedRoof.move(to: NSPoint(x: -15, y: 15))
        roundedRoof.curve(to: NSPoint(x: 13, y: 15), controlPoint1: NSPoint(x: -13, y: 23),
                          controlPoint2: NSPoint(x: 11, y: 23))
        roundedRoof.close()
        extrude(group, roundedRoof, 14, roof, bevel: 0.4)
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
                                                           pivot: vector(15, 4, side * 5)), as: .serpent)
        }
        return group
    }

    private static func specialStriker() -> SCNNode {
        let group = SCNNode(), green = material("#477D69"), wood = material("#BB8751")
        // Ace's narrow one-person fire-powered craft has two side floats.
        for z in [-3.0, 3] {
            cylinder(group, 1.3, 1.3, 23, green, 0, 0, z, rz: .pi / 2)
            sphere(group, 1.3, 10, green, 11.5, 0, z).scale = vector(1.8, 1, 1)
        }
        box(group, 13, 0.7, 6, wood, 0, 1.5)
        box(group, 3, 1, 3, material("#8D6849"), -1, 2.3)
        cylinder(group, 0.4, 0.4, 13, material("#534C42"), 3, 8)
        flat(group, [(3.4, 13.8), (3.4, 4), (10, 4)], material("#EEE2C1", doubleSided: true))
        cylinder(group, 1.2, 1.8, 3, material("#605F56"), -7, 2.5, rz: .pi / 2)
        let flame = material("#F29A37")
        let fire = sphere(group, 1.3, 10, flame, -10, 2.5)
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
        for index in 0..<4 {
            let t = Double(index)
            sphere(group, 1.7, 10, green, 12.5 + sin(t * 0.6) * 2, 6 + t * 1.7)
        }
        sphere(group, 2.6, 12, green, 16.7, 12.7).scale = vector(1.4, 0.8, 0.85)
        for z in [-1.5, 1.5] {
            cylinder(group, 0, 0.6, 4, gold, 14.5, 15, z, rz: 0.7)
            sphere(group, 0.45, 8, material("#EBD99B"), 18, 13.4, z)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: dragonStart,
                                                       pivot: vector(12.5, 6, 0)), as: .figurehead)
        let tailStart = group.childNodes.count
        profile(group, [(-13, 3), (-17, 7), (-19, 7.5), (-18, 5), (-15, 2)], 2, green)
        PaperweightShipAnimation.tag(specialMovingPart(group, from: tailStart,
                                                       pivot: vector(-13, 3, 0)), as: .serpent)
        return group
    }

    private static func specialGerma() -> SCNNode {
        let group = SCNNode(), cream = material("#DDD4B9"), dark = material("#4D6975")
        // Germa's seagoing castle rides a gigantic Den Den Mushi.
        sphere(group, 9, 16, material("#A5AD8B"), 1, 0.5).scale = vector(1.65, 0.6, 0.85)
        sphere(group, 7, 16, dark, -4, 5).scale = vector(1.4, 1, 1.15)
        torus(group, 4.3, 0.7, rings: 20, sides: 6, cream, -4, 5.5, 7.8)
        torus(group, 2.7, 0.6, rings: 18, sides: 6, cream, -4, 5.5, 7.9)
        box(group, 14, 5, 11, cream, -4, 11)
        for x in [-10.0, 2] {
            for z in [-4.5, 4.5] {
                specialTurret(group, x: x, y: 11, z: z, height: 6, radius: 1.7,
                              wall: cream, roof: material("#416A89"))
            }
        }
        let headStart = group.childNodes.count
        sphere(group, 3.6, 14, material("#A5AD8B"), 13, 2.7)
        for z in [-2.0, 2] {
            cylinder(group, 0.35, 0.5, 5, material("#A5AD8B"), 13, 7, z, rz: -0.1)
            sphere(group, 1.1, 12, cream, 13.3, 9.5, z)
            sphere(group, 0.5, 8, material("#202731"), 14.15, 9.5, z)
        }
        PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                       pivot: vector(10, 3, 0)), as: .serpent)
        for x in [-8.0, 0] {
            mast(group, x, 13, 14, material("#252C37"))
            sail(group, x, 22.5, 6.5, 6, material("#272D37", doubleSided: true), brace: 0)
            // Twin sixes on each black Germa sail.
            for digit in [-1.2, 1.2] {
                for side in [-1.0, 1] {
                    torus(group, 0.7, 0.19, rings: 12, sides: 6, cream,
                          x + digit, 22, side * 1.1)
                    box(group, 0.35, 1.5, 0.2, cream, x + digit - 0.55, 23, side * 1.1,
                        rz: -0.25)
                }
            }
        }
        return group
    }

    private static func specialMarine(garp: Bool) -> SCNNode {
        let group = SCNNode(), blue = material("#3C6A8E"), white = material("#EFEADB")
        specialHull(group, color: "#47769A", width: 12, length: 31, rail: "#F0EEE0")
        box(group, 8, 6, 10, white, -10, 8)
        for (x, height) in [(-6.0, 17.0), (2, 21), (9, 16)] {
            mast(group, x, 5, height, material("#806444"))
            sail(group, x, 5 + height * 0.55, 8, 7, white, brace: 0.2)
            // Navy-blue gull-like mark, drawn with geometry on both sail sides.
            for side in [-1.0, 1] {
                box(group, 3.4, 0.4, 0.15, blue, x - 1.4, 5 + height * 0.55,
                    side * 1.3, rz: -0.35)
                box(group, 3.4, 0.4, 0.15, blue, x + 1.4, 5 + height * 0.55,
                    side * 1.3, rz: 0.35)
            }
        }
        for side in [-1.0, 1] {
            for x in stride(from: -10.0, through: 10, by: 4) {
                box(group, 1.5, 1.3, 0.25, material("#293344"), x, 2.4, side * 6.1)
                cylinder(group, 0.4, 0.5, 2.2, material("#4C5156"), x, 2.4, side * 7, rx: .pi / 2)
            }
        }
        if garp {
            let headStart = group.childNodes.count
            sphere(group, 3.8, 14, material("#F4E9D6"), 15, 7)
            sphere(group, 2, 12, material("#D6B88C"), 18, 6.2).scale = vector(1.4, 0.8, 1)
            sphere(group, 0.9, 10, material("#29313A"), 20.3, 6.8)
            for z in [-2.7, 2.7] {
                sphere(group, 1.8, 10, material("#A98563"), 13.4, 8.3, z).scale = vector(0.6, 1.5, 0.8)
                sphere(group, 0.45, 8, material("#29313A"), 17.2, 8.3, z * 0.5)
            }
            // The dog's bone is visible even at miniature size.
            box(group, 0.8, 0.8, 8, white, 18.7, 5.7)
            for z in [-4.0, 4] { sphere(group, 0.8, 10, white, 18.7, 5.7, z) }
            PaperweightShipAnimation.tag(specialMovingPart(group, from: headStart,
                                                           pivot: vector(13, 5, 0)), as: .figurehead)
        } else {
            profile(group, [(13, 5), (17, 11), (19, 10), (17, 4)], 2.5, white)
        }
        return group
    }

    private static func specialRaft() -> SCNNode {
        let group = SCNNode(), wood = material("#9A6A3C"), dark = material("#59412F")
        for z in stride(from: -6.0, through: 6, by: 3) {
            cylinder(group, 1.6, 1.6, 29, wood, 0, -0.2, z, rz: .pi / 2)
            for x in [-14.6, 14.6] {
                disc(group, 1.25, 12, material("#CB9C61"), x, -0.2, z, ry: .pi / 2)
            }
        }
        for x in [-9.0, 8] { box(group, 1, 0.8, 16, dark, x, 1.4) }
        mast(group, 0, 1.8, 20, dark)
        sail(group, 0, 13.5, 16, 10, material("#EEE3C8", doubleSided: true), brace: 0.12)
        plane(group, 4.5, 2.8, textured(pirateFlag), 2.2, 22)
        // Blackbeard's three-skull device has a different silhouette from a single Jolly Roger.
        for x in [-3.0, 0, 3] {
            sphere(group, 1.2, 10, material("#2A2828"), x, 14, 1)
            box(group, 1.3, 1.2, 0.6, material("#2A2828"), x, 12.8, 1)
        }
        for z in [-4.0, 4] { box(group, 5, 3, 3, material("#826647"), -8, 3.4, z) }
        return group
    }
}
