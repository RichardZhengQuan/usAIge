import Foundation
import Testing
@testable import UsageHUD

@Suite("Weather-driven water")
struct CruiseSeaProfileTests {
    @Test func theActualWaterSurfaceRespondsToWeather() {
        func swell(_ weather: CruiseWeather) -> Double {
            let sea = SailingSeaSimulation()
            sea.configure(size: CGSize(width: 960, height: 560), compact: false, weather: weather)
            let heights = (0...96).map { sea.surface(at: Double($0) * 10) }
            return (heights.max() ?? 0) - (heights.min() ?? 0)
        }
        let sunny = swell(.sunny), cloudy = swell(.cloudy), rain = swell(.rain), storm = swell(.storm)
        #expect(storm > rain && rain > cloudy && cloudy > sunny)
        #expect(storm > sunny * 2)
        #expect(swell(.snow) < sunny)
        #expect(swell(.night) < sunny)
    }

    @Test func stormsGenerateFoamWhileCalmConditionsDoNot() {
        #expect(CruiseWeather.storm.seaProfile.foam > CruiseWeather.rain.seaProfile.foam)
        #expect(CruiseWeather.storm.seaProfile.speed > CruiseWeather.sunny.seaProfile.speed)
        #expect(CruiseWeather.storm.seaProfile.choppiness > CruiseWeather.rain.seaProfile.choppiness)
        for weather in [CruiseWeather.sunny, .snow, .night] {
            #expect(weather.seaProfile.foam == 0)
        }
    }

    @Test(arguments: [CruiseWeather.sunny, .cloudy, .rain, .storm, .snow, .night])
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
