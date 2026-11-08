import AppKit
import Metal
import SceneKit
import Testing
import simd
@testable import UsageHUD

@Suite("Ship orientation")
@MainActor
struct ShipOrientationTests {
    @Test func canvasArtworkStaysUprightOnCurvedSailsAndSmallPlaneFlagsFromBothSides() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device: device, options: nil)
        let artwork = PaperweightShipFactory.canvas(256, 256) { context, width, height in
            PaperweightShipFactory.fill(context, "#ffffff", CGRect(x: 0, y: 0, width: width, height: height))
            // Deliberately asymmetric artwork, painted in the real canvas's
            // top-left convention. No flipped test-only texture is supplied.
            PaperweightShipFactory.fill(context, "#ff0000", CGRect(x: 96, y: 16, width: 64, height: 48))
            PaperweightShipFactory.fill(context, "#0000ff", CGRect(x: 96, y: 192, width: 64, height: 48))
            PaperweightShipFactory.fill(context, "#00ff00", CGRect(x: 16, y: 96, width: 48, height: 64))
            PaperweightShipFactory.fill(context, "#ffff00", CGRect(x: 192, y: 96, width: 48, height: 64))
        }
        try saveDiagnostics(artwork, label: "synthetic-source-canvas")
        for curved in [true, false] {
            for back in [false, true] {
                try autoreleasepool {
                    let subject = SCNNode()
                    let cloth = PaperweightShipFactory.textured(artwork)
                    cloth.lightingModel = .constant
                    if curved {
                        PaperweightShipFactory.craftedSail(subject, x: 0, y: 0, width: 3.2, height: 2.6,
                                                          material: cloth, bulge: 0.08)
                    } else {
                        // These dimensions exercise the actual SCNPlane flag
                        // path rather than plane()'s large-sail delegation.
                        PaperweightShipFactory.plane(subject, 2.4, 1.8, cloth, 0, 0)
                    }
                    let label = "synthetic-\(curved ? "curved-sail" : "plane-flag")-\(back ? "back" : "front")"
                    let pixels = try render(subject, back: back, renderer: renderer, label: label)
                    let red = try #require(pixels.centroid { r, g, b in r > 180 && g < 80 && b < 80 })
                    let blue = try #require(pixels.centroid { r, g, b in b > 180 && r < 80 && g < 80 })
                    let green = try #require(pixels.centroid { r, g, b in g > 180 && r < 80 && b < 80 })
                    let yellow = try #require(pixels.centroid { r, g, b in r > 180 && g > 180 && b < 80 })
                    try expectAbove(red, blue, in: pixels)
                    #expect(abs(red.y - blue.y) > 20, "Top and bottom artwork must remain distinguishable")
                    // Looking through the physical back of a double-sided
                    // cloth mirrors left/right, but never reverses gravity.
                    #expect(back ? green.x > yellow.x : green.x < yellow.x,
                            "The cloth must have the intended front/back horizontal orientation")
                }
            }
        }
        renderer.scene = nil
        renderer.pointOfView = nil
    }

    @Test(arguments: [PaperweightShipKind.goingMerry, .thousandSunny])
    func theActualStrawHatSailHasItsRedHatAboveTheSkullEyes(_ kind: PaperweightShipKind) throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let ship = PaperweightShipFactory.make(kind)
        var candidate: SCNNode?
        ship.enumerateChildNodes { node, _ in
            guard candidate == nil, let geometry = node.geometry,
                  let image = geometry.firstMaterial?.diffuse.contents as? NSImage,
                  let pixels = try? OrientationPixels(image: image) else { return }
            let red = pixels.count { r, g, b in r > 145 && r * 10 > g * 16 && g < 125 && b < 125 }
            let proportion = Double(red) / Double(pixels.width * pixels.height)
            // A small red hat band identifies the real crest while excluding
            // red-striped aft canvas and plain wood textures.
            if proportion > 0.002 && proportion < 0.07 { candidate = node }
        }
        let original = try #require(candidate, "\(kind.title) needs its actual Straw Hat sail artwork")
        if let source = original.geometry?.firstMaterial?.diffuse.contents as? NSImage {
            try saveDiagnostics(source, label: "\(kind.rawValue)-source-canvas")
        }
        let geometry = try #require(original.geometry?.copy() as? SCNGeometry)
        geometry.materials = geometry.materials.map { original in
            let material = original.copy() as! SCNMaterial
            material.lightingModel = .constant
            return material
        }
        let subject = SCNNode(geometry: geometry)
        let bounds = geometry.boundingBox
        let width = Double(bounds.max.x - bounds.min.x), height = Double(bounds.max.y - bounds.min.y)
        let scale = min(3.2 / max(width, 0.001), 2.6 / max(height, 0.001))
        subject.scale = SCNVector3(scale, scale, scale)
        subject.position = SCNVector3(-Double(bounds.min.x + bounds.max.x) * scale / 2,
                                     -Double(bounds.min.y + bounds.max.y) * scale / 2,
                                     -Double(bounds.min.z + bounds.max.z) * scale / 2)
        let renderer = SCNRenderer(device: device, options: nil)
        for back in [false, true] {
            let pixels = try render(subject, back: back, renderer: renderer,
                                    label: "\(kind.rawValue)-hat-\(back ? "back" : "front")")
            let band = try #require(pixels.centroid { r, g, b in r > 145 && r * 10 > g * 16 && g < 125 && b < 125 })
            let eyes = try #require(pixels.centroid(central: true) { r, g, b in r < 80 && g < 80 && b < 90 })
            try expectAbove(band, eyes, in: pixels)
            #expect(abs(band.y - eyes.y) > 8, "The red hat must visibly sit above the eye region")
        }
        renderer.scene = nil
        renderer.pointOfView = nil
    }

    @Test func sunnysLionFacesForwardAlongTheBowAxis() throws {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(.thousandSunny)
        let mane = try named("sunny-mane", in: ship)
        let face = try named("sunny-face", in: ship)
        let muzzle = try named("sunny-muzzle", in: ship)
        let nose = try named("sunny-nose", in: ship)
        let maneBounds = try bounds(of: mane, in: ship)
        let faceBounds = try bounds(of: face, in: ship)
        let muzzleBounds = try bounds(of: muzzle, in: ship)
        let noseBounds = try bounds(of: nose, in: ship)
        #expect(maneBounds.span.x < min(maneBounds.span.y, maneBounds.span.z) * 0.75,
                "The circular mane must lie across Y/Z, not along the ship's side")
        let normal = mane.convertVector(SCNVector3(0, 0, 1), to: ship)
        let direction = simd_normalize(SIMD3(Double(normal.x), Double(normal.y), Double(normal.z)))
        #expect(direction.x > 0.8, "The mane's front must face the +X bow")
        #expect(faceBounds.span.x < faceBounds.span.z,
                "The lion face must be broad across the bow and shallow fore/aft")
        #expect(muzzleBounds.center.x > faceBounds.center.x)
        #expect(noseBounds.center.x > muzzleBounds.center.x)
        #expect(abs(noseBounds.center.z - faceBounds.center.z) < faceBounds.span.z * 0.12,
                "The nose must face forward instead of pointing to either side")
    }

    @Test(arguments: PaperweightShipKind.allCases)
    func squareYardsCrossTheBeamWhileFlagsStayForeAndAft(_ kind: PaperweightShipKind) throws {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(kind)
        var rigs: [SCNNode] = [], flags: [SCNNode] = []
        ship.enumerateChildNodes { node, _ in
            if let name = node.name,
               ["pirate-square-rig", "special-square-rig", "classic-square-rig"].contains(where: name.hasPrefix) {
                rigs.append(node)
            }
            if node.geometry is SCNPlane, node.name?.contains("|usAIge.motion=flag") == true { flags.append(node) }
        }
        if [.goingMerry, .thousandSunny, .oroJackson, .mobyDick, .redForce].contains(kind) {
            try #require(!rigs.isEmpty, "\(kind.title) needs named square-yard assemblies")
        }
        for rig in rigs {
            let normal = normalized(rig.convertVector(SCNVector3(0, 0, 1), to: ship))
            let yard = normalized(rig.convertVector(SCNVector3(1, 0, 0), to: ship))
            #expect(normal.x > 0.85, "\(kind.title): braced square sails must face mostly toward the +X bow")
            #expect(abs(yard.z) > 0.85, "\(kind.title): square yards must cross the Z beam rather than follow the keel")
        }
        for flag in flags {
            #expect(abs(normalized(flag.convertVector(SCNVector3(0, 0, 1), to: ship)).z) > 0.85,
                    "Fore-and-aft flags must not inherit the square-yard assembly's rotation")
        }
    }

    @Test(arguments: PaperweightShipKind.allCases)
    func mechanicalPartsTurnAroundTheirPhysicalAxes(_ kind: PaperweightShipKind) {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(kind)
        ship.enumerateChildNodes { node, _ in
            guard let role = node.name?.components(separatedBy: "|usAIge.motion=").last,
                  node.name?.contains("|usAIge.motion=") == true else { return }
            switch role {
            case "propeller":
                let axis = normalized(node.convertVector(SCNVector3(1, 0, 0), to: ship))
                #expect(abs(axis.x) > 0.85, "\(kind.title): screw shafts must follow the fore/aft X axis")
                #expect(node.convertPosition(SCNVector3Zero, to: ship).x < 0,
                        "\(kind.title): ship screw joints must be aft of the hull centre")
            case "rotor":
                let axis = normalized(node.convertVector(SCNVector3(0, 1, 0), to: ship))
                #expect(abs(axis.y) > 0.85, "\(kind.title): lifting rotors must turn around the vertical Y axis")
            case "wheel":
                let axis = normalized(node.convertVector(SCNVector3(0, 0, 1), to: ship))
                #expect(abs(axis.z) > 0.85, "\(kind.title): side paddle wheels must turn around the Z beam")
            default: break
            }
        }
    }

    @available(macOS 14.0, *)
    private func render(_ subject: SCNNode, back: Bool, renderer: SCNRenderer, label: String) throws -> OrientationPixels {
        let scene = SCNScene()
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(subject)
        // World-space calibration removes any bitmap row-order ambiguity.
        // Magenta is physically above cyan in both front and back views.
        for (y, color) in [(1.95, NSColor.magenta), (-1.95, NSColor.cyan)] {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.isDoubleSided = true
            let marker = SCNNode(geometry: SCNPlane(width: 0.18, height: 0.12))
            marker.geometry?.firstMaterial = material
            marker.position = SCNVector3(0, y, 0)
            scene.rootNode.addChildNode(marker)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 2.25
        camera.camera?.wantsHDR = false
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.position = SCNVector3(0, 0, back ? -8 : 8)
        // Set both views explicitly. A look-at change on a newly paused
        // scene left the back camera facing away during its first snapshot.
        camera.eulerAngles = SCNVector3(0, back ? CGFloat.pi : 0, 0)
        scene.rootNode.addChildNode(camera)
        SCNTransaction.commit()
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 440, height: 352), antialiasingMode: .multisampling4X)
        let origin = renderer.projectPoint(SCNVector3Zero)
        let top = renderer.projectPoint(SCNVector3(0, 1.95, 0))
        let bottom = renderer.projectPoint(SCNVector3(0, -1.95, 0))
        try saveDiagnostics(image, label: label, extra: [
            "projectedOrigin": [Double(origin.x), Double(origin.y), Double(origin.z)],
            "projectedWorldTop": [Double(top.x), Double(top.y), Double(top.z)],
            "projectedWorldBottom": [Double(bottom.x), Double(bottom.y), Double(bottom.z)],
            "orthographicScale": camera.camera?.orthographicScale ?? 0,
            "cameraEulerAngles": [Double(camera.eulerAngles.x), Double(camera.eulerAngles.y), Double(camera.eulerAngles.z)],
            "backView": back,
        ])
        try #require(origin.z.isFinite && origin.z >= 0 && origin.z <= 1,
                     "The orientation fixture must frame the origin inside its actual front/back frustum")
        return try OrientationPixels(image: image)
    }

    /// Opt-in evidence preserves the real GPU frame and the exact canonical
    /// bytes consumed by the color assertions; it never alters their artwork.
    private func saveDiagnostics(_ image: NSImage, label: String, extra: [String: Any] = [:]) throws {
        guard let raw = ProcessInfo.processInfo.environment["USAIGE_RENDER_ORIENTATION"] else { return }
        try #require(raw.hasPrefix("/"), "Choose an absolute orientation output directory")
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(label).png"))
        let pixels = try OrientationPixels(image: image)
        var report = pixels.diagnostics
        report["sourceBitmapInfo"] = cgImage.bitmapInfo.rawValue
        report["sourceBitsPerPixel"] = cgImage.bitsPerPixel
        report["sourceColorSpace"] = cgImage.colorSpace?.name.map { $0 as String } ?? "unknown"
        report["nsImagePointSize"] = [Double(image.size.width), Double(image.size.height)]
        report.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("\(label).json"))
    }

    private func expectAbove(_ first: CGPoint, _ second: CGPoint, in pixels: OrientationPixels) throws {
        let up = try #require(pixels.centroid { r, g, b in r > 180 && b > 180 && g < 80 })
        let down = try #require(pixels.centroid { r, g, b in g > 180 && b > 180 && r < 80 })
        #expect((first.y - second.y) * (up.y - down.y) > 0,
                "Canvas top must appear toward world +Y, never upside down")
    }

    private func named(_ prefix: String, in ship: SCNNode) throws -> SCNNode {
        var result: SCNNode?
        ship.enumerateChildNodes { node, _ in if node.name?.hasPrefix(prefix) == true { result = node } }
        return try #require(result, "Missing semantic geometry: \(prefix)")
    }

    private func normalized(_ vector: SCNVector3) -> SIMD3<Double> {
        simd_normalize(SIMD3(Double(vector.x), Double(vector.y), Double(vector.z)))
    }

    private func bounds(of node: SCNNode, in ship: SCNNode) throws -> OrientationBounds {
        var leaves = [node]
        node.enumerateChildNodes { child, _ in leaves.append(child) }
        var minimum = SIMD3<Double>(repeating: .infinity), maximum = SIMD3<Double>(repeating: -.infinity)
        var count = 0
        for leaf in leaves {
            guard let geometry = leaf.geometry else { continue }
            let box = geometry.boundingBox
            for x in [box.min.x, box.max.x] {
                for y in [box.min.y, box.max.y] {
                    for z in [box.min.z, box.max.z] {
                        let point = leaf.convertPosition(SCNVector3(x, y, z), to: ship)
                        let value = SIMD3(Double(point.x), Double(point.y), Double(point.z))
                        minimum = simd_min(minimum, value); maximum = simd_max(maximum, value)
                        count += 1
                    }
                }
            }
        }
        try #require(count > 0)
        return OrientationBounds(minimum: minimum, maximum: maximum)
    }
}

