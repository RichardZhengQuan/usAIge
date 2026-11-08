import AppKit
import SceneKit

@available(macOS 14.0, *)
@MainActor
extension PaperweightShipFactory {
    static func detailedGalleon() -> SCNNode { detailedOceanGalleon(ghost: false) }

    static func detailedGhost() -> SCNNode { detailedOceanGalleon(ghost: true) }

    private static func detailedOceanGalleon(ghost: Bool) -> SCNNode {
        let group = SCNNode()
        let timber = woodMaterial(hex: ghost ? "#4F917B" : "#513B2B")
        let deck = woodMaterial(hex: ghost ? "#9CCBB2" : "#A47A49")
        let spars = woodMaterial(hex: ghost ? "#83B99D" : "#76563B")
        let trim = material(ghost ? "#A8DFBF" : "#C6A46A", roughness: 0.5, metalness: ghost ? 0 : 0.4)
        let rope = material(ghost ? "#8DBCA0" : "#A18B67", roughness: 1)
        let dark = material(ghost ? "#2D6559" : "#251F1B", roughness: 0.85)
        let cloth = sailCloth(hex: ghost ? "#D7EFE0" : "#C4B697")
        if ghost {
            cloth.transparent.contents = tornSail
            cloth.transparencyMode = .aOne
            cloth.transparency = 0.84
            cloth.writesToDepthBuffer = false
            for surface in [timber, deck, spars, trim, cloth] {
                surface.emission.contents = color("#275A43")
                surface.emission.intensity = 0.25
            }
        }

        let hull = historicHull(group, beam: 9.6, material: timber, sternHeight: 8.6)
        hull.name = "carved-timber-hull"
        // Keep timber depth-writing and opaque: overlapping translucent hull
        // triangles otherwise expose station seams as dark vertical bands.
        historicDeck(group, from: -13.5, to: 14.3, y: 5.0, beam: 9.3, material: deck)
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
        let transom = SCNNode()
        transom.position = vector(-14.92, 0, 0)
        transom.eulerAngles.y = -.pi / 2
        group.addChildNode(transom)
        gallery(transom, x: 0, y: 7.1, z: 0, width: 5.9,
                glass: ghost ? "#9EE4BC" : "#899998", trim: trim)
        carvedStern(group, x: -14.9, y: 8.7, width: 6.4, material: trim)
        anchors(group, x: 11.1, y: 3.6, beam: 8.8, material: dark)
        capstan(group, x: 8.3, y: 6.7, material: spars, rim: trim)
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
            squareCourse(group, x: x, y: top - 10.6, width: width, height: 4.9,
                         cloth: cloth, yard: spars, rope: rope, tattered: ghost)
            squareCourse(group, x: x, y: top - 4.75, width: width * 0.72, height: 3.55,
                         cloth: cloth, yard: spars, rope: rope, tattered: ghost)
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
        historicDeck(group, from: -13.7, to: 14.3, y: 6.0, beam: 9.9, material: deck)
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
        let transom = SCNNode()
        transom.position = vector(-14.92, 0, 0)
        transom.eulerAngles.y = -.pi / 2
        group.addChildNode(transom)
        gallery(transom, x: 0, y: 7.8, z: 0, width: 6.4, glass: "#748C92", trim: brass)
        carvedStern(group, x: -14.9, y: 9.25, width: 6.7, material: brass)
        anchors(group, x: 11.2, y: 3.9, beam: 9.3, material: dark)
        capstan(group, x: 8.2, y: 7.2, material: wood, rim: brass)
        rail(group, from: (11.5, 6.5, 0), to: (21.0, 11.6, 0), radius: 0.23, material: wood)
        rail(group, from: (13.0, 3.5, 0), to: (20.9, 11.3, 0), radius: 0.06, material: rope)
        for (x, top, width) in [(-6.7, 21.5, 7.0), (0.2, 23.45, 7.6), (7.0, 20.4, 6.5)] {
            detailedMast(group, x: x, deck: 6.1, top: top, material: wood, trim: brass)
            for (y, factor, height) in [(10.15, 1.0, 3.4), (14.4, 0.81, 3.05), (18.0, 0.59, 2.45)] {
                squareCourse(group, x: x, y: y + (top - 23.45) * 0.7, width: width * factor, height: height,
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
        shapedTimberHull(group, stations: [
            (-16.0, 9.5, 0.8, 2.1), (-14.3, 8.4, -2.2, 4.0),
            (-10.5, 6.0, -3.7, 5.0), (-5.5, 5.9, -3.8, 5.3),
            (2.0, 5.9, -3.8, 5.3), (9.0, 6.0, -3.5, 4.9),
            (13.8, 6.7, -0.5, 3.3), (17.0, 8.1, 4.5, 0.28),
        ], material: hull)
        historicDeck(group, from: -14.1, to: 15.6, y: 6.2, beam: 10.25, material: deck)
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
        // A perforated stern rudder and ventilated hatch sit below the pavilion.
        profile(group, [(-15.2, 1.5), (-16.3, 0.5), (-16.3, -2.1), (-14.9, -1.4)], 0.30, wood, bevel: 0.08)
        box(group, 2.8, 0.5, 2.6, wood, 5.1, 6.7)
        for x in [4.3, 4.8, 5.3, 5.8] {
            rail(group, from: (x, 7.0, -1.1), to: (x, 7.0, 1.1), radius: 0.055, material: gold)
        }
        capstan(group, x: 11.5, y: 6.7, material: wood, rim: gold)
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
        shapedTimberHull(group, stations: [
            (-14.1, 4.0, 2.3, 0.18), (-11.5, 3.65, -0.5, 2.1),
            (-7.0, 3.30, -2.6, 3.4), (0.0, 3.1, -3.0, 3.65),
            (7.0, 3.30, -2.6, 3.4), (11.5, 3.65, -0.5, 2.1),
            (14.1, 4.0, 2.3, 0.18),
        ], material: timber)
        historicDeck(group, from: -13.5, to: 13.5, y: 3.45, beam: 6.9, material: paleWood)
        for side in [-1.0, 1] {
            for y in [0.4, 1.8, 3.35] {
                let points: [(Double, Double, Double)] = [(-13.1, y + 1.0, side * 1.05),
                    (-10.1, y + 0.1, side * 2.77), (-5.0, y - 0.10, side * 3.55),
                    (0, y - 0.15, side * 3.72), (5.0, y - 0.10, side * 3.55),
                    (10.1, y + 0.1, side * 2.77), (13.1, y + 1.0, side * 1.05)]
                for index in 0..<(points.count - 1) {
                    rail(group, from: points[index], to: points[index + 1], radius: y > 3 ? 0.13 : 0.065, material: darkWood)
                }
            }
            for (index, x) in [-9.4, -6.7, -4.0, -1.3, 1.4, 4.1, 6.8, 9.5].enumerated() {
                let shield = textured(vikingShield(index: index), roughness: 0.78)
                let shieldZ = side * (3.85 - abs(x) * 0.065)
                cylinder(group, 1.0, 1.0, 0.16, darkWood, x, 3.2, shieldZ, rx: .pi / 2)
                disc(group, 1.0, 24, shield, x, 3.2, shieldZ + side * 0.10, ry: side > 0 ? 0 : .pi)
                sphere(group, 0.26, 12, bronze, x, 3.2, shieldZ + side * 0.21).scale = vector(1, 1, 0.55)
            }
            for x in [-9.0, -5.3, -1.6, 2.1, 5.8, 9.5] {
                let oar = SCNNode()
                oar.position = vector(x, 2.6, side * 2.8)
                group.addChildNode(oar)
                rail(oar, from: (0, 0, 0), to: (-1.3, -2.5, side * 3.4),
                     radius: 0.10, material: paleWood)
                box(oar, 0.52, 1.25, 0.18, paleWood, -1.5, -2.85, side * 3.75, rz: -0.32)
                PaperweightShipAnimation.tag(oar, as: .oar)
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
        let deckY = sternHeight > 8.8 ? 6.0 : 5.3
        return shapedTimberHull(group, stations: [
            (-14.8, sternHeight, -0.8, beam * 0.31),
            (-13.8, sternHeight - 0.25, -2.5, beam * 0.43),
            (-10.0, deckY + 0.15, -3.65, beam * 0.49),
            (-5.5, deckY, -3.8, beam * 0.50),
            (1.0, deckY, -3.8, beam * 0.50),
            (7.6, deckY + 0.1, -3.5, beam * 0.47),
            (12.7, deckY + 0.65, -1.9, beam * 0.34),
            (15.7, 6.7, 1.3, beam * 0.15),
            (16.8, 7.0, 4.4, 0.14),
        ], material: material)
    }

    /// Rounded cross sections narrow into a real stem and transom rather than
    /// carrying the same rectangular beam all the way to each end.
    @discardableResult
    private static func shapedTimberHull(_ group: SCNNode,
                                         stations: [(Double, Double, Double, Double)],
                                         material: SCNMaterial) -> SCNNode {
        let segments = 16
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = [], indices: [Int32] = []
        for (index, station) in stations.enumerated() {
            let (x, sheer, keel, halfBeam) = station
            for side in 0...segments {
                let angle = Double(side) / Double(segments) * .pi
                vertices.append(vector(x, sheer - (sheer - keel) * pow(sin(angle), 0.38), halfBeam * cos(angle)))
                coordinates.append(CGPoint(x: Double(index) / Double(stations.count - 1), y: Double(side) / Double(segments)))
                if index > 0, side > 0 {
                    let a = Int32((index - 1) * (segments + 1) + side - 1)
                    let b = a + 1, c = a + Int32(segments + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
            if index > 0 {
                let a = Int32((index - 1) * (segments + 1))
                let b = a + Int32(segments), c = a + Int32(segments + 1), d = c + Int32(segments)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        // The transom is closed independently; normals are area weighted so
        // curved bilges catch broad highlights instead of looking faceted.
        for end in [0, stations.count - 1] {
            let base = Int32(end * (segments + 1))
            for side in 1..<(segments - 1) {
                if end == 0 { indices.append(contentsOf: [base, base + Int32(side + 1), base + Int32(side)]) }
                else { indices.append(contentsOf: [base, base + Int32(side), base + Int32(side + 1)]) }
            }
        }
        var sums = Array(repeating: (0.0, 0.0, 0.0), count: vertices.count)
        for index in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[index]), ib = Int(indices[index + 1]), ic = Int(indices[index + 2])
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]
            let ux = Double(b.x - a.x), uy = Double(b.y - a.y), uz = Double(b.z - a.z)
            let vx = Double(c.x - a.x), vy = Double(c.y - a.y), vz = Double(c.z - a.z)
            let n = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
            for vertex in [ia, ib, ic] {
                let old = sums[vertex]; sums[vertex] = (old.0 + n.0, old.1 + n.1, old.2 + n.2)
            }
        }
        let normals = sums.map { n in
            let length = max(0.0001, sqrt(n.0 * n.0 + n.1 * n.1 + n.2 * n.2))
            return vector(n.0 / length, n.1 / length, n.2 / length)
        }
        return put(group, mesh(vertices, normals, coordinates, indices), material)
    }

    private static func historicDeck(_ group: SCNNode, from stern: Double, to bow: Double,
                                     y: Double, beam: Double, material: SCNMaterial) {
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: stern, y: -beam * 0.30))
        outline.curve(to: NSPoint(x: bow, y: 0), controlPoint1: NSPoint(x: stern + 7, y: -beam * 0.62),
                      controlPoint2: NSPoint(x: bow - 6, y: -beam * 0.59))
        outline.curve(to: NSPoint(x: stern, y: beam * 0.30), controlPoint1: NSPoint(x: bow - 6, y: beam * 0.59),
                      controlPoint2: NSPoint(x: stern + 7, y: beam * 0.62))
        outline.close()
        let node = extrude(group, outline, 0.28, material, bevel: 0.04)
        node.eulerAngles.x = .pi / 2
        node.position.y = CGFloat(y + 0.14)
        node.position.z = 0
    }

    private static func historicStrake(_ group: SCNNode, y: Double, z: Double,
                                       material: SCNMaterial, thickness: Double = 0.32) {
        let samples: [(Double, Double, Double)] = [(-13.9, 0.55, 0.88), (-11.0, 0.08, 0.98),
            (-6.0, 0, 1), (1.0, 0, 1), (8.7, 0.06, 0.95), (12.1, 0.43, 0.76), (14.5, 1.10, 0.47)]
        var vertices: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for (index, sample) in samples.enumerated() {
            let (x, lift, beamFactor) = sample
            vertices.append(vector(x, y + lift, z * beamFactor))
            vertices.append(vector(x, y + lift - thickness, z * beamFactor))
            uv.append(CGPoint(x: Double(index) / Double(samples.count - 1), y: 0))
            uv.append(CGPoint(x: Double(index) / Double(samples.count - 1), y: 1))
            if index > 0 {
                let a = Int32((index - 1) * 2)
                if z > 0 { indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2]) }
                else { indices.append(contentsOf: [a, a + 2, a + 1, a + 1, a + 2, a + 3]) }
            }
        }
        put(group, mesh(vertices, Array(repeating: vector(0, 0.1, z > 0 ? 1 : -1), count: vertices.count), uv, indices), material)
    }

    private static func carvedStern(_ group: SCNNode, x: Double, y: Double, width: Double, material: SCNMaterial) {
        for side in [-1.0, 1] {
            for index in 0..<7 {
                let t = Double(index) / 6
                let z = side * width * 0.5 * t
                sphere(group, 0.16, 10, material, x - 0.08, y + sin(t * .pi) * 0.36, z)
            }
        }
        cylinder(group, 0.18, 0.32, 0.7, material, x, y + 0.35)
    }

    private static func anchors(_ group: SCNNode, x: Double, y: Double, beam: Double, material: SCNMaterial) {
        for side in [-1.0, 1] {
            let z = side * beam / 2
            rail(group, from: (x, y + 0.8, z), to: (x - 0.3, y - 1.0, z), radius: 0.085, material: material)
            rail(group, from: (x - 0.8, y + 0.4, z), to: (x + 0.55, y + 0.6, z), radius: 0.075, material: material)
            rail(group, from: (x - 0.3, y - 1.0, z), to: (x - 1.0, y - 0.45, z), radius: 0.09, material: material)
            rail(group, from: (x - 0.3, y - 1.0, z), to: (x + 0.5, y - 0.35, z), radius: 0.09, material: material)
        }
    }

    private static func capstan(_ group: SCNNode, x: Double, y: Double, material: SCNMaterial, rim: SCNMaterial) {
        cylinder(group, 0.42, 0.62, 0.9, material, x, y)
        cylinder(group, 0.72, 0.72, 0.16, rim, x, y + 0.5)
        for z in [-1.0, 1] {
            rail(group, from: (x - 1.0, y + 0.4, z * 0.2), to: (x + 1.0, y + 0.4, z * 0.2), radius: 0.065, material: material)
        }
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
                                     cloth: SCNMaterial, yard: SCNMaterial, rope: SCNMaterial,
                                     brace: Double = 0.18, tattered: Bool = false) {
        let course = SCNNode()
        course.eulerAngles.y = CGFloat(brace)
        course.position = vector(x, y, 0.4)
        group.addChildNode(course)
        PaperweightShipAnimation.tag(course, as: .sail)
        func point(_ u: Double, _ v: Double) -> SCNVector3 {
            let leech = 0.92 + 0.08 * v - 0.075 * sin(v * .pi)
            let tornFoot = tattered ? pow(max(0, sin(u * .pi * 7)), 5) * height * 0.15 : 0
            let foot = height * 0.12 * sin(u * .pi) + tornFoot
            return vector((u - 0.5) * width * leech,
                          (v - 0.5) * height + (1 - v) * foot - v * height * 0.022 * sin(u * .pi),
                          width * 0.14 * sin(u * .pi) * sin((0.17 + v * 0.68) * .pi))
        }
        put(course, clothSurface(rows: 10, columns: 18, point: point), cloth)
        rail(course, from: (-width * 0.54, height * 0.5 + 0.12, 0),
             to: (width * 0.54, height * 0.5 + 0.12, 0), radius: 0.105, material: yard)
        // Bolt ropes follow the bowed leeches and scalloped foot. Reef points
        // remain individual knots rather than a dark grid painted over cloth.
        for side in [0.0, 1.0] {
            for segment in 0..<8 {
                let a = point(side, Double(segment) / 8), b = point(side, Double(segment + 1) / 8)
                rail(course, from: (Double(a.x), Double(a.y), Double(a.z)),
                     to: (Double(b.x), Double(b.y), Double(b.z)), radius: 0.030, material: rope)
            }
        }
        for segment in 0..<12 {
            let a = point(Double(segment) / 12, 0), b = point(Double(segment + 1) / 12, 0)
            rail(course, from: (Double(a.x), Double(a.y), Double(a.z)),
                 to: (Double(b.x), Double(b.y), Double(b.z)), radius: 0.032, material: rope)
        }
        for index in 1..<7 {
            let knot = point(Double(index) / 7, 0.47)
            rail(course, from: (Double(knot.x), Double(knot.y), Double(knot.z) + 0.045),
                 to: (Double(knot.x) + 0.035, Double(knot.y) - height * 0.065, Double(knot.z) + 0.06),
                 radius: 0.025, material: rope)
        }
    }

    private static func clothSurface(rows: Int, columns: Int,
                                      point: (Double, Double) -> SCNVector3) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let p = point(u, v)
                let a = point(min(1, u + 0.002), v), b = point(max(0, u - 0.002), v)
                let c = point(u, min(1, v + 0.002)), d = point(u, max(0, v - 0.002))
                let ux = Double(a.x - b.x), uy = Double(a.y - b.y), uz = Double(a.z - b.z)
                let vx = Double(c.x - d.x), vy = Double(c.y - d.y), vz = Double(c.z - d.z)
                let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
                let length = max(0.0001, sqrt(nx * nx + ny * ny + nz * nz))
                vertices.append(p); normals.append(vector(nx / length, ny / length, nz / length))
                uv.append(CGPoint(x: u, y: 1 - v))
                if row < rows, column < columns {
                    let a = Int32(row * (columns + 1) + column), b = a + 1
                    let c = a + Int32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
        }
        return mesh(vertices, normals, uv, indices)
    }

    private static func triangularCloth(_ group: SCNNode, points: [(Double, Double)], material: SCNMaterial, z: Double) {
        guard points.count == 3 else { return }
        let a = points[0], b = points[1], c = points[2]
        let span = max(abs(a.0 - b.0), abs(a.0 - c.0), abs(b.0 - c.0))
        func point(_ u: Double, _ v: Double) -> SCNVector3 {
            let blendX = a.0 * (1 - u) + b.0 * u
            let blendY = a.1 * (1 - u) + b.1 * u
            return vector(blendX * (1 - v) + c.0 * v, blendY * (1 - v) + c.1 * v,
                          z + sin(u * .pi) * sin(v * .pi) * span * 0.10)
        }
        PaperweightShipAnimation.tag(put(group, clothSurface(rows: 10, columns: 12, point: point), material), as: .sail)
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
        let course = SCNNode()
        course.position.x = CGFloat(x)
        group.addChildNode(course)
        PaperweightShipAnimation.tag(course, as: .sail)
        func point(_ u: Double, _ v: Double) -> SCNVector3 {
            let span = width * (1.0 - 0.34 * v + 0.07 * sin(v * .pi))
            return vector(span * u - width * 0.18 - 0.11 * width * v,
                          bottom + height * v + u * (0.25 + 0.60 * v) + 0.16 * sin(u * .pi),
                          0.7 + sin(u * .pi) * width * (0.13 + 0.025 * sin(v * .pi)))
        }
        put(course, clothSurface(rows: 12, columns: 16, point: point), cloth)
        for row in 0...7 {
            let v = Double(row) / 7
            for segment in 0..<8 {
                let a = point(Double(segment) / 8, v), b = point(Double(segment + 1) / 8, v)
                rail(course, from: (Double(a.x), Double(a.y), Double(a.z) + 0.035),
                     to: (Double(b.x), Double(b.y), Double(b.z) + 0.035), radius: 0.065, material: batten)
            }
            let clew = point(1, v)
            rail(course, from: (Double(clew.x), Double(clew.y), Double(clew.z)),
                 to: (width * 0.18, bottom - 0.7, 0.7), radius: 0.024, material: rope)
        }
        for edge in [0.0, 1.0] {
            for segment in 0..<12 {
                let a = point(edge, Double(segment) / 12), b = point(edge, Double(segment + 1) / 12)
                rail(course, from: (Double(a.x), Double(a.y), Double(a.z)),
                     to: (Double(b.x), Double(b.y), Double(b.z)), radius: 0.040, material: rope)
            }
        }
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
            profile(group, [(16.25, 9.8), (17.6, 9.7), (17.1, 9.3), (16.0, 9.35)], 0.42, material, bevel: 0.09)
            rail(group, from: (16.65, 9.45, 0), to: (17.7, 9.2, 0), radius: 0.065, material: trim)
            for x in [15.25, 15.65, 16.05] {
                profile(group, [(x, 10.35), (x + 0.12, 11.0), (x + 0.4, 10.4)], 0.18, trim, bevel: 0.025)
            }
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
