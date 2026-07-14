import Foundation

/// App-local persistence for user-defined remote tool endpoints.
public actor ToolConfigurationStore {
    public nonisolated let storageURL: URL

    public init(fileURL: URL? = nil) {
        storageURL = fileURL
            ?? JSONFileStorage.applicationSupportDirectory()
                .appendingPathComponent("remote-tools.json", isDirectory: false)
    }

    /// Loads all configurations. A missing file represents an empty collection.
    public func load() throws -> [RemoteToolConfiguration] {
        let values = try JSONFileStorage.load(
            [RemoteToolConfiguration].self,
            from: storageURL
        ) ?? []

        // Re-run the public initializer so data written by an older build cannot
        // restore a zero or negative refresh interval.
        return values.map {
            RemoteToolConfiguration(
                id: $0.id,
                name: $0.name,
                endpointURL: $0.endpointURL,
                refreshIntervalMinutes: $0.refreshIntervalMinutes,
                isEnabled: $0.isEnabled
            )
        }
    }

    public func save(_ configurations: [RemoteToolConfiguration]) throws {
        let normalized = configurations.map {
            RemoteToolConfiguration(
                id: $0.id,
                name: $0.name,
                endpointURL: $0.endpointURL,
                refreshIntervalMinutes: $0.refreshIntervalMinutes,
                isEnabled: $0.isEnabled
            )
        }
        try JSONFileStorage.save(normalized, to: storageURL)
    }
}
