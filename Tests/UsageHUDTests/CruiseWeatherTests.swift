import Testing
@testable import UsageHUD

@Suite struct CruiseWeatherTests {
    @Test func automaticIsTheFirstAndDefaultPreference() {
        #expect(CruiseWeather.allCases.first == .automatic)
        #expect(CruiseWeather.defaultPreference == .automatic)
        #expect(CruiseWeather.automatic.title == "Automatic")
    }

    @Test func manualWeatherPreferencesRemainCompatible() {
        let conditions: [CruiseWeather] = [.sunny, .cloudy, .rain, .thunder, .storm, .typhoon, .snow, .night]
        #expect(CruiseWeather.allCases.filter { $0 != .automatic } == conditions)
        for condition in conditions {
            #expect(CruiseWeather(rawValue: condition.rawValue) == condition)
            #expect(!condition.title.isEmpty && !condition.symbol.isEmpty)
        }
    }
}
