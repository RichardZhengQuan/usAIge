import Foundation

/// A remembered visual preference. Resource oceans resolve Automatic from
/// observed conditions; the decorative rail uses its shared weather cycle.
enum CruiseWeather: String, CaseIterable, Identifiable, Sendable {
    case automatic, sunny, cloudy, rain, thunder, storm, typhoon, snow, night

    static let defaultsKey = "usageHUD.cruise.weather.v1"
    static let defaultPreference = CruiseWeather.automatic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .sunny: "Sunny"
        case .cloudy: "Cloudy"
        case .rain: "Rain"
        case .thunder: "Thunder"
        case .storm: "Storm"
        case .typhoon: "Typhoon"
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
        case .thunder: "cloud.bolt.fill"
        case .storm: "cloud.bolt.rain.fill"
        case .typhoon: "hurricane"
        case .snow: "cloud.snow.fill"
        case .night: "moon.stars.fill"
        }
    }

}
