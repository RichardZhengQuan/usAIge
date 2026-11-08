import Foundation
import Testing
@testable import UsageHUD

@Suite struct CruiseWeatherCycleTests {
    @Test func seededSamplesAreIndependentOfSamplingHistory() {
        let first = CruiseWeatherCycle(seed: 0xCAFE, startTime: 400)
        let second = CruiseWeatherCycle(seed: 0xCAFE, startTime: 400)
        let times = [400.0, 430, 510, 580, 800, 1_600, 10_000, 1_000_000_000]
        let expected = times.map { first.sample(at: $0) }
        for time in times.reversed() { _ = second.sample(at: time) }
        #expect(times.map { second.sample(at: $0) } == expected)
        let different = CruiseWeatherCycle(seed: 0xBEEF, startTime: 400)
        #expect(times.map { different.sample(at: $0) } != expected)
    }

    @Test func theFirstConditionRestsImmediately() {
        let cycle = CruiseWeatherCycle(seed: 73, startTime: 1_000)
        let first = cycle.sample(at: 1_000)
        #expect(first.from == first.to)
        #expect(first.progress == 0)
        #expect(first.current != .automatic)
        #expect(cycle.sample(at: 1_089) == first)
    }

    @Test func everyShuffledBagContainsAllEightWithoutEdgeRepeats() throws {
        let expected = Set(CruiseWeather.allCases.filter { $0 != .automatic }.map(\.rawValue))
        for seed in [0, 1, 72, UInt64.max] {
            let cycle = CruiseWeatherCycle(seed: seed)
            var sequence: [CruiseWeather] = []
            for time in stride(from: 0.0, to: 3_384, by: 0.5) {
                let condition = cycle.sample(at: time).current
                if sequence.last != condition { sequence.append(condition) }
            }
            try #require(sequence.count >= 24)
            for start in stride(from: 0, to: 24, by: 8) {
                #expect(Set(sequence[start..<(start + 8)].map(\.rawValue)) == expected)
            }
            for time in stride(from: 0.0, to: 3_384, by: 1) {
                let transition = cycle.sample(at: time)
                if transition.progress > 0 {
                    #expect(transition.from != transition.to)
                }
            }
        }
    }

    @Test func holdsLastNinetyToOneHundredEightySecondsBetweenSixSecondTransitions() throws {
        let cycle = CruiseWeatherCycle(seed: 54)
        let starts = transitionStarts(cycle, until: 5_000)
        try #require(starts.count > 24)
        #expect(starts[0] >= 90 && starts[0] <= 180)
        for (previous, next) in zip(starts, starts.dropFirst()) {
            let hold = next - previous - CruiseWeatherCycle.transitionDuration
            #expect(hold >= 90 - 0.000001 && hold <= 180 + 0.000001)
        }
        // Different holds confirm that the schedule is not a fixed cadence.
        #expect(Set(starts.dropFirst().enumerated().map { Int(($0.element - starts[$0.offset]).rounded()) }).count > 4)
    }

    @Test func transitionEndpointsAreContinuousAndEased() throws {
        let cycle = CruiseWeatherCycle(seed: 97)
        let start = try #require(transitionStarts(cycle, until: 200).first)
        let epsilon = 0.00001
        let before = cycle.sample(at: start - epsilon)
        let beginning = cycle.sample(at: start + epsilon)
        let quarter = cycle.sample(at: start + 1.5)
        let midpoint = cycle.sample(at: start + 3)
        let ending = cycle.sample(at: start + 6 - epsilon)
        let after = cycle.sample(at: start + 6 + epsilon)
        #expect(before.from == before.to && before.progress == 0)
        #expect(beginning.from == before.current)
        #expect(beginning.progress >= 0 && beginning.progress < 0.000001)
        #expect(abs(quarter.progress - 0.15625) < 0.000001)
        #expect(abs(midpoint.progress - 0.5) < 0.000001)
        #expect(ending.progress > 0.999999 && ending.progress <= 1)
        #expect(after.from == ending.to && after.to == ending.to && after.progress == 0)
        #expect(beginning.current == beginning.from)
        #expect(ending.current == ending.to)
    }

    @Test func invalidBackwardAndVeryLargeTimesRemainSafe() {
        let cycle = CruiseWeatherCycle(seed: 8, startTime: 100)
        let initial = cycle.sample(at: 100)
        for time in [-Double.infinity, Double.infinity, Double.nan, -100, 0, 99] {
            #expect(cycle.sample(at: time) == initial)
        }
        _ = cycle.sample(at: 10_000)
        #expect(cycle.sample(at: 120) == CruiseWeatherCycle(seed: 8, startTime: 100).sample(at: 120))
        for time in [1e12, 1e100, Double.greatestFiniteMagnitude] {
            let sample = cycle.sample(at: time)
            #expect(sample.from != .automatic && sample.to != .automatic)
            #expect(sample.progress.isFinite && sample.progress >= 0 && sample.progress <= 1)
        }
        #expect(CruiseWeatherCycle(seed: 8, startTime: .nan).sample(at: 0)
                == CruiseWeatherCycle(seed: 8).sample(at: 0))
    }

    private func transitionStarts(_ cycle: CruiseWeatherCycle, until end: Double) -> [Double] {
        var starts: [Double] = []
        var wasTransitioning = false
        for time in stride(from: 0.0, through: end, by: 0.5) {
            let sample = cycle.sample(at: time)
            let transitioning = sample.from != sample.to
            if transitioning && !wasTransitioning {
                var lower = max(0, time - 0.5), upper = time
                for _ in 0..<32 {
                    let middle = (lower + upper) / 2
                    if cycle.sample(at: middle).from == cycle.sample(at: middle).to {
                        lower = middle
                    } else {
                        upper = middle
                    }
                }
                starts.append(upper)
            }
            wasTransitioning = transitioning
        }
        return starts
    }
}
