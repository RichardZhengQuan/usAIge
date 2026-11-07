import Darwin
import Foundation

struct LocatedRepository: Identifiable, Equatable, Sendable {
    /// The repository's shared `.git` directory, the same for all its worktrees.
    let commonDirectory: String
    let name: String

    var id: String { commonDirectory }
}

/// Finds repositories from working folders by reading `.git` pointers, with
/// no git process. Folders macOS protects are not touched until the person
/// asks: reading one can prompt, and iCloud can hang or start downloads.
struct RepositoryLocator: Sendable {
    let home: String
    var allowedFolders: [String] = []

    private static let protectedLocations = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"]

    /// `/tmp` and `/var` are symbolic links, and tools report either spelling.
    static func normalized(_ path: String) -> String {
        for prefix in ["/tmp/", "/var/"] where path.hasPrefix(prefix) { return "/private" + path }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    func isProtected(_ path: String) -> Bool {
        Self.protectedLocations.contains { Self.contains(home + "/" + $0, path) }
    }

    func isAllowed(_ path: String) -> Bool {
        !isProtected(path) || allowedFolders.contains { Self.contains(RepositoryLocator.normalized($0), path) }
    }

    /// The folder to offer when asking about a protected path: the project,
    /// not one of the many worktrees an AI tool keeps inside it.
    static func projectFolder(of path: String) -> String {
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/"] {
            if let range = path.range(of: marker) { return String(path[..<range.lowerBound]) }
        }
        return path
    }

    func locate(folders: some Sequence<String>) -> (repositories: [LocatedRepository], notChecked: [String]) {
        var directories: Set<String> = []
        var notChecked: Set<String> = []
        var seen: Set<String> = []
        for raw in folders {
            let folder = Self.normalized(raw)
            guard seen.insert(folder).inserted else { continue }
            guard isAllowed(folder) else {
                notChecked.insert(Self.projectFolder(of: folder))
                continue
            }
            if let directory = Self.commonDirectory(containing: folder) { directories.insert(directory) }
        }
        let repositories = directories.sorted().map { directory in
            LocatedRepository(commonDirectory: directory, name: Self.displayName(forCommonDirectory: directory))
        }
        return (repositories, notChecked.sorted())
    }

    static func displayName(forCommonDirectory directory: String) -> String {
        let url = URL(fileURLWithPath: directory)
        return url.lastPathComponent == ".git"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
    }

    /// Walks up from a folder to its repository's shared `.git` directory.
    static func commonDirectory(containing folder: String) -> String? {
        var current = folder
        for _ in 0..<64 {
            let dotGit = current + "/.git"
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFDIR { return dotGit }
                if info.st_mode & S_IFMT == S_IFREG { return commonDirectory(fromPointerFile: dotGit) }
            }
            guard current != "/", !current.isEmpty else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// A worktree's `.git` is a file naming its private directory, and that
    /// directory's `commondir` names the shared one.
    private static func commonDirectory(fromPointerFile path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              contents.hasPrefix("gitdir:") else { return nil }
        let pointer = contents.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (path as NSString).deletingLastPathComponent
        let gitDirectory = resolved(pointer, relativeTo: base)
        guard let common = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8) else {
            return gitDirectory
        }
        return resolved(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory)
    }

    private static func resolved(_ path: String, relativeTo base: String) -> String {
        let full = path.hasPrefix("/") ? path : base + "/" + path
        return normalized((full as NSString).standardizingPath)
    }

    /// iCloud Drive marks the items it manages; reading one can start a
    /// download, so such folders only get a listing, never a status or a size.
    static func isManagedByICloud(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return true }
        return getxattr(path, "com.apple.file-provider-domain-id", nil, 0, 0, 0) >= 0
    }
}
