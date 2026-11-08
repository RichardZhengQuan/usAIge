import Foundation

/// Condition weights preserve the exact visible sky when a paused scene
/// rejoins a shared cycle that continued in another window.
struct CruiseWeatherMix: Equatable, Sendable {
    // Matches the stable weather IDs in the Metal renderer.
    static let conditions: [CruiseWeather] = [.sunny, .cloudy, .rain, .storm, .snow, .night, .thunder, .typhoon]
    let weights: SIMD8<Double>

    init(transition: CruiseWeatherTransition) {
        let amount = transition.progress.isFinite ? min(1, max(0, transition.progress)) : 0
        var values = SIMD8<Double>.zero
        let first = Self.conditions.firstIndex(of: transition.from) ?? 5
        let second = Self.conditions.firstIndex(of: transition.to) ?? 5
        values[first] += 1 - amount
        values[second] += amount
        weights = values
    }

    private init(weights: SIMD8<Double>) { self.weights = weights }

    func interpolated(to other: CruiseWeatherMix, progress: Double) -> CruiseWeatherMix {
        let amount = progress.isFinite ? min(1, max(0, progress)) : 0
        if amount <= 0 { return self }
        if amount >= 1 { return other }
        return CruiseWeatherMix(weights: weights * (1 - amount) + other.weights * amount)
    }

    var seaProfile: CruiseSeaProfile {
        var value = SIMD4<Float>.zero
        for index in Self.conditions.indices {
            value += Self.conditions[index].seaProfile.spectrum * Float(weights[index])
        }
        return CruiseSeaProfile(roughness: value.x, speed: value.y, choppiness: value.z, foam: value.w)
    }
}
