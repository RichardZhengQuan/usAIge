import AppKit
import SceneKit

@available(macOS 14.0, *)
@MainActor
extension PaperweightShipFactory {
    static func detailedGalleon() -> SCNNode { detailedOceanGalleon(ghost: false) }

    static func detailedGhost() -> SCNNode { detailedOceanGalleon(ghost: true) }

    private static func detailedOceanGalleon(ghost: Bool) -> SCNNode {
        let group = SCNNode()
        let timber = woodMaterial(hex: ghost ? "#659F88" : "#513B2B")
        let deck = woodMaterial(hex: ghost ? "#9CCBB2" : "#A47A49")
        let spars = woodMaterial(hex: ghost ? "#83B99D" : "#76563B")
        let trim = material(ghost ? "#A8DFBF" : "#C6A46A", roughness: 0.5, metalness: ghost ? 0 : 0.4)
        let rope = material(ghost ? "#8DBCA0" : "#A18B67", roughness: 1)
        let dark = material(ghost ? "#2D6559" : "#251F1B", roughness: 0.85)
        let cloth = sailCloth(hex: ghost ? "#D7EFE0" : "#767264")
        if ghost {
            cloth.transparent.contents = tornSail
            cloth.transparencyMode = .aOne
            cloth.writesToDepthBuffer = false
            for surface in [timber, deck, spars, trim, cloth] {
                surface.emission.contents = color("#275A43")
                surface.emission.intensity = 0.25
            }
        }

        let hull = historicHull(group, beam: 9.6, material: timber, sternHeight: 8.6)
        hull.name = "carved-timber-hull"
        if ghost { hull.opacity = 0.62 }
        box(group, 25.2, 0.55, 9.2, deck, -0.1, 5.0)
        box(group, 5.8, 0.48, 9.5, deck, -11.2, 8.6)
        box(group, 4.8, 0.45, 8.4, deck, 10.8, 6.4)
        for side in [-1.0, 1] {
            historicStrake(group, y: 1.7, z: side * 4.87, material: trim)
            historicStrake(group, y: 4.6, z: side * 4.88, material: spars)
            for x in [-10.2, -6.5, -2.8, 0.9, 4.6, 8.3] {
                box(group, 1.05, 0.85, 0.15, dark, x, 2.9, side * 4.94)
                cylinder(group, 0.18, 0.23, 0.78, trim, x, 2.84, side * 5.25, rx: .pi / 2)
            }
            gallery(group, x: -11.4, y: 7.05, z: side * 4.94, width: 4.8,
                    glass: ghost ? "#9EE4BC" : "#A1A798", trim: trim)
            railing(group, fromX: -8, toX: 8.6, y: 5.25, z: side * 4.55,
                    spacing: 2.8, material: trim)
            railing(group, fromX: -13.4, toX: -8.6, y: 8.8, z: side * 4.45,
                    spacing: 2.4, material: trim)
        }
        // The raised stern gallery and swept bowsprit give the hull a shaped
        // silhouette before its smaller rigging is visible.
        box(group, 0.45, 2.5, 9.4, spars, -14.2, 7.05)
        rail(group, from: (11.5, 6.0, 0), to: (21.3, 11.1, 0), radius: 0.24, material: spars)
        rail(group, from: (12.4, 3.8, 0), to: (21.2, 10.9, 0), radius: 0.065, material: rope)
        rail(group, from: (15.2, 5.1, 0), to: (19.8, 7.0, 0), radius: 0.11, material: trim)
        sphere(group, 0.62, 12, trim, 15.5, 5.3).scale = vector(1.5, 0.75, 0.65)
        box(group, 2.8, 0.5, 2.8, spars, -5.5, 5.65)
        for x in [-6.1, -5.5, -4.9] {
            rail(group, from: (x, 5.95, -1.2), to: (x, 5.95, 1.2), radius: 0.06, material: dark)
        }

        for (x, top, width) in [(-6.3, 21.1, 7.0), (0.8, 23.0, 7.8), (7.4, 20.6, 6.5)] {
            detailedMast(group, x: x, deck: 5.2, top: top, material: spars, trim: trim)
            squareCourse(group, x: x, y: 11.0, width: width, height: 4.9,
                         cloth: cloth, yard: spars, rope: rope)
            squareCourse(group, x: x, y: 16.9, width: width * 0.72, height: 3.55,
                         cloth: cloth, yard: spars, rope: rope)
            shroud(group, x: x, bottom: 5.4, top: 15.1, width: 3.2, z: 4.6,
                   material: ratlineMaterial(ghost: ghost))
            rail(group, from: (x, top - 0.6, 0), to: (x - 3.3, 5.5, -3.7), radius: 0.055, material: rope)
            rail(group, from: (x, top - 0.6, 0), to: (x + 3.3, 5.5, 3.7), radius: 0.055, material: rope)
        }
        rail(group, from: (-6.3, 20.5, 0), to: (0.8, 22.6, 0), radius: 0.06, material: rope)
        rail(group, from: (0.8, 22.6, 0), to: (7.4, 20.1, 0), radius: 0.06, material: rope)
        rail(group, from: (7.4, 20.1, 0), to: (21.1, 10.9, 0), radius: 0.065, material: rope)
        triangularCloth(group, points: [(8.0, 18.7), (18.7, 10.6), (10.2, 10.6)], material: cloth, z: 0.2)
        let flag = textured(pirateFlag, roughness: 0.95)
        if ghost { flag.emission.contents = color("#326E4C") }
        plane(group, 2.1, 1.35, flag, 1.95, 22.45, 0.12)
        if ghost { group.opacity = 0.82 }
        return group
    }

