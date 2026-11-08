import Foundation

/// Shared sea conditions for the ocean shading and buoyant ship motion.
struct CruiseSeaProfile: Equatable, Sendable {
    let roughness: Float
    let speed: Float
    let choppiness: Float
    let foam: Float

    func interpolated(to other: CruiseSeaProfile, progress: Double) -> CruiseSeaProfile {
        let amount = Float(progress.isFinite ? min(1, max(0, progress)) : 0)
        let value = spectrum + (other.spectrum - spectrum) * amount
        return CruiseSeaProfile(roughness: value.x, speed: value.y, choppiness: value.z, foam: value.w)
    }

    var spectrum: SIMD4<Float> { SIMD4(roughness, speed, choppiness, foam) }
}

extension CruiseWeather {
    var seaProfile: CruiseSeaProfile {
        switch self {
        case .sunny: CruiseSeaProfile(roughness: 0.18, speed: 0.70, choppiness: 0.25, foam: 0)
        case .cloudy: CruiseSeaProfile(roughness: 0.38, speed: 0.90, choppiness: 0.32, foam: 0.08)
        case .rain: CruiseSeaProfile(roughness: 0.60, speed: 1.05, choppiness: 0.37, foam: 0.16)
        case .thunder: CruiseSeaProfile(roughness: 0.78, speed: 1.15, choppiness: 0.45, foam: 0.30)
        case .storm: CruiseSeaProfile(roughness: 1.10, speed: 1.45, choppiness: 0.58, foam: 1)
        case .typhoon: CruiseSeaProfile(roughness: 1.75, speed: 1.90, choppiness: 0.76, foam: 1.20)
        case .snow: CruiseSeaProfile(roughness: 0.08, speed: 0.40, choppiness: 0.16, foam: 0)
        case .automatic, .night: CruiseSeaProfile(roughness: 0.12, speed: 0.50, choppiness: 0.18, foam: 0)
        }
    }
}

extension CruiseWeatherTransition {
    var seaProfile: CruiseSeaProfile { from.seaProfile.interpolated(to: to.seaProfile, progress: progress) }
}
