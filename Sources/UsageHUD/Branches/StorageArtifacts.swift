import Darwin
import Foundation

enum StorageArtifactKind: String, CaseIterable, Sendable {
    case nodeModules, nextCache, xcodeBuild, xcodeIndex, npmCache, claudeCodeCache

    var relativePath: String {
        switch self {
        case .nodeModules: "node_modules"
        case .nextCache: ".next/cache"
        case .xcodeBuild: "Build/Intermediates.noindex"
        case .xcodeIndex: "Index.noindex"
        case .npmCache: ".npm/_cacache"
        case .claudeCodeCache: "Library/Application Support/Claude/Code Cache"
        }
    }

    var title: String {
        switch self {
        case .nodeModules: "npm dependencies"
        case .nextCache: "Next.js cache"
        case .xcodeBuild: "Xcode build intermediates"
        case .xcodeIndex: "Xcode index"
        case .npmCache: "npm download cache"
        case .claudeCodeCache: "Claude code cache"
        }
    }

    var consequence: String {
        switch self {
        case .nodeModules: "Run npm ci to reinstall the packages. Local edits inside this folder are lost."
        case .nextCache: "Next.js rebuilds its cache on the next build."
        case .xcodeBuild: "Xcode rebuilds these files on the next build."
        case .xcodeIndex: "Xcode recreates the index when it opens the project."
        case .npmCache: "npm downloads packages again when it needs them."
        case .claudeCodeCache: "Claude rebuilds this code cache when it runs."
        }
    }

    static let projectKinds: [Self] = [.nodeModules, .nextCache]
    static let xcodeKinds: [Self] = [.xcodeBuild, .xcodeIndex]
    static let homeKinds: [Self] = [.npmCache, .claudeCodeCache]
    static let derivedDataPath = "Library/Developer/Xcode/DerivedData"

    static func isVerifiedProjectOutput(_ path: String, within worktree: String) -> Bool {
        for kind in projectKinds where path.hasSuffix("/" + kind.relativePath) {
            let owner = String(path.dropLast(kind.relativePath.count + 1))
            if RepositoryLocator.contains(worktree, owner), kind.matches(owner: owner) { return true }
        }
        return false
    }

    func matches(owner: String) -> Bool {
        let path = owner + "/" + relativePath
        guard CleanupFileInspection.directory(owner) != nil, CleanupFileInspection.directory(path) != nil else { return false }
        switch self {
        case .nodeModules:
            return Self.matchesNPMPackages(project: owner, modules: path)
        case .nextCache:
            guard let manifest = Self.json(owner + "/package.json") else { return false }
            return ["dependencies", "devDependencies", "optionalDependencies"].contains { key in
                (manifest[key] as? [String: String])?["next"] != nil
            }
        case .xcodeBuild, .xcodeIndex:
            let infoPath = owner + "/info.plist"
            guard let info = CleanupFileInspection.regularFile(infoPath), info.st_size <= 262_144,
                  let data = FileManager.default.contents(atPath: infoPath),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let workspace = plist["WorkspacePath"] as? String else { return false }
            return workspace.hasPrefix("/")
        case .npmCache:
            return Self.hasLayout(path, permitted: ["content-v2", "index-v5", "tmp"], marker: "content-v2")
        case .claudeCodeCache:
            return Self.hasLayout(path, permitted: ["js", "wasm"], marker: "js")
                || Self.hasLayout(path, permitted: ["js", "wasm"], marker: "wasm")
        }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let info = CleanupFileInspection.regularFile(path), info.st_size <= 16 * 1024 * 1024,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hasLayout(_ path: String, permitted: Set<String>, marker: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              names.contains(marker), names.allSatisfy(permitted.contains) else { return false }
        return names.allSatisfy { CleanupFileInspection.directory(path + "/" + $0) != nil }
    }

    private static func matchesNPMPackages(project: String, modules: String) -> Bool {
        guard json(project + "/package.json") != nil,
              let lock = json(project + "/npm-shrinkwrap.json") ?? json(project + "/package-lock.json"),
              let packages = lock["packages"] as? [String: Any],
              let children = try? FileManager.default.contentsOfDirectory(atPath: modules) else { return false }
        let expected = Set(packages.keys)
        let generatedDirectories: Set<String> = [".bin", ".vite", ".vite-temp"]
        for name in children {
            let path = modules + "/" + name
            if name == ".package-lock.json" {
                guard CleanupFileInspection.regularFile(path) != nil else { return false }
                continue
            }
            guard CleanupFileInspection.directory(path) != nil else { return false }
            if generatedDirectories.contains(name) { continue }
            if name.hasPrefix("@") {
                guard let scoped = try? FileManager.default.contentsOfDirectory(atPath: path),
                      scoped.allSatisfy({ expected.contains("node_modules/\(name)/\($0)")
                          && CleanupFileInspection.directory(path + "/" + $0) != nil }) else { return false }
            } else if !expected.contains("node_modules/" + name) {
                return false
            }
        }
        return true
    }

    static func processMayUseStorage(_ name: String, executable: String?) -> Bool {
        let name = name.lowercased()
        let executable = executable?.lowercased() ?? ""
        return projectProcesses.contains(name) || xcodeProcesses.contains(name)
            || executable.contains("/xcode.app/") || executable.contains("/claude.app/")
    }

    private static let projectProcesses: Set<String> = [
        "node", "npm", "npx", "next", "next-server", "bun", "deno", "pnpm", "yarn", "vite"
    ]

    private static let xcodeProcesses: Set<String> = [
        "xcode", "xcodebuild", "xcbuild", "xcbuildservice", "swift", "swift-frontend", "sourcekitservice"
    ]

    func isBusy(_ processes: [WorkProcess], workspace: String, path: String) -> Bool {
        processes.contains { process in
            let folder = CleanupFileInspection.normalized(process.folder)
            if RepositoryLocator.contains(path, folder) { return true }
            let name = process.name.lowercased()
            let executable = process.executablePath?.lowercased() ?? ""
            switch self {
            case .nodeModules, .nextCache:
                return RepositoryLocator.contains(workspace, folder) && Self.projectProcesses.contains(name)
            case .xcodeBuild, .xcodeIndex:
                return Self.xcodeProcesses.contains(name) || executable.contains("/xcode.app/")
            case .npmCache:
                return Self.projectProcesses.contains(name)
            case .claudeCodeCache:
                return name == "claude" || executable.contains("/claude.app/")
            }
        }
    }
}

struct StorageArtifactLocation: Equatable, Sendable {
    let kind: StorageArtifactKind
    let owner: String
    /// The project or worktree root discovered by the scan.
    let workspace: String
    var gitWorktree: String? = nil

