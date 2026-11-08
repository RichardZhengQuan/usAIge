import AppKit
import CryptoKit
import ImageIO
import Metal
import SceneKit
import Testing
import UniformTypeIdentifiers
@testable import UsageHUD

/// Exports the actual posed geometry, including the classic fleet, as looping
/// GIFs. Nothing runs in ordinary test builds unless this destination is set:
/// USAIGE_RENDER_SHIP_ANIMATIONS=/absolute/path swift test --filter ShipAnimationRender
@Suite("ShipAnimationRender", .enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_SHIP_ANIMATIONS"] != nil))
@MainActor
struct ShipAnimationRenderTests {
    private let frameCount = 24
    private let shipSize = CGSize(width: 320, height: 220)

    @Test func exportsAndVerifiesEveryAnimatedShip() throws {
        guard #available(macOS 14.0, *) else { return }
        let rawDirectory = try #require(ProcessInfo.processInfo.environment["USAIGE_RENDER_SHIP_ANIMATIONS"])
        try #require(rawDirectory.hasPrefix("/"), "Choose an absolute GIF output directory")
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = false
        var receipts: [[String: Any]] = []

        for kind in PaperweightShipKind.allCases {
            let receipt = try autoreleasepool { () throws -> [String: Any] in
                let subject = ShipAnimationSubject(kind)
                #expect(subject.animation.partCount > 0, "\(kind.title) needs animated geometry")
                let destination = try makeDestination(directory.appendingPathComponent("\(kind.rawValue).gif"))
                var baseline: Data?
                var hashes = Set<Data>()
                var changedPhases = 0
                var maximumChangedBytes = 0
                for phase in 0..<frameCount {
                    try autoreleasepool {
                        let image = try snapshot(subject, phase: phase, renderer: renderer)
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let pointer = try #require(bitmap.bitmapData)
                        let pixels = Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                        hashes.insert(Data(SHA256.hash(data: pixels)))
                        if let baseline {
                            let changes = zip(baseline, pixels).reduce(into: 0) { count, pair in
                                if pair.0 != pair.1 { count += 1 }
                            }
                            if changes > 0 { changedPhases += 1 }
                            maximumChangedBytes = max(maximumChangedBytes, changes)
                        } else {
                            baseline = pixels
                        }
                        CGImageDestinationAddImage(destination, image, frameProperties)
                    }
                }
                #expect(hashes.count >= 3, "\(kind.title) must show movement at multiple phases; got \(hashes.count) rendered poses")
                #expect(changedPhases >= 2 && maximumChangedBytes > 12,
                        "\(kind.title)'s animated parts must visibly change pixels")
                guard CGImageDestinationFinalize(destination) else { throw ShipGIFError.finalization }
                renderer.scene = nil
                renderer.pointOfView = nil
                return ["ship": kind.rawValue, "title": kind.title, "frames": frameCount,
                        "uniqueRenderedPoses": hashes.count, "changedPhases": changedPhases,
                        "maximumChangedPixelBytes": maximumChangedBytes]
            }
            receipts.append(receipt)
        }

        try exportContactSheet(directory: directory, renderer: renderer)
        let receipt: [String: Any] = [
            "ships": receipts, "shipCount": PaperweightShipKind.allCases.count,
            "framesPerCycle": frameCount, "cycleSeconds": PaperweightShipAnimation.cycleDuration,
            "contactSheet": "ship-animations.gif",
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("ship-animation-verification.json"))
    }

    @available(macOS 14.0, *)
    private func snapshot(_ subject: ShipAnimationSubject, phase: Int, renderer: SCNRenderer) throws -> CGImage {
        let time = Double(phase) * PaperweightShipAnimation.cycleDuration / Double(frameCount)
        subject.animation.apply(time: time)
        renderer.scene = subject.scene
        renderer.pointOfView = subject.camera
        let image = renderer.snapshot(atTime: time, with: shipSize, antialiasingMode: .multisampling4X)
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return try #require(cgImage)
    }

    @available(macOS 14.0, *)
    private func exportContactSheet(directory: URL, renderer: SCNRenderer) throws {
        let representatives: [PaperweightShipKind] = [
            .thousandSunny, .goingMerry, .polarTang, .arkMaxim,
            .perfumeYuda, .germa66, .liner, .sub,
            .carrier, .viking, .steamer, .tug,
        ]
        let subjects = representatives.map(ShipAnimationSubject.init)
        let destination = try makeDestination(directory.appendingPathComponent("ship-animations.gif"))
        let columns = 4, rows = 3, cellWidth = 280, cellHeight = 200, titleHeight = 64
        let width = columns * cellWidth, height = rows * cellHeight + titleHeight

        for phase in 0..<frameCount {
            try autoreleasepool {
                let optionalBitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )
                let bitmap = try #require(optionalBitmap)
                let optionalContext = NSGraphicsContext(bitmapImageRep: bitmap)
                let context = try #require(optionalContext)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                do {
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: width, height: height).fill()
                    "THE FLEET, IN MOTION".draw(at: NSPoint(x: 22, y: height - 33), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 21, weight: .bold),
                        .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1),
                    ])
                    "12 of \(PaperweightShipKind.allCases.count) animated ships · 4-second seamless cycle".draw(
                        at: NSPoint(x: 23, y: height - 53), withAttributes: [
                            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1),
                        ]
                    )
                    for (index, subject) in subjects.enumerated() {
                        let cgImage = try snapshot(subject, phase: phase, renderer: renderer)
                        let x = CGFloat(index % columns * cellWidth)
                        let y = CGFloat(height - titleHeight - (index / columns + 1) * cellHeight)
                        NSImage(cgImage: cgImage, size: shipSize).draw(in: NSRect(x: x + 8, y: y + 25, width: 264, height: 170))
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.alignment = .center
                        representatives[index].title.draw(in: NSRect(x: x + 6, y: y + 3, width: 268, height: 22), withAttributes: [
                            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                            .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1), .paragraphStyle: paragraph,
                        ])
                    }
                }
                let image = try #require(bitmap.cgImage)
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw ShipGIFError.finalization }
        renderer.scene = nil
        renderer.pointOfView = nil
    }

    @available(macOS 14.0, *)
    private var frameProperties: CFDictionary {
        let delay = PaperweightShipAnimation.cycleDuration / Double(frameCount)
        return [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary
    }

    private func makeDestination(_ url: URL) throws -> CGImageDestination {
        let optionalDestination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        let destination = try #require(optionalDestination)
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        return destination
    }
}

@available(macOS 14.0, *)
@MainActor
private final class ShipAnimationSubject {
    let scene = SCNScene()
    let camera = SCNNode()
    let animation: PaperweightShipAnimation

    init(_ kind: PaperweightShipKind) {
        let ship = PaperweightShipFactory.make(kind)
        animation = PaperweightShipAnimation(ship: ship, kind: kind)
        scene.rootNode.addChildNode(ship)
        scene.isPaused = true
        scene.background.contents = NSColor(calibratedWhite: 0.96, alpha: 1)
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
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1_200
        key.eulerAngles = SCNVector3(-0.5, -0.4, 0)
        scene.rootNode.addChildNode(key)
    }
}

private enum ShipGIFError: Error {
    case finalization
}