private struct OrientationBounds {
    let minimum: SIMD3<Double>
    let maximum: SIMD3<Double>
    var center: SIMD3<Double> { (minimum + maximum) / 2 }
    var span: SIMD3<Double> { maximum - minimum }
}

@MainActor
private struct OrientationPixels {
    let width: Int
    let height: Int
    private let stride: Int
    private let bytes: [UInt8]

    init(image: NSImage) throws {
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                                | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: CGFloat(pixels.height)))
        width = pixels.width; height = pixels.height; stride = context.bytesPerRow
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        bytes = Array(UnsafeBufferPointer(start: pointer, count: stride * height))
    }

    var diagnostics: [String: Any] {
        var histogram: [String: Int] = [:]
        var maxima = [UInt8](repeating: 0, count: 4)
        var visible = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                for channel in 0..<4 { maxima[channel] = max(maxima[channel], bytes[offset + channel]) }
                guard bytes[offset + 3] > 180 else { continue }
                visible += 1
                let key = (0..<4).map { String(Int(bytes[offset + $0]) / 16 * 16) }.joined(separator: ",")
                histogram[key, default: 0] += 1
            }
        }
        let common = histogram.sorted { $0.value > $1.value }.prefix(16)
            .map { ["rgbaBin": $0.key, "pixels": $0.value] as [String: Any] }
        return ["width": width, "height": height, "bytesPerRow": stride,
                "canonicalOrder": "RGBA8, byteOrder32Big, premultipliedLast", "opaquePixels": visible,
                "maximumRGBA": maxima.map(Int.init), "commonOpaqueColors": common,
                "redPixels": count { r, g, b in r > 180 && g < 80 && b < 80 },
                "bluePixels": count { r, g, b in b > 180 && r < 80 && g < 80 },
                "greenPixels": count { r, g, b in g > 180 && r < 80 && b < 80 },
                "yellowPixels": count { r, g, b in r > 180 && g > 180 && b < 80 },
                "magentaPixels": count { r, g, b in r > 180 && b > 180 && g < 80 },
                "cyanPixels": count { r, g, b in g > 180 && b > 180 && r < 80 },
                "hatBandPixels": count { r, g, b in r > 145 && r * 10 > g * 16 && g < 125 && b < 125 }]
    }

    func count(where match: (Int, Int, Int) -> Bool) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                if bytes[offset + 3] > 180, match(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) { count += 1 }
            }
        }
        return count
    }

    func centroid(central: Bool = false, where match: (Int, Int, Int) -> Bool) -> CGPoint? {
        var xTotal = 0.0, yTotal = 0.0, count = 0
        let xRange = central ? (width * 3 / 10)..<(width * 7 / 10) : 0..<width
        let yRange = central ? (height / 4)..<(height * 3 / 4) : 0..<height
        for y in yRange {
            for x in xRange {
                let offset = y * stride + x * 4
                if bytes[offset + 3] > 180, match(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) {
                    xTotal += Double(x); yTotal += Double(y); count += 1
                }
            }
        }
        guard count >= 8 else { return nil }
        return CGPoint(x: xTotal / Double(count), y: yTotal / Double(count))
    }
}
