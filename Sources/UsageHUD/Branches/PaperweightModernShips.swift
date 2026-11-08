import AppKit
import SceneKit

@available(macOS 14.0, *)
extension PaperweightShipFactory {
    static func detailedLiner() -> SCNNode {
        let group = SCNNode()
        let hull = metalHullMaterial(hex: "#25303B")
        let white = material("#EEECE4", roughness: 0.58)
        let cream = material("#E2DCCB", roughness: 0.75)
        let buff = material("#D6A45E", roughness: 0.65)
        let black = material("#20262C", roughness: 0.64)
        let glass = material("#263F50", roughness: 0.22, metalness: 0.15)
        let wood = woodMaterial(hex: "#AE8C60")
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -17.7, y: 4.3))
        outline.line(to: NSPoint(x: 18, y: 4.3))
        outline.curve(to: NSPoint(x: 14.8, y: -3.6), controlPoint1: NSPoint(x: 17.5, y: 0.9), controlPoint2: NSPoint(x: 16.5, y: -2.5))
        outline.curve(to: NSPoint(x: -14.9, y: -4.1), controlPoint1: NSPoint(x: 9, y: -4.9), controlPoint2: NSPoint(x: -10, y: -4.7))
        outline.curve(to: NSPoint(x: -17.7, y: 4.3), controlPoint1: NSPoint(x: -17.9, y: -3), controlPoint2: NSPoint(x: -17.6, y: 1.4))
        outline.close()
        extrude(group, outline, 9.2, hull, bevel: 0.34)
        profile(group, [(-16, -0.4), (16.6, -0.4), (14.6, -3.65), (-14.8, -3.8)], 9.25,
                material("#8E352D", roughness: 0.8), bevel: 0.18)
        modernBox(group, 34.4, 0.4, 9.65, wood, 0, 4.42)
        modernBox(group, 27.7, 3.05, 8.4, white, -0.5, 6.1)
        modernBox(group, 22.3, 2.15, 7.1, cream, -0.8, 8.55)
        modernBox(group, 28.6, 0.25, 8.9, wood, -0.5, 7.72)
        modernBox(group, 22.8, 0.27, 7.7, white, -0.8, 9.75)
        modernBox(group, 4.7, 1.45, 7.45, white, 10.7, 9.35)
        modernBox(group, 4.8, 0.22, 7.8, cream, 10.7, 10.18)
        for side in [-1.0, 1] {
            let z = side * 4.25
            portholes(group, xs: Array(stride(from: -14.0, through: 15, by: 1.5)), y: 2.25, z: side * 4.66,
                      radius: 0.19, material: glass)
            for x in stride(from: -12.4, through: 12.5, by: 1.18) {
                modernBox(group, 0.65, 0.76, 0.08, glass, x, 6.35, z)
            }
            for x in stride(from: -10.3, through: 9.4, by: 1.34) {
                modernBox(group, 0.7, 0.63, 0.08, glass, x, 8.62, side * 3.59)
            }
            railing(group, fromX: -15.8, toX: 16, y: 4.65, z: side * 4.67, spacing: 2.7, material: white)
            railing(group, fromX: -10.9, toX: 9.1, y: 9.9, z: side * 3.64, spacing: 2.8, material: white)
            for x in [-9.6, -5.6, -1.6, 2.4, 6.4] {
                modernLifeboat(group, at: (x, 8.2, side * 4.15), material: cream)
                rail(group, from: (x - 1.3, 7.85, side * 3.95), to: (x - 1.3, 9.25, side * 4.1), radius: 0.07, material: white)
                rail(group, from: (x + 1.3, 7.85, side * 3.95), to: (x + 1.3, 9.25, side * 4.1), radius: 0.07, material: white)
            }
        }
        for x in [-7.5, -2.9, 1.7, 6.3] {
            cylinder(group, 1.04, 1.14, 5.8, buff, x, 12.65, rz: 0.11)
            cylinder(group, 1.06, 1.06, 1.15, black, x - 0.36, 15.53, rz: 0.11)
            cylinder(group, 0.88, 0.88, 0.09, material("#080E14"), x - 0.43, 16.1, rz: 0.11)
            rail(group, from: (x - 0.8, 10, 1.1), to: (x - 0.6, 14.7, 1.1), radius: 0.055, material: black)
        }
        for x in [-14.1, 14.2] {
            cylinder(group, 0.14, 0.23, 14.0, buff, x, 11.5)
            rail(group, from: (x, 17.9, 0), to: (x < 0 ? -17.0 : 17.4, 4.9, 0), radius: 0.048, material: black)
            rail(group, from: (x, 17.1, 0), to: (x < 0 ? -8.7 : 8.9, 8, 0), radius: 0.048, material: black)
            rail(group, from: (x - 1.8, 15.2, 0), to: (x + 1.8, 15.2, 0), radius: 0.08, material: buff)
        }
        for z in [-2.5, -0.85, 0.85, 2.5] {
            modernBox(group, 0.08, 0.7, 1.0, glass, 13.1, 9.52, z)
        }
        rail(group, from: (-14.1, 17.1, 0), to: (14.2, 17.1, 0), radius: 0.035, material: black)
        return group
    }

    static func detailedSubmarine() -> SCNNode {
        let group = SCNNode()
        let hull = metalHullMaterial(hex: "#546B7C")
        let dark = material("#233746", roughness: 0.4, metalness: 0.25)
        let edge = material("#7B919C", roughness: 0.42, metalness: 0.4)
        let brass = material("#C3A256", roughness: 0.35, metalness: 0.5)
        cylinder(group, 3.35, 3.35, 21.4, hull, 0, -0.45, rz: .pi / 2)
        sphere(group, 3.35, 26, hull, 10.7, -0.45).scale = vector(1.56, 1, 1)
        sphere(group, 3.35, 26, hull, -10.7, -0.45).scale = vector(1.8, 1, 1)
        modernBox(group, 23, 0.35, 2.2, dark, -0.2, 2.87)
        let fin = NSBezierPath()
        fin.move(to: NSPoint(x: -1.2, y: 2.8))
        fin.line(to: NSPoint(x: 5.9, y: 2.8))
        fin.curve(to: NSPoint(x: 4.3, y: 8.2), controlPoint1: NSPoint(x: 5.5, y: 6.2), controlPoint2: NSPoint(x: 5, y: 8.1))
        fin.line(to: NSPoint(x: 0.2, y: 8.2))
        fin.curve(to: NSPoint(x: -1.2, y: 2.8), controlPoint1: NSPoint(x: -1.6, y: 7.8), controlPoint2: NSPoint(x: -1.2, y: 5.4))
        fin.close()
        extrude(group, fin, 2.4, hull, bevel: 0.2)
        modernBox(group, 4.3, 0.2, 3.0, dark, 2.3, 8.27)
        for (x, height) in [(1.1, 4.0), (2.7, 3.0), (4.0, 2.2)] {
            cylinder(group, 0.13, 0.17, height, edge, x, 8.3 + height / 2)
            if x == 1.1 { rail(group, from: (x, 12.25, 0), to: (x + 0.8, 12.25, 0), radius: 0.18, material: dark) }
        }
        modernBox(group, 3.5, 0.25, 7.2, dark, 2.5, 5.7)
        for x in stride(from: -10.0, through: 8, by: 3.6) {
            torus(group, 3.36, 0.055, rings: 36, sides: 6, edge, x, -0.45, 0, ry: .pi / 2)
        }
        for side in [-1.0, 1] {
            for x in [-7.6, -3.5, 0.6, 4.7, 8.8] {
                disc(group, 0.34, 18, brass, x, 0.65, side * 3.23, ry: side < 0 ? .pi : 0)
                disc(group, 0.21, 18, dark, x, 0.65, side * 3.25, ry: side < 0 ? .pi : 0)
            }
            for x in [-3.4, -2.7, -2.0, -1.3] { modernBox(group, 0.13, 0.95, 0.08, dark, x, 1.8, side * 2.88) }
            modernBox(group, 2.8, 0.22, 2.5, hull, -14.3, -0.4, side * 3.7)
        }
        modernBox(group, 3.1, 4.3, 0.24, hull, -14.25, -0.45)
        cylinder(group, 0.5, 0.55, 3.4, dark, -17.0, -0.45, rz: .pi / 2)
        let screw = SCNNode()
        screw.position = vector(-18.6, -0.45, 0)
        group.addChildNode(screw)
        sphere(screw, 0.6, 16, brass, 0, 0, 0).scale = vector(1.25, 1, 1)
        for index in 0..<4 {
            let angle = Double(index) * .pi / 2
            let blade = SCNNode()
            blade.eulerAngles.x = CGFloat(angle)
            screw.addChildNode(blade)
            modernBox(blade, 0.25, 1.7, 0.8, brass, 0, 1.05, 0, rx: 0.22)
        }
        return group
    }

    static func detailedCarrier() -> SCNNode {
        let group = SCNNode()
        let hull = metalHullMaterial(hex: "#657A89")
        let deck = material("#465461", roughness: 0.9)
        let light = material("#BBC7CD", roughness: 0.6)
        let dark = material("#283D4C", roughness: 0.28)
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -17, y: 3.2))
        outline.line(to: NSPoint(x: 18.6, y: 3.2))
        outline.curve(to: NSPoint(x: 14.6, y: -4), controlPoint1: NSPoint(x: 17, y: 0.4), controlPoint2: NSPoint(x: 16.5, y: -3.2))
        outline.line(to: NSPoint(x: -14.5, y: -4))
        outline.curve(to: NSPoint(x: -17, y: 3.2), controlPoint1: NSPoint(x: -16.1, y: -3.6), controlPoint2: NSPoint(x: -17.1, y: 0))
        outline.close()
        extrude(group, outline, 10.2, hull, bevel: 0.32)
        let topDeck = SCNBox(width: 36.5, height: 0.65, length: 14.3, chamferRadius: 0.24)
        let deckMaterials = [deck, deck, deck, deck, textured(carrierDeckTexture, roughness: 0.95), deck]
        topDeck.materials = deckMaterials
        let deckNode = SCNNode(geometry: topDeck)
        deckNode.position = vector(0.4, 3.8, 0)
        group.addChildNode(deckNode)
        modernBox(group, 35.8, 0.3, 14.8, light, 0.4, 3.36)
        modernBox(group, 5.4, 4.2, 2.8, hull, 4.5, 6.25, -4.7)
        modernBox(group, 4.4, 1.65, 3.0, light, 4.4, 9.15, -4.7)
        modernBox(group, 4.0, 0.68, 0.09, dark, 4.4, 9.34, -3.14)
        modernBox(group, 3.3, 1.1, 2.4, hull, 5.0, 10.51, -4.7)
        for z in [-5.7, -4.6, -3.5] { modernBox(group, 0.08, 0.62, 0.65, dark, 6.67, 9.34, z) }
        cylinder(group, 0.13, 0.2, 5.2, light, 4.7, 13.5, -4.7)
        rail(group, from: (3.0, 14.5, -4.7), to: (6.4, 14.5, -4.7), radius: 0.09, material: light)
        modernBox(group, 2.9, 0.9, 0.13, dark, 4.7, 14.7, -4.7)
        railing(group, fromX: 2.2, toX: 6.7, y: 11.25, z: -3.25, spacing: 1.1, material: light)
        railing(group, fromX: -16.7, toX: 16.9, y: 4.13, z: 7.15, spacing: 3.3, material: light)
        for x in [-12.2, -8.0, -3.8, 9.0, 13.1] {
            modernBox(group, 2.0, 0.55, 0.14, dark, x, 2.3, 5.19)
        }
        for (x, z, yaw) in [(-11.8, -3.8, 0.08), (-6.7, -3.8, 0.08), (9.7, 3.4, -0.35), (14.3, 3.6, -0.35)] {
            modernJet(group, x: x, y: 4.5, z: z, yaw: yaw)
        }
        // Side elevator, rescue craft and catwalk supports read at the larger size.
        modernBox(group, 4.8, 0.25, 2.1, deck, -8.8, 3.55, 6.4)
        for x in [-10.6, -6.9, 2.8, 10.3] {
            rail(group, from: (x, 0.8, 5), to: (x, 3.36, 6.65), radius: 0.18, material: hull)
        }
        modernLifeboat(group, at: (-1.7, 1.7, 5.7), material: material("#DB8E38"))
        return group
    }

    static func detailedSteamer() -> SCNNode {
        let group = SCNNode()
        let white = material("#F0E8D7", roughness: 0.75)
        let red = material("#A83B34", roughness: 0.65)
        let dark = material("#26313C", roughness: 0.48)
        let glass = material("#365267", roughness: 0.25)
        let wood = woodMaterial(hex: "#AD8959")
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -14.6, y: 3.1))
        outline.line(to: NSPoint(x: 15.7, y: 3.1))
        outline.curve(to: NSPoint(x: 11.3, y: -3), controlPoint1: NSPoint(x: 15.4, y: 0.2), controlPoint2: NSPoint(x: 13.5, y: -2.8))
        outline.line(to: NSPoint(x: -11.8, y: -3))
        outline.curve(to: NSPoint(x: -14.6, y: 3.1), controlPoint1: NSPoint(x: -13.9, y: -2.5), controlPoint2: NSPoint(x: -14.3, y: 0.3))
        outline.close()
        extrude(group, outline, 8.9, white, bevel: 0.4)
        modernBox(group, 28.7, 0.34, 10.4, wood, 0, 3.35)
        modernBox(group, 23.7, 0.24, 9.8, white, 0.4, 7.05)
        modernBox(group, 19.5, 3.4, 8.2, white, 1.3, 5.15)
        modernBox(group, 16.1, 2.5, 6.7, white, 2.3, 8.45)
        modernBox(group, 17.6, 0.33, 7.7, wood, 2.3, 9.88)
        modernBox(group, 5.2, 2.2, 5.0, white, 6.4, 11.1)
        modernBox(group, 5.9, 0.28, 5.7, red, 6.4, 12.36)
        for side in [-1.0, 1] {
            for x in stride(from: -7.2, through: 10, by: 1.65) {
                modernBox(group, 0.68, 1.15, 0.08, glass, x, 5.43, side * 4.16)
            }
            for x in stride(from: -4.5, through: 8.8, by: 1.65) {
                modernBox(group, 0.62, 0.91, 0.08, glass, x, 8.6, side * 3.4)
            }
            for x in [5.3, 6.6, 7.9] { modernBox(group, 0.8, 0.95, 0.08, glass, x, 11.2, side * 2.55) }
            railing(group, fromX: -12.5, toX: 13.0, y: 3.53, z: side * 4.85, spacing: 2.7, material: white)
            railing(group, fromX: -9.7, toX: 10.7, y: 7.18, z: side * 4.65, spacing: 2.6, material: white)
            railing(group, fromX: -5.6, toX: 10, y: 10.05, z: side * 3.6, spacing: 2.6, material: white)
        }
        for z in [-2.0, 2] {
            cylinder(group, 0.72, 0.87, 8.7, dark, 7.0, 16.45, z)
            cylinder(group, 1.0, 0.94, 0.6, dark, 7, 20.84, z)
            torus(group, 0.85, 0.15, rings: 20, sides: 6, red, 7, 20.0, z, rx: .pi / 2)
            rail(group, from: (7, 19.5, z), to: (1.5, 10.3, z), radius: 0.045, material: dark)
        }
        let wheel = SCNNode()
        wheel.name = "paddle-wheel"
        wheel.position = vector(-15.2, 2.2, 0)
        group.addChildNode(wheel)
        let bronze = material("#B48C49", roughness: 0.45, metalness: 0.35)
        for z in [-4.0, 4] {
            torus(wheel, 3.65, 0.24, rings: 36, sides: 8, red, 0, 0, z)
            torus(wheel, 2.7, 0.13, rings: 30, sides: 6, red, 0, 0, z)
            disc(wheel, 0.65, 18, bronze, 0, 0, z)
        }
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi
            let y = cos(angle) * 3.55, x = sin(angle) * 3.55
            for z in [-4.0, 4] {
                rail(wheel, from: (0, 0, z), to: (x, y, z), radius: 0.085, material: red)
            }
            modernBox(wheel, 0.35, 1.0, 8.5, wood, x, y, 0, rz: -angle)
        }
        cylinder(wheel, 0.38, 0.38, 9.1, bronze, 0, 0, rx: .pi / 2)
        return group
    }

    static func detailedTugboat() -> SCNNode {
        let group = SCNNode()
        let red = metalHullMaterial(hex: "#B44735")
        let dark = material("#26313A", roughness: 0.62)
        let cream = material("#E7E1CE", roughness: 0.62)
        let glass = material("#254A63", roughness: 0.2, metalness: 0.25)
        let yellow = material("#DDAA4E", roughness: 0.55)
        let wood = woodMaterial(hex: "#987345")
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -13.4, y: 3.6))
        outline.curve(to: NSPoint(x: 13.6, y: 5.0), controlPoint1: NSPoint(x: -3, y: 3.2), controlPoint2: NSPoint(x: 10, y: 4.7))
        outline.curve(to: NSPoint(x: 10.1, y: -3.2), controlPoint1: NSPoint(x: 13.1, y: 1.1), controlPoint2: NSPoint(x: 12.0, y: -2.9))
        outline.curve(to: NSPoint(x: -10.8, y: -3.5), controlPoint1: NSPoint(x: 5, y: -4.4), controlPoint2: NSPoint(x: -6, y: -4.1))
        outline.curve(to: NSPoint(x: -13.4, y: 3.6), controlPoint1: NSPoint(x: -13.5, y: -2.5), controlPoint2: NSPoint(x: -13.6, y: 1.0))
        outline.close()
        extrude(group, outline, 9.2, red, bevel: 0.48)
        modernBox(group, 25.7, 0.8, 10.25, dark, -0.2, 3.1)
        modernBox(group, 24.1, 0.27, 9.4, wood, -0.3, 3.63)
        modernBox(group, 10.4, 4.35, 6.5, cream, -0.5, 6.1)
        modernBox(group, 7.2, 3.2, 6.1, cream, 1.4, 9.85)
        modernBox(group, 8.0, 0.4, 6.8, dark, 1.4, 11.72)
        modernBox(group, 6.3, 1.35, 0.13, glass, 1.4, 10.25, 3.13)
        modernBox(group, 6.3, 1.35, 0.13, glass, 1.4, 10.25, -3.13)
        for x in [-1.6, 0.35, 2.3, 4.25] {
            modernBox(group, 0.13, 1.45, 0.16, cream, x, 10.25, 3.22)
            modernBox(group, 0.13, 1.45, 0.16, cream, x, 10.25, -3.22)
        }
        for z in [-1.9, 0, 1.9] { modernBox(group, 0.1, 1.3, 1.5, glass, 5.05, 10.25, z) }
        for side in [-1.0, 1] {
            modernBox(group, 2.1, 2.8, 0.1, dark, -3.2, 5.55, side * 3.31)
            modernBox(group, 1.65, 2.5, 0.1, cream, -3.2, 5.55, side * 3.38)
            disc(group, 0.34, 16, glass, -3.2, 6.1, side * 3.46, ry: side < 0 ? .pi : 0)
            railing(group, fromX: -11.0, toX: 10.5, y: 3.8, z: side * 4.6, spacing: 2.5, material: cream)
            for x in [-9.9, -5.7, -1.5, 2.7, 6.9, 10.3] {
                torus(group, 0.87, 0.28, rings: 24, sides: 8, dark, x, 1.2, side * 4.92, ry: side < 0 ? .pi : 0)
                rail(group, from: (x, 2.0, side * 4.95), to: (x, 3.75, side * 4.95), radius: 0.055, material: dark)
            }
            torus(group, 0.66, 0.16, rings: 24, sides: 8, material("#D36B43"), 3.3, 6.8, side * 3.46)
        }
        cylinder(group, 0.97, 1.22, 5.4, yellow, -6.7, 10.3)
        cylinder(group, 1.0, 1.0, 1.2, dark, -6.7, 13.28)
        cylinder(group, 0.72, 0.72, 0.12, dark, -6.7, 13.93)
        cylinder(group, 0.10, 0.17, 6.1, cream, 0.7, 14.75)
        rail(group, from: (-1.1, 15.4, 0), to: (2.5, 15.4, 0), radius: 0.1, material: cream)
        for x in [-1.1, 2.5] { sphere(group, 0.26, 12, material(x < 0 ? "#AC4938" : "#5D9B72"), x, 15.5, 0) }
        // A tow winch, aft bollards and vents give the working deck a purpose.
        cylinder(group, 0.55, 0.55, 3.7, dark, -9.4, 4.6, rx: .pi / 2)
        for z in [-2.1, 2.1] { cylinder(group, 0.75, 0.75, 0.2, yellow, -9.4, 4.6, z, rx: .pi / 2) }
        for x in [-11.8, 10.5] {
            for z in [-2.5, 2.5] {
                cylinder(group, 0.3, 0.36, 1.1, dark, x, 4.2, z)
                modernBox(group, 1.1, 0.22, 0.58, dark, x, 4.8, z)
            }
        }
        for x in [-5.0, -4.45, -3.9] { modernBox(group, 0.18, 0.9, 0.1, dark, x, 7, 3.34) }
        return group
    }

    private static func modernBox(_ group: SCNNode, _ width: Double, _ height: Double, _ depth: Double,
                                  _ material: SCNMaterial, _ x: Double, _ y: Double, _ z: Double = 0,
                                  rx: Double = 0, ry: Double = 0, rz: Double = 0) {
        let geometry = SCNBox(width: width, height: height, length: depth,
                              chamferRadius: min(0.16, min(width, min(height, depth)) * 0.16))
        geometry.chamferSegmentCount = 2
        put(group, geometry, material, x, y, z, rx: rx, ry: ry, rz: rz)
    }

    private static func modernLifeboat(_ group: SCNNode, at position: (Double, Double, Double), material: SCNMaterial) {
        let boat = sphere(group, 1, 18, material, position.0, position.1, position.2)
        boat.scale = vector(1.45, 0.38, 0.48)
        modernBox(group, 2.2, 0.11, 0.75, self.material("#7F6848", roughness: 0.8), position.0, position.1 + 0.32, position.2)
    }

    private static func modernJet(_ group: SCNNode, x: Double, y: Double, z: Double, yaw: Double) {
        let jet = SCNNode()
        jet.position = vector(x, y, z)
        jet.eulerAngles.y = CGFloat(yaw)
        group.addChildNode(jet)
        let body = material("#ADBCC3", roughness: 0.55, metalness: 0.18)
        let canopy = material("#3F667A", roughness: 0.16, metalness: 0.22)
        let fuselage = sphere(jet, 1, 16, body, 0, 0.4, 0)
        fuselage.scale = vector(1.9, 0.3, 0.35)
        sphere(jet, 0.6, 16, canopy, 0.5, 0.64, 0).scale = vector(0.85, 0.36, 0.44)
        modernBox(jet, 1.1, 0.11, 3.45, body, -0.1, 0.4, 0, ry: -0.12)
        modernBox(jet, 0.8, 0.1, 1.45, body, -1.3, 0.45, 0)
        modernBox(jet, 0.85, 0.74, 0.11, body, -1.3, 0.78, 0)
    }

    private static var carrierDeckTexture: NSImage {
        canvas(512, 256) { context, width, height in
            fill(context, "#465461", CGRect(x: 0, y: 0, width: width, height: height))
            context.setStrokeColor(NSColor(calibratedWhite: 0.9, alpha: 0.82).cgColor)
            context.setLineWidth(2)
            for y in [height * 0.25, height * 0.70] {
                context.move(to: CGPoint(x: 12, y: y))
                context.addLine(to: CGPoint(x: width - 12, y: y))
            }
            context.strokePath()
            context.setStrokeColor(NSColor(calibratedRed: 0.9, green: 0.72, blue: 0.3, alpha: 1).cgColor)
            context.move(to: CGPoint(x: 15, y: height * 0.14))
            context.addLine(to: CGPoint(x: width * 0.72, y: height * 0.68))
            context.strokePath()
            for x in stride(from: 20.0, through: 450, by: 35) {
                fill(context, "#E7E9DE", CGRect(x: x, y: height * 0.45, width: 18, height: 3))
            }
            for index in 0..<5 {
                fill(context, "#DADFD9", CGRect(x: width - 74 + Double(index) * 10, y: height * 0.3, width: 4, height: height * 0.3))
            }
        }
    }
}
