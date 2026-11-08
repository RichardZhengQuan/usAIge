import AppKit
import Metal
import Testing
@testable import UsageHUD

/// Checks the boundaries between the shared schedule, native visibility clock,
/// buoyancy, and actual GPU frames. Bag/randomness rules have their own tests.
@Suite("Automatic weather integration")
@MainActor
struct AutomaticWeatherIntegrationTests {
    @Test func twoScenesShareTheSameWeatherWithoutAdvancingTheScheduleTwice() {
        guard #available(macOS 14.0, *) else { return }
        let cycle = CruiseWeatherCycle(seed: 0xA170_8E12)
        let transitionTime = (90...180).map(Double.init).first { cycle.sample(at: $0).from != cycle.sample(at: $0).to } ?? 135
        let clock = AutomaticWeatherTestClock(time: transitionTime)
        let windowScene = automaticWeatherTestView(cycle: cycle, clock: clock)
        let railScene = automaticWeatherTestView(cycle: cycle, clock: clock, compact: true)
        defer { windowScene.stop(); railScene.stop() }
        #expect(windowScene.weatherTransition == cycle.sample(at: clock.time))
        #expect(railScene.weatherTransition == windowScene.weatherTransition)
        #expect(railScene.weatherMix == windowScene.weatherMix)
        #expect(railScene.seaProfile == windowScene.seaProfile)

        for _ in 0..<8 {
            clock.time += 0.25
            windowScene.advanceAnimation(by: 1.0 / 24)
            // Repeated sampling by one owner must not consume another bag item
            // or cause the rail to see a later weather condition.
            windowScene.advanceAnimation(by: 1.0 / 24)
            railScene.advanceAnimation(by: 1.0 / 12)
            #expect(windowScene.weatherTransition == railScene.weatherTransition)
            #expect(windowScene.weatherTransition == cycle.sample(at: clock.time))
            #expect(windowScene.weatherMix == railScene.weatherMix)
            #expect(windowScene.seaProfile == railScene.seaProfile)
        }
    }

