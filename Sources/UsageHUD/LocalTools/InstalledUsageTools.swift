import AppKit
import Foundation

/// Presence is independent of a provider's sign-in, cached readings, or the
/// user's permission to read credentials. Detection never starts a tool.
enum InstalledUsageTools {
    @MainActor
    static func detect() async -> Set<AIToolID> {
        let applications = AIToolDescriptor.all.compactMap { tool -> AIToolID? in
            guard let url = AIToolLauncher.applicationURL(for: tool),
                  !url.pathComponents.contains(".Trash"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return tool.id
        }
        return await Task.detached(priority: .utility) {
            detected(applications: Set(applications))
        }.value
    }

    static func detected(
        applications: Set<AIToolID>,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [URL]? = nil,
        commandDirectories: [URL]? = nil
    ) -> Set<AIToolID> {
        let fileManager = FileManager.default
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let appFolders = applicationDirectories ?? CodexExecutableResolver.defaultApplicationDirectories(environment: environment)
        var installed = applications
        let names: [AIToolID: [String]] = [
            .windsurf: ["Devin", "Windsurf"], .antigravity: ["Antigravity"],
            .kiro: ["Kiro"], .copilot: ["GitHub Copilot for Xcode"],
            .openCodeGo: ["OpenCode"]
        ]
        for (tool, names) in names where !installed.contains(tool) {
            if appFolders.contains(where: { folder in names.contains { name in
                let app = folder.appendingPathComponent(name + ".app")
                return Bundle(url: app)?.executableURL.map { fileManager.isExecutableFile(atPath: $0.path) } == true
            } }) { installed.insert(tool) }
        }

        let commands: [AIToolID: [String]] = [
            .chatGPT: ["codex"], .claude: ["claude"], .gemini: ["gemini"],
            .cursor: ["cursor", "cursor-agent"], .grok: ["grok"], .windsurf: ["windsurf"],
            .antigravity: ["agy", "antigravity"], .copilot: ["copilot", "gh-copilot"],
            .kiro: ["kiro-cli", "kiro"], .amp: ["amp"], .muse: ["muse"],
            .ohMyPi: ["omp"], .commandCode: ["cmd"], .cline: ["cline"], .openCodeGo: ["opencode"]
        ]
        var directories = commandDirectories ?? LocalCommandLocator.searchDirectories(environment: environment)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if commandDirectories == nil, let home {
            let extras = [".grok/bin", ".opencode/bin", ".amp/bin", ".volta/bin", ".local/share/pnpm"]
            directories += extras.map { home.appendingPathComponent($0) }
            // GUI launches don't inherit the terminal's active Node version.
            let nodeVersions = home.appendingPathComponent(".nvm/versions/node")
            let versions = (try? fileManager.contentsOfDirectory(at: nodeVersions, includingPropertiesForKeys: nil)) ?? []
            directories += versions.map { $0.appendingPathComponent("bin") }
        }
        if commandDirectories == nil, let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            directories.append(URL(fileURLWithPath: grokHome).appendingPathComponent("bin"))
        }
        for (tool, names) in commands where !installed.contains(tool) {
            if directories.contains(where: { folder in names.contains { name in
                let path = folder.appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
            } }) { installed.insert(tool) }
        }

        if let home {
            let extensions: [AIToolID: [String]] = [
                .chatGPT: ["openai.chatgpt"], .claude: ["anthropic.claude-code"],
                .gemini: ["google.geminicodeassist"], .openCodeGo: ["sst-dev.opencode"],
                .copilot: ["github.copilot", "github.copilot-chat"], .cline: ["saoudrizwan.claude-dev", "cline.cline"]
            ]
            for editor in [".vscode", ".vscode-insiders", ".vscode-oss", ".cursor", ".windsurf", ".kiro"] {
                let folder = home.appendingPathComponent(editor + "/extensions")
                guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
                let obsolete = (try? Data(contentsOf: folder.appendingPathComponent(".obsolete")))
                    .flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
                for (tool, identifiers) in extensions where !installed.contains(tool) {
                    if entries.contains(where: { entry in
                        guard obsolete[entry] != true,
                              identifiers.contains(where: { entry.lowercased().hasPrefix($0 + "-") }),
                              fileManager.fileExists(atPath: folder.appendingPathComponent(entry + "/package.json").path)
                        else { return false }
                        return true
                    }) { installed.insert(tool) }
                }
            }
        }
        return installed
    }
}
