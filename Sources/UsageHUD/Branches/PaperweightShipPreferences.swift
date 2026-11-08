import Foundation

/// The rail and Branches window read the same choices without keeping a
/// Branches store, scanner or window alive just for the rail.
enum PaperweightShipPreferences {
    static let memoryKey = "usageHUD.branches.memoryShip.v1"
    static let storageKey = "usageHUD.branches.storageShip.v1"

    static func key(for paperweight: PaperweightID) -> String {
        paperweight == .memory ? memoryKey : storageKey
    }

    static func defaultShip(for paperweight: PaperweightID) -> PaperweightShipKind {
        paperweight == .memory ? .sailboat : .galleon
    }

    static func ship(for paperweight: PaperweightID, defaults: UserDefaults = .standard) -> PaperweightShipKind {
        defaults.string(forKey: key(for: paperweight))
            .flatMap(PaperweightShipKind.init(rawValue:)) ?? defaultShip(for: paperweight)
    }

    static func set(_ ship: PaperweightShipKind, for paperweight: PaperweightID, defaults: UserDefaults = .standard) {
        defaults.set(ship.rawValue, forKey: key(for: paperweight))
    }
}