    static func detailedVictory() -> SCNNode {
        let group = SCNNode()
        let hull = woodMaterial(hex: "#3B332B"), deck = woodMaterial(hex: "#B08A52")
        let ochre = material("#C89A4A", roughness: 0.72)
        let brass = material("#BC9B56", roughness: 0.42, metalness: 0.4)
        let wood = woodMaterial(hex: "#765538"), dark = material("#242426", roughness: 0.8)
        let rope = material("#9B8F74", roughness: 1), cloth = sailCloth(hex: "#E8DDC4")
        historicHull(group, beam: 10.2, material: hull, sternHeight: 9.0)
        box(group, 25.5, 0.55, 9.8, deck, -0.5, 6.0)
        box(group, 5.8, 0.45, 10.0, deck, -11.5, 9.0)
        box(group, 5.3, 0.42, 8.6, deck, 10.8, 7.0)
        for side in [-1.0, 1] {
            for y in [1.35, 3.75] {
                historicStrake(group, y: y, z: side * 5.17, material: ochre, thickness: 1.05)
                for x in stride(from: -10.0, through: 10, by: 2.8) {
                    box(group, 1.12, 0.82, 0.16, dark, x, y, side * 5.22)
                }
            }
            for x in [-7.2, -1.6, 4.0, 9.6] {
                cylinder(group, 0.16, 0.22, 0.83, dark, x, 3.73, side * 5.55, rx: .pi / 2)
            }
            historicStrake(group, y: 5.6, z: side * 5.18, material: brass, thickness: 0.3)
            gallery(group, x: -11.2, y: 7.6, z: side * 5.23, width: 5.1, glass: "#748C92", trim: brass)
            railing(group, fromX: -8.7, toX: 8.8, y: 6.22, z: side * 4.8,
                    spacing: 2.9, material: wood)
            railing(group, fromX: -13.6, toX: -8.6, y: 9.23, z: side * 4.8,
                    spacing: 2.5, material: brass)
        }
        box(group, 0.42, 3.0, 9.6, wood, -14.2, 7.5)
        rail(group, from: (11.5, 6.5, 0), to: (21.0, 11.6, 0), radius: 0.23, material: wood)
        rail(group, from: (13.0, 3.5, 0), to: (20.9, 11.3, 0), radius: 0.06, material: rope)
        for (x, top, width) in [(-6.7, 21.5, 7.0), (0.2, 23.45, 7.6), (7.0, 20.4, 6.5)] {
            detailedMast(group, x: x, deck: 6.1, top: top, material: wood, trim: brass)
            for (y, factor, height) in [(10.15, 1.0, 3.4), (14.4, 0.81, 3.05), (18.0, 0.59, 2.45)] {
                squareCourse(group, x: x, y: y, width: width * factor, height: height,
                             cloth: cloth, yard: wood, rope: rope, brace: 0.13)
            }
            shroud(group, x: x, bottom: 6.35, top: 14.7, width: 3.15, z: 4.9,
                   material: ratlineMaterial(ghost: false))
            rail(group, from: (x, top - 0.5, 0), to: (x - 3.4, 6.4, -4.1), radius: 0.055, material: rope)
            rail(group, from: (x, top - 0.5, 0), to: (x + 3.4, 6.4, 4.1), radius: 0.055, material: rope)
        }
        rail(group, from: (-6.7, 21.0, 0), to: (0.2, 22.9, 0), radius: 0.06, material: rope)
        rail(group, from: (0.2, 22.9, 0), to: (7.0, 19.9, 0), radius: 0.06, material: rope)
        rail(group, from: (7.0, 19.9, 0), to: (20.8, 11.3, 0), radius: 0.06, material: rope)
        triangularCloth(group, points: [(7.6, 18.5), (19.2, 11.1), (8.7, 10.5)], material: cloth, z: 0.2)
        rail(group, from: (-13.9, 9.1, 0), to: (-16.2, 14.4, 0), radius: 0.12, material: wood)
        flat(group, [(-16.1, 14.3), (-12.8, 14.0), (-13.4, 12.75), (-15.5, 13.0)], material("#AB3031", doubleSided: true), 0, 0, 0.15)
        // Carved stern ornaments remain a few warm highlights at miniature size.
        for z in [-3.2, 0.0, 3.2] {
            sphere(group, 0.34, 10, brass, -14.4, 8.8, z).scale = vector(0.7, 1.5, 1)
        }
        return group
    }

