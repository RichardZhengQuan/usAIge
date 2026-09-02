import AppKit
import Foundation

/// The vendors' own marks, shipped in `Contents/Resources/ToolMarks` as
/// white-on-transparent PNGs and drawn as template images so they take the
/// current text color like the app-provided ChatGPT template does.
enum BundledToolMark {
    static let directoryName = "ToolMarks"
    static let environmentKey = "USAIGE_TOOL_MARKS_DIR"

    nonisolated(unsafe) private static var cache: [AIToolID: NSImage?] = [:]
    private static let lock = NSLock()

    static func fileName(for id: AIToolID) -> String? {
        switch id {
        case .claude, .cursor, .grok: "\(id.rawValue).png"
        default: nil
        }
    }

    /// Search order: an explicit directory from the environment (tests and
    /// `swift run`), then the app bundle's resources.
    static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> [URL] {
        var directories: [URL] = []
        if let override = environment[environmentKey], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = bundle.resourceURL {
            directories.append(resources.appendingPathComponent(directoryName, isDirectory: true))
        }
        return directories
    }

    static func url(
        for id: AIToolID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let fileName = fileName(for: id) else { return nil }
        return searchDirectories(environment: environment, bundle: bundle)
            .map { $0.appendingPathComponent(fileName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    static func image(for id: AIToolID) -> NSImage? {
        lock.lock()
        if let cached = cache[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let image = url(for: id).flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        lock.lock()
        cache[id] = image
        lock.unlock()
        return image
    }
}
