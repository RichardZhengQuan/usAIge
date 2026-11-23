import SwiftUI

/// How usAIge looks. Modern is the standard look. Classic keeps the liquid
/// paperweights, their ships and Shake for anyone who prefers them.
enum InterfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case modern
    case classic

    /// Kept outside the rail's settings so the rail, the Branches window and
    /// Settings all follow one choice without passing a model around.
    static let defaultsKey = "usageHUD.interfaceStyle.v1"
    static let standard = InterfaceStyle.modern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .classic: "Classic"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> InterfaceStyle {
        defaults.string(forKey: defaultsKey).flatMap(InterfaceStyle.init(rawValue:)) ?? standard
    }
}

private struct InterfaceStyleKey: EnvironmentKey {
    /// Views shared by both looks draw Classic unless a Modern page says so.
    static let defaultValue = InterfaceStyle.classic
}

private struct RowShowsProjectKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var interfaceStyle: InterfaceStyle {
        get { self[InterfaceStyleKey.self] }
        set { self[InterfaceStyleKey.self] = newValue }
    }

    /// Rows under a project's heading leave its name out.
    var rowShowsProject: Bool {
        get { self[RowShowsProjectKey.self] }
        set { self[RowShowsProjectKey.self] = newValue }
    }
}
