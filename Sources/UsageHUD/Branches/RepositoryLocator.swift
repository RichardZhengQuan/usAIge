import Darwin
import Foundation

struct LocatedRepository: Identifiable, Equatable, Sendable {
    /// The repository's shared .git directory, the same for all its worktrees.
    let commonDirectory: String
    let name: String

    var id: String { commonDirectory }
}

/// Checks the path of every Git pointer before following it. A session path
/// outside Documents can still have its Git metadata in a protected project.
struct RepositoryLocator: Sendable {
    let home: String
    var allowedFolders: [String] = []

    enum PathAccess {
        case allowed(String)
        case locked(String)
        case unavailable
    }

    enum Lookup {
        case found(GitLocation)
        case locked(String)
        case missing
    }

    struct GitLocation {
        let root: String
        let gitDirectory: String
        let commonDirectory: String
        var isLinkedWorktree: Bool { gitDirectory != commonDirectory }
    }

    private static let protectedFolders = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
    static let photoLibraryExtensions = ["photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "migratedaplibrary"]

    static func isPhotoLibraryName(_ name: String) -> Bool {
        photoLibraryExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func containsPhotoLibrary(_ path: String) -> Bool {
        path.split(separator: "/").contains { isPhotoLibraryName(String($0)) }
    }

    /// /tmp and /var are symbolic links, and tools report either spelling.
    static func normalized(_ path: String) -> String {
        for prefix in ["/tmp/", "/var/"] where path.hasPrefix(prefix) { return "/private" + path }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Normalizes spelling for permission comparisons without visiting the file system.
    static func lexicalPath(_ path: String, relativeTo base: String = "/") -> String {
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        var components: [Substring] = []
        for part in absolute.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(part)
            }
        }
        let path = "/" + components.joined(separator: "/")
        if path == "/tmp" || path == "/var" { return "/private" + path }
        return normalized(path)
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func protectedRoot(containing path: String) -> String? {
        let path = lexicalPolicyPath(path)
        let folded = path.lowercased()
        let components = path.split(separator: "/")
        if components.count >= 2, components[0].lowercased() == "volumes" {
            return "/" + components.prefix(2).joined(separator: "/")
        }
        let home = lexicalPolicyPath(home)
        for folder in Self.protectedFolders {
            let root = home + "/" + folder
            if Self.contains(root.lowercased(), folded) { return root }
        }
        return nil
    }

    func isProtected(_ path: String) -> Bool {
        protectedRoot(containing: path) != nil
    }

    func excludesPhotos(at path: String) -> Bool {
        let path = lexicalPolicyPath(path)
        let pictures = lexicalPolicyPath(home) + "/Pictures"
        return Self.contains(pictures.lowercased(), path.lowercased())
            || Self.containsPhotoLibrary(path)
    }

    /// A login shell can report home as its working directory. Treat only
    /// folders narrower than home or its ancestors as workspace candidates.
    func isWorkspacePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let folded = lexicalPolicyPath(path).lowercased()
        return folded != "/volumes"
            && !Self.contains(folded, lexicalPolicyPath(home).lowercased())
            && !excludesPhotos(at: path)
    }

    /// A project grant must be inside a protected location. Choosing home or
    /// Documents itself must never give a background scan access to its projects.
    func protectedProjectPath(_ folder: String) -> String? {
        guard isWorkspacePath(folder) else { return nil }
        let path = lexicalPolicyPath(folder)
        guard let root = protectedRoot(containing: path),
              path.lowercased() != root.lowercased() else { return nil }
        return path
    }

    func isAllowed(_ path: String) -> Bool {
        let path = lexicalPolicyPath(path)
        guard !excludesPhotos(at: path) else { return false }
        return !isProtected(path) || allowedFolders.contains { folder in
            guard let project = protectedProjectPath(folder) else { return false }
            return Self.contains(project, path)
        }
    }

    private func lexicalPolicyPath(_ path: String) -> String {
        let value = Self.lexicalPath(path)
        let dataVolume = "/System/Volumes/Data"
        if value == dataVolume { return "/" }
        return value.hasPrefix(dataVolume + "/") ? String(value.dropFirst(dataVolume.count)) : value
    }

    /// Resolve links one component at a time so a link into Documents is
    /// identified before the app reads its destination.
    func access(to path: String) -> PathAccess {
        guard path.hasPrefix("/") else { return .unavailable }
        let spelling = Self.lexicalPath(path)
        guard !excludesPhotos(at: spelling) else { return .unavailable }
        guard isAllowed(spelling) else { return .locked(spelling) }

        var pending = Array(path.split(separator: "/").reversed())
        var resolved: [Substring] = []
        var links = 0
        while let name = pending.popLast() {
            if name == "." { continue }
            if name == ".." {
                _ = resolved.popLast()
                continue
            }
            let next = "/" + (resolved + [name]).joined(separator: "/")
            guard !excludesPhotos(at: next) else { return .unavailable }
            if !isAllowed(next) {
                // Reaching a chosen project can require crossing its protected parent.
                let destination = Self.lexicalPath(pending.reversed().joined(separator: "/"), relativeTo: next)
                guard Self.contains(Self.lexicalPath(next), destination), isAllowed(destination) else {
                    return .locked(destination)
                }
            }
            var info = stat()
            if lstat(next, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFLNK {
                    links += 1
                    guard links <= 40,
                          let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) else {
                        return .unavailable
                    }
                    if target.hasPrefix("/") { resolved.removeAll() }
                    pending.append(contentsOf: target.split(separator: "/").reversed())
                    continue
                }
            } else if (errno == EACCES || errno == EPERM), isProtected(next) {
                return .locked(Self.lexicalPath(pending.reversed().joined(separator: "/"), relativeTo: next))
            }
            resolved.append(name)
        }
        return .allowed("/" + resolved.joined(separator: "/"))
    }