    @Test func pauseReducedMotionAndFrozenGalleryKeepTheHeldWeatherThroughLayout() {
        guard #available(macOS 14.0, *) else { return }
        let cycle = CruiseWeatherCycle(seed: 0xFE02_61A4)
        let states = [(active: false, reduced: false, captures: false),
                      (active: true, reduced: true, captures: false),
                      (active: true, reduced: true, captures: true)]
        for state in states {
            let clock = AutomaticWeatherTestClock(time: 140)
            let view = automaticWeatherTestView(cycle: cycle, clock: clock)
            defer { view.stop() }
            let held = view.weatherTransition, heldMix = view.weatherMix, profile = view.seaProfile
            let time = view.animationTime
            let heldReads = clock.reads
            clock.time = 800
            view.configure(active: state.active, compact: false, weather: .automatic, ship: .galleon,
                           showsShip: false, dark: true, reduced: state.reduced, capturesWeather: state.captures)
            view.setFrameSize(CGSize(width: 600, height: 320))
            view.layout()
            let readsAfterLayout = clock.reads
            #expect(readsAfterLayout == heldReads,
                    "Pause, reduced motion, frozen capture and layout must reuse the held weather")
            view.advanceAnimation(by: 0.25)
            #expect(view.weatherTransition == held)
            #expect(view.weatherMix == heldMix)
            #expect(view.seaProfile == profile)
            #expect(view.animationTime == time)
            #expect(clock.reads == readsAfterLayout, "A stopped scene must not sample the automatic schedule")
            #expect(!view.isAnimating)
        }
    }

    @Test func aSceneWithoutAVisibleWindowDoesNotPollAutomaticWeather() {
        guard #available(macOS 14.0, *) else { return }
        let clock = AutomaticWeatherTestClock(time: 0)
        let view = automaticWeatherTestView(cycle: CruiseWeatherCycle(seed: 57), clock: clock)
        defer { view.stop() }
        let held = view.weatherTransition, reads = clock.reads
        clock.time = 500
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!view.isAnimating)
        #expect(clock.reads == reads, "A weather-specific timer must not poll an invisible scene")
        #expect(view.weatherTransition == held)
    }

    @Test func returningAfterALongGapStartsFromTheHeldProfileAndRejoinsTheSharedWeather() throws {
        guard #available(macOS 14.0, *) else { return }
        let cycle = CruiseWeatherCycle(seed: 0x6A9_2026)
        let clock = AutomaticWeatherTestClock(time: 0)
        let view = automaticWeatherTestView(cycle: cycle, clock: clock)
        defer { view.stop() }
        let held = view.weatherTransition, heldMix = view.weatherMix, heldProfile = view.seaProfile
        let candidate = (190...1_000).map(Double.init).first { time in
            let start = cycle.sample(at: time), end = cycle.sample(at: time + 7)
            return start.from == start.to && end.from == end.to
                && start.current == end.current && start.current != held.current
        }
        let resumeTime = try #require(candidate, "Fixture needs a later, different stable condition")
        clock.time = resumeTime
        view.advanceAnimation(by: 1.0 / 24)
        #expect(view.weatherMix == heldMix)
        #expect(view.seaProfile == heldProfile, "Resuming must not instantly replace the water beneath the hull")

        for halfSecond in 1...12 {
            clock.time = resumeTime + Double(halfSecond) * 0.5
            view.advanceAnimation(by: 1.0 / 24)
            if halfSecond == 6 {
                #expect(!automaticWeatherProfilesMatch(view.seaProfile, heldProfile))
                #expect(!automaticWeatherProfilesMatch(view.seaProfile, cycle.sample(at: clock.time).seaProfile))
            }
        }
        #expect(view.weatherTransition.current == cycle.sample(at: clock.time).current)
        #expect(view.weatherMix == CruiseWeatherMix(transition: cycle.sample(at: clock.time)))
        #expect(automaticWeatherProfilesMatch(view.seaProfile, cycle.sample(at: clock.time).seaProfile))
        clock.time += 0.25
        view.advanceAnimation(by: 1.0 / 24)
        #expect(view.weatherTransition == cycle.sample(at: clock.time))
    }

    @Test func resumingAPartialFadePreservesBothHeldSkiesAndBlendsIntoTheSharedTarget() throws {
        guard #available(macOS 14.0, *) else { return }
        let cycle = CruiseWeatherCycle(seed: 0xFAD_E2026)
        let partialTime = stride(from: 90.0, through: 180.0, by: 0.125).first { time in
            let sample = cycle.sample(at: time)
            return sample.from != sample.to && (0.35...0.65).contains(sample.progress)
        }
        let initialTime = try #require(partialTime)
        let clock = AutomaticWeatherTestClock(time: initialTime)
        let view = automaticWeatherTestView(cycle: cycle, clock: clock)
        defer { view.stop() }
        let heldTransition = view.weatherTransition, heldMix = view.weatherMix, heldProfile = view.seaProfile
        let laterTime = (190...2_000).map(Double.init).first { time in
            let start = cycle.sample(at: time), end = cycle.sample(at: time + 7)
            return start.from == start.to && end.from == end.to && start.current == end.current
                && start.current != heldTransition.from && start.current != heldTransition.to
        }
        let resumeTime = try #require(laterTime, "Fixture needs a third weather condition after the pause")
        view.configure(active: false, compact: false, weather: .automatic, ship: .galleon,
                       showsShip: false, dark: false, reduced: false)
        clock.time = resumeTime
        view.configure(active: true, compact: false, weather: .automatic, ship: .galleon,
                       showsShip: false, dark: false, reduced: false)
        view.advanceAnimation(by: 1.0 / 24)
        #expect(view.weatherMix == heldMix, "Resuming midway through a fade must retain both held skies")
        #expect(view.seaProfile == heldProfile)
        for quarterSecond in 1...24 {
            clock.time = resumeTime + Double(quarterSecond) * 0.25
            view.advanceAnimation(by: 1.0 / 24)
            if quarterSecond == 12 {
                let weights = (0..<8).map { view.weatherMix.weights[$0] }
                #expect(weights.filter { $0 > 0.01 }.count == 3,
                        "Recovery must fade the two held skies into the new third sky")
                #expect(abs(weights.reduce(0, +) - 1) < 0.000_001)
                #expect(weights.allSatisfy { $0 >= 0 && $0 <= 1 })
            }
        }
        #expect(view.weatherMix == CruiseWeatherMix(transition: cycle.sample(at: clock.time)))
        #expect(automaticWeatherProfilesMatch(view.seaProfile, cycle.sample(at: clock.time).seaProfile))
    }

    @Test func changingWaveSpeedAfterALongRunDoesNotRotateTheExistingSurface() {
        let sea = SailingSeaSimulation()
        let size = CGSize(width: 960, height: 560)
        let baseline = CruiseWeather.sunny.seaProfile
        sea.configure(size: size, compact: false, weather: .sunny, profile: baseline)
        for _ in 0..<720 { sea.step(dt: 0.25) }
        let locations = (0...48).map { Double($0) * 20 }
        let before = locations.map { sea.surface(at: $0) }
        let oceanTime = sea.oceanTime
        let faster = CruiseSeaProfile(roughness: baseline.roughness, speed: CruiseWeather.typhoon.seaProfile.speed,
                                     choppiness: baseline.choppiness, foam: baseline.foam)
        sea.configure(size: size, compact: false, weather: .sunny, profile: faster)
        #expect(sea.oceanTime == oceanTime)
        #expect(locations.map { sea.surface(at: $0) } == before,
                "Changing speed must affect future motion, rather than multiply 180 seconds by a new speed")
        sea.step(dt: 1.0 / 120)
        let after = locations.map { sea.surface(at: $0) }
        #expect(zip(before, after).allSatisfy { abs($0.0 - $0.1) < 1 },
                "The next small physics step must continue the held waves smoothly")
        #expect(sea.boat.y.isFinite && sea.boat.angle.isFinite)
        #expect(abs(sea.boat.angle) <= PaperweightConstants.maximumRoll)
        #expect(sea.boat.y <= sea.surface(at: sea.boat.x))
    }

    @Test func gpuCrossfadeEndpointsMatchManualWeatherAndTheMiddleBlendsBoth() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no diagnostic")")
        let profile = CruiseWeather.sunny.seaProfile.interpolated(to: CruiseWeather.snow.seaProfile, progress: 0.5)
        for compact in [false, true] {
            for dark in [false, true] {
                let manualSun = try automaticWeatherFrame(renderer, weather: .sunny, profile: profile,
                                                          compact: compact, dark: dark)
                let manualSnow = try automaticWeatherFrame(renderer, weather: .snow, profile: profile,
                                                           compact: compact, dark: dark)
                let beginning = try automaticWeatherFrame(renderer, weather: .automatic, profile: profile,
                    transition: CruiseWeatherTransition(from: .sunny, to: .snow, progress: 0), compact: compact, dark: dark)
                let middle = try automaticWeatherFrame(renderer, weather: .automatic, profile: profile,
                    transition: CruiseWeatherTransition(from: .sunny, to: .snow, progress: 0.5), compact: compact, dark: dark)
                let end = try automaticWeatherFrame(renderer, weather: .automatic, profile: profile,
                    transition: CruiseWeatherTransition(from: .sunny, to: .snow, progress: 1), compact: compact, dark: dark)
                #expect(beginning == manualSun)
                #expect(end == manualSnow)
                #expect(automaticWeatherChangedBytes(middle, beginning) > 100)
                #expect(automaticWeatherChangedBytes(middle, end) > 100)
            }
        }
    }

    @Test func lightningSuppressionAppliesToBothCrossfadeDirections() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no diagnostic")")
        for sample in [CruiseWeatherTransition(from: .thunder, to: .snow, progress: 0.5),
                       CruiseWeatherTransition(from: .snow, to: .thunder, progress: 0.5)] {
            let strike = try automaticWeatherFrame(renderer, weather: .automatic, profile: sample.seaProfile,
                                                   transition: sample, time: 2, lightning: true)
            let disabled = try automaticWeatherFrame(renderer, weather: .automatic, profile: sample.seaProfile,
                                                     transition: sample, time: 2, lightning: false)
            #expect(automaticWeatherChangedBytes(strike, disabled) > 100)
            let rest = try automaticWeatherFrame(renderer, weather: .automatic, profile: sample.seaProfile,
                                                 transition: sample, time: 0, lightning: true)
            let disabledRest = try automaticWeatherFrame(renderer, weather: .automatic, profile: sample.seaProfile,
                                                         transition: sample, time: 0, lightning: false)
            #expect(rest == disabledRest)
        }
    }

    @Test func gpuRecoveryRetainsTheExactPartialFadeBeforeIntroducingTheNewSky() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no diagnostic")")
        let heldTransition = CruiseWeatherTransition(from: .sunny, to: .storm, progress: 0.4)
        let heldMix = CruiseWeatherMix(transition: heldTransition)
        let target = CruiseWeatherTransition(from: .snow, to: .snow, progress: 0)
        let targetMix = CruiseWeatherMix(transition: target)
        let original = try automaticWeatherFrame(renderer, weather: .automatic, profile: heldMix.seaProfile,
                                                 transition: heldTransition)
        // The shared schedule has changed, but an explicit saved mixture must
        // still reproduce both old skies exactly on the first resumed frame.
        let resumed = try automaticWeatherFrame(renderer, weather: .automatic, profile: heldMix.seaProfile,
                                                transition: target, mix: heldMix)
        #expect(original == resumed)
        let middleMix = heldMix.interpolated(to: targetMix, progress: 0.5)
        let middle = try automaticWeatherFrame(renderer, weather: .automatic, profile: middleMix.seaProfile,
                                               transition: target, mix: middleMix)
        let final = try automaticWeatherFrame(renderer, weather: .snow, profile: targetMix.seaProfile,
                                              transition: target, mix: targetMix)
        #expect(automaticWeatherChangedBytes(middle, resumed) > 100)
        #expect(automaticWeatherChangedBytes(middle, final) > 100)
    }
}

