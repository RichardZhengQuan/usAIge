import Foundation

/// One repository's listing, read fresh.
struct RepositorySnapshot: Equatable, Sendable {
    var located: LocatedRepository
    var baseRef: String?
    var localBaseName: String?
    var baseCommit: String?
    var worktrees: [GitWorktreeRecord] = []
    var branches: [GitBranchRecord] = []
    var stashCounts: [String: Int] = [:]
    var lastFetchedAt: Date?
    /// Which project this is a copy of, from its `origin` remote.
    var project: ProjectIdentity?
    var failure: String?
}

/// The project a repository is a copy of. Clones of one remote share it.
struct ProjectIdentity: Hashable, Sendable {
    /// Host and path, with no user name, password, or token.
    let key: String
    let name: String

    /// Reads `https://user:token@host/owner/name.git`, `git@host:owner/name`,
    /// `ssh://git@host:22/owner/name`, and local paths alike. Anything before
    /// an `@` in the host part is dropped, since it can hold a credential.
    static func fromRemote(_ remote: String) -> ProjectIdentity? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var host = ""
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            let slash = text.firstIndex(of: "/") ?? text.endIndex
            host = String(text[..<slash])
            text = String(text[slash...])
        } else if !text.hasPrefix("/"), !text.hasPrefix("."), let colon = text.firstIndex(of: ":"),
                  !text[..<colon].contains("/") {
            host = String(text[..<colon])
            text = "/" + text[text.index(after: colon)...]
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let port = host.lastIndex(of: ":") { host = String(host[..<port]) }
        var path = text
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }
        // Hosts like GitHub ignore case in paths; a folder on disk may not.
        return ProjectIdentity(key: host.isEmpty ? path : (host + path).lowercased(), name: name)
    }
}

enum RepositoryReader {
    static func read(git: GitClient, located: LocatedRepository) async -> RepositorySnapshot {
        let directory = located.commonDirectory
        var snapshot = RepositorySnapshot(located: located)
        let worktrees = await git.run(in: directory, ["worktree", "list", "--porcelain", "-z"])
        guard worktrees.succeeded else {
            snapshot.failure = worktrees.timedOut ? "Git took too long to answer." : "Git couldn't read this repository."
            return snapshot
        }
        snapshot.worktrees = GitParsing.worktrees(fromPorcelain: worktrees.stdout)
        let branches = await git.run(in: directory, ["for-each-ref", "refs/heads", "--format=\(GitParsing.branchFormat)"])
        guard branches.succeeded else {
            snapshot.failure = "Git couldn't list this repository's branches."
            return snapshot
        }
        snapshot.branches = GitParsing.branches(fromForEachRef: branches.text)
        let stashes = await git.run(in: directory, ["log", "-g", "--format=%gs", "refs/stash"])
        if stashes.succeeded { snapshot.stashCounts = GitParsing.stashCountsByBranch(fromSubjects: stashes.text) }
        snapshot.lastFetchedAt = AgentActivityFiles.attributes(
            of: URL(fileURLWithPath: directory + "/FETCH_HEAD")
        )?.modifiedAt
        let origin = await git.run(in: directory, ["config", "--get", "remote.origin.url"])
        if origin.succeeded { snapshot.project = ProjectIdentity.fromRemote(origin.trimmedText) }
        await readBase(git: git, directory: directory, into: &snapshot)
        return snapshot
    }

