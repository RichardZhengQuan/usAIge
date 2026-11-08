import AppKit
import Metal
import SceneKit
import SwiftUI

/// SceneKit produces a baseline image and a small sprite strip on first hover.
/// The rail retains only images, never a scene or continuously running renderer.
@available(macOS 14.0, *)
struct RailPaperweightShipImage: View {
    let kind: PaperweightShipKind
    var size = CGSize(width: 18, height: 12)
    var animationTime: TimeInterval? = nil
    @Environment(\.displayScale) private var displayScale

    @MainActor static var canAnimate: Bool { RailPaperweightShipImageCache.shared.hasGraphicsDevice }

    /// The model's root is the waterline; the hull extends below it.
    nonisolated static var waterlineFraction: CGFloat {
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02
        let bottom = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel + 0.02
        return CGFloat(top / (top + bottom))
    }

    var body: some View {
        Group {
            if let image = RailPaperweightShipImageCache.shared.image(for: kind, size: size, scale: displayScale,
                                                                     animationTime: animationTime) {
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

@MainActor
enum RailPaperweightShipTiming {
    static let frameCount = 20
    // The motion model also runs in non-UI tests on the older deployment
    // target. SceneKit's rig itself is available only on macOS 14 and newer.
    private static var cycleDuration: TimeInterval {
        if #available(macOS 14.0, *) { return PaperweightShipAnimation.cycleDuration }
        return 4
    }
    static var frameDuration: TimeInterval { cycleDuration / Double(frameCount) }

    static func frameIndex(at time: TimeInterval) -> Int {
        guard time.isFinite else { return 0 }
        let phase = max(0, time).truncatingRemainder(dividingBy: cycleDuration)
        return min(frameCount - 1, Int(phase / frameDuration + 0.000_000_01))
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RailPaperweightShipImageCache {
    static let shared = RailPaperweightShipImageCache()
    private lazy var device = MTLCreateSystemDefaultDevice()
    private var images: [Key: Cached<NSImage>] = [:]
    private var strips: [Key: Cached<[NSImage]>] = [:]
    private var unavailable: Set<Key> = []
    private var access = 0

    var hasGraphicsDevice: Bool { device != nil }

    private struct Cached<Value> {
        let value: Value
        var access: Int
    }

    private struct Key: Hashable {
        let kind: PaperweightShipKind
        let pixelWidth: Int
        let pixelHeight: Int
    }

    func image(for kind: PaperweightShipKind, size: CGSize, scale: CGFloat,
               animationTime: TimeInterval? = nil) -> NSImage? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              scale.isFinite else { return nil }
        let scale = min(4, max(1, scale))
        // This is a tiny rail asset. A malformed layout must not allocate an
        // enormous offscreen texture or overflow the pixel-size conversion.
        let key = Key(kind: kind, pixelWidth: max(1, Int(min(512, size.width * scale).rounded())),
                      pixelHeight: max(1, Int(min(512, size.height * scale).rounded())))
        access += 1
        if let animationTime, animationTime.isFinite {
            if var cached = strips[key] {
                cached.access = access
                strips[key] = cached
                return cached.value[RailPaperweightShipTiming.frameIndex(at: animationTime)]
            }
        } else if var cached = images[key] {
            cached.access = access
            images[key] = cached
            return cached.value
        }
        guard !unavailable.contains(key), let device else { return nil }

        let animated = animationTime?.isFinite == true
        let snapshots: [NSImage]? = autoreleasepool {
            let (renderer, ship) = makeRenderer(for: key.kind, device: device)
            let animation = animated ? PaperweightShipAnimation(ship: ship, kind: key.kind) : nil
            var result: [NSImage] = []
            let count = animated ? RailPaperweightShipTiming.frameCount : 1
            for index in 0..<count {
                let time = Double(index) * RailPaperweightShipTiming.frameDuration
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                animation?.apply(time: time)
                SCNTransaction.commit()
                let image: NSImage? = autoreleasepool {
                    let snapshot = renderer.snapshot(atTime: time,
                                                     with: CGSize(width: CGFloat(key.pixelWidth), height: CGFloat(key.pixelHeight)),
                                                     antialiasingMode: .multisampling4X)
                    var rect = NSRect(origin: .zero, size: snapshot.size)
                    guard snapshot.cgImage(forProposedRect: &rect, context: nil, hints: nil) != nil else { return nil }
                    snapshot.size = size
                    return snapshot
                }
                guard let image else { return nil }
                result.append(image)
            }
            // The renderer, scene, rig and temporary render allocations die
            // here. Later ticks select an already-rasterized frame only.
            return result
        }
        guard let snapshots else {
            if unavailable.count >= 128 { unavailable.removeAll(keepingCapacity: true) }
            unavailable.insert(key)
            return nil
        }
        if animated, let animationTime {
            strips[key] = Cached(value: snapshots, access: access)
            if strips.count > 8, let oldest = strips.min(by: { $0.value.access < $1.value.access })?.key {
                strips.removeValue(forKey: oldest)
            }
            return snapshots[RailPaperweightShipTiming.frameIndex(at: animationTime)]
        }
        let image = snapshots[0]
        images[key] = Cached(value: image, access: access)
        if images.count > 128, let oldest = images.min(by: { $0.value.access < $1.value.access })?.key {
            images.removeValue(forKey: oldest)
        }
        return image
    }

    private func makeRenderer(for kind: PaperweightShipKind, device: MTLDevice) -> (SCNRenderer, SCNNode) {
        let scene = SCNScene()
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        let ship = PaperweightShipFactory.make(kind)
        scene.rootNode.addChildNode(ship)

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
        return (renderer, ship)
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
