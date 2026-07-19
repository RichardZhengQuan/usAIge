import Foundation

enum AppGroup {
    static let identifier = "group.com.richardq.usaige"
    static let snapshotFileName = "usage-snapshot.json"
    static let widgetKind = "com.richardq.usaige.watch.limits"

    static func snapshotURL(fileManager: FileManager = .default) -> URL {
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) {
            let sharedURL = container.appendingPathComponent(snapshotFileName, isDirectory: false)
            let legacyURL = fallbackSnapshotURL(fileManager: fileManager)
            if !fileManager.fileExists(atPath: sharedURL.path),
               fileManager.fileExists(atPath: legacyURL.path) {
                try? fileManager.copyItem(at: legacyURL, to: sharedURL)
            }
            return sharedURL
        }

        // App Group containers are unavailable in previews and unsigned command-line builds.
        return fallbackSnapshotURL(fileManager: fileManager)
    }

    private static func fallbackSnapshotURL(fileManager: FileManager) -> URL {
        let fallback = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usAIgeWatch", isDirectory: true)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback.appendingPathComponent(snapshotFileName, isDirectory: false)
    }
}
