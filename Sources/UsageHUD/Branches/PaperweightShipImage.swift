import AppKit
import Metal
import SceneKit
import SwiftUI

/// SceneKit produces a baseline image and a small sprite strip on first use.
/// Sailing and rail views retain images, never a scene or running renderer.
@available(macOS 14.0, *)
struct RailPaperweightShipImage: View {
    let kind: PaperweightShipKind
    var size = CGSize(width: 18, height: 12)
    var animationTime: TimeInterval? = nil
    @Environment(\.displayScale) private var displayScale

    @MainActor static var canAnimate: Bool { PaperweightShipImageCache.shared.hasGraphicsDevice }

    /// The model's root is the waterline; the hull extends below it.
    nonisolated static var waterlineFraction: CGFloat {
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02
        let bottom = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel + 0.02
        return CGFloat(top / (top + bottom))
    }

    var body: some View {
        Group {
            if let image = PaperweightShipImageCache.shared.image(for: kind, size: size, scale: displayScale,
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

/// Shared snapshots let the rail and cruising ships reuse the same 3D artwork.
@available(macOS 14.0, *)
@MainActor
final class PaperweightShipImageCache {
    static let shared = PaperweightShipImageCache()
    private lazy var device = MTLCreateSystemDefaultDevice()
    private var images: [Key: Cached<NSImage>] = [:]
    private var strips: [Key: Cached<[NSImage]>] = [:]
    private var unavailable: Set<Key> = []
    private var access = 0

    var hasGraphicsDevice: Bool { device != nil }

    private struct Cached<Value> {
        let value: Value
        let cost: Int
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
        // Preserve the requested aspect ratio while capping every texture.
        // This also prevents huge layouts overflowing pixel-size conversion.
        let rasterScale = min(scale, 512 / max(size.width, size.height))
        let key = Key(kind: kind, pixelWidth: max(1, Int((size.width * rasterScale).rounded())),
                      pixelHeight: max(1, Int((size.height * rasterScale).rounded())))
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
        let snapshots: (images: [NSImage], cost: Int)? = autoreleasepool {
            let (renderer, ship) = makeRenderer(for: key.kind, device: device)
            let animation = animated ? PaperweightShipAnimation(ship: ship, kind: key.kind) : nil
            var result: [NSImage] = []
            var cost = 0
            let count = animated ? RailPaperweightShipTiming.frameCount : 1
            for index in 0..<count {
                let time = Double(index) * RailPaperweightShipTiming.frameDuration
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                animation?.apply(time: time)
                SCNTransaction.commit()
                let frame: (image: NSImage, cost: Int)? = autoreleasepool {
                    let snapshot = renderer.snapshot(atTime: time,
                                                     with: CGSize(width: CGFloat(key.pixelWidth), height: CGFloat(key.pixelHeight)),
                                                     antialiasingMode: .multisampling4X)
                    var rect = NSRect(origin: .zero, size: snapshot.size)
                    guard let pixels = snapshot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                          let bitmap = CGContext(data: nil, width: key.pixelWidth, height: key.pixelHeight,
                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    // Own a bounded CPU bitmap, independent of SceneKit's
                    // readback representation or temporary Metal resources.
                    bitmap.draw(pixels, in: CGRect(x: 0, y: 0, width: CGFloat(key.pixelWidth), height: CGFloat(key.pixelHeight)))
                    guard let frame = bitmap.makeImage() else { return nil }
                    return (NSImage(cgImage: frame, size: size), frame.bytesPerRow * frame.height)
                }
                guard let frame else { return nil }
                result.append(frame.image)
                cost += frame.cost
            }
            // The renderer, scene, rig and temporary render allocations die
            // here. Later ticks select an already-rasterized frame only.
            return (result, cost)
        }
        guard let snapshots else {
            if unavailable.count >= 128 { unavailable.removeAll(keepingCapacity: true) }
            unavailable.insert(key)
            return nil
        }
        if animated, let animationTime {
            strips[key] = Cached(value: snapshots.images, cost: snapshots.cost, access: access)
            Self.trim(&strips, count: 8, bytes: 32 * 1_024 * 1_024)
            return snapshots.images[RailPaperweightShipTiming.frameIndex(at: animationTime)]
        }
        let image = snapshots.images[0]
        images[key] = Cached(value: image, cost: snapshots.cost, access: access)
        Self.trim(&images, count: 128, bytes: 16 * 1_024 * 1_024)
        return image
    }

    /// Budget the actual bitmap stride, including padding, rather than only
    /// counting keys: a large sailing strip costs more than a rail strip.
    private static func trim<Value>(_ cache: inout [Key: Cached<Value>], count: Int, bytes: Int) {
        var cost = cache.values.reduce(0) { $0 + $1.cost }
        while cache.count > count || cost > bytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cost -= removed.cost
        }
    }

    private func makeRenderer(for kind: PaperweightShipKind, device: MTLDevice) -> (SCNRenderer, SCNNode) {
        let scene = SCNScene()
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        let ship = PaperweightShipFactory.make(kind)
        // A little yaw reveals the fittings. The elevated camera below shows
        // the deck while keeping the model origin at the shared keel anchor.
        ship.eulerAngles.y = -CGFloat.pi / 18
        scene.rootNode.addChildNode(ship)
        scene.lightingEnvironment.contents = PaperweightSceneAssets.environmentTexture()
        scene.lightingEnvironment.intensity = 0.55

        let camera = PaperweightShipSpriteCamera.make()
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
        return (renderer, ship)
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

/// The same camera frames cached sprites and the GPU projection regression.
/// Padding and elevation must not move the root away from the waterline used
/// by both the rail and the sailing scene.
@available(macOS 14.0, *)
@MainActor
enum PaperweightShipSpriteCamera {
    static func make() -> SCNNode {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = -0.2
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02
        let bottom = -PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel - 0.02
        let scale = (top - bottom) / 2 * 1.06
        let horizontalOffset = 0.48, rise = 0.27, distance = 3.0
        let horizontal = hypot(horizontalOffset, distance)
        let verticalProjection = horizontal / hypot(horizontal, rise)
        let center = (Double(RailPaperweightShipImage.waterlineFraction) - 0.5) * 2 * scale / verticalProjection
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.camera?.orthographicScale = scale
        camera.position = SCNVector3(horizontalOffset, center + rise, distance)
        camera.eulerAngles = SCNVector3(-atan2(rise, horizontal), atan2(horizontalOffset, distance), 0)
        SCNTransaction.commit()
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.55
        camera.camera?.screenSpaceAmbientOcclusionRadius = 0.035
        camera.camera?.screenSpaceAmbientOcclusionBias = 0.003
        return camera
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