    /// Suggest the project rather than an internal worktree or Git directory.
    static func projectFolder(of path: String) -> String {
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/", "/.git/"] {
            if let range = path.range(of: marker) { return String(path[..<range.lowerBound]) }
        }
        return path.hasSuffix("/.git") ? String(path.dropLast("/.git".count)) : path
    }

    func locate(folders: some Sequence<String>) -> (repositories: [LocatedRepository], notChecked: [String]) {
        var directories: Set<String> = []
        var checkedDirectories: Set<String> = []
        var notChecked: Set<String> = []
        var seen: Set<String> = []
        for raw in folders {
            let folder = Self.normalized(raw)
            guard seen.insert(folder).inserted else { continue }
            switch lookup(containing: folder) {
            case let .found(location):
                let directory = location.commonDirectory
                guard checkedDirectories.insert(directory).inserted else { continue }
                guard let blocked = lockedWorktrees(in: directory) else { continue }
                if blocked.isEmpty { directories.insert(directory) }
                else { notChecked.formUnion(blocked) }
            case let .locked(path):
                notChecked.insert(Self.projectFolder(of: path))
            case .missing:
                break
            }
        }
        let repositories = directories.sorted().map { directory in
            LocatedRepository(commonDirectory: directory, name: Self.displayName(forCommonDirectory: directory))
        }
        return (repositories, Set(notChecked.compactMap(protectedProjectPath)).sorted())
    }

    static func displayName(forCommonDirectory directory: String) -> String {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        return url.lastPathComponent == ".git"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
    }

    func lookup(containing folder: String, forLiveWork: Bool = false) -> Lookup {
        guard isWorkspacePath(folder) else { return .missing }
        switch access(to: folder) {
        case let .allowed(path):
            // A missing worktree must not inherit the branch of its parent.
            if forLiveWork {
                guard FileManager.default.fileExists(atPath: path),
                      !(isProtected(path) && Self.isManagedByICloud(path)) else { return .missing }
            }
            return lookup(fromResolvedFolder: path)
        case let .locked(path): return .locked(path)
        case .unavailable: return .missing
        }
    }

    private func lookup(fromResolvedFolder folder: String) -> Lookup {
        var root = folder
        for _ in 0..<64 {
            guard isWorkspacePath(root) else { return .missing }
            let dotGit = root + "/.git"
            // Searching parents stops at the edge of the selected folder.
            guard isAllowed(dotGit) else { return .missing }
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                switch access(to: dotGit) {
                case let .allowed(path): return gitLocation(root: root, dotGit: path)
                case let .locked(path): return .locked(path)
                case .unavailable: return .missing
                }
            } else if (errno == EACCES || errno == EPERM), isProtected(dotGit) {
                return .locked(root)
            }
            root = (root as NSString).deletingLastPathComponent
        }
        return .missing
    }

    private func gitLocation(root: String, dotGit: String) -> Lookup {
        var info = stat()
        guard lstat(dotGit, &info) == 0 else { return .missing }
        let directory: String
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            directory = dotGit
        case S_IFREG:
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  text.hasPrefix("gitdir:") else { return .missing }
            let pointer = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pointer.isEmpty else { return .missing }
            switch access(to: Self.absolutePath(pointer, relativeTo: root)) {
            case let .allowed(path): directory = path
            case let .locked(path): return .locked(path)
            case .unavailable: return .missing
            }
        default:
            return .missing
        }

        let commonFile: String
        switch access(to: directory + "/commondir") {
        case let .allowed(path): commonFile = path
        case let .locked(path): return .locked(path)
        case .unavailable: return .missing
        }
        var common = directory
        if let text = try? String(contentsOfFile: commonFile, encoding: .utf8) {
            let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pointer.isEmpty else { return .missing }
            switch access(to: Self.absolutePath(pointer, relativeTo: directory)) {
            case let .allowed(path): common = path
            case let .locked(path): return .locked(path)
            case .unavailable: return .missing
            }
        }
        return .found(GitLocation(root: root, gitDirectory: directory, commonDirectory: common))
    }

    /// Git's worktree listing checks each backlink for prunable entries.
    /// Check the destinations first using only metadata in the shared Git directory.
    private func lockedWorktrees(in directory: String) -> [String]? {
        let worktrees: String
        switch access(to: directory + "/worktrees") {
        case let .allowed(path): worktrees = path
        case let .locked(path): return [Self.projectFolder(of: path)]
        case .unavailable: return nil
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? []
        var locked: [String] = []
        for entry in entries {
            let metadata = worktrees + "/" + entry
            switch access(to: metadata + "/gitdir") {
            case let .allowed(path):
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let pointer = text.trimmingCharacters(in: .newlines)
                switch access(to: Self.absolutePath(pointer, relativeTo: metadata)) {
                case .allowed: break
                case let .locked(blocked): locked.append(Self.projectFolder(of: blocked))
                case .unavailable: return nil
                }
            case let .locked(path): locked.append(Self.projectFolder(of: path))
            case .unavailable: return nil
            }
        }
        return locked
    }

    private static func absolutePath(_ path: String, relativeTo base: String) -> String {
        path.hasPrefix("/") ? path : base + "/" + path
    }

    /// iCloud Drive can hydrate files when read, so it is only listed.
    static func isManagedByICloud(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return true }
        return getxattr(path, "com.apple.file-provider-domain-id", nil, 0, 0, 0) >= 0
    }
}
