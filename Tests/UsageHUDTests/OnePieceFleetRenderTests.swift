import AppKit
import Metal
import SceneKit
import Testing
@testable import UsageHUD

/// Opt-in contact sheet of the actual meshes, without the glass hiding details.
/// USAIGE_RENDER_FLEET=/absolute/output/path swift test --filter OnePieceFleetRender
@Suite("OnePieceFleetRender", .enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_FLEET"] != nil))
@MainActor
struct OnePieceFleetRenderTests {
    @Test func rendersEveryMiniature() throws {
        guard #available(macOS 14.0, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["USAIGE_RENDER_FLEET"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ships = PaperweightShipKind.allCases.filter { $0.collection != .classics }
        let renderer = SCNRenderer(device: device, options: nil)
        let cell = CGSize(width: 240, height: 190)
        let columns = 6, rows = (ships.count + 5) / 6
        let sheet = NSImage(size: CGSize(width: cell.width * Double(columns), height: cell.height * Double(rows) + 60))
        do {
            sheet.lockFocus()
            defer { sheet.unlockFocus() }
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(origin: .zero, size: sheet.size).fill()
            let title = "ONE PIECE · \(ships.count) SHIP MINIATURES"
            title.draw(at: CGPoint(x: 24, y: sheet.size.height - 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black,
            ])
            var renderedImages = Set<Data>()
            for (index, kind) in ships.enumerated() {
                let scene = SCNScene()
                scene.background.contents = NSColor.clear
                scene.rootNode.addChildNode(PaperweightShipFactory.make(kind))
                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.usesOrthographicProjection = true
                camera.camera?.orthographicScale = 0.46
                camera.camera?.wantsHDR = false
                camera.position = SCNVector3(0.7, 0.55, 3)
                camera.look(at: SCNVector3(0, 0.18, 0))
                scene.rootNode.addChildNode(camera)
                let ambient = SCNNode()
                ambient.light = SCNLight()
                ambient.light?.type = .ambient
                ambient.light?.intensity = 600
                scene.rootNode.addChildNode(ambient)
                let light = SCNNode()
                light.light = SCNLight()
                light.light?.type = .directional
                light.light?.intensity = 1_200
                light.eulerAngles = SCNVector3(-0.5, -0.4, 0)
                scene.rootNode.addChildNode(light)
                renderer.scene = scene
                renderer.pointOfView = camera
                let image = renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 320), antialiasingMode: .multisampling4X)
                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                var visible = 0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        visible += 1
                    }
                }
                #expect(visible > 1_000, "\(kind.title) must render a visible model, not a fallback")
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(renderedImages.insert(png).inserted, "\(kind.title) must have its own appearance")
                try png.write(to: directory.appendingPathComponent("\(kind.rawValue).png"))
                let x = Double(index % columns) * cell.width
                let y = sheet.size.height - 60 - Double(index / columns + 1) * cell.height
                image.draw(in: NSRect(x: x + 5, y: y + 30, width: 230, height: 153))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                kind.title.draw(in: NSRect(x: x + 8, y: y, width: 224, height: 30), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
                ])
            }
        }
        let tiff = try #require(sheet.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("one-piece-fleet.png"))
    }
}