@MainActor
private final class AutomaticWeatherTestClock {
    var time: TimeInterval
    var reads = 0
    init(time: TimeInterval) { self.time = time }
    func now() -> TimeInterval { reads += 1; return time }
}

@available(macOS 14.0, *)
@MainActor
private func automaticWeatherTestView(cycle: CruiseWeatherCycle, clock: AutomaticWeatherTestClock,
                                      compact: Bool = false) -> UsageAtmosphereView {
    let size = compact ? CGSize(width: 80, height: 192) : CGSize(width: 640, height: 360)
    let view = UsageAtmosphereView(frame: CGRect(origin: .zero, size: size))
    view.weatherCycle = cycle
    view.weatherNow = { clock.now() }
    view.configure(active: true, compact: compact, weather: .automatic, ship: .galleon,
                   showsShip: false, dark: false, reduced: false)
    return view
}

private func automaticWeatherProfilesMatch(_ left: CruiseSeaProfile, _ right: CruiseSeaProfile) -> Bool {
    zip([left.roughness, left.speed, left.choppiness, left.foam],
        [right.roughness, right.speed, right.choppiness, right.foam]).allSatisfy { abs($0.0 - $0.1) < 0.000_01 }
}

@available(macOS 14.0, *)
@MainActor
private func automaticWeatherFrame(_ renderer: CruiseWeatherRenderer, weather: CruiseWeather,
                                   profile: CruiseSeaProfile, transition: CruiseWeatherTransition? = nil,
                                   mix: CruiseWeatherMix? = nil,
                                   time: TimeInterval = 1.3, lightning: Bool = false,
                                   compact: Bool = false, dark: Bool = false) throws -> Data {
    let optionalImage = renderer.snapshot(size: CGSize(width: 128, height: 96), time: time,
                                         weather: weather, dark: dark, compact: compact,
                                         lightningEnabled: lightning, transition: transition,
                                         seaProfile: profile, oceanTime: 123.45, mix: mix)
    let image = try #require(optionalImage)
    var bytes = Data(count: image.width * image.height * 4)
    let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    try #require(drew)
    return bytes
}

private func automaticWeatherChangedBytes(_ left: Data, _ right: Data) -> Int {
    zip(left, right).reduce(into: 0) { count, pair in if pair.0 != pair.1 { count += 1 } }
}
