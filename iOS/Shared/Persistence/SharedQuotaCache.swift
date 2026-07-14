import Foundation

public enum SharedAppGroup {
    public static let identifier = "group.com.richardq.usaige"
}

/// App Group cache read by both the iOS app and its WidgetKit extension.
///
/// The app is the cache writer. Atomic file replacement makes concurrent widget
/// reads safe. If the App Group entitlement is unavailable (for example in a
/// preview or unit test), storage falls back to this process's Application
/// Support directory instead of crashing.
public actor SharedQuotaCache {
    public nonisolated let storageURL: URL
    public nonisolated let usesAppGroupContainer: Bool

    public init(
        appGroupIdentifier: String = SharedAppGroup.identifier,
        fallbackDirectoryURL: URL? = nil
    ) {
        let fileManager = FileManager.default
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            usesAppGroupContainer = true
            storageURL = containerURL
                .appendingPathComponent("Library/Application Support/usAIge", isDirectory: true)
                .appendingPathComponent("quota-cache.json", isDirectory: false)
        } else {
            usesAppGroupContainer = false
            storageURL = (fallbackDirectoryURL
                ?? JSONFileStorage.applicationSupportDirectory())
                .appendingPathComponent("quota-cache.json", isDirectory: false)
        }
    }

    /// Loads the last complete state. A missing file represents an empty cache.
    public func load() throws -> QuotaCacheState {
        try JSONFileStorage.load(QuotaCacheState.self, from: storageURL) ?? .empty
    }

    public func save(_ state: QuotaCacheState) throws {
        try JSONFileStorage.save(state, to: storageURL)
    }
}
