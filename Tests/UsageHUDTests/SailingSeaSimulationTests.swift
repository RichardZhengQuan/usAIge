import Foundation
import Testing
@testable import UsageHUD

@Suite struct SailingSeaSimulationTests {
    @Test func aShakenBoatRightsItselfAndReturnsToTheAmbientWaves() {
        for compact in [false, true] {
            let size = compact ? CGSize(width: 84, height: 450) : CGSize(width: 1180, height: 780)
            let shaken = SailingSeaSimulation(), calm = SailingSeaSimulation()
            for sea in [shaken, calm] { sea.configure(size: size, compact: compact, weather: .sunny) }
            shaken.shake(amplitude: 4)
            var maximumRoll = 0.0
            for _ in 0..<720 {
                shaken.step(dt: 1.0 / 60)
                calm.step(dt: 1.0 / 60)
                maximumRoll = max(maximumRoll, abs(shaken.boat.angle))
            }
            #expect(maximumRoll > 0.03)
            #expect(abs(shaken.boat.angle - calm.boat.angle) < 0.01)
            #expect(abs(shaken.boat.y - calm.boat.y) < 0.1)
            #expect(abs(shaken.surface(at: shaken.boat.x) - calm.surface(at: calm.boat.x)) < 0.01)
            expectSafe(shaken, in: size)
        }
    }

    @Test func extremeWeatherAndRepeatedLargeShakesCannotSinkOrCapsizeEitherScene() {
        for weather in [CruiseWeather.storm, .typhoon] {
            for compact in [false, true] {
                let size = compact ? CGSize(width: 80, height: 420) : CGSize(width: 900, height: 320)
                let sea = SailingSeaSimulation()
                sea.configure(size: size, compact: compact, weather: weather)
                for frame in 0..<1_200 {
                    if frame.isMultiple(of: 17) {
                        sea.shake(amplitude: frame.isMultiple(of: 34) ? 1_000_000 : -1_000_000)
                        expectSafe(sea, in: size)
                    }
                    sea.step(dt: 1.0 / 60)
                    if frame.isMultiple(of: 4) { expectSafe(sea, in: size) }
                }
            }
        }
    }

    @Test func weatherTransitionsKeepBuoyancyAndStormHasLargerWaves() {
        let size = CGSize(width: 1080, height: 640)
        let sea = SailingSeaSimulation()
        sea.configure(size: size, compact: false, weather: .sunny)
        let calmRange = surfaceRange(sea, width: size.width)
        sea.configure(size: size, compact: false, weather: .storm)
        #expect(surfaceRange(sea, width: size.width) > calmRange * 2)
        for weather in CruiseWeather.allCases {
            sea.configure(size: size, compact: false, weather: weather)
            expectSafe(sea, in: size)
            for _ in 0..<60 { sea.step(dt: 1.0 / 60) }
            expectSafe(sea, in: size)
        }
    }

