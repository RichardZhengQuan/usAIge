import AppKit
import Metal
import SceneKit
import SwiftUI

/// SceneKit is used once per ship, size and screen scale. Hovering moves this
/// cached image, so the always-visible rail never keeps a renderer alive.
@available(macOS 14.0, *)
struct RailPaperweightShipImage: View {
    let kind: PaperweightShipKind
    var size = CGSize(width: 18, height: 12)
    @Environment(\.displayScale) private var displayScale

    /// The model's root is the waterline; the hull extends below it.
    nonisolated static var waterlineFraction: CGFloat {
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02
        let bottom = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel + 0.02
        return CGFloat(top / (top + bottom))
    }

    var body: some View {
        Group {
            if let image = PaperweightShipImageCache.shared.image(for: kind, size: size, scale: displayScale) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RailSailboatSilhouette().fill(Color.primary.opacity(0.78))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Shared snapshots let the rail and cruising ships reuse the same 3D artwork.
@available(macOS 14.0, *)
@MainActor
final class PaperweightShipImageCache {
    static let shared = PaperweightShipImageCache()
    private lazy var device = MTLCreateSystemDefaultDevice()
    private var images: [Key: NSImage] = [:]
    private var unavailable: Set<Key> = []

    private struct Key: Hashable {
        let kind: PaperweightShipKind
        let pixelWidth: Int
        let pixelHeight: Int
    }

    func image(for kind: PaperweightShipKind, size: CGSize, scale: CGFloat) -> NSImage? {
        guard size.width > 0, size.height > 0, scale.isFinite else { return nil }
        let scale = min(4, max(1, scale))
        let key = Key(kind: kind, pixelWidth: max(1, Int((size.width * scale).rounded())),
                      pixelHeight: max(1, Int((size.height * scale).rounded())))
        if let image = images[key] { return image }
        guard !unavailable.contains(key), let device else { return nil }

        let scene = SCNScene()
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        let ship = PaperweightShipFactory.make(kind)
        // A little yaw shows the bow, stern and depth of the fittings. Keep
        // pitch at zero: projecting the water plane obliquely would move its
        // visible edge away from the buoyancy model's exact waterline.
        ship.eulerAngles.y = -CGFloat.pi / 18
        scene.rootNode.addChildNode(ship)
        scene.lightingEnvironment.contents = PaperweightSceneAssets.environmentTexture()
        scene.lightingEnvironment.intensity = 0.55

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = -0.2
        camera.position.z = 3
        // Fixed bounds preserve the ships' relative sizes and put every hull
        // at the same waterline instead of centring each model differently.
        let top = CGFloat(PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02)
        let bottom = -CGFloat(PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel + 0.02)
        // A hand-built projection matrix rendered an empty image, so the
        // camera's own orthographic scale (half the visible height) frames it.
        camera.camera?.orthographicScale = Double(top - bottom) / 2
        camera.position.y = (top + bottom) / 2
        scene.rootNode.addChildNode(camera)

        addLight(to: scene, type: .ambient, intensity: 330,
                 color: NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1))
        addLight(to: scene, type: .directional, intensity: 900,
                 color: NSColor(calibratedRed: 1, green: 0.96, blue: 0.88, alpha: 1),
                 angles: SCNVector3(-CGFloat.pi / 4, -CGFloat.pi / 5, 0))
        addLight(to: scene, type: .directional, intensity: 340,
                 color: NSColor(calibratedRed: 0.77, green: 0.88, blue: 1, alpha: 1),
                 angles: SCNVector3(-CGFloat.pi / 9, CGFloat.pi / 3, 0))
        addLight(to: scene, type: .directional, intensity: 520,
                 color: NSColor(calibratedRed: 0.88, green: 0.95, blue: 1, alpha: 1),
                 angles: SCNVector3(-CGFloat.pi / 3, CGFloat.pi * 0.9, 0))

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: CGFloat(key.pixelWidth), height: CGFloat(key.pixelHeight)),
                                      antialiasingMode: .multisampling4X)
        var rect = NSRect(origin: .zero, size: image.size)
        guard image.cgImage(forProposedRect: &rect, context: nil, hints: nil) != nil else {
            unavailable.insert(key)
            return nil
        }
        image.size = size
        images[key] = image
        return image
    }

    private func addLight(to scene: SCNScene, type: SCNLight.LightType, intensity: CGFloat,
                          color: NSColor, angles: SCNVector3 = SCNVector3Zero) {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = type
        node.light?.intensity = intensity
        node.light?.color = color
        node.eulerAngles = angles
        scene.rootNode.addChildNode(node)
    }
}

/// A single readable silhouette covers machines without a graphics device.
@available(macOS 14.0, *)
private struct RailSailboatSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        let line = height * RailPaperweightShipImage.waterlineFraction
        var path = Path()
        path.move(to: CGPoint(x: width * 0.1, y: line))
        path.addQuadCurve(to: CGPoint(x: width * 0.28, y: line + height * 0.15),
                          control: CGPoint(x: width * 0.16, y: line + height * 0.15))
        path.addLine(to: CGPoint(x: width * 0.74, y: line + height * 0.15))
        path.addQuadCurve(to: CGPoint(x: width * 0.91, y: line),
                          control: CGPoint(x: width * 0.84, y: line + height * 0.15))
        path.closeSubpath()
        path.addRect(CGRect(x: width * 0.51, y: height * 0.06, width: max(0.7, width * 0.035), height: line - height * 0.06))
        path.move(to: CGPoint(x: width * 0.48, y: height * 0.1))
        path.addLine(to: CGPoint(x: width * 0.48, y: line - height * 0.08))
        path.addLine(to: CGPoint(x: width * 0.16, y: line - height * 0.08))
        path.closeSubpath()
        path.move(to: CGPoint(x: width * 0.58, y: height * 0.26))
        path.addLine(to: CGPoint(x: width * 0.86, y: line - height * 0.08))
        path.addLine(to: CGPoint(x: width * 0.58, y: line - height * 0.08))
        path.closeSubpath()
        return path
    }
}
