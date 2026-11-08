import Metal
import AppKit
import SceneKit
import SwiftUI
import Testing
@testable import UsageHUD

@Suite("Ship animation")
@MainActor
struct PaperweightShipAnimationTests {
    @Test(arguments: PaperweightShipKind.allCases)
    func everyShipHasMovingPartsAndAnExactRestPose(_ kind: PaperweightShipKind) {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(kind)
        let animation = PaperweightShipAnimation(ship: ship, kind: kind)
        var nodes: [SCNNode] = []
        ship.enumerateChildNodes { node, _ in nodes.append(node) }
        let rest = nodes.map(\.simdTransform)
        #expect(animation.partCount > 0, "\(kind.title) needs actual moving parts")
        animation.apply(time: 0.37)
        let pose = nodes.map(\.simdTransform)
        #expect(zip(rest, pose).contains { $0.0 != $0.1 }, "\(kind.title) must change its mesh pose")
        animation.apply(time: 0.37)
        #expect(nodes.map(\.simdTransform) == pose, "Poses must not accumulate drift")
        animation.apply(time: 3.3)
        animation.apply(time: 0.37, reduceMotion: true)
        #expect(nodes.map(\.simdTransform) == rest, "Reduce Motion restores every joint")
        animation.apply(time: .infinity)
        #expect(nodes.map(\.simdTransform) == rest)
        #expect(ship.position.x == 0 && ship.position.y == 0 && ship.position.z == 0)
    }

    @Test(arguments: PaperweightShipKind.allCases)
    func animatedPartsFitAtEveryRollAngle(_ kind: PaperweightShipKind) {
        guard #available(macOS 14.0, *) else { return }
        let ship = PaperweightShipFactory.make(kind)
        let animation = PaperweightShipAnimation(ship: ship, kind: kind)
        var leaves: [SCNNode] = []
        ship.enumerateChildNodes { node, _ in if node.geometry != nil { leaves.append(node) } }
        var side = 0.0, top = 0.0, bottom = 0.0, depth = 0.0
        for frame in 0..<32 {
            animation.apply(time: Double(frame) * PaperweightShipAnimation.cycleDuration / 32)
            for leaf in leaves {
                let bounds = leaf.geometry!.boundingBox
                for x in [bounds.min.x, bounds.max.x] {
                    for y in [bounds.min.y, bounds.max.y] {
                        for z in [bounds.min.z, bounds.max.z] {
                            let p = leaf.convertPosition(SCNVector3(x, y, z), to: nil)
                            let px = Double(p.x), py = Double(p.y)
                            depth = max(depth, abs(Double(p.z)))
                            var angles = [-PaperweightConstants.maximumRoll, 0, PaperweightConstants.maximumRoll]
                            for base in [atan2(-py, px), atan2(px, py)] {
                                for turn in -2...2 {
                                    let angle = base + Double(turn) * .pi
                                    if abs(angle) <= PaperweightConstants.maximumRoll { angles.append(angle) }
                                }
                            }
                            for angle in angles {
                                side = max(side, abs(px * cos(angle) - py * sin(angle)))
                                let y = px * sin(angle) + py * cos(angle)
                                top = max(top, y); bottom = min(bottom, y)
                            }
                        }
                    }
                }
            }
        }
        let unit = PaperweightConstants.unitsPerPixel
        #expect(side <= PaperweightConstants.boatMargin * unit, "\(kind.title) reaches a side wall")
        #expect(top <= PaperweightConstants.boatHeight * unit, "\(kind.title) reaches the lid")
        #expect(bottom >= -PaperweightConstants.boatDraft * unit, "\(kind.title) reaches the floor")
        #expect(depth <= PaperweightConstants.ZF, "\(kind.title) reaches the front/back glass")
    }

