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
        // Longitudinal sections give the liner a fine entry, rounded stern,
        // and an actual bilge instead of an extruded side silhouette.
        modernHull(group, sections: [(-17.7, 1.35, 4.6, -1.2), (-16.5, 3.2, 4.4, -2.6),
            (-13.5, 4.6, 4.3, -3.0), (-8, 4.65, 4.3, -3.1), (8, 4.65, 4.3, -3.1),
            (13.5, 3.9, 4.45, -2.6), (16.7, 1.9, 4.8, -1.3), (18, 0.12, 5.1, 0.8)],
            material: hull, antifouling: material("#86392F", roughness: 0.82))
        modernDeck(group, length: 34.8, beam: 9.3, height: 0.32, material: wood, x: 0, y: 4.48)
        modernBox(group, 27.7, 3.05, 8.4, white, -0.5, 6.1)
        modernBox(group, 22.3, 2.15, 7.1, cream, -0.8, 8.55)
        modernDeck(group, length: 28.6, beam: 8.9, height: 0.25, material: wood, x: -0.5, y: 7.72)
        modernDeck(group, length: 22.8, beam: 7.7, height: 0.27, material: white, x: -0.8, y: 9.75)
        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: 8.35, y: 8.62))
        bridge.line(to: NSPoint(x: 13.05, y: 8.62))
        bridge.line(to: NSPoint(x: 12.65, y: 10.08))
        bridge.line(to: NSPoint(x: 8.35, y: 10.08))
        bridge.close()
        extrude(group, bridge, 7.45, white, bevel: 0.12)
        modernBox(group, 4.8, 0.22, 7.8, cream, 10.7, 10.18)
        for side in [-1.0, 1] {
            let z = side * 4.25
            portholes(group, xs: Array(stride(from: -12.5, through: 11.5, by: 1.5)), y: 2.25, z: side * 4.66,
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
            modernBox(group, 0.08, 0.7, 1.0, glass, 12.87, 9.52, z, rz: -0.27)
        }
        let brass = material("#BFAB77", roughness: 0.54, metalness: 0.2)
        for side in [-1.0, 1] {
            rail(group, from: (-13.3, 4.08, side * 4.64), to: (12.2, 4.08, side * 4.38), radius: 0.065, material: brass)
            modernBox(group, 3.3, 0.12, 0.13, black, 11.7, 10.0, side * 3.65)
            for x in [-10.0, -5.4, -0.8, 3.8] {
                cylinder(group, 0.22, 0.29, 1.0, white, x, 10.35, side * 2.2)
                sphere(group, 0.33, 12, white, x + 0.12, 10.85, side * 2.2).scale = vector(1.25, 0.75, 0.8)
            }
            // Fine vertical promenade columns break up the long glazing band.
            for x in stride(from: -12.8, through: 12.8, by: 2.36) {
                modernBox(group, 0.10, 1.05, 0.10, white, x, 6.32, side * 4.32)
            }
            cylinder(group, 0.27, 0.34, 0.7, black, 15.1, 5.0, side * 1.5)
        }
        modernBox(group, 2.0, 0.32, 1.7, black, 14.9, 4.9)
        rail(group, from: (15.7, 4.95, 0), to: (17.1, 5.12, 0), radius: 0.09, material: black)
        rail(group, from: (-14.1, 17.1, 0), to: (14.2, 17.1, 0), radius: 0.035, material: black)
        return group
    }

    static func detailedSubmarine() -> SCNNode {
        let group = SCNNode()
        let hull = metalHullMaterial(hex: "#546B7C")
        let dark = material("#233746", roughness: 0.4, metalness: 0.25)
        let edge = material("#7B919C", roughness: 0.42, metalness: 0.4)
        let brass = material("#C3A256", roughness: 0.35, metalness: 0.5)
        modernSubHull(group, material: hull)
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
        // Swept bridge planes and tapered tail surfaces read as hydroplanes.
        for side in [-1.0, 1] {
            modernFin(group, points: [(0.7, side * 0.9), (3.8, side * 1.1), (3.4, side * 4.1), (1.8, side * 3.8)],
                      y: 5.8, thickness: 0.18, material: dark)
        }
        for x in stride(from: -10.0, through: 8, by: 3.6) {
            torus(group, 3.36, 0.055, rings: 36, sides: 6, edge, x, -0.45, 0, ry: .pi / 2)
        }
        for side in [-1.0, 1] {
            for x in [-7.6, -3.5, 0.6, 4.7, 8.8] {
                disc(group, 0.43, 24, brass, x, 0.65, side * 3.23, ry: side < 0 ? .pi : 0)
                disc(group, 0.29, 24, dark, x, 0.65, side * 3.25, ry: side < 0 ? .pi : 0)
            }
            for x in [-3.4, -2.7, -2.0, -1.3] { modernBox(group, 0.13, 0.95, 0.08, dark, x, 1.8, side * 2.88) }
            modernFin(group, points: [(-12.5, side * 1.8), (-15.8, side * 1.2), (-15.5, side * 4.9), (-13.9, side * 4.5)],
                      y: -0.4, thickness: 0.18, material: hull)
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
        for x in [-7.2, -4.7] {
            cylinder(group, 0.64, 0.64, 0.12, edge, x, 3.08)
            torus(group, 0.40, 0.055, rings: 20, sides: 6, dark, x, 3.17, 0, rx: .pi / 2)
            modernBox(group, 0.75, 0.08, 0.10, dark, x, 3.22)
        }
        // A navigation light and ladder soften the formerly featureless tower.
        for y in stride(from: 3.5, through: 7.7, by: 0.58) {
            rail(group, from: (0.2, y, 1.24), to: (0.8, y, 1.24), radius: 0.045, material: edge)
        }
        modernBox(group, 0.16, 0.45, 2.3, edge, 1.0, 7.9)
        sphere(group, 0.18, 12, material("#CD8069"), 1.0, 8.0, 1.3)
        return group
    }

    static func detailedCarrier() -> SCNNode {
        let group = SCNNode()
        let hull = metalHullMaterial(hex: "#657A89")
        let deck = material("#465461", roughness: 0.9)
        let light = material("#BBC7CD", roughness: 0.6)
        let dark = material("#283D4C", roughness: 0.28)
        modernHull(group, sections: [(-17, 1.5, 3.2, -0.8), (-15.4, 4.8, 3.2, -2.7),
            (-11, 5.1, 3.2, -3.1), (10, 5.1, 3.25, -3.1), (15.4, 2.8, 3.5, -1.8), (18.6, 0.15, 3.9, 0.6)], material: hull)
        let flightDeck = modernDeck(group, length: 37.0, beam: 14.3, height: 0.65,
                                   material: deck, x: 0.4, y: 3.8, bowTaper: 0.74)
        flightDeck.geometry?.materials = [deck, textured(carrierDeckTexture, roughness: 0.95), deck]
        modernDeck(group, length: 36.5, beam: 14.8, height: 0.22, material: light, x: 0.4, y: 3.36, bowTaper: 0.74)
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
        // Open hangar bays, island lattice and angled antennas distinguish the
        // carrier even when its flight deck is almost edge-on.
        for x in [-10.5, -5.8, 8.0] {
            modernBox(group, 2.7, 1.0, 0.15, dark, x, 1.95, 5.18)
            for offset in [-1.45, 1.45] { modernBox(group, 0.15, 1.3, 0.3, light, x + offset, 2.0, 5.25) }
        }
        for x in [3.7, 5.7] {
            rail(group, from: (x, 11, -4.7), to: (4.7, 15.6, -4.7), radius: 0.08, material: light)
        }
        rail(group, from: (3.7, 12.5, -4.7), to: (5.7, 14.1, -4.7), radius: 0.05, material: light)
        rail(group, from: (5.7, 12.5, -4.7), to: (3.7, 14.1, -4.7), radius: 0.05, material: light)
        modernBox(group, 2.3, 0.17, 1.15, light, 7.6, 10.2, -4.7)
        rail(group, from: (6.2, 8.7, -4.7), to: (8.6, 10.15, -4.7), radius: 0.09, material: light)
        for x in [7.7, 8.5] { rail(group, from: (x, 10.2, -4.7), to: (x + 0.5, 13.0, -4.7), radius: 0.055, material: light) }
        cylinder(group, 0.22, 0.22, 0.24, light, 4.7, 15.9, -4.7)
        sphere(group, 0.38, 14, light, 4.7, 16.0, -4.7).scale = vector(1.3, 0.75, 0.65)
        return group
    }

    static func detailedSteamer() -> SCNNode {
        let group = SCNNode()
        let white = material("#F0E8D7", roughness: 0.75)
        let red = material("#A83B34", roughness: 0.65)
        let dark = material("#26313C", roughness: 0.48)
        let glass = material("#365267", roughness: 0.25)
        let wood = woodMaterial(hex: "#AD8959")
        modernHull(group, sections: [(-14.6, 2.8, 3.1, -0.7), (-12, 4.45, 3.1, -2.2),
            (-7, 4.5, 3.15, -2.35), (8, 4.4, 3.15, -2.3), (13, 2.4, 3.55, -1.1), (15.7, 0.15, 4.2, 0.7)], material: white)
        modernDeck(group, length: 29.5, beam: 10.4, height: 0.34, material: wood, x: 0, y: 3.35)
        modernDeck(group, length: 23.7, beam: 9.8, height: 0.24, material: white, x: 0.4, y: 7.05)
        modernBox(group, 19.5, 3.4, 8.2, white, 1.3, 5.15)
        modernBox(group, 16.1, 2.5, 6.7, white, 2.3, 8.45)
        modernDeck(group, length: 17.6, beam: 7.7, height: 0.33, material: wood, x: 2.3, y: 9.88)
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
        for (stackX, z) in [(4.9, -1.8), (7.6, 1.8)] {
            cylinder(group, 0.72, 0.87, 8.7, dark, stackX, 16.45, z)
            cylinder(group, 1.0, 0.94, 0.6, dark, stackX, 20.84, z)
            torus(group, 0.85, 0.15, rings: 20, sides: 6, red, stackX, 20.0, z, rx: .pi / 2)
            rail(group, from: (stackX, 19.5, z), to: (1.5, 10.3, z), radius: 0.045, material: dark)
        }
        for side in [-1.0, 1] {
            // Turned veranda columns, deck fascia and scalloped trim.
            for x in stride(from: -8.5, through: 10.0, by: 2.25) {
                cylinder(group, 0.10, 0.12, 3.2, white, x, 5.35, side * 4.55)
                sphere(group, 0.19, 10, white, x, 6.8, side * 4.55).scale = vector(1, 0.5, 1)
            }
            modernBox(group, 22.9, 0.17, 0.17, red, 0.4, 6.87, side * 4.8)
            modernBox(group, 16.8, 0.15, 0.15, red, 2.3, 9.65, side * 3.7)
            for x in [-2.0, 1.4] { torus(group, 0.52, 0.12, rings: 20, sides: 6, red, x, 8.5, side * 3.51) }
            rail(group, from: (-11.8, 3.8, side * 3.8), to: (-8.0, 7.2, side * 3.8), radius: 0.08, material: white)
            for step in 0..<7 {
                modernBox(group, 0.5, 0.10, 1.2, wood, -11.5 + Double(step) * 0.48, 3.9 + Double(step) * 0.45, side * 3.8)
            }
        }
        rail(group, from: (9.3, 12.55, 0), to: (10.0, 16.5, 0), radius: 0.08, material: white)
        flat(group, [(10.0, 16.45), (12.5, 16.1), (11.6, 15.6), (10.1, 15.8)], red, 0, 0, 0.05)
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
        modernHull(group, sections: [(-13.4, 2.0, 3.6, -0.8), (-11.7, 4.15, 3.55, -2.6),
            (-7.5, 4.6, 3.6, -2.9), (5, 4.6, 3.9, -2.9), (10.4, 3.1, 4.6, -1.8), (13.6, 0.4, 5.1, 0.6)], material: red)
        modernDeck(group, length: 25.7, beam: 10.25, height: 0.58, material: dark, x: -0.2, y: 3.1)
        modernDeck(group, length: 24.1, beam: 9.4, height: 0.27, material: wood, x: -0.3, y: 3.63)
        modernBox(group, 10.4, 4.35, 6.5, cream, -0.5, 6.1)
        modernBox(group, 7.2, 3.2, 6.1, cream, 1.4, 9.85)
        modernDeck(group, length: 8.0, beam: 6.8, height: 0.4, material: dark, x: 1.4, y: 11.72, bowTaper: 0.92)
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
            for x in [-8.8, -5.0, -1.2, 2.6, 6.4] {
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
        let chrome = material("#BFC6C2", roughness: 0.28, metalness: 0.7)
        // A swept bow fender and towing hoop make a convincing working tug.
        for side in [-1.0, 1] {
            rail(group, from: (7.7, 3.55, side * 4.6), to: (11.2, 4.15, side * 2.6), radius: 0.30, material: dark)
            rail(group, from: (11.2, 4.15, side * 2.6), to: (13.2, 4.65, side * 0.45), radius: 0.30, material: dark)
            rail(group, from: (-7.9, 3.9, side * 3.5), to: (-8.2, 6.2, side * 2.0), radius: 0.13, material: cream)
            for y in stride(from: 4.1, through: 8.3, by: 0.65) {
                rail(group, from: (-4.9, y, side * 3.38), to: (-4.2, y, side * 3.38), radius: 0.055, material: chrome)
            }
        }
        rail(group, from: (-8.2, 6.2, -2.0), to: (-8.2, 6.2, 2.0), radius: 0.13, material: cream)
        cylinder(group, 0.3, 0.35, 1.0, chrome, -1.2, 12.4)
        sphere(group, 0.42, 16, cream, -1.2, 12.95).scale = vector(1.4, 0.8, 1)
        cylinder(group, 0.1, 0.1, 1.4, dark, 4.7, 12.6, rz: -0.3)
        modernBox(group, 2.0, 0.1, 0.6, chrome, 1.7, 16.7)
        return group
    }

    /// A lofted hull: each section is (longitudinal x, half beam, sheer, keel).
    /// The curved bilge and narrowing ends catch light naturally at profile yaw.
    private static func modernHull(_ group: SCNNode, sections stations: [(Double, Double, Double, Double)],
                                   material: SCNMaterial, antifouling: SCNMaterial? = nil) {
        let sections = modernSmoothSections(stations)
        let ring = 48
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = [], indices: [Int32] = []
        for (sectionIndex, section) in sections.enumerated() {
            for point in 0...ring {
                let angle = Double(point) / Double(ring) * 2 * .pi
                let c = cos(angle), lateral = sin(angle)
                let shoulder = section.2 - 0.55
                let y = c >= 0 ? shoulder + 0.55 * c : shoulder + (shoulder - section.3) * c
                let z = section.1 * lateral
                vertices.append(vector(section.0, y, z))
                coordinates.append(CGPoint(x: Double(sectionIndex) / Double(sections.count - 1), y: Double(point) / Double(ring)))
                if sectionIndex < sections.count - 1, point < ring {
                    let a = Int32(sectionIndex * (ring + 1) + point), b = a + Int32(ring + 1)
                    indices += [a, b + 1, b, a, a + 1, b + 1]
                }
            }
        }
        for (sectionIndex, reverse) in [(0, false), (sections.count - 1, true)] {
            let section = sections[sectionIndex]
            let center = Int32(vertices.count)
            vertices.append(vector(section.0, (section.2 + section.3) / 2, 0)); coordinates.append(CGPoint(x: 0.5, y: 0.5))
            for point in 0..<ring {
                let a = Int32(sectionIndex * (ring + 1) + point), b = a + 1
                indices += reverse ? [center, a, b] : [center, b, a]
            }
        }
        if let antifouling {
            let geometry = modernPaintSplit(vertices, coordinates, indices, at: -0.3)
            geometry.materials = [material, antifouling]
            group.addChildNode(SCNNode(geometry: geometry))
        } else {
            put(group, modernSmoothMesh(vertices, coordinates, indices), material)
        }
    }

    /// Bounded monotone Hermite interpolation makes the loft fair between
    /// stations while keeping every point within the original design envelope.
    private static func modernSmoothSections(_ stations: [(Double, Double, Double, Double)]) -> [(Double, Double, Double, Double)] {
        let xs = stations.map { $0.0 }
        func interpolate(_ values: [Double], segment: Int, t: Double) -> Double {
            var slopes: [Double] = []
            for index in 0..<(values.count - 1) {
                let rise: Double = values[index + 1] - values[index]
                let run: Double = xs[index + 1] - xs[index]
                slopes.append(rise / run)
            }
            func tangent(_ index: Int) -> Double {
                if index == 0 { return slopes[0] }
                if index == values.count - 1 { return slopes[slopes.count - 1] }
                let a = slopes[index - 1], b = slopes[index]
                guard a * b > 0 else { return 0 }
                let average = (a + b) / 2
                return (average < 0 ? -1 : 1) * min(abs(average), 3 * min(abs(a), abs(b)))
            }
            let d = xs[segment + 1] - xs[segment], t2 = t * t, t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * values[segment]
                + (t3 - 2 * t2 + t) * d * tangent(segment)
                + (-2 * t3 + 3 * t2) * values[segment + 1]
                + (t3 - t2) * d * tangent(segment + 1)
            return min(max(values[segment], values[segment + 1]), max(min(values[segment], values[segment + 1]), value))
        }
        var result: [(Double, Double, Double, Double)] = []
        let beams = stations.map { $0.1 }, sheers = stations.map { $0.2 }, keels = stations.map { $0.3 }
        for segment in 0..<(stations.count - 1) {
            for step in 0..<10 {
                let t = Double(step) / 10
                result.append((xs[segment] + (xs[segment + 1] - xs[segment]) * t,
                    interpolate(beams, segment: segment, t: t), interpolate(sheers, segment: segment, t: t),
                    interpolate(keels, segment: segment, t: t)))
            }
        }
        if let last = stations.last { result.append(last) }
        return result
    }

    /// Clip both paint regions against the exact same horizontal plane. The
    /// new edge vertices inherit interpolated normals and texture coordinates,
    /// so a paint boundary never follows coarse triangles or creates a crease.
    private static func modernPaintSplit(_ vertices: [SCNVector3], _ coordinates: [CGPoint],
                                         _ indices: [Int32], at cut: CGFloat) -> SCNGeometry {
        let normals = modernNormals(vertices, indices)
        typealias Vertex = (position: SCNVector3, normal: SCNVector3, uv: CGPoint)
        var output: [SCNVector3] = [], outputNormals: [SCNVector3] = [], outputUV: [CGPoint] = []
        var regions: [[Int32]] = [[], []]
        func intersection(_ a: Vertex, _ b: Vertex) -> Vertex {
            let t = (cut - a.position.y) / (b.position.y - a.position.y)
            func lerp(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
                SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
            }
            var position = lerp(a.position, b.position); position.y = cut
            let normal = lerp(a.normal, b.normal)
            let length = max(0.000001, sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z))
            return (position, SCNVector3(normal.x / length, normal.y / length, normal.z / length),
                    CGPoint(x: a.uv.x + (b.uv.x - a.uv.x) * t, y: a.uv.y + (b.uv.y - a.uv.y) * t))
        }
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let face: [Vertex] = indices[triangle..<(triangle + 3)].map { (vertices[Int($0)], normals[Int($0)], coordinates[Int($0)]) }
            for region in 0..<2 {
                func inside(_ vertex: Vertex) -> Bool { region == 0 ? vertex.position.y >= cut : vertex.position.y <= cut }
                var polygon: [Vertex] = []
                for index in face.indices {
                    let a = face[index], b = face[(index + 1) % face.count]
                    if inside(a) { polygon.append(a) }
                    if inside(a) != inside(b) { polygon.append(intersection(a, b)) }
                }
                guard polygon.count >= 3 else { continue }
                let base = Int32(output.count)
                for vertex in polygon { output.append(vertex.position); outputNormals.append(vertex.normal); outputUV.append(vertex.uv) }
                for index in 1..<(polygon.count - 1) { regions[region] += [base, base + Int32(index), base + Int32(index + 1)] }
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: output), SCNGeometrySource(normals: outputNormals),
                                     SCNGeometrySource(textureCoordinates: outputUV)], elements: regions.map {
            SCNGeometryElement(indices: $0, primitiveType: .triangles)
        })
    }

    /// A real tapered plan shape keeps deck slabs from projecting past the bow.
    @discardableResult
    private static func modernDeck(_ group: SCNNode, length: Double, beam: Double, height: Double,
                                   material: SCNMaterial, x: Double, y: Double, bowTaper: Double = 0.4) -> SCNNode {
        let h = length / 2, b = beam / 2
        let points = [(-h, -b * 0.50), (-h + length * 0.07, -b), (h - length * 0.16, -b),
                      (h, -b * bowTaper), (h, b * bowTaper), (h - length * 0.16, b),
                      (-h + length * 0.07, b), (-h, b * 0.50)]
        return modernFin(group, points: points, y: y, thickness: height, material: material, x: x)
    }

    @discardableResult
    private static func modernFin(_ group: SCNNode, points: [(Double, Double)], y: Double,
                                  thickness: Double, material: SCNMaterial, x: Double = 0) -> SCNNode {
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = []
        var sideIndices: [Int32] = [], topIndices: [Int32] = [], bottomIndices: [Int32] = []
        let xs = points.map { $0.0 }, zs = points.map { $0.1 }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minZ = zs.min() ?? 0, maxZ = zs.max() ?? 1
        for vertical in [-0.5, 0.5] {
            for point in points {
                vertices.append(vector(point.0, thickness * vertical, point.1))
                coordinates.append(CGPoint(x: (point.0 - minX) / max(0.01, maxX - minX),
                                           y: (point.1 - minZ) / max(0.01, maxZ - minZ)))
            }
        }
        let n = Int32(points.count)
        for index in 0..<n {
            let next = (index + 1) % n
            sideIndices += [index, next + n, next, index, index + n, next + n]
        }
        for index in 1..<(n - 1) {
            // Plan points wind counterclockwise when viewed from below.
            topIndices += [n, n + index + 1, n + index]
            bottomIndices += [0, index, index + 1]
        }
        let indices = sideIndices + topIndices + bottomIndices
        let smooth = modernSmoothMesh(vertices, coordinates, indices)
        let geometry = SCNGeometry(sources: smooth.sources, elements: [
            SCNGeometryElement(indices: sideIndices, primitiveType: .triangles),
            SCNGeometryElement(indices: topIndices, primitiveType: .triangles),
            SCNGeometryElement(indices: bottomIndices, primitiveType: .triangles),
        ])
        geometry.materials = [material, material, material]
        let node = SCNNode(geometry: geometry)
        node.position = vector(x, y, 0)
        group.addChildNode(node)
        return node
    }

    private static func modernSubHull(_ group: SCNNode, material: SCNMaterial) {
        // A single pressure hull avoids the visible intersection rings of the
        // previous cylinder-and-sphere construction.
        let sections: [(Double, Double)] = (0...128).map { step in
            let x = -17.0 + Double(step) / 128 * 33.2
            let offset = x < -10.7 ? (x + 10.7) / 6.3 : (x > 10.7 ? (x - 10.7) / 5.5 : 0)
            return (x, max(0.005, 3.35 * sqrt(max(0, 1 - offset * offset))))
        }
        let ring = 32
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = [], indices: [Int32] = []
        for (sectionIndex, section) in sections.enumerated() {
            for point in 0...ring {
                let angle = Double(point) / Double(ring) * 2 * .pi
                vertices.append(vector(section.0, -0.45 + cos(angle) * section.1, sin(angle) * section.1))
                coordinates.append(CGPoint(x: Double(sectionIndex) / Double(sections.count - 1), y: Double(point) / Double(ring)))
                if sectionIndex < sections.count - 1, point < ring {
                    let a = Int32(sectionIndex * (ring + 1) + point), b = a + Int32(ring + 1)
                    indices += [a, b + 1, b, a, a + 1, b + 1]
                }
            }
        }
        put(group, modernSmoothMesh(vertices, coordinates, indices), material)
    }

    private static func modernSmoothMesh(_ vertices: [SCNVector3], _ coordinates: [CGPoint], _ indices: [Int32]) -> SCNGeometry {
        mesh(vertices, modernNormals(vertices, indices), coordinates, indices)
    }

    private static func modernNormals(_ vertices: [SCNVector3], _ indices: [Int32]) -> [SCNVector3] {
        var normals = [SCNVector3](repeating: SCNVector3Zero, count: vertices.count)
        for index in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[index]), b = Int(indices[index + 1]), c = Int(indices[index + 2])
            let ab = vector(Double(vertices[b].x - vertices[a].x), Double(vertices[b].y - vertices[a].y), Double(vertices[b].z - vertices[a].z))
            let ac = vector(Double(vertices[c].x - vertices[a].x), Double(vertices[c].y - vertices[a].y), Double(vertices[c].z - vertices[a].z))
            let normal = SCNVector3(ab.y * ac.z - ab.z * ac.y, ab.z * ac.x - ab.x * ac.z, ab.x * ac.y - ab.y * ac.x)
            for vertex in [a, b, c] {
                normals[vertex].x += normal.x; normals[vertex].y += normal.y; normals[vertex].z += normal.z
            }
        }
        for index in normals.indices {
            let normal = normals[index], length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            if length > 0.000001 { normals[index] = SCNVector3(normal.x / length, normal.y / length, normal.z / length) }
        }
        return normals
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
        modernFin(jet, points: [(0.7, -0.25), (-0.9, -1.75), (-1.3, -1.75), (-0.65, 0),
                               (-1.3, 1.75), (-0.9, 1.75), (0.7, 0.25)],
                  y: 0.43, thickness: 0.10, material: body)
        modernFin(jet, points: [(-0.9, -0.12), (-1.65, -0.85), (-1.9, -0.85), (-1.65, 0),
                               (-1.9, 0.85), (-1.65, 0.85), (-0.9, 0.12)],
                  y: 0.45, thickness: 0.09, material: body)
        profile(jet, [(-1.65, 0.45), (-1.9, 1.3), (-1.45, 1.25), (-1.0, 0.45)], 0.10, body, bevel: 0.02)
        for z in [-0.35, 0.35] { cylinder(jet, 0.09, 0.09, 0.22, material("#263944"), -0.6, 0.18, z) }
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
