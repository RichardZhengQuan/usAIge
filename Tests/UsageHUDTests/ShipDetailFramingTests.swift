import AppKit
import Metal
import SceneKit
import Testing
@testable import UsageHUD

@Suite("Ship detail framing")
@MainActor
struct ShipDetailFramingTests {
    @Test func spriteCameraProjectsTheModelWaterlineAtTheSharedAnchor() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device: device, options: nil)
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let camera = PaperweightShipSpriteCamera.make()
        _ = try #require(camera.camera, "Use the actual sprite camera")
        scene.rootNode.addChildNode(camera)
        let marker = SCNNode(geometry: SCNSphere(radius: 0.01))
        let markerMaterial = SCNMaterial()
        markerMaterial.lightingModel = .constant
        markerMaterial.diffuse.contents = NSColor.white
        marker.geometry?.firstMaterial = markerMaterial
        scene.rootNode.addChildNode(marker)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        defer { renderer.scene = nil; renderer.pointOfView = nil }

        for size in [CGSize(width: 128, height: 96), CGSize(width: 512, height: 341)] {
            try autoreleasepool {
                // Rendering initializes SceneKit's real viewport, including
                // the aspect ratio used by the cached sprite strip.
                let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .none)
                let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #expect(pixels.width == Int(size.width) && pixels.height == Int(size.height))
                let projected = renderer.projectPoint(SCNVector3Zero)
                #expect(projected.x.isFinite && projected.y.isFinite && projected.z.isFinite)
                #expect(projected.z >= 0 && projected.z <= 1, "Waterline must lie inside the camera frustum")
                let fractionFromTop = 1 - Double(projected.y) / Double(size.height)
                let anchor = Double(RailPaperweightShipImage.waterlineFraction)
                #expect(abs(fractionFromTop - anchor) * Double(size.height) <= 1,
                        "The rendered waterline must match the sailing/rail anchor within one pixel")
                #expect(abs(Double(projected.x) - Double(size.width) / 2) <= 1,
                        "The ship root must remain horizontally centered")
            }
        }
    }

    @Test func theEntireGhostAndItsTornSailsRemainTranslucent() throws {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(.ghost)
        var nodes = [ship]
        ship.enumerateChildNodes { node, _ in nodes.append(node) }
        var checked = Set<ObjectIdentifier>()
        var foundTornSail = false
        for node in nodes {
            for material in node.geometry?.materials ?? [] where checked.insert(ObjectIdentifier(material)).inserted {
                #expect(!material.writesToDepthBuffer, "Ghost detail must not occlude transparent surfaces")
                #expect(material.blendMode == .alpha, "Ghost detail must retain alpha blending")
                if let color = material.transparent.contents as? NSColor {
                    let rgba = try #require(color.usingColorSpace(.deviceRGB))
                    #expect(rgba.alphaComponent > 0 && rgba.alphaComponent < 1,
                            "Rigging, rails and seams must use translucent materials too")
                } else if let image = material.transparent.contents as? NSImage {
                    let stats = try alphaStatistics(image)
                    #expect(stats.maximum > 0 && Double(stats.maximum) / 255 <= 0.63,
                            "The torn-sail mask must retain its spectral opacity")
                    #expect(stats.interiorHoles > 0, "Tears must remain transparent inside the sail")
                    foundTornSail = true
                } else {
                    Issue.record("Ghost material needs an explicit translucent color or sail mask")
                }
            }
        }
        #expect(!checked.isEmpty)
        #expect(foundTornSail, "The ghost must retain an actual torn-sail alpha mask")
    }

    private func alphaStatistics(_ image: NSImage) throws -> (maximum: UInt8, interiorHoles: Int) {
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: CGFloat(pixels.height)))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var maximum: UInt8 = 0
        var interiorHoles = 0
        let insetX = max(1, pixels.width / 10), insetY = max(1, pixels.height / 10)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let alpha = bytes[y * context.bytesPerRow + x * 4 + 3]
                maximum = max(maximum, alpha)
                if alpha == 0, x >= insetX, x < pixels.width - insetX,
                   y >= insetY, y < pixels.height - insetY { interiorHoles += 1 }
            }
        }
        return (maximum, interiorHoles)
    }
}