    @Test func resizeAndTinyOrInvalidBoundsRemainFiniteAndInsideTheWholeScene() {
        let sea = SailingSeaSimulation()
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 80, height: 24),
                     CGSize(width: 900, height: 300), CGSize(width: 1600, height: 500),
                     CGSize(width: 32, height: 4), CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            for compact in [false, true] {
                sea.configure(size: size, compact: compact, weather: .storm)
                sea.shake(amplitude: 4)
                for _ in 0..<30 { sea.step(dt: 1.0 / 60) }
                if size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 {
                    expectSafe(sea, in: size)
                } else {
                    #expect(sea.shipSize == .zero)
                    #expect(sea.boat.x == 0 && sea.boat.y == 0)
                }
            }
        }
    }

    @Test func invalidTimeAndImpulseInputsCannotChangeTheState() {
        let sea = SailingSeaSimulation()
        sea.configure(size: CGSize(width: 900, height: 300), compact: false, weather: .rain)
        let boat = sea.boat, time = sea.time, water = sea.surface(at: 100)
        for value in [0.0, -1, .nan, .infinity, -.infinity] { sea.step(dt: value) }
        for value in [0.0, .nan, .infinity, -.infinity] { sea.shake(amplitude: value) }
        #expect(sea.boat == boat)
        #expect(sea.time == time)
        #expect(sea.surface(at: 100) == water)
        #expect(sea.surface(at: .nan).isFinite)
        #expect(sea.surface(at: .infinity).isFinite)
        #expect(sea.surface(at: Double.greatestFiniteMagnitude).isFinite)
        sea.step(dt: Double.greatestFiniteMagnitude)
        #expect(sea.time > 0 && sea.time <= 0.251)
    }

    @Test func everyWeatherKeepsTheShipNearTheCenterThroughSeveralGentleDriftCycles() {
        for weather in CruiseWeather.allCases where weather != .automatic {
            for compact in [false, true] {
                let size = compact ? CGSize(width: 84, height: 450) : CGSize(width: 1180, height: 780)
                let sea = SailingSeaSimulation()
                sea.configure(size: size, compact: compact, weather: weather)
                let center = Double(size.width) / 2
                let limit = compact ? 2.5 : 28.0
                #expect(sea.boat.x == center, "A new sailing scene must start with its ship at the center")
                expectSafe(sea, in: size)
                sea.step(dt: 1.0 / 120)
                var previousX = sea.boat.x, previousVelocity = sea.boat.velocityX
                var minimumX = sea.boat.x, maximumX = sea.boat.x
                var lastDirection = sea.boat.velocityX >= 0 ? 1 : -1
                var reversals = 0
                let interval = 0.25
                // Calm and extreme weather span multiple cycles and the old
                // ~82 s main-window wrap. Other conditions cover one full
                // drift cycle without repeating a long physics stress test.
                let longRun = weather == .sunny || weather == .typhoon
                let steps = longRun ? (compact ? 160 : 360) : (compact ? 80 : 160)
                for frame in 0..<steps {
                    sea.step(dt: interval)
                    let x = sea.boat.x, velocity = sea.boat.velocityX
                    minimumX = min(minimumX, x); maximumX = max(maximumX, x)
                    #expect(abs(x - center) <= limit + 0.000_001,
                            "\(weather.title) must keep the \(compact ? "rail" : "window") ship centered")
                    #expect(abs(x - previousX) <= (compact ? 1 : 5) * interval + 0.001,
                            "The ship must drift gently, with no offscreen wrap or teleport")
                    #expect(abs(velocity - previousVelocity) <= (compact ? 0.1 : 0.3),
                            "Direction reversals must decelerate smoothly")
                    #expect(abs((x - previousX) / interval - (velocity + previousVelocity) / 2)
                            < (compact ? 0.01 : 0.05), "Reported velocity must follow the continuous drift")
                    if abs(velocity) > 0.000_01 {
                        let direction = velocity > 0 ? 1 : -1
                        if direction != lastDirection { reversals += 1 }
                        lastDirection = direction
                    }
                    expectHorizontalSpriteInside(sea, in: size)
                    if frame.isMultiple(of: 60) { expectSafe(sea, in: size) }
                    previousX = x; previousVelocity = velocity
                }
                #expect(minimumX < center - limit / 2 && maximumX > center + limit / 2,
                        "The centered ship should still have a small visible drift in both directions")
                #expect(reversals >= (longRun ? 4 : 2),
                        "The scene must reverse gently instead of leaving the view")
                expectSafe(sea, in: size)
            }
        }
    }

    @Test func resizingReanchorsTheDriftToTheNewCenterAndKeepsRolledCornersVisible() {
        for compact in [false, true] {
            let sea = SailingSeaSimulation()
            let sizes = [CGSize(width: 1180, height: 780), CGSize(width: 2400, height: 640),
                         CGSize(width: 900, height: 320), CGSize(width: 320, height: 240),
                         CGSize(width: 84, height: 450), CGSize(width: 32, height: 160),
                         CGSize(width: 16, height: 24), CGSize(width: 1, height: 1)]
            for (index, size) in sizes.enumerated() {
                sea.configure(size: size, compact: compact, weather: .typhoon)
                let limit = min(compact ? 2.5 : 28, Double(size.width) * (compact ? 0.045 : 0.035))
                #expect(abs(sea.boat.x - Double(size.width) / 2) <= limit + 0.000_001,
                        "Resizing must use the new scene center, including narrow and tiny layouts")
                if index == 0 { #expect(sea.boat.x == Double(size.width) / 2) }
                expectSafe(sea, in: size)
                for frame in 0..<80 {
                    if frame.isMultiple(of: 9) {
                        sea.shake(amplitude: frame.isMultiple(of: 18) ? 1_000_000 : -1_000_000)
                    }
                    sea.step(dt: 0.1)
                    #expect(abs(sea.boat.x - Double(size.width) / 2) <= limit + 0.000_001)
                    expectHorizontalSpriteInside(sea, in: size)
                    if frame.isMultiple(of: 10) { expectSafe(sea, in: size) }
                }
                expectSafe(sea, in: size)
            }
        }
    }

    @Test func theSharedWaterSurfaceHasNoSpatialSeams() {
        let sea = SailingSeaSimulation()
        sea.configure(size: CGSize(width: 900, height: 320), compact: false, weather: .storm)
        sea.shake()
        for _ in 0..<20 { sea.step(dt: 1.0 / 60) }
        let wavelength = max(sea.shipSize.width * 2.8, 900 * 0.38)
        for period in [wavelength, wavelength / 1.8, wavelength / 0.75] {
            for multiple in -3...3 {
                let x = period * Double(multiple)
                #expect(abs(sea.surface(at: x - 0.00001) - sea.surface(at: x + 0.00001)) < 0.001)
            }
        }
    }

    @Test func settlingLeavesAnUprightBoatSupportedByTheCurrentWave() {
        let sea = SailingSeaSimulation()
        let size = CGSize(width: 900, height: 320)
        sea.configure(size: size, compact: false, weather: .storm)
        sea.shake(amplitude: 3)
        for _ in 0..<45 { sea.step(dt: 1.0 / 60) }
        let time = sea.time, x = sea.boat.x
        sea.settle()
        #expect(sea.time == time && sea.boat.x == x)
        #expect(sea.boat.angle == 0)
        #expect(sea.boat.velocityX == 0 && sea.boat.velocityY == 0 && sea.boat.angularVelocity == 0)
        expectSafe(sea, in: size)
        var nearestContact = Double.infinity
        for index in 0...128 {
            let offset = sea.shipSize.width * (Double(index) / 128 - 0.5) * 0.8
            nearestContact = min(nearestContact, sea.surface(at: x + offset) - sea.boat.y)
        }
        #expect(nearestContact >= -0.001 && nearestContact < 0.06)
        let settled = sea.boat
        sea.settle()
        #expect(sea.boat == settled)
    }

    private func surfaceRange(_ sea: SailingSeaSimulation, width: Double) -> Double {
        let values = (0...200).map { sea.surface(at: width * Double($0) / 200) }
        return values.max()! - values.min()!
    }

    private func expectSafe(_ sea: SailingSeaSimulation, in size: CGSize, sourceLocation: SourceLocation = #_sourceLocation) {
        let boat = sea.boat
        let isFinite = [boat.x, boat.y, boat.angle, boat.velocityX, boat.velocityY, boat.angularVelocity]
            .allSatisfy { $0.isFinite }
        #expect(isFinite, sourceLocation: sourceLocation)
        #expect(abs(boat.angle) <= PaperweightConstants.maximumRoll + 0.000001, sourceLocation: sourceLocation)
        #expect(boat.y <= sea.surface(at: boat.x) + 0.001, sourceLocation: sourceLocation)
        // Test more points than the simulation samples, including bow/stern.
        for index in 0...256 {
            let offset = sea.shipSize.width * (Double(index) / 256 - 0.5) * 0.8
            let x = boat.x + offset * cos(boat.angle)
            let y = boat.y + offset * sin(boat.angle)
            #expect(y <= sea.surface(at: x) + 0.001, sourceLocation: sourceLocation)
        }
        let top = boat.y - abs(sin(boat.angle)) * sea.shipSize.width * 0.5
            - cos(boat.angle) * sea.shipSize.height * sea.waterlineFraction
        let bottom = boat.y + abs(sin(boat.angle)) * sea.shipSize.width * 0.5
            + cos(boat.angle) * sea.shipSize.height * (1 - sea.waterlineFraction)
        #expect(top >= -0.001 && bottom <= size.height + 0.001, sourceLocation: sourceLocation)
        expectHorizontalSpriteInside(sea, in: size, sourceLocation: sourceLocation)
    }

    private func expectHorizontalSpriteInside(_ sea: SailingSeaSimulation, in size: CGSize,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
        // The picture rotates around its real waterline, not its center, so
        // the mast corners can reach farther sideways than the hull itself.
        let halfWidth = Double(sea.shipSize.width) / 2
        let top = -Double(sea.shipSize.height) * sea.waterlineFraction
        let bottom = Double(sea.shipSize.height) * (1 - sea.waterlineFraction)
        for dx in [-halfWidth, halfWidth] {
            for dy in [top, bottom] {
                let x = sea.boat.x + dx * cos(sea.boat.angle) - dy * sin(sea.boat.angle)
                #expect(x >= -0.001 && x <= Double(size.width) + 0.001,
                        "Every rolled sprite corner must stay horizontally inside the scene",
                        sourceLocation: sourceLocation)
            }
        }
    }
}