    var path: String { owner + "/" + kind.relativePath }

    var title: String {
        if StorageArtifactKind.homeKinds.contains(kind) { return kind.title }
        if isProject, workspace != owner, RepositoryLocator.contains(workspace, owner) {
            let workspaceName = URL(fileURLWithPath: workspace).lastPathComponent
            let projectPath = owner.dropFirst(workspace.count + 1)
            return "\(kind.title) · \(workspaceName)/\(projectPath)"
        }
        let folderName = URL(fileURLWithPath: owner).lastPathComponent
        return "\(kind.title) · \(folderName)"
    }

    var isProject: Bool { StorageArtifactKind.projectKinds.contains(kind) }
}

struct StorageCleanupCandidate: Identifiable, Equatable, Sendable {
    let location: StorageArtifactLocation
    let inspection: CleanupFileInspection

    var id: String { location.path }
    var bytes: Int64 { inspection.allocatedBytes }
}

struct StorageCleanupRow: Identifiable, Equatable, Sendable {
    let location: StorageArtifactLocation
    let bytes: Int64?
    let reason: String?
    let candidate: StorageCleanupCandidate?

    var id: String { location.path }
}

struct StorageCleanupInventory: Equatable, Sendable {
    var rows: [StorageCleanupRow] = []
    var foldersChecked = 0
    var skippedFolders: [String] = []
    var reachedScanLimit = false
}

/// Measured disk space represented by the two lists on Clean. A generated
/// folder can also be part of a finished worktree's measured footprint.
struct CleanableSpace: Equatable {
    let bytes: Int64
    let isPartial: Bool

    init(inventory: StorageCleanupInventory?, worktrees: [WorkItem], checkedWorktrees: Bool) {
        var folders = [String: Int64]()
        for candidate in inventory?.rows.compactMap(\.candidate) ?? [] {
            folders[CleanupFileInspection.normalized(candidate.id)] = candidate.bytes
        }
        var partial = inventory == nil || inventory?.reachedScanLimit == true || !checkedWorktrees
        for item in worktrees where item.facts.folderExists && BranchesBoard.lane(for: item) == .safeToClear {
            guard let path = item.worktreePath else { continue }
            if let bytes = item.size?.totalBytes {
                folders[CleanupFileInspection.normalized(path)] = bytes
            } else {
                partial = true
            }
        }
        self.bytes = folders.reduce(into: Int64(0)) { total, folder in
            var ancestor = (folder.key as NSString).deletingLastPathComponent
            while !ancestor.isEmpty && ancestor != "/" {
                if folders[ancestor] != nil { return }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            total += folder.value
        }
        self.isPartial = partial
    }

    @available(macOS 12.0, *)
    func label(locale: Locale) -> String {
        if isPartial && bytes == 0 { return "…" }
        let size = bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
        return isPartial ? "≥\(size)" : size
    }
}

struct StorageArtifactScanner: Sendable {
    let home: String
    let locator: RepositoryLocator
    let git: GitClient?
    let processes: @Sendable () -> [WorkProcess]
    let sessions: [SessionLogEntry]
    let now: Date