    private static func readBase(git: GitClient, directory: String, into snapshot: inout RepositorySnapshot) async {
        var candidates = ["origin/main", "origin/master", "main", "master"]
        let remoteHead = await git.run(in: directory, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        if remoteHead.succeeded, !remoteHead.trimmedText.isEmpty { candidates.insert(remoteHead.trimmedText, at: 0) }
        for candidate in candidates {
            let commit = await git.run(in: directory, ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"])
            guard commit.succeeded, !commit.trimmedText.isEmpty else { continue }
            snapshot.baseRef = candidate
            snapshot.baseCommit = commit.trimmedText
            snapshot.localBaseName = candidate.split(separator: "/", maxSplits: 1).last.map(String.init)
            return
        }
    }

    /// The rows a listing makes, one per worktree and one per branch without
    /// a worktree, with only the facts the listing alone can answer.
    static func items(from snapshot: RepositorySnapshot, locator: RepositoryLocator) -> [WorkItem] {
        let repositoryID = snapshot.located.commonDirectory
        let worktreePaths = snapshot.worktrees.map { RepositoryLocator.normalized($0.path) }
        let branchesByName = Dictionary(snapshot.branches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [WorkItem] = []
        var branchesWithWorktree: Set<String> = []
        for (position, record) in snapshot.worktrees.enumerated() where !record.isBare {
            let path = RepositoryLocator.normalized(record.path)
            if let branch = record.branch { branchesWithWorktree.insert(branch) }
            var facts = WorkFacts()
            facts.hasWorktree = true
            facts.isMainCopy = position == 0 || (record.branch != nil && record.branch == snapshot.localBaseName)
            facts.isDetached = record.branch == nil
            facts.isLocked = record.isLocked
            facts.lockReason = record.lockReason
            facts.mainBranchKnown = snapshot.baseCommit != nil
            facts.containsOtherWorktree = worktreePaths.contains { $0 != path && RepositoryLocator.contains(path, $0) }
            facts.stashCount = record.branch.flatMap { snapshot.stashCounts[$0] } ?? 0
            if locator.isAllowed(path) {
                facts.folderExists = FileManager.default.fileExists(atPath: path)
                facts.folderReadable = !(locator.isProtected(path) && RepositoryLocator.isManagedByICloud(path))
            } else {
                facts.folderExists = true
                facts.folderReadable = false
            }
            let head = record.head.flatMap { $0.allSatisfy { $0 == "0" } ? nil : $0 }
            let branch = record.branch.flatMap { branchesByName[$0] }
            items.append(WorkItem(
                id: "\(repositoryID)|worktree|\(path)",
                repositoryID: repositoryID,
                repositoryName: snapshot.located.name,
                branch: record.branch,
                worktreePath: path,
                tip: head,
                upstream: branch?.upstream,
                committedAt: branch?.committedAt,
                facts: facts
            ))
        }
        for branch in snapshot.branches where !branchesWithWorktree.contains(branch.name) {
            var facts = WorkFacts()
            facts.isMainCopy = branch.name == snapshot.localBaseName
            facts.mainBranchKnown = snapshot.baseCommit != nil
            facts.stashCount = snapshot.stashCounts[branch.name] ?? 0
            items.append(WorkItem(
                id: "\(repositoryID)|branch|\(branch.name)",
                repositoryID: repositoryID,
                repositoryName: snapshot.located.name,
                branch: branch.name,
                worktreePath: nil,
                tip: branch.tip,
                upstream: branch.upstream,
                committedAt: branch.committedAt,
                facts: facts
            ))
        }
        return items
    }

    struct RowProbe: Sendable {
        var counts: GitStatusCounts?
        var commitsAtRisk: Int?
    }

    /// Everything Git ignores in a folder, or nil if that couldn't be read.
    /// Listing these takes far longer than a plain status, so it's a separate
    /// read, done with the folder's size and again just before a delete.
    static func ignoredFiles(git: GitClient, folder: String) async -> [String]? {
        let status = await git.run(
            in: folder,
            ["status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal"],
            timeout: 60
        )
        return status.succeeded ? GitParsing.statusCounts(fromPorcelain: status.stdout).ignored : nil
    }

    /// The per-row reads: uncommitted files, and commits that exist nowhere
    /// else. A detached worktree's commits are safe if any branch holds them;
    /// a branch's are safe once a remote, a tag, or main holds them.
    static func probe(git: GitClient, item: WorkItem, repository: String, baseCommit: String) async -> RowProbe {
        var probe = RowProbe()
        if let path = item.worktreePath, item.facts.folderExists, item.facts.folderReadable {
            let status = await git.run(
                in: path,
                ["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
                timeout: 60
            )
            if status.succeeded { probe.counts = GitParsing.statusCounts(fromPorcelain: status.stdout) }
        }
        guard let tip = item.tip else {
            probe.commitsAtRisk = 0
            return probe
        }
        let exclusions = item.branch == nil
            ? ["--branches", "--tags", "--remotes"]
            : ["--remotes", "--tags", baseCommit]
        let risk = await git.run(in: repository, ["rev-list", "--count", tip, "--not"] + exclusions)
        if risk.succeeded { probe.commitsAtRisk = Int(risk.trimmedText) }
        return probe
    }
}

extension WorkItem {
    /// Git-ignored files no build recreates, which deleting the folder loses.
    var irreplaceableIgnored: [String] {
        (ignoredFiles ?? []).filter { FolderSizer.cacheName(forIgnoredPath: $0) == nil }
    }

    mutating func apply(_ probe: RepositoryReader.RowProbe, hadFolderToRead: Bool) {
        if let counts = probe.counts {
            facts.changedFiles = counts.changed
            facts.untrackedFiles = counts.untracked
        } else if hadFolderToRead {
            // A status that failed or timed out proves nothing about the
            // folder, so it can't be treated as clean.
            facts.folderReadable = false
        }
        facts.commitsAtRisk = probe.commitsAtRisk
    }

    mutating func apply(_ tipFacts: TipFacts) {
        facts.ownCommits = tipFacts.ownCommits
        facts.merge = tipFacts.merge
    }
}