    @Test func decorativeFramesLeaveSettledWaterAlone() {
        guard #available(macOS 14.0, *) else { return }
        let configuration = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 400))
        let bottle = PaperweightBottle(configuration: configuration, shipKind: .steamer)
        bottle.simulation.settle()
        let boat = bottle.simulation.boat, waves = bottle.simulation.waveHeights
        let levels = bottle.simulation.currentLevels
        for _ in 0..<120 { bottle.animateShip(dt: 1.0 / 15, reduceMotion: false) }
        #expect(bottle.simulation.boat == boat)
        #expect(bottle.simulation.waveHeights == waves)
        #expect(bottle.simulation.currentLevels == levels)
    }

    @Test func sailingSpritesPreserveShipProportionsAtThePixelCap() throws {
        guard #available(macOS 14.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        let size = CGSize(width: 360, height: 240)
        let times: [TimeInterval?] = [nil, 0.6]
        for time in times {
            let optionalImage = PaperweightShipImageCache.shared.image(for: .thousandSunny,
                                                                       size: size, scale: 2, animationTime: time)
            let image = try #require(optionalImage)
            let optionalPixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let pixels = try #require(optionalPixels)
            #expect(pixels.width <= 512 && pixels.height <= 512)
            #expect(abs(Double(pixels.width) / Double(pixels.height) - 1.5) < 0.01)
            #expect(image.size == size)
        }
    }

    @Test(arguments: [PaperweightShipKind.sub, .polarTang, .sharkSubmerge, .miniMerry, .steamer, .carrier, .liner])
    func cachedRailFramesDoNotMakeMovingPartsAppearStationary(_ kind: PaperweightShipKind) throws {
        guard #available(macOS 14.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        var poses = Set<Data>()
        for frame in 0..<RailPaperweightShipTiming.frameCount {
            let renderer = ImageRenderer(content: RailPaperweightShipImage(
                kind: kind, animationTime: Double(frame) * RailPaperweightShipTiming.frameDuration
            ))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            poses.insert(png)
        }
        #expect(poses.count >= 3, "\(kind.title) needs distinct poses at the rail's actual sampling rate")
    }

    @Test func hidingAHoveredRailCancelsBothClocksAndRestoresTheStaticShip() async throws {
        let configuration = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 400))
        let motion = RailPaperweightMotion(configuration: configuration)
        motion.update(configuration: configuration, hovered: true, visible: true)
        #expect(motion.shipTime != nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        motion.update(configuration: configuration, hovered: true, visible: false)
        let stopped = motion.frame.curves
        #expect(motion.shipTime == nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(motion.shipTime == nil)
        #expect(motion.frame.curves == stopped)
        motion.update(configuration: configuration, hovered: true, visible: true)
        #expect(motion.shipTime == 0)
        motion.stop()
        #expect(motion.shipTime == nil)
    }

    @Test func theVisibleClockUsesLowFPSAndStopsForVisibilityAndReducedMotion() {
        guard #available(macOS 14.0, *), MTLCreateSystemDefaultDevice() != nil else { return }
        let view = SCNView()
        let renderer = PaperweightSceneRenderer(view: view)
        let configuration = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 400))
        func update(reduceMotion: Bool) {
            renderer.update(configurations: [configuration], front: .storage, selectedLayerID: nil,
                            ships: [.storage: .thousandSunny], command: nil, reduceMotion: reduceMotion,
                            isDark: false, onSelect: { _, _ in }, onSwap: { _ in }, onMovingChanged: { _ in })
        }
        update(reduceMotion: true)
        renderer.setVisible(true)
        #expect(!renderer.hasDrawingClock)
        update(reduceMotion: false)
        #expect(renderer.hasDrawingClock)
        #expect(abs(renderer.frameInterval - 1.0 / 15) < 0.0001)
        renderer.setVisible(false)
        #expect(!renderer.hasDrawingClock)
        renderer.setVisible(true)
        #expect(renderer.hasDrawingClock)
        update(reduceMotion: true)
        #expect(!renderer.hasDrawingClock)
        renderer.setVisible(false)
    }
}
