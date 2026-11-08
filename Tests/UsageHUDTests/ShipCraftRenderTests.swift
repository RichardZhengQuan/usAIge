import AppKit
import Metal
import SceneKit
import Testing
@testable import UsageHUD

/// Resource guards run normally. PNG exports are opt-in:
/// USAIGE_RENDER_SHIP_DETAILS=/absolute/path swift test --filter ShipCraftRender
@Suite("ShipCraftRender")
@MainActor
struct ShipCraftRenderTests {
    @Test func polygonMetricsExcludeHeadersAndAdditionalIndexChannels() {
        // SceneKit's documented layout: two quads and a pentagon, followed
        // by separate position/UV index channels. They form seven triangles.
        let counts: [UInt32] = [4, 4, 5]
        let channel: [UInt32] = [0, 1, 2, 3, 5, 4, 3, 2, 7, 6, 5, 2, 1]
        let words = counts + channel + channel
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(ShipDetailMetrics.polygonTriangles(data: data, primitiveCount: 3, bytesPerIndex: 4) == 7)
        #expect(ShipDetailMetrics.polygonTriangles(data: Data([4, 0, 1]), primitiveCount: 1, bytesPerIndex: 1) == nil)
    }

    @Test(arguments: PaperweightShipKind.allCases)
    func detailedModelsHaveBoundedLocalFiniteGeometry(_ kind: PaperweightShipKind) {
        guard #available(macOS 14.0, *) else { return }
        autoreleasepool {
            let ship = PaperweightShipFactory.make(kind)
            let metrics = ShipDetailMetrics(ship: ship)
            #expect(metrics.nodes <= 1_000, "\(kind.title) has \(metrics.nodes) nodes")
            #expect(metrics.triangles <= 100_000, "\(kind.title) has \(metrics.triangles) triangles")
            #expect(metrics.geometries > 0 && metrics.triangles > 0, "\(kind.title) needs a real mesh")
            #expect(metrics.issues.isEmpty, "\(kind.title): \(metrics.issues.joined(separator: "; "))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_SHIP_DETAILS"] != nil))
    func exportsAllShipsAndFlagshipDetailViews() throws {
        guard #available(macOS 14.0, *) else { return }
        let raw = try #require(ProcessInfo.processInfo.environment["USAIGE_RENDER_SHIP_DETAILS"])
        try #require(raw.hasPrefix("/"), "Choose an absolute output directory")
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        let detailDirectory = directory.appendingPathComponent("flagship-details", isDirectory: true)
        try FileManager.default.createDirectory(at: detailDirectory, withIntermediateDirectories: true)
        let orientationDirectory = directory.appendingPathComponent("orientation", isDirectory: true)
        try FileManager.default.createDirectory(at: orientationDirectory, withIntermediateDirectories: true)
        let device = try #require(MTLCreateSystemDefaultDevice(), "Detail exports require a Metal device")
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = false
        defer { renderer.scene = nil; renderer.pointOfView = nil }
        let flagships: [PaperweightShipKind] = [.goingMerry, .thousandSunny, .polarTang, .mobyDick]
        let fleet = try ShipDetailSheet(columns: 6, rows: (PaperweightShipKind.allCases.count + 5) / 6,
                                        cell: CGSize(width: 240, height: 196),
                                        title: "THE FLEET · \(PaperweightShipKind.allCases.count) SHIPS",
                                        subtitle: "Actual meshes · bow three-quarter view · rest pose")
        let portSheet = try ShipDetailSheet(columns: 6, rows: (PaperweightShipKind.allCases.count + 5) / 6,
                                            cell: CGSize(width: 240, height: 196), title: "PORT SIDE · ALL 59 SHIPS",
                                            subtitle: "Opposite side · artwork remains upright")
        let frontSheet = try ShipDetailSheet(columns: 6, rows: (PaperweightShipKind.allCases.count + 5) / 6,
                                             cell: CGSize(width: 240, height: 196), title: "BOW VIEW · ALL 59 SHIPS",
                                             subtitle: "Looking toward the stern · forward-facing figureheads and square yards")
        let overview = try ShipDetailSheet(columns: 2, rows: 2, cell: CGSize(width: 640, height: 470),
                                           title: "FLAGSHIP DETAILS",
                                           subtitle: "Going Merry · Thousand Sunny · Polar Tang · Moby Dick")
        var receipts: [[String: Any]] = []
        for (index, kind) in PaperweightShipKind.allCases.enumerated() {
            let receipt = try autoreleasepool { () throws -> [String: Any] in
                let started = ProcessInfo.processInfo.systemUptime
                let ship = PaperweightShipFactory.make(kind)
                let factoryMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                let subject = ShipDetailSubject(ship: ship, kind: kind)
                defer { renderer.scene = nil; renderer.pointOfView = nil }
                let image = try subject.snapshot(renderer: renderer, angle: .bow, time: nil)
                let port = try subject.snapshot(renderer: renderer, angle: .port, time: nil)
                let front = try subject.snapshot(renderer: renderer, angle: .front, time: nil)
                try write(port, to: orientationDirectory.appendingPathComponent("\(kind.rawValue)-port.png"))
                try write(front, to: orientationDirectory.appendingPathComponent("\(kind.rawValue)-front.png"))
                portSheet.add(port, index: index, title: kind.title, subtitle: "Port side")
                frontSheet.add(front, index: index, title: kind.title, subtitle: "Bow view")
                // SceneKit tessellates some primitive geometry lazily. Inspect
                // the actual rendered meshes, not only their cold estimates.
                let metrics = ShipDetailMetrics(ship: ship)
                #expect(metrics.nodes <= 1_000, "\(kind.title) has \(metrics.nodes) rendered nodes")
                #expect(metrics.triangles <= 100_000, "\(kind.title) has \(metrics.triangles) rendered triangles")
                #expect(metrics.geometries > 0 && metrics.triangles > 0, "\(kind.title) needs a real rendered mesh")
                #expect(metrics.issues.isEmpty, "\(kind.title): \(metrics.issues.joined(separator: "; "))")
                try write(image, to: directory.appendingPathComponent("\(kind.rawValue).png"))
                fleet.add(image, index: index, title: kind.title, subtitle: kind.collection.title)
                if let flagshipIndex = flagships.firstIndex(of: kind) {
                    overview.add(image, index: flagshipIndex, title: kind.title, subtitle: "Bow ¾ · rest pose")
                    for angle in ShipDetailAngle.allCases {
                        for pose in 0...1 {
                            try autoreleasepool {
                                let detail = try subject.snapshot(renderer: renderer, angle: angle,
                                                                  time: pose == 0 ? nil : 1)
                                let name = "\(kind.rawValue)-\(angle.rawValue)-\(pose == 0 ? "rest" : "phase-1s").png"
                                try write(detail, to: detailDirectory.appendingPathComponent(name))
                            }
                        }
                    }
                }
                return ["ship": kind.rawValue, "title": kind.title, "nodes": metrics.nodes,
                        "geometryInstances": metrics.geometries, "triangles": metrics.triangles,
                        "uniqueMaterials": metrics.materials, "factoryMilliseconds": factoryMS,
                        "geometryIssues": metrics.issues]
            }
            receipts.append(receipt)
        }
        try fleet.write(to: directory.appendingPathComponent("ship-detail-fleet.png"))
        try overview.write(to: directory.appendingPathComponent("ship-detail-flagships.png"))
        try portSheet.write(to: directory.appendingPathComponent("ship-detail-port.png"))
        try frontSheet.write(to: directory.appendingPathComponent("ship-detail-front.png"))
        let report: [String: Any] = ["shipCount": receipts.count, "imageWidth": 640, "imageHeight": 420,
                                    "flagshipDetailImages": flagships.count * ShipDetailAngle.allCases.count * 2,
                                    "allShipOrientationImages": receipts.count * 2, "phaseSeconds": 1,
                                    "timingsAreInformational": true, "ships": receipts]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("ship-detail-metrics.json"))
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

@MainActor
private struct ShipDetailMetrics {
    var nodes = 0
    var geometries = 0
    var triangles = 0
    var materials = 0
    var issues: [String] = []

    init(ship: SCNNode) {
        var materialIDs = Set<ObjectIdentifier>()
        var descendants = [ship]
        ship.enumerateChildNodes { node, _ in descendants.append(node) }
        nodes = descendants.count
        for node in descendants {
            let transform = node.simdTransform
            let components = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
            if components.contains(where: { column in (0..<4).contains { !column[$0].isFinite } }) {
                issues.append("nonfinite node transform")
            }
            guard let geometry = node.geometry else { continue }
            geometries += 1
            let bounds = geometry.boundingBox
            let points = [bounds.min, bounds.max].flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
            if !points.allSatisfy(\.isFinite) { issues.append("nonfinite geometry bounds") }
            for element in geometry.elements {
                switch element.primitiveType {
                case .triangles, .triangleStrip: triangles += element.primitiveCount
                case .polygon:
                    if let count = Self.polygonTriangles(data: element.data, primitiveCount: element.primitiveCount,
                                                         bytesPerIndex: element.bytesPerIndex) {
                        triangles += count
                    } else { issues.append("malformed polygon vertex-count header") }
                case .line, .point: break
                @unknown default: issues.append("unknown mesh primitive type")
                }
            }
            for source in geometry.sources(for: .vertex) where !finiteVertices(source) {
                issues.append("nonfinite or malformed vertex positions")
            }
            for material in geometry.materials where materialIDs.insert(ObjectIdentifier(material)).inserted {
                let properties = [material.diffuse, material.ambient, material.specular, material.emission,
                                  material.transparent, material.reflective, material.multiply, material.normal,
                                  material.displacement, material.ambientOcclusion, material.metalness, material.roughness,
                                  material.selfIllumination, material.clearCoat, material.clearCoatRoughness, material.clearCoatNormal]
                for property in properties {
                    let url = (property.contents as? URL) ?? (property.contents as? String).flatMap(URL.init(string:))
                    if let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        issues.append("remote material URL: \(url!.absoluteString)")
                    }
                }
            }
        }
        materials = materialIDs.count
    }

    /// SCNGeometry.h defines a polygon-size header followed by index channels.
    /// Counting those words measures storage, including duplicated normal/UV
    /// indices, rather than the number of triangles the polygons tessellate to.
    static func polygonTriangles(data: Data, primitiveCount: Int, bytesPerIndex: Int) -> Int? {
        guard [1, 2, 4, 8].contains(bytesPerIndex), primitiveCount >= 0,
              data.count.isMultiple(of: bytesPerIndex) else { return nil }
        let words = data.count / bytesPerIndex
        guard primitiveCount <= words else { return nil }
        return data.withUnsafeBytes { bytes -> Int? in
            var vertices = 0, triangles = 0
            for polygon in 0..<primitiveCount {
                let offset = polygon * bytesPerIndex
                let raw: UInt64
                switch bytesPerIndex {
                case 1: raw = UInt64(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                case 2: raw = UInt64(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                case 4: raw = UInt64(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                default: raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                }
                // At least one index channel must fit after the header.
                guard raw >= 3, raw <= UInt64(words - primitiveCount - vertices) else { return nil }
                let count = Int(raw)
                vertices += count
                triangles += count - 2
            }
            return triangles
        }
    }

    private func finiteVertices(_ source: SCNGeometrySource) -> Bool {
        guard source.usesFloatComponents else { return true }
        let width = source.bytesPerComponent
        guard width == 4 || width == 8, source.componentsPerVector >= 3 else { return false }
        let stride = source.dataStride > 0 ? source.dataStride : source.componentsPerVector * width
        return source.data.withUnsafeBytes { bytes in
            for vector in 0..<source.vectorCount {
                for component in 0..<3 {
                    let offset = source.dataOffset + vector * stride + component * width
                    guard offset >= 0, offset + width <= bytes.count else { return false }
                    if width == 4 {
                        if !bytes.loadUnaligned(fromByteOffset: offset, as: Float.self).isFinite { return false }
                    } else if !bytes.loadUnaligned(fromByteOffset: offset, as: Double.self).isFinite { return false }
                }
            }
            return true
        }
    }
}

private enum ShipDetailAngle: String, CaseIterable {
    case side, port, bow, stern, front

    var cameraPosition: SCNVector3 {
        switch self {
        case .side: SCNVector3(0, 0.48, 3)
        case .port: SCNVector3(0, 0.48, -3)
        case .front: SCNVector3(3, 0.65, 0)
        case .bow: SCNVector3(1.6, 0.95, 3)
        case .stern: SCNVector3(-1.6, 0.95, 3)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class ShipDetailSubject {
    let scene = SCNScene()
    let camera = SCNNode()
    let animation: PaperweightShipAnimation

    init(ship: SCNNode, kind: PaperweightShipKind) {
        animation = PaperweightShipAnimation(ship: ship, kind: kind)
        scene.rootNode.addChildNode(ship)
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 0.46
        camera.camera?.wantsHDR = false
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1_100
        key.eulerAngles = SCNVector3(-0.6, -0.45, 0)
        scene.rootNode.addChildNode(key)
    }

    func snapshot(renderer: SCNRenderer, angle: ShipDetailAngle, time: TimeInterval?) throws -> CGImage {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        if let time { animation.apply(time: time) } else { animation.reset() }
        camera.position = angle.cameraPosition
        camera.look(at: SCNVector3(0, 0.18, 0), up: SCNVector3(0, 1, 0),
                    localFront: SCNVector3(0, 0, -1))
        SCNTransaction.commit()
        renderer.scene = scene
        renderer.pointOfView = camera
        let snapshot = renderer.snapshot(atTime: time ?? 0, with: CGSize(width: 640, height: 420),
                                         antialiasingMode: .multisampling4X)
        let image = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let origin = renderer.projectPoint(SCNVector3Zero)
        let above = renderer.projectPoint(SCNVector3(0, 0.1, 0))
        #expect(abs(origin.x - above.x) < 1, "Changing inspection angles must not roll the camera")
        #expect(above.y > origin.y, "Inspection renders keep world up above the keel")
        let bitmap = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                           bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let data = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var visible = 0
        for y in 0..<image.height {
            for x in 0..<image.width where data[y * bitmap.bytesPerRow + x * 4 + 3] > 25 { visible += 1 }
        }
        #expect(visible > 2_000, "Detail views must contain visible mesh pixels")
        return image
    }
}

@MainActor
private final class ShipDetailSheet {
    private let bitmap: NSBitmapImageRep
    private let context: NSGraphicsContext
    private let columns: Int
    private let cell: CGSize
    private let header: CGFloat = 72

    init(columns: Int, rows: Int, cell: CGSize, title: String, subtitle: String) throws {
        self.columns = columns
        self.cell = cell
        bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                                               pixelsWide: Int(cell.width) * columns,
                                               pixelsHigh: Int(cell.height) * rows + 72,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
        context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        withContext {
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
            title.draw(at: CGPoint(x: 22, y: CGFloat(bitmap.pixelsHigh) - 34), withAttributes: [
                .font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor.black,
            ])
            subtitle.draw(at: CGPoint(x: 23, y: CGFloat(bitmap.pixelsHigh) - 56), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray,
            ])
        }
    }

    func add(_ image: CGImage, index: Int, title: String, subtitle: String) {
        withContext {
            let x = CGFloat(index % columns) * cell.width
            let y = CGFloat(bitmap.pixelsHigh) - header - CGFloat(index / columns + 1) * cell.height
            let inset: CGFloat = cell.width > 300 ? 16 : 7
            let available = CGRect(x: x + inset, y: y + 43, width: cell.width - inset * 2, height: cell.height - 48)
            let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            NSImage(cgImage: image, size: size).draw(in: CGRect(x: available.midX - size.width / 2,
                                                              y: available.midY - size.height / 2,
                                                              width: size.width, height: size.height))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            title.draw(in: CGRect(x: x + 7, y: y + 21, width: cell.width - 14, height: 20), withAttributes: [
                .font: NSFont.systemFont(ofSize: cell.width > 300 ? 17 : 12, weight: .semibold),
                .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
            ])
            subtitle.draw(in: CGRect(x: x + 7, y: y + 5, width: cell.width - 14, height: 15), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray, .paragraphStyle: paragraph,
            ])
        }
    }

    func write(to url: URL) throws {
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func withContext(_ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw()
    }
}
