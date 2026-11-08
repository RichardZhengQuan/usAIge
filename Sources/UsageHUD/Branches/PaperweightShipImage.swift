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
        scene.rootNode.addChildNode(PaperweightShipFactory.make(kind))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.wantsHDR = false
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

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 1_150
        light.eulerAngles = SCNVector3(-CGFloat.pi / 4, -CGFloat.pi / 6, 0)
        scene.rootNode.addChildNode(light)

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
