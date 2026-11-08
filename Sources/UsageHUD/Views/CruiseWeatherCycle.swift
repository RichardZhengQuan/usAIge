import Foundation

struct CruiseWeatherTransition: Equatable, Sendable {
    let from: CruiseWeather
    let to: CruiseWeather
    let progress: Double

    var current: CruiseWeather { progress < 0.5 ? from : to }
}

/// An immutable schedule sampled by the scene's existing visibility clock.
/// Independent bag seeds permit constant-size work after long hidden gaps.
final class CruiseWeatherCycle: Sendable {
    static let shared = CruiseWeatherCycle(seed: UInt64.random(in: .min ... .max),
                                           startTime: ProcessInfo.processInfo.systemUptime)
    static let transitionDuration: TimeInterval = 6

    private static let conditions = CruiseWeather.allCases.filter { $0 != .automatic }
    // Complementary random holds total 270 seconds per pair. A complete bag
    // has a known duration while every individual hold stays in 90...180.
    private static let bagDuration = Double(conditions.count) * (135 + transitionDuration)
    private let seed: UInt64
    private let startTime: TimeInterval

    init(seed: UInt64, startTime: TimeInterval = 0) {
        self.seed = seed
        self.startTime = startTime.isFinite ? startTime : 0
    }

    func sample(at time: TimeInterval) -> CruiseWeatherTransition {
        let delta = time - startTime
        let elapsed = time.isFinite && delta.isFinite ? max(0, delta) : 0
        let number = floor(elapsed / Self.bagDuration)
        // Avoid converting an unbounded elapsed time directly to an integer.
        // Wrapping only changes the schedule after far more than a lifetime.
        let index = UInt64(number.truncatingRemainder(dividingBy: 18_446_744_073_709_551_616.0))
        var remaining = elapsed.truncatingRemainder(dividingBy: Self.bagDuration)
        let bag = conditions(in: index)
        let durations = holds(in: index)

        for position in bag.indices {
            let current = bag[position]
            if remaining < durations[position] {
                return CruiseWeatherTransition(from: current, to: current, progress: 0)
            }
            remaining -= durations[position]
            if remaining < Self.transitionDuration {
                let next = position + 1 < bag.count ? bag[position + 1] : conditions(in: index &+ 1)[0]
                let linear = min(1, max(0, remaining / Self.transitionDuration))
                let eased = linear * linear * (3 - 2 * linear)
                return CruiseWeatherTransition(from: current, to: next, progress: eased)
            }
            remaining -= Self.transitionDuration
        }
        // Floating-point summation can leave a fraction of a picosecond at
        // a bag boundary; continue directly into the next resting condition.
        let next = conditions(in: index &+ 1)[0]
        return CruiseWeatherTransition(from: next, to: next, progress: 0)
    }

    private func conditions(in index: UInt64) -> [CruiseWeather] {
        var bag = shuffledConditions(in: index)
        // Only swap positions before the last one. This leaves the preceding
        // bag's final item knowable without recursively replaying older bags.
        if bag[0] == shuffledConditions(in: index &- 1).last {
            bag.swapAt(0, 1)
        }
        return bag
    }

    private func shuffledConditions(in index: UInt64) -> [CruiseWeather] {
        var random = Random(seed: seed &+ index &* 0xD134_2543_DE82_EF95)
        var bag = Self.conditions
        for position in stride(from: bag.count - 1, through: 1, by: -1) {
            bag.swapAt(position, Int(random.next() % UInt64(position + 1)))
        }
        return bag
    }

    private func holds(in index: UInt64) -> [TimeInterval] {
        var random = Random(seed: (seed ^ 0xA076_1D64_78BD_642F) &+ index &* 0xE703_7ED1_A0B4_28DB)
        var holds = [TimeInterval](repeating: 135, count: Self.conditions.count)
        let half = holds.count / 2
        for position in 0..<half {
            let unit = Double(random.next() >> 11) / 9_007_199_254_740_992.0
            holds[position] = 90 + unit * 90
            holds[position + half] = 270 - holds[position]
        }
        return holds
    }

    /// SplitMix64: deterministic private randomness, independent of Swift's
    /// randomized hashing and of the order in which scenes sample the cycle.
    private struct Random {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}
