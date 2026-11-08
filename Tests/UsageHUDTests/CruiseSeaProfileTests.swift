import Foundation
import Testing
@testable import UsageHUD

@Suite("Weather-driven water")
struct CruiseSeaProfileTests {
    @Test func typhoonRemainsStrongerThanStormInShortAndCompactLayouts() {
        for compact in [false, true] {
            for size in [CGSize(width: 900, height: 200), CGSize(width: 80, height: 120)] {
                func range(_ weather: CruiseWeather) -> Double {
                    let sea = SailingSeaSimulation()
                    sea.configure(size: size, compact: compact, weather: weather)
                    let heights = (0...256).map { sea.surface(at: size.width * Double($0) / 256) }
                    return (heights.max() ?? 0) - (heights.min() ?? 0)
                }
                #expect(range(.typhoon) > range(.storm))
            }
        }
    }

    @Test func theActualWaterSurfaceRespondsToWeather() {
        func swell(_ weather: CruiseWeather) -> Double {
            let sea = SailingSeaSimulation()
            sea.configure(size: CGSize(width: 960, height: 560), compact: false, weather: weather)
            let heights = (0...96).map { sea.surface(at: Double($0) * 10) }
            return (heights.max() ?? 0) - (heights.min() ?? 0)
        }
        let sunny = swell(.sunny), cloudy = swell(.cloudy), rain = swell(.rain), storm = swell(.storm)
        #expect(swell(.typhoon) > storm)
        #expect(swell(.thunder) > rain && swell(.thunder) < storm)
        #expect(storm > rain && rain > cloudy && cloudy > sunny)
        #expect(storm > sunny * 2)
        #expect(swell(.snow) < sunny)
        #expect(swell(.night) < sunny)
    }

    @Test func stormsGenerateFoamWhileCalmConditionsDoNot() {
        #expect(CruiseWeather.typhoon.seaProfile.foam > CruiseWeather.storm.seaProfile.foam)
        #expect(CruiseWeather.storm.seaProfile.foam > CruiseWeather.rain.seaProfile.foam)
        #expect(CruiseWeather.storm.seaProfile.speed > CruiseWeather.sunny.seaProfile.speed)
        #expect(CruiseWeather.storm.seaProfile.choppiness > CruiseWeather.rain.seaProfile.choppiness)
        for weather in [CruiseWeather.sunny, .snow, .night] {
            #expect(weather.seaProfile.foam == 0)
        }
    }

    @Test(arguments: [CruiseWeather.sunny, .cloudy, .rain, .thunder, .storm, .typhoon, .snow, .night])
    func everyConditionHasLiveWaterThatKeepsTheShipAfloat(_ weather: CruiseWeather) {
        let sea = SailingSeaSimulation()
        sea.configure(size: CGSize(width: 960, height: 560), compact: false, weather: weather)
        let before = (0...24).map { sea.surface(at: Double($0) * 40) }
        sea.shake()
        for _ in 0..<240 { sea.step(dt: 1.0 / 120) }
        let after = (0...24).map { sea.surface(at: Double($0) * 40) }
        #expect(before != after)
        #expect(sea.boat.y.isFinite && sea.boat.angle.isFinite)
        #expect(abs(sea.boat.angle) <= PaperweightConstants.maximumRoll)
        #expect(sea.boat.y <= sea.surface(at: sea.boat.x))
    }
}