    func scan(sessionFolders: [String], addedFolders: [String]) async -> StorageCleanupInventory {
        let folders = Array(Set((addedFolders + sessionFolders).map(CleanupFileInspection.normalized))).sorted()
        let chosen = Set(addedFolders.map(CleanupFileInspection.normalized))
        let workspaceFolders = folders.filter(locator.isWorkspacePath)
        let local = workspaceFolders.filter(isReadableRoot)
        var result = StorageCleanupInventory()
        let located = locator.locate(folders: local)
        result.skippedFolders = Array(Set(workspaceFolders.filter { !local.contains($0) } + located.notChecked)).sorted()
        let repositories = located.repositories
        var roots = Set(local)
        if let git {
            for repo in repositories {
                if Task.isCancelled { return result }
                let list = await git.run(in: repo.commonDirectory, ["worktree", "list", "--porcelain", "-z"])
                guard list.succeeded else {
                    result.skippedFolders.append(repo.name + " worktrees")
                    continue
                }
                for worktree in GitParsing.worktrees(fromPorcelain: list.stdout)
                where !worktree.isBare && !worktree.isPrunable {
                    let path = CleanupFileInspection.normalized(worktree.path)
                    if isReadableRoot(path) { roots.insert(path) } else { result.skippedFolders.append(path) }
                }
            }
        }

        let activity = processes()
        var seenPaths: Set<String> = []
        var seenItems: Set<CleanupFileIdentity> = []
        var budget = 400
        let orderedRoots = roots.sorted { left, right in
            if chosen.contains(left) != chosen.contains(right) { return chosen.contains(left) }
            return (left.count, left) < (right.count, right)
        }
        for root in orderedRoots {
            if Task.isCancelled { return result }
            let projects = projectFolders(in: root, excluding: roots, visited: &seenPaths, budget: &budget)
            result.foldersChecked += 1
            for owner in projects {
                let worktree: String?
                switch locator.lookup(containing: owner) {
                case let .found(location): worktree = location.root
                case let .locked(path):
                    result.skippedFolders.append(RepositoryLocator.projectFolder(of: path))
                    continue
                case .missing: worktree = nil
                }
                for kind in StorageArtifactKind.projectKinds {
                    let location = StorageArtifactLocation(kind: kind, owner: owner, workspace: worktree ?? root,
                                                           gitWorktree: worktree)
                    if let row = await inspect(location, processes: activity, seen: &seenItems) { result.rows.append(row) }
                }
            }
            if budget <= 0 { result.reachedScanLimit = true; break }
        }
        for owner in derivedDataFolders() {
            for kind in StorageArtifactKind.xcodeKinds {
                let location = StorageArtifactLocation(kind: kind, owner: owner, workspace: home)
                if let row = await inspect(location, processes: activity, seen: &seenItems) { result.rows.append(row) }
            }
        }
        for kind in StorageArtifactKind.homeKinds {
            let location = StorageArtifactLocation(kind: kind, owner: home, workspace: home)
            if let row = await inspect(location, processes: activity, seen: &seenItems) { result.rows.append(row) }
        }
        result.rows.sort { ($0.bytes ?? -1) == ($1.bytes ?? -1) ? $0.id < $1.id : ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        return result
    }

    func remove(_ candidate: StorageCleanupCandidate) async -> String? {
        let location = candidate.location
        if let reason = await refusal(for: location) { return reason }
        guard let current = CleanupFileInspection.read(location.path, locator: locator), current.protectedPath == nil,
              current.identity == candidate.inspection.identity, current.fingerprint == candidate.inspection.fingerprint else {
            return "The folder or its contents changed. Scan again to review it."
        }
        if isBusy(location, processes: processes()) { return "The folder is in use. Close the tool and scan again." }
        guard CleanupFileInspection.directory(location.path) == current.identity else {
            return "The folder moved. Scan again to review it."
        }
        do {
            try FileManager.default.removeItem(atPath: location.path)
            return nil
        } catch {
            return "Removal did not finish. \(error.localizedDescription)"
        }
    }

    private func inspect(_ location: StorageArtifactLocation, processes: [WorkProcess],
                         seen: inout Set<CleanupFileIdentity>) async -> StorageCleanupRow? {
        guard !Task.isCancelled, case let .allowed(resolved) = locator.access(to: location.path),
              resolved == location.path, let info = CleanupFileInspection.metadata(location.path),
              seen.insert(CleanupFileIdentity(info)).inserted else { return nil }
        let refusal = await refusal(for: location)
        let inspection = CleanupFileInspection.directory(location.path) == nil ? nil
            : CleanupFileInspection.read(location.path, locator: locator)
        let reason: String?
        if let refusal { reason = refusal }
        else if inspection == nil { reason = "The folder could not be read completely." }
        else if let protected = inspection?.protectedPath {
            reason = "Contains a protected file or link (\(URL(fileURLWithPath: protected).lastPathComponent))."
        } else if isBusy(location, processes: processes) {
            reason = "In use by a running tool or a recent session."
        } else {
            reason = nil
        }
        let candidate = reason == nil ? inspection.map { StorageCleanupCandidate(location: location, inspection: $0) } : nil
        return StorageCleanupRow(location: location, bytes: inspection?.allocatedBytes, reason: reason, candidate: candidate)
    }

    private func refusal(for location: StorageArtifactLocation) async -> String? {
        guard !location.isProject || isReadableRoot(location.workspace),
              case let .allowed(resolved) = locator.access(to: location.path), resolved == location.path,
              let homeID = CleanupFileInspection.directory(home),
              let identity = CleanupFileInspection.directory(location.path), identity.device == homeID.device else {
            return "This folder is protected, inaccessible, or on another volume."
        }
        guard location.kind.matches(owner: location.owner) else {
            return "The owning tool or generated contents could not be verified."
        }
        if location.isProject {
            guard RepositoryLocator.contains(location.workspace, location.owner),
                  matchesGitWorktree(location) else {
                return "The project location changed."
            }
            if let repository = location.gitWorktree {
                guard repository == location.workspace, let git else { return "Git could not verify this folder." }
                let relativePath = String(location.path.dropFirst(repository.count + 1))
                // A differently cased index entry can name the same files on APFS.
                let tracked = await git.run(in: repository, ["ls-files", "-z", "--", ":(icase,literal)" + relativePath],
                                            maximumOutputBytes: 64 * 1024)
                guard tracked.succeeded, tracked.stdout.isEmpty else {
                    return "Git tracks files here or could not verify them."
                }
                let ignored = await git.run(in: repository, ["check-ignore", "--quiet", "--", relativePath])
                guard ignored.succeeded else { return "The project does not mark this folder as ignored." }
            }
        } else if StorageArtifactKind.xcodeKinds.contains(location.kind) {
            let derive = home + "/" + StorageArtifactKind.derivedDataPath
            guard (location.owner as NSString).deletingLastPathComponent == derive else {
                return "The Xcode build folder moved."
            }
        } else if location.owner != home {
            return "The tool cache location moved."
        }
        return nil
    }

    private func isBusy(_ location: StorageArtifactLocation, processes: [WorkProcess]) -> Bool {
        if location.kind.isBusy(processes, workspace: location.workspace, path: location.path) { return true }
        return location.isProject && sessions.contains(where: { session in
            return RepositoryLocator.contains(location.workspace, CleanupFileInspection.normalized(session.folder))
                && now.timeIntervalSince(session.modifiedAt) < WorkRules.recentSessionWindow
        })
    }

    private func isReadableRoot(_ path: String) -> Bool {
        guard locator.isWorkspacePath(path), case let .allowed(resolved) = locator.access(to: path), resolved == path
        else { return false }
        return CleanupFileInspection.directory(path) != nil
    }

    private func projectFolders(in root: String, excluding roots: Set<String>,
                                visited: inout Set<String>, budget: inout Int) -> [String] {
        var projects: [String] = []
        var pending = [(root, 0)]
        let ignored: Set<String> = ["node_modules", "Library", "build", "dist", "target", "vendor", "Pods", "Applications"]
        while let (folder, depth) = pending.popLast(), budget > 0, !Task.isCancelled {
            guard visited.insert(folder).inserted, isReadableRoot(folder) else { continue }
            budget -= 1
            if CleanupFileInspection.regularFile(folder + "/package.json") != nil { projects.append(folder) }
            guard depth < 3, let children = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in children.sorted().reversed() where !name.hasPrefix(".") && !ignored.contains(name) {
                let path = folder + "/" + name
                if !roots.contains(path), locator.isAllowed(path),
                   let info = CleanupFileInspection.metadata(path), CleanupFileInspection.isDirectory(info) {
                    pending.append((path, depth + 1))
                }
            }
        }
        return projects
    }

    private func derivedDataFolders() -> [String] {
        let path = home + "/" + StorageArtifactKind.derivedDataPath
        guard isReadableRoot(path),
              let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return children.sorted().map { path + "/" + $0 }
    }

    private func matchesGitWorktree(_ location: StorageArtifactLocation) -> Bool {
        switch locator.lookup(containing: location.owner) {
        case let .found(found): return found.root == location.gitWorktree
        case .locked: return false
        case .missing: return location.gitWorktree == nil
        }
    }
}
