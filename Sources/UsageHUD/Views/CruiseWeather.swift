import Foundation

/// A remembered visual setting for the ships, independent of local forecasts.
enum CruiseWeather: String, CaseIterable, Identifiable, Sendable {
    case automatic, sunny, cloudy, rain, storm, snow, night

    static let defaultsKey = "usageHUD.cruise.weather.v1"
    static let defaultPreference = CruiseWeather.automatic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .sunny: "Sunny"
        case .cloudy: "Cloudy"
        case .rain: "Rain"
        case .storm: "Storm"
        case .snow: "Snow"
        case .night: "Night"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "sparkles"
        case .sunny: "sun.max.fill"
        case .cloudy: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .storm: "cloud.bolt.rain.fill"
        case .snow: "cloud.snow.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// A manual choice stays selected while automatic weather follows the
    /// most urgent activity reported by the app's existing agent store.
    func resolved(phases: [CodexAgentPhase]) -> CruiseWeather {
        guard self == .automatic else { return self }
        if phases.contains(.error) { return .storm }
        if phases.contains(.needsInput) { return .rain }
        if phases.contains(.thinking) { return .cloudy }
        if phases.contains(.complete) { return .sunny }
        return .night
    }
}
