import Foundation

enum ToolStorageKind: String, Codable, Sendable {
    case rebuildable, history, runtime, review

    var label: String {
        switch self {
        case .rebuildable: "Rebuildable"
        case .history: "Your history"
        case .runtime: "Tool runtime"
        case .review: "Review first"
        }
    }
}

struct ToolStorageEntry: Identifiable, Codable, Equatable, Sendable {
    let name: String
    let path: String?
    let bytes: Int64
    let kind: ToolStorageKind

    var id: String { name }
}

/// What AI tools and developer tools keep on this Mac outside any repository.
/// The window only shows these; usAIge never clears any of them.
enum ToolStorageScanner {
    struct CatalogItem: Sendable {
        let name: String
        let relativePath: String
        let kind: ToolStorageKind
    }

    static let minimumShownBytes: Int64 = 10 * 1024 * 1024

    static let catalog: [CatalogItem] = [
        .init(name: "Claude Code transcripts", relativePath: ".claude/projects", kind: .history),
        .init(name: "Claude Code file history", relativePath: ".claude/file-history", kind: .history),
        .init(name: "Claude Code versions", relativePath: ".local/share/claude/versions", kind: .runtime),
        .init(name: "Claude VM bundles", relativePath: "Library/Application Support/Claude/vm_bundles", kind: .runtime),
        .init(name: "Claude app caches", relativePath: "Library/Application Support/Claude/Cache", kind: .rebuildable),
        .init(name: "Claude app code cache", relativePath: "Library/Application Support/Claude/Code Cache", kind: .rebuildable),
        .init(name: "Codex sessions", relativePath: ".codex/sessions", kind: .history),
        .init(name: "Codex archived sessions", relativePath: ".codex/archived_sessions", kind: .history),
        .init(name: "Codex thread history", relativePath: ".codex/thread_history_1.sqlite", kind: .history),
        .init(name: "Codex state", relativePath: ".codex/state_5.sqlite", kind: .history),
        .init(name: "Codex generated images", relativePath: ".codex/generated_images", kind: .history),
        .init(name: "Codex visualizations", relativePath: ".codex/visualizations", kind: .review),
        .init(name: "Codex packages", relativePath: ".codex/packages", kind: .runtime),
        .init(name: "Codex plugins", relativePath: ".codex/plugins", kind: .runtime),
        .init(name: "Cursor app data", relativePath: "Library/Application Support/Cursor", kind: .review),
        .init(name: "Cursor projects and extensions", relativePath: ".cursor", kind: .review),
        .init(name: "Grok Build", relativePath: ".grok", kind: .review),
        .init(name: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", kind: .rebuildable),
        .init(name: "Xcode device support", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", kind: .rebuildable),
        .init(name: "Simulator devices", relativePath: "Library/Developer/CoreSimulator/Devices", kind: .review),
        .init(name: "Simulator caches", relativePath: "Library/Developer/CoreSimulator/Caches", kind: .rebuildable),
        .init(name: "SwiftPM cache", relativePath: "Library/Caches/org.swift.swiftpm", kind: .rebuildable),
        .init(name: "npm cache", relativePath: ".npm", kind: .rebuildable),
        .init(name: "pnpm store", relativePath: "Library/pnpm", kind: .rebuildable),
        .init(name: "Shared ~/.cache folder", relativePath: ".cache", kind: .rebuildable),
        .init(name: "Go build cache", relativePath: "Library/Caches/go-build", kind: .rebuildable),
        .init(name: "Go modules", relativePath: "go/pkg/mod", kind: .rebuildable),
        .init(name: "pip cache", relativePath: "Library/Caches/pip", kind: .rebuildable),
        .init(name: "uv cache", relativePath: ".local/share/uv", kind: .rebuildable),
        .init(name: "Homebrew cache", relativePath: "Library/Caches/Homebrew", kind: .rebuildable),
        .init(name: "Playwright browsers", relativePath: "Library/Caches/ms-playwright", kind: .rebuildable),
    ]

    static func scan(home: URL) async -> [ToolStorageEntry] {
        var entries: [ToolStorageEntry] = []
        for item in catalog {
            if Task.isCancelled { return entries }
            let url = home.appendingPathComponent(item.relativePath)
            guard FileManager.default.fileExists(atPath: url.path),
                  let bytes = await FolderSizer.bytes(of: url.path) else { continue }
            entries.append(ToolStorageEntry(name: item.name, path: url.path, bytes: bytes, kind: item.kind))
        }
        entries.append(contentsOf: await simulatorRuntimes())
        return displayOrder(entries)
    }

    static func displayOrder(_ entries: [ToolStorageEntry]) -> [ToolStorageEntry] {
        entries.filter { $0.bytes >= minimumShownBytes }.sorted { $0.bytes > $1.bytes }
    }

    private static func simulatorRuntimes() async -> [ToolStorageEntry] {
        // Only ask once they exist: `xcrun` offers to install tools otherwise.
        guard FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator") else { return [] }
        let output = await CommandRunner.run(
            ShellCommand(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "runtime", "list", "-j"]
            ),
            timeout: 30
        )
        guard output.succeeded else { return [] }
        return simulatorRuntimes(fromListJSON: output.stdout)
    }

    static func simulatorRuntimes(fromListJSON data: Data) -> [ToolStorageEntry] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(runtimes) = value else { return [] }
        return runtimes.values.compactMap { runtime -> ToolStorageEntry? in
            guard let identifier = runtime["runtimeIdentifier"]?.stringValue,
                  let bytes = runtime["sizeBytes"]?.numberValue else { return nil }
            return ToolStorageEntry(name: "\(runtimeName(identifier)) simulator runtime", path: nil, bytes: Int64(bytes), kind: .runtime)
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` reads as `iOS 26.5`.
    private static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard let platform = parts.first, parts.count > 1 else { return last }
        return platform + " " + parts.dropFirst().joined(separator: ".")
    }
}
