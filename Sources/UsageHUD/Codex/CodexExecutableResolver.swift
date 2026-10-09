import Foundation

/// Finds the `codex` executable that serves the local app-server.
///
/// The ChatGPT (Codex) app bundles the CLI. Newer builds ship it as a
/// package under `Contents/Resources/codex-cli` whose `codex-package.json`
/// names the entry point (`bin/codex`); older builds put a bare `codex`
/// binary in `Contents/Resources`. Standalone installs are checked after the
/// apps, then `PATH`.
enum CodexExecutableResolver {
    static let appNames = ["ChatGPT.app", "Codex.app"]

    static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [URL]? = nil
    ) -> URL? {
        let directories = applicationDirectories ?? defaultApplicationDirectories(environment: environment)
        var candidates: [URL] = []
        for directory in directories {
            for name in appNames {
                let resources = directory
                    .appendingPathComponent(name)
                    .appendingPathComponent("Contents/Resources")
                let package = resources.appendingPathComponent("codex-cli")
                if let entrypoint = packageEntrypoint(in: package, fileManager: fileManager) {
                    candidates.append(entrypoint)
                }
                candidates.append(package.appendingPathComponent("bin/codex"))
                candidates.append(resources.appendingPathComponent("codex"))
            }
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("codex"))
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func defaultApplicationDirectories(environment: [String: String]) -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications")]
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(URL(fileURLWithPath: home).appendingPathComponent("Applications"))
        }
        return directories
    }

    /// The entry point a `codex-cli` package declares, kept inside the package.
    static func packageEntrypoint(in package: URL, fileManager: FileManager) -> URL? {
        let manifest = package.appendingPathComponent("codex-package.json")
        guard let data = fileManager.contents(atPath: manifest.path),
              let entrypoint = JSONValue.parse(data)?["entrypoint"]?.stringValue,
              !entrypoint.isEmpty, !entrypoint.hasPrefix("/") else { return nil }
        let root = package.standardizedFileURL.path
        let resolved = package.appendingPathComponent(entrypoint).standardizedFileURL
        guard resolved.path.hasPrefix(root + "/") else { return nil }
        return resolved
    }
}