    static func detailedTreasure() -> SCNNode {
        let group = SCNNode()
        let hull = woodMaterial(hex: "#8E4932"), deck = woodMaterial(hex: "#B68D57")
        let wood = woodMaterial(hex: "#65432C"), green = material("#39716A", roughness: 0.74)
        let gold = material("#D0AC63", roughness: 0.47, metalness: 0.35)
        let rope = material("#A38D64", roughness: 0.95)
        let cloth = sailCloth(hex: "#B96945")
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -16.0, y: 9.5))
        outline.curve(to: NSPoint(x: -10.8, y: 5.9), controlPoint1: NSPoint(x: -13.8, y: 10.4), controlPoint2: NSPoint(x: -10.8, y: 8.3))
        outline.line(to: NSPoint(x: 10.8, y: 5.9))
        outline.curve(to: NSPoint(x: 17.0, y: 8.1), controlPoint1: NSPoint(x: 13.1, y: 6.0), controlPoint2: NSPoint(x: 16.2, y: 7.5))
        outline.curve(to: NSPoint(x: 9.0, y: -3.5), controlPoint1: NSPoint(x: 16.0, y: 1.3), controlPoint2: NSPoint(x: 12.9, y: -3.2))
        outline.curve(to: NSPoint(x: -11.7, y: -3.8), controlPoint1: NSPoint(x: 0.2, y: -4.2), controlPoint2: NSPoint(x: -8.8, y: -4.3))
        outline.curve(to: NSPoint(x: -16.0, y: 9.5), controlPoint1: NSPoint(x: -15.0, y: -1.9), controlPoint2: NSPoint(x: -15.9, y: 4.7))
        outline.close()
        extrude(group, outline, 10.6, hull, bevel: 0.6)
        box(group, 25.0, 0.55, 10.2, deck, -0.1, 6.2)
        for side in [-1.0, 1] {
            historicStrake(group, y: 2.0, z: side * 5.37, material: gold, thickness: 0.45)
            historicStrake(group, y: 4.8, z: side * 5.38, material: wood, thickness: 0.42)
            railing(group, fromX: -10.2, toX: 10.6, y: 6.5, z: side * 5.0,
                    spacing: 3.4, material: gold)
            disc(group, 1.05, 24, material("#E7DDBF"), 13.8, 4.6, side * 5.40,
                 ry: side > 0 ? 0 : .pi)
            disc(group, 0.44, 18, material("#282B2B"), 14.1, 4.6, side * 5.43,
                 ry: side > 0 ? 0 : .pi)
        }
        // Layered pavilion eaves distinguish the raised stern from the
        // European galleries, and their curved corners stay within the hull.
        box(group, 4.7, 2.25, 7.0, wood, -11.6, 8.0)
        junkRoof(group, x: -11.6, y: 9.2, width: 6.3, depth: 8.0, material: green, trim: gold)
        box(group, 3.0, 1.15, 5.0, wood, -11.6, 10.2)
        junkRoof(group, x: -11.6, y: 10.85, width: 4.6, depth: 6.0, material: green, trim: gold)
        for x in [-13.0, -11.6, -10.2] {
            box(group, 0.42, 1.05, 7.1, gold, x, 8.0)
        }
        for (x, top, width) in [(-8.8, 18.8, 5.2), (-4.1, 21.0, 6.2), (1.0, 23.1, 6.9), (6.3, 20.5, 6.0), (11.0, 17.6, 4.8)] {
            cylinder(group, 0.16, 0.29, top - 6.3, wood, x, (top + 6.3) / 2)
            fanCourse(group, x: x, bottom: 8.0, top: top - 0.8, width: width,
                      cloth: cloth, batten: wood, rope: rope)
            rail(group, from: (x, top - 0.2, 0), to: (x - 2.5, 6.6, -4.6), radius: 0.05, material: rope)
            if x < 8 {
                flat(group, [(x, top), (x + 1.8, top - 0.35), (x, top - 0.7)],
                     material("#9A3031", doubleSided: true), 0, 0, 0.12)
            }
        }
        // A small carved prow and whisker curves complete the distinctive bow.
        sphere(group, 0.60, 14, gold, 17.3, 7.3).scale = vector(1.7, 0.8, 0.65)
        for side in [-1.0, 1] {
            rail(group, from: (17.6, 7.2, side * 0.3), to: (19.4, 7.5, side * 0.7), radius: 0.07, material: gold)
            rail(group, from: (19.4, 7.5, side * 0.7), to: (20.1, 8.4, side * 0.9), radius: 0.07, material: gold)
        }
        return group
    }

    static func detailedViking() -> SCNNode {
        let group = SCNNode()
        let timber = woodMaterial(hex: "#8B5938"), darkWood = woodMaterial(hex: "#533A29")
        let paleWood = woodMaterial(hex: "#B58B57")
        let bronze = material("#B4965B", roughness: 0.55, metalness: 0.35)
        let rope = material("#A08D6A", roughness: 1)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: -14.1, y: 4.0))
        body.curve(to: NSPoint(x: 14.1, y: 4.0), controlPoint1: NSPoint(x: -7.0, y: 2.8), controlPoint2: NSPoint(x: 7.0, y: 2.8))
        body.curve(to: NSPoint(x: 8.8, y: -2.9), controlPoint1: NSPoint(x: 13.2, y: -0.5), controlPoint2: NSPoint(x: 11.6, y: -2.9))
        body.curve(to: NSPoint(x: -8.8, y: -2.9), controlPoint1: NSPoint(x: 3.0, y: -3.6), controlPoint2: NSPoint(x: -3.0, y: -3.6))
        body.curve(to: NSPoint(x: -14.1, y: 4.0), controlPoint1: NSPoint(x: -11.6, y: -2.9), controlPoint2: NSPoint(x: -13.2, y: -0.5))
        body.close()
        extrude(group, body, 7.3, timber, bevel: 0.45)
        box(group, 23.8, 0.35, 6.9, paleWood, 0, 3.45)
        for side in [-1.0, 1] {
            for (y, thickness) in [(0.4, 0.15), (1.8, 0.15), (3.35, 0.3)] {
                flat(group, [(-13.1, y + 1.0), (-10.1, y + 0.1), (0, y - 0.15), (10.1, y + 0.1), (13.1, y + 1.0),
                             (12.9, y + 1.0 - thickness), (10.1, y + 0.1 - thickness), (0, y - 0.15 - thickness), (-10.1, y + 0.1 - thickness), (-12.9, y + 1.0 - thickness)],
                     darkWood, 0, 0, side * 3.72)
            }
            for (index, x) in [-9.4, -6.7, -4.0, -1.3, 1.4, 4.1, 6.8, 9.5].enumerated() {
                let shield = textured(vikingShield(index: index), roughness: 0.78)
                disc(group, 1.0, 24, shield, x, 3.2, side * 3.85, ry: side > 0 ? 0 : .pi)
                sphere(group, 0.26, 12, bronze, x, 3.2, side * 3.99).scale = vector(1, 1, 0.55)
            }
            for x in [-9.0, -5.3, -1.6, 2.1, 5.8, 9.5] {
                rail(group, from: (x, 2.6, side * 2.8), to: (x - 1.3, 0.1, side * 6.2),
                     radius: 0.10, material: paleWood)
                box(group, 0.52, 1.25, 0.18, paleWood, x - 1.5, -0.25, side * 6.55, rz: -0.32)
            }
        }
        for x in [-8.1, -4.8, -1.5, 1.8, 5.1, 8.4] {
            box(group, 0.65, 0.4, 6.6, darkWood, x, 3.8)
        }
        dragonStem(group, bow: true, material: darkWood, trim: bronze)
        dragonStem(group, bow: false, material: darkWood, trim: bronze)
        cylinder(group, 0.20, 0.37, 17.0, darkWood, 0, 11.9)
        squareCourse(group, x: 0.1, y: 12.0, width: 13.1, height: 8.4,
                     cloth: textured(vikingCanvas, roughness: 0.9), yard: darkWood, rope: rope, brace: 0)
        rail(group, from: (0, 20.0, 0), to: (-12.5, 3.7, 0), radius: 0.06, material: rope)
        rail(group, from: (0, 20.0, 0), to: (13.1, 4.3, 0), radius: 0.06, material: rope)
        rail(group, from: (0, 18.6, 0), to: (-2.0, 3.8, 3.0), radius: 0.055, material: rope)
        rail(group, from: (0, 18.6, 0), to: (2.0, 3.8, -3.0), radius: 0.055, material: rope)
        flat(group, [(0.1, 20.5), (3.5, 20.1), (2.1, 19.5), (0.1, 19.7)],
             material("#B13F35", doubleSided: true), 0, 0, 0.1)
        return group
    }

    // These hulls use continuous curves, while deck and gun fittings remain
    // separate geometry so lighting shows their edges in the larger scene.
    @discardableResult
    private static func historicHull(_ group: SCNNode, beam: Double, material: SCNMaterial,
                                     sternHeight: Double) -> SCNNode {
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: -14.8, y: sternHeight))
        outline.line(to: NSPoint(x: -10.3, y: sternHeight))
        outline.line(to: NSPoint(x: -9.6, y: 5.3))
        outline.line(to: NSPoint(x: 9.7, y: 5.3))
        outline.curve(to: NSPoint(x: 16.8, y: 7.0), controlPoint1: NSPoint(x: 12.6, y: 5.4), controlPoint2: NSPoint(x: 15.4, y: 6.6))
        outline.curve(to: NSPoint(x: 9.2, y: -3.4), controlPoint1: NSPoint(x: 15.0, y: 1.1), controlPoint2: NSPoint(x: 12.9, y: -3.2))
        outline.curve(to: NSPoint(x: -10.7, y: -3.7), controlPoint1: NSPoint(x: 2.8, y: -4.1), controlPoint2: NSPoint(x: -7.3, y: -4.2))
        outline.curve(to: NSPoint(x: -14.8, y: sternHeight), controlPoint1: NSPoint(x: -14.6, y: -2.4), controlPoint2: NSPoint(x: -15.1, y: 3.3))
        outline.close()
        return extrude(group, outline, beam, material, bevel: 0.55)
    }

    private static func historicStrake(_ group: SCNNode, y: Double, z: Double,
                                       material: SCNMaterial, thickness: Double = 0.32) {
        flat(group, [(-13.9, y + 0.45), (-10.5, y), (8.7, y), (14.5, y + 0.9),
                     (14.35, y + 0.9 - thickness), (8.7, y - thickness), (-10.5, y - thickness), (-13.9, y + 0.45 - thickness)],
             material, 0, 0, z)
    }

    private static func detailedMast(_ group: SCNNode, x: Double, deck: Double, top: Double,
                                     material: SCNMaterial, trim: SCNMaterial) {
        cylinder(group, 0.16, 0.32, top - deck, material, x, (deck + top) / 2)
        let nestY = deck + (top - deck) * 0.58
        cylinder(group, 0.85, 0.48, 0.55, material, x, nestY)
        torus(group, 0.77, 0.07, rings: 18, sides: 5, trim, x, nestY + 0.33, rx: .pi / 2)
        cylinder(group, 0.23, 0.23, 0.35, trim, x, deck + 0.25)
    }

    private static func squareCourse(_ group: SCNNode, x: Double, y: Double, width: Double, height: Double,
                                     cloth: SCNMaterial, yard: SCNMaterial, rope: SCNMaterial, brace: Double = 0.18) {
        let course = SCNNode()
        course.eulerAngles.y = CGFloat(brace)
        course.position = vector(x, y, 0.4)
        group.addChildNode(course)
        sail(course, 0, 0, width, height, cloth, brace: 0, bulge: width * 0.12, columns: 12)
        rail(course, from: (-width * 0.54, height * 0.5 + 0.12, 0),
             to: (width * 0.54, height * 0.5 + 0.12, 0), radius: 0.105, material: yard)
        for side in [-1.0, 1] {
            rail(course, from: (side * width * 0.51, height * 0.5 + 0.1, 0),
                 to: (side * width * 0.47, -height * 0.52, 0.2), radius: 0.035, material: rope)
        }
    }

    private static func triangularCloth(_ group: SCNNode, points: [(Double, Double)], material: SCNMaterial, z: Double) {
        flat(group, points, material, 0, 0, z)
    }

    private static func gallery(_ group: SCNNode, x: Double, y: Double, z: Double,
                                width: Double, glass: String, trim: SCNMaterial) {
        let image = canvas(192, 72) { context, w, h in
            fill(context, "#453B30", CGRect(x: 0, y: 0, width: w, height: h))
            for index in 0..<5 {
                let left = 6 + CGFloat(index) * 37
                fill(context, "#BBA477", CGRect(x: left, y: 6, width: 31, height: 60))
                fill(context, glass, CGRect(x: left + 3, y: 10, width: 25, height: 52))
                fill(context, "#C9B58B", CGRect(x: left + 14, y: 10, width: 2, height: 52))
                fill(context, "#C9B58B", CGRect(x: left + 3, y: 34, width: 25, height: 2))
            }
        }
        plane(group, width, 1.9, textured(image, roughness: 0.65), x, y, z)
        box(group, width + 0.3, 0.18, 0.25, trim, x, y + 1.02, z)
        box(group, width + 0.4, 0.22, 0.4, trim, x, y - 1.05, z)
    }

    private static func shroud(_ group: SCNNode, x: Double, bottom: Double, top: Double,
                               width: Double, z: Double, material: SCNMaterial) {
        plane(group, width, top - bottom, material, x, (bottom + top) / 2, z)
    }

    private static func ratlineMaterial(ghost: Bool) -> SCNMaterial {
        let image = ghost ? ghostRatlines : timberRatlines
        let result = textured(image, roughness: 1)
        result.lightingModel = .constant
        result.writesToDepthBuffer = false
        result.transparent.contents = image
        result.transparencyMode = .aOne
        return result
    }

    private static let timberRatlines = ratlineTexture(hex: "#9F9277")
    private static let ghostRatlines = ratlineTexture(hex: "#96C7AD")

    private static func ratlineTexture(hex: String) -> NSImage {
        canvas(128, 256) { context, w, h in
            context.setStrokeColor(color(hex).cgColor)
            context.setLineWidth(2.1)
            context.setLineCap(.round)
            for base in [8.0, 35, 64, 93, 120] {
                context.move(to: CGPoint(x: 64, y: 0))
                context.addLine(to: CGPoint(x: base, y: Double(h)))
            }
            for index in 1...11 {
                let amount = Double(index) / 11
                let spread = 56 * amount
                context.move(to: CGPoint(x: 64 - spread, y: amount * Double(h)))
                context.addLine(to: CGPoint(x: 64 + spread, y: amount * Double(h)))
            }
            context.strokePath()
        }
    }

    private static func junkRoof(_ group: SCNNode, x: Double, y: Double, width: Double, depth: Double,
                                 material: SCNMaterial, trim: SCNMaterial) {
        let roof = NSBezierPath()
        roof.move(to: NSPoint(x: x - width / 2, y: y + 0.45))
        roof.curve(to: NSPoint(x: x, y: y + 0.65), controlPoint1: NSPoint(x: x - width * 0.30, y: y - 0.15), controlPoint2: NSPoint(x: x - width * 0.14, y: y + 0.60))
        roof.curve(to: NSPoint(x: x + width / 2, y: y + 0.45), controlPoint1: NSPoint(x: x + width * 0.14, y: y + 0.60), controlPoint2: NSPoint(x: x + width * 0.30, y: y - 0.15))
        roof.line(to: NSPoint(x: x + width / 2, y: y + 0.18))
        roof.line(to: NSPoint(x: x - width / 2, y: y + 0.18))
        roof.close()
        extrude(group, roof, depth, material, bevel: 0.1)
        for side in [-1.0, 1] {
            rail(group, from: (x - width * 0.46, y + 0.28, side * depth * 0.51),
                 to: (x + width * 0.46, y + 0.28, side * depth * 0.51), radius: 0.07, material: trim)
        }
    }

    private static func fanCourse(_ group: SCNNode, x: Double, bottom: Double, top: Double, width: Double,
                                  cloth: SCNMaterial, batten: SCNMaterial, rope: SCNMaterial) {
        let height = top - bottom
        let rows = 6, columns = 8
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var uv: [CGPoint] = [], indices: [Int32] = []
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            let span = width * (1.0 - 0.42 * v)
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let z = 0.7 + sin(u * .pi) * sin(v * .pi) * width * 0.12
                vertices.append(vector(x + span * u - width * 0.18, bottom + height * v + u * 0.35, z))
                normals.append(vector(0, 0, 1))
                uv.append(CGPoint(x: u, y: v))
                if row < rows, column < columns {
                    let a = Int32(row * (columns + 1) + column)
                    let b = a + 1, c = a + Int32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        put(group, mesh(vertices, normals, uv, indices), cloth)
        for row in 0...rows {
            let v = Double(row) / Double(rows), span = width * (1.0 - 0.42 * v)
            rail(group, from: (x - width * 0.18, bottom + height * v, 0.73),
                 to: (x + span - width * 0.18, bottom + height * v + 0.35, 0.73),
                 radius: 0.075, material: batten)
        }
        rail(group, from: (x - width * 0.18, bottom, 0.75), to: (x - width * 0.18, top, 0.75), radius: 0.045, material: rope)
        rail(group, from: (x + width * 0.82, bottom + 0.35, 0.75),
             to: (x + width * 0.40, top + 0.35, 0.75), radius: 0.045, material: rope)
    }

    private static func dragonStem(_ group: SCNNode, bow: Bool, material: SCNMaterial, trim: SCNMaterial) {
        let sign = bow ? 1.0 : -1
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: sign * 12.2, y: 2.5))
        neck.curve(to: NSPoint(x: sign * 16.2, y: 10.2), controlPoint1: NSPoint(x: sign * 14.8, y: 3.4), controlPoint2: NSPoint(x: sign * 13.6, y: 9.0))
        neck.curve(to: NSPoint(x: sign * 15.0, y: 7.2), controlPoint1: NSPoint(x: sign * 17.2, y: 10.2), controlPoint2: NSPoint(x: sign * 16.0, y: 9.1))
        neck.curve(to: NSPoint(x: sign * 13.0, y: 2.1), controlPoint1: NSPoint(x: sign * 14.6, y: 5.2), controlPoint2: NSPoint(x: sign * 14.2, y: 2.7))
        neck.close()
        extrude(group, neck, 1.3, material, bevel: 0.16)
        if bow {
            sphere(group, 0.68, 14, material, 16.25, 10.1).scale = vector(1.65, 0.65, 0.7)
            for side in [-1.0, 1] {
                sphere(group, 0.14, 10, trim, 16.5, 10.2, side * 0.46)
            }
            rail(group, from: (16.65, 9.9, 0), to: (17.5, 9.7, 0), radius: 0.11, material: trim)
        } else {
            torus(group, 0.68, 0.18, rings: 20, sides: 6, material, -16.1, 10.0)
        }
    }

    private static let vikingCanvas = canvas(256, 192) { context, w, h in
        for stripe in 0..<8 {
            fill(context, stripe.isMultiple(of: 2) ? "#AC4439" : "#E9DDBF",
                 CGRect(x: CGFloat(stripe) * w / 8, y: 0, width: w / 8 + 1, height: h))
        }
        context.setStrokeColor(color("#8A6B4D").withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1.2)
        for x in stride(from: 8.0, through: 256, by: 16) {
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: Double(h)))
        }
        context.strokePath()
        context.setLineWidth(3)
        context.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
    }

    private static func vikingShield(index: Int) -> NSImage {
        let colors = ["#AD4438", "#D4B260", "#4E7B8D", "#637F57"]
        return canvas(64, 64) { context, w, h in
            context.setFillColor(color(colors[index % colors.count]).cgColor)
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
            context.saveGState()
            context.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
            context.clip()
            context.setFillColor(color("#E6D8AF").cgColor)
            context.fill(CGRect(x: 31, y: 0, width: 2.5, height: h))
            context.fill(CGRect(x: 0, y: 31, width: w, height: 2.5))
            context.restoreGState()
            context.setStrokeColor(color("#514333").cgColor)
            context.setLineWidth(4)
            context.strokeEllipse(in: CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        }
    }
}
