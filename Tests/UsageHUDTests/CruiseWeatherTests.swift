import Testing
@testable import UsageHUD

@Suite struct CruiseWeatherTests {
    @Test func automaticIsTheFirstAndDefaultPreference() {
        #expect(CruiseWeather.allCases.first == .automatic)
        #expect(CruiseWeather.defaultPreference == .automatic)
        #expect(CruiseWeather.automatic.title == "Automatic")
    }

    @Test func automaticFollowsActivityTransitions() {
        let preference = CruiseWeather.automatic
        let transitions: [(CodexAgentPhase, CruiseWeather)] = [
            (.idle, .night), (.thinking, .cloudy), (.needsInput, .rain),
            (.error, .storm), (.thinking, .cloudy), (.complete, .sunny), (.idle, .night),
        ]
        for (phase, expected) in transitions {
            #expect(preference.resolved(phases: [phase]) == expected)
        }
        #expect(preference == .automatic)
    }

    @Test func urgentActivityWinsRegardlessOfToolOrder() {
        let preference = CruiseWeather.automatic
        #expect(preference.resolved(phases: [.complete, .idle]) == .sunny)
        #expect(preference.resolved(phases: [.complete, .thinking]) == .cloudy)
        #expect(preference.resolved(phases: [.thinking, .needsInput, .complete]) == .rain)
        #expect(preference.resolved(phases: [.complete, .thinking, .needsInput, .error]) == .storm)
        #expect(preference.resolved(phases: [.error, .needsInput, .thinking, .complete]) == .storm)
    }

    @Test func noActivityAndIdleActivityUseNight() {
        #expect(CruiseWeather.automatic.resolved(phases: []) == .night)
        #expect(CruiseWeather.automatic.resolved(phases: [.idle, .idle]) == .night)
    }

    @Test func rememberedManualWeatherSurvivesActivityChanges() {
        let scenarios: [[CodexAgentPhase]] = [[], [.idle], [.thinking], [.needsInput], [.error], [.complete]]
        for manual in CruiseWeather.allCases where manual != .automatic {
            let restored = CruiseWeather(rawValue: manual.rawValue)
            #expect(restored == manual)
            for phases in scenarios {
                #expect(restored?.resolved(phases: phases) == manual)
            }
        }
    }
}
