import Foundation

struct RepositoryInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var baseRef: String?
    var lastFetchedAt: Date?
    var project: ProjectIdentity?
    var failure: String?

    /// The folder the repository's main copy lives in.
    var folder: String {
        id.hasSuffix("/.git") ? String(id.dropLast(5)) : id
    }
}

enum BranchesActivity: Equatable, Sendable {
    case idle
    case readingSessions
    case checking(done: Int, total: Int)
    case measuring(done: Int, total: Int)
    case clearing(done: Int, total: Int)
}

/// What deleting a row would lose, read when someone asks to see it.
struct WorkEvidence: Equatable, Sendable {
    /// Subjects of the commits that would be lost or that aren't on main,
    /// newest first, at most `shownLimit` of them.
    var commits: [String] = []
    var moreCommits = 0
    /// Files with changes that aren't committed.
    var files: [String] = []
    var moreFiles = 0

    static let shownLimit = 6
}

struct BranchesSnapshot: Equatable, Sendable {
    var repositories: [RepositoryInfo] = []
    var items: [WorkItem] = []
    /// Protected folders AI sessions worked in, waiting for the person's OK.
    var notCheckedFolders: [String] = []
    var activity = BranchesActivity.idle
    var gitIsMissing = false
    var deletions: [DeletionRecord] = []
}

/// What the scanner keeps between runs. It's only a speed-up: deleting it
/// costs one slow scan, and a delete always re-checks without it.
struct BranchesCacheFile: Codable, Equatable, Sendable {
    struct Repository: Codable, Equatable, Sendable {
        var index: MainBranchIndex?
        var tips: [String: TipFacts] = [:]
        /// Each tip's subject, as `MergeDetector.subject` read it. Optional
        /// so a file from before it existed still loads.
        var subjects: [String: String]?
    }

    static let currentVersion = 1
    /// Session entries from before titles were read have none, and an
    /// unchanged log isn't read again, so older entries are dropped.
    static let currentSessionFormat = 2

    var version = currentVersion
    var sessionFormat: Int?
    var sessions: [String: SessionLogEntry] = [:]
    var repositories: [String: Repository] = [:]
    var sizes: [String: FolderSize] = [:]
    var toolStorage: [ToolStorageEntry] = []
    var toolStorageMeasuredAt: Date?
}

actor BranchesScanner {
    struct Environment: Sendable {
        var home: URL
        var cacheFile: URL
        var deletionLogFile: URL
        var git: GitClient?
        var cursorDatabase: URL?
        var addedFolders: @Sendable () -> [String]
        var processes: @Sendable () -> [WorkProcess]
        var now: @Sendable () -> Date

        static func live(addedFolders: @escaping @Sendable () -> [String]) -> Environment {
            let fileManager = FileManager.default
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let name = Bundle.main.bundleIdentifier ?? "usAIge"
            return Environment(
                home: fileManager.homeDirectoryForCurrentUser,
                cacheFile: caches.appendingPathComponent(name, isDirectory: true).appendingPathComponent("branches-v1.json"),
                deletionLogFile: support.appendingPathComponent(name, isDirectory: true).appendingPathComponent("branch-deletions.json"),
                git: GitClient.locate(),
                addedFolders: addedFolders,
                processes: { ProcessScanner.scan() },
                now: Date.init
            )
        }
    }

    typealias Publisher = @Sendable (BranchesSnapshot) async -> Void

    static let sizeFreshness: TimeInterval = 60 * 60
    private static let maximumConcurrentGitRows = 2
    private static let publishInterval: TimeInterval = 0.25
    private static let maximumDeletionRecords = 50
    /// Too general to link a session to a row by branch name alone.
    private static let commonBranchNames: Set<String> = ["main", "master", "develop", "dev", "trunk", "HEAD"]

    private let environment: Environment
    private var cache = BranchesCacheFile()
    private var cacheLoaded = false
    private var snapshots: [String: RepositorySnapshot] = [:]
    private var rows: [String: WorkItem] = [:]
    private var notCheckedFolders: [String] = []
    private var activity = BranchesActivity.idle
    private var deletions: [DeletionRecord] = []
    private var lastPublishedAt = Date.distantPast

    init(environment: Environment) {
        self.environment = environment
    }

    private var locator: RepositoryLocator {
        RepositoryLocator(home: environment.home.path, allowedFolders: environment.addedFolders())
    }

    // MARK: Scanning

    func scan(force: Bool, publish: @escaping Publisher) async {
        loadPersistedState()
        activity = .readingSessions
        await publish(currentSnapshot())

        cache.sessions = SessionLogIndexer(home: environment.home, cursorDatabase: environment.cursorDatabase)
            .update(from: cache.sessions)
        if Task.isCancelled { return }

        let folders = cache.sessions.values.map(\.folder) + environment.addedFolders()
        let located = locator.locate(folders: folders)
        notCheckedFolders = located.notChecked

        guard let git = environment.git else {
            activity = .idle
            await publish(currentSnapshot())
            return
        }

        var freshSnapshots: [String: RepositorySnapshot] = [:]
        var freshRows: [String: WorkItem] = [:]
        for repository in located.repositories {
            if Task.isCancelled { return }
            let snapshot = await RepositoryReader.read(git: git, located: repository)
            freshSnapshots[repository.id] = snapshot
            for item in RepositoryReader.items(from: snapshot, locator: locator) {
                freshRows[item.id] = seeded(item, from: rows[item.id], in: snapshot)
            }
        }
        snapshots = freshSnapshots
        rows = freshRows
        relinkSessionsAndProcesses()
        activity = .checking(done: 0, total: rows.count)
        await publish(currentSnapshot())

        var done = 0
        for repository in located.repositories {
            if Task.isCancelled { return }
            await checkRows(of: repository.id, done: &done, publish: publish)
        }
        persistCache()

        await measureSizes(force: force, publish: publish)
        if Task.isCancelled { return }
        activity = .idle
        persistCache()
        await publish(currentSnapshot())
    }

    /// A row reappears with what's still known about it: facts tied to its
    /// commit stay valid, and its status simply shows as checking until the
    /// live reads return.
    private func seeded(_ item: WorkItem, from previous: WorkItem?, in snapshot: RepositorySnapshot) -> WorkItem {
        var item = item
        if let path = item.worktreePath, let size = cache.sizes[path] {
            item.size = size
            item.ignoredFiles = size.ignored
        }
        if let tip = item.tip, let base = snapshot.baseCommit,
           let known = cache.repositories[item.repositoryID]?.tips[tip], known.isCurrent(forBase: base) {
            item.apply(known)
        }
        if let tip = item.tip { item.subject = cache.repositories[item.repositoryID]?.subjects?[tip] }
        if previous?.tip == item.tip, let previous {
            item.facts.changedFiles = previous.facts.changedFiles
            item.facts.untrackedFiles = previous.facts.untrackedFiles
            item.facts.commitsAtRisk = previous.facts.commitsAtRisk
        }
        return item
    }

    private func checkRows(of repositoryID: String, done: inout Int, publish: @escaping Publisher) async {
        guard let git = environment.git, let snapshot = snapshots[repositoryID] else { return }
        let ids = rows.values.filter { $0.repositoryID == repositoryID }.map(\.id)
        guard let baseCommit = snapshot.baseCommit else {
            done += ids.count
            activity = .checking(done: done, total: rows.count)
            return
        }

        var stored = cache.repositories[repositoryID] ?? BranchesCacheFile.Repository()
        let index = await MergeDetector.updatedIndex(
            git: git, repository: repositoryID, baseCommit: baseCommit, previous: stored.index
        )
        if let index { stored.index = index }
        // Without an index nothing can match by content, which only makes a
        // merged row look unmerged. That's safe to show, but not to remember.
        let searchable = index ?? MainBranchIndex(baseCommit: baseCommit, commitsByPatchID: [:])
        let liveTips = Set(ids.compactMap { rows[$0]?.tip })
        let missing = liveTips.filter { stored.tips[$0]?.isCurrent(forBase: baseCommit) != true }
        let firstParent = missing.isEmpty ? [] : await MergeDetector.firstParentCommits(
            git: git, repository: repositoryID, baseCommit: baseCommit
        )
        var unremembered: [String: TipFacts] = [:]
        if let firstParent {
            await forEachBounded(Array(missing)) { tip in
                (tip, await MergeDetector.tipFacts(
                    git: git, repository: repositoryID, tip: tip,
                    baseCommit: baseCommit, index: searchable, firstParent: firstParent
                ))
            } receive: { tip, facts in
                guard let facts else { return }
                if index == nil { unremembered[tip] = facts } else { stored.tips[tip] = facts }
            }
        }
        stored.tips = stored.tips.filter { liveTips.contains($0.key) }
        for id in ids {
            guard let tip = rows[id]?.tip else {
                // An orphan branch has no commits at all.
                rows[id]?.facts.ownCommits = 0
                continue
            }
            if let facts = unremembered[tip] ?? stored.tips[tip] { rows[id]?.apply(facts) }
        }

        // A subject only names the work, so it's read once per commit.
        var subjects = (stored.subjects ?? [:]).filter { liveTips.contains($0.key) }
        let unnamed = liveTips.filter { subjects[$0] == nil }
        let merges = Dictionary(ids.compactMap { id in rows[id].flatMap { row in row.tip.map { ($0, row.facts.merge) } } },
                                uniquingKeysWith: { first, _ in first })
        await forEachBounded(Array(unnamed)) { tip in
            (tip, await MergeDetector.subject(
                git: git, repository: repositoryID, tip: tip, baseCommit: baseCommit, merge: merges[tip] ?? nil
            ))
        } receive: { tip, subject in
            if let subject { subjects[tip] = subject }
        }
        stored.subjects = subjects
        for id in ids {
            if let tip = rows[id]?.tip { rows[id]?.subject = subjects[tip] }
        }
        cache.repositories[repositoryID] = stored
        await publishIfDue(publish)

        let items = ids.compactMap { rows[$0] }
        var finished = done
        await forEachBounded(items) { item in
            (item.id, await RepositoryReader.probe(git: git, item: item, repository: repositoryID, baseCommit: baseCommit))
        } receive: { id, probe in
            if let hadFolder = rows[id].map({ $0.facts.hasWorktree && $0.facts.folderExists && $0.facts.folderReadable }) {
                rows[id]?.apply(probe, hadFolderToRead: hadFolder)
            }
            finished += 1
            activity = .checking(done: finished, total: rows.count)
            await publishIfDue(publish)
        }
        done = finished
    }

    private func forEachBounded<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        work: @escaping @Sendable (Input) async -> Output,
        receive: (Output) async -> Void
    ) async {
        await withTaskGroup(of: Output.self) { group in
            var iterator = inputs.makeIterator()
            for _ in 0..<Self.maximumConcurrentGitRows {
                guard let next = iterator.next() else { break }
                group.addTask { await work(next) }
            }
            while let output = await group.next() {
                await receive(output)
                if !Task.isCancelled, let next = iterator.next() {
                    group.addTask { await work(next) }
                }
            }
        }
    }

    private func measureSizes(force: Bool, publish: @escaping Publisher) async {
        let now = environment.now()
        // Inner folders first, so what contains them can subtract their size.
        let candidates = rows.values
            .filter { $0.worktreePath != nil && $0.facts.folderExists && $0.facts.folderReadable }
            .sorted { ($0.worktreePath?.count ?? 0) > ($1.worktreePath?.count ?? 0) }
        var nested: [String: Int64] = [:]
        var done = 0
        for item in candidates {
            if Task.isCancelled { return }
            guard let path = item.worktreePath else { continue }
            activity = .measuring(done: done, total: candidates.count)
            if !force, let known = cache.sizes[path], now.timeIntervalSince(known.measuredAt) < Self.sizeFreshness {
                nested[path] = known.totalBytes
            } else if let git = environment.git,
                      let ignored = await RepositoryReader.ignoredFiles(git: git, folder: path) {
                rows[item.id]?.ignoredFiles = ignored
                if let size = await FolderSizer.measure(folder: path, ignored: ignored, nestedSizes: nested, now: now) {
                    cache.sizes[path] = size
                    nested[path] = size.totalBytes
                    rows[item.id]?.size = size
                }
            }
            done += 1
            await publishIfDue(publish)
        }
        let livePaths = Set(rows.values.compactMap(\.worktreePath))
        cache.sizes = cache.sizes.filter { livePaths.contains($0.key) }
    }

    private func publishIfDue(_ publish: Publisher) async {
        let now = environment.now()
        guard now.timeIntervalSince(lastPublishedAt) >= Self.publishInterval else { return }
        lastPublishedAt = now
        await publish(currentSnapshot())
    }

    // MARK: Linking

    /// Refreshes only what's running, for the window's periodic update.
    func refreshRunningProcesses() -> BranchesSnapshot {
        relinkSessionsAndProcesses()
        return currentSnapshot()
    }

    private func relinkSessionsAndProcesses() {
        let links = Self.link(
            items: Array(rows.values),
            sessions: Array(cache.sessions.values),
            processes: environment.processes(),
            commonBranchNames: Self.commonBranchNames
        )
        let now = environment.now()
        for id in Array(rows.keys) {
            let summary = links.sessions[id] ?? WorkSessionSummary()
            rows[id]?.sessions = summary
            rows[id]?.processes = links.processes[id] ?? []
            rows[id]?.facts.runningProcesses = links.processes[id]?.count ?? 0
            rows[id]?.facts.sessionActiveRecently = summary.lastActiveAt.map {
                now.timeIntervalSince($0) < WorkRules.recentSessionWindow
            } ?? false
        }
    }

    /// Attaches each session and process to the deepest worktree holding its
    /// folder. A session also counts for the branch its log names, since it
    /// may have started in another folder or one that's gone now.
    static func link(
        items: [WorkItem],
        sessions: [SessionLogEntry],
        processes: [WorkProcess],
        commonBranchNames: Set<String>
    ) -> (sessions: [String: WorkSessionSummary], processes: [String: [WorkProcess]]) {
        let folders = items
            .compactMap { item in item.worktreePath.map { (path: $0, id: item.id, repository: item.repositoryID) } }
            .sorted { $0.path.count > $1.path.count }
        let deepest: (String) -> (path: String, id: String, repository: String)? = { folder in
            folders.first { RepositoryLocator.contains($0.path, folder) }
        }
        var rowsByBranch: [String: [WorkItem]] = [:]
        for item in items { if let branch = item.branch { rowsByBranch[branch, default: []].append(item) } }

        var sessionEntries: [String: [SessionLogEntry]] = [:]
        for session in sessions {
            let folder = RepositoryLocator.normalized(session.folder)
            let owner = deepest(folder)
            if let owner { sessionEntries[owner.id, default: []].append(session) }
            guard let branch = session.branch, let candidates = rowsByBranch[branch] else { continue }
            let sameRepository = owner.map { owner in candidates.filter { $0.repositoryID == owner.repository } }
            if let matches = sameRepository, !matches.isEmpty {
                for match in matches where match.id != owner?.id {
                    sessionEntries[match.id, default: []].append(session)
                }
            } else if owner == nil, !commonBranchNames.contains(branch), candidates.count == 1 {
                sessionEntries[candidates[0].id, default: []].append(session)
            }
        }

        var processEntries: [String: [WorkProcess]] = [:]
        for process in processes {
            if let owner = deepest(RepositoryLocator.normalized(process.folder)) {
                processEntries[owner.id, default: []].append(process)
            }
        }
        let branches = Dictionary(items.map { ($0.id, $0.branch) }, uniquingKeysWith: { first, _ in first })
        var summaries: [String: WorkSessionSummary] = [:]
        for (id, entries) in sessionEntries {
            summaries[id] = WorkSessionSummary(entries: entries, branch: branches[id] ?? nil)
        }
        return (summaries, processEntries)
    }

    private func currentSnapshot() -> BranchesSnapshot {
        BranchesSnapshot(
            repositories: snapshots.values
                .map { snapshot in
                    RepositoryInfo(
                        id: snapshot.located.id,
                        name: snapshot.located.name,
                        baseRef: snapshot.baseRef,
                        lastFetchedAt: snapshot.lastFetchedAt,
                        project: snapshot.project,
                        failure: snapshot.failure
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            // A dictionary's order changes between reads.
            items: rows.values.sorted { $0.id < $1.id },
            notCheckedFolders: notCheckedFolders,
            activity: activity,
            gitIsMissing: environment.git == nil,
            deletions: deletions
        )
    }

    // MARK: Tool storage

    /// The storage list, from the last hour's reading unless `force` is set.
    func toolStorage(force: Bool) async -> [ToolStorageEntry] {
        loadPersistedState()
        if !force, let measuredAt = cache.toolStorageMeasuredAt,
           environment.now().timeIntervalSince(measuredAt) < Self.sizeFreshness {
            return cache.toolStorage
        }
        let entries = await ToolStorageScanner.scan(home: environment.home)
        guard !Task.isCancelled else { return entries }
        cache.toolStorage = entries
        cache.toolStorageMeasuredAt = environment.now()
        persistCache()
        return entries
    }

    // MARK: Evidence

    /// The commits and files a card shows before anyone deletes it. Read only
    /// when asked: names of commits and files, never their contents.
    func evidence(for item: WorkItem) async -> WorkEvidence {
        var evidence = WorkEvidence()
        guard let git = environment.git, let base = snapshots[item.repositoryID]?.baseCommit else { return evidence }
        let limit = WorkEvidence.shownLimit
        if let tip = item.tip {
            // What would be lost: commits nothing else holds. For work that is
            // saved elsewhere, what hasn't reached main.
            let atRisk = (item.facts.commitsAtRisk ?? 0) > 0
            let exclusions = !atRisk ? [base] : item.branch == nil
                ? ["--branches", "--tags", "--remotes"]
                : ["--remotes", "--tags", base]
            let log = await git.run(
                in: item.repositoryID,
                ["log", "--no-merges", "--format=%s", "-n", String(limit + 1), tip, "--not"] + exclusions
            )
            if log.succeeded {
                let subjects = log.text.split(separator: "\n").map(String.init)
                evidence.commits = Array(subjects.prefix(limit))
                let total = atRisk ? item.facts.commitsAtRisk ?? subjects.count : item.facts.ownCommits ?? subjects.count
                evidence.moreCommits = max(0, total - evidence.commits.count)
            }
        }
        if let path = item.worktreePath, item.facts.folderExists, item.facts.folderReadable,
           (item.facts.changedFiles ?? 0) + (item.facts.untrackedFiles ?? 0) > 0 {
            let status = await git.run(in: path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], timeout: 60)
            if status.succeeded {
                let files = GitParsing.changedPaths(fromPorcelain: status.stdout)
                evidence.files = Array(files.prefix(limit))
                evidence.moreFiles = max(0, files.count - limit)
            }
        }
        return evidence
    }

    // MARK: Deleting

    /// Re-reads everything about the row first, without any cached result. A
    /// row that changed since it was reviewed is left alone. Stopping the task
    /// stops before the next row; one already started is finished.
    func delete(_ reviewed: [WorkItem], publish: @escaping Publisher) async -> [DeletionOutcome] {
        guard let git = environment.git else {
            return reviewed.map { .refused(name: $0.displayName, reason: "Git isn't available.") }
        }
        loadPersistedState()
        cache.sessions = SessionLogIndexer(home: environment.home, cursorDatabase: environment.cursorDatabase)
            .update(from: cache.sessions)
        var outcomes: [DeletionOutcome] = []
        for item in reviewed {
            if Task.isCancelled { break }
            activity = .clearing(done: outcomes.count, total: reviewed.count)
            await publish(currentSnapshot())
            if let reason = await refusalReason(for: item, git: git) {
                outcomes.append(.refused(name: item.displayName, reason: reason))
                continue
            }
            let outcome = await WorkDeleter.perform(
                git: git, item: item, repository: item.repositoryID, now: environment.now()
            )
            if let record = outcome.record { remember(record) }
            outcomes.append(outcome)
            if case .deleted = outcome { rows[item.id] = nil }
        }
        activity = .idle
        persistDeletions()
        await publish(currentSnapshot())
        return outcomes
    }

    private func refusalReason(for reviewed: WorkItem, git: GitClient) async -> String? {
        let changed = "It changed after you reviewed it. Check it again."
        guard let located = snapshots[reviewed.repositoryID]?.located else { return changed }
        let snapshot = await RepositoryReader.read(git: git, located: located)
        guard snapshot.failure == nil, let baseCommit = snapshot.baseCommit else {
            return "Git couldn't re-read this repository."
        }
        let rowsNow = RepositoryReader.items(from: snapshot, locator: locator)
        guard var fresh = rowsNow.first(where: { $0.id == reviewed.id }), fresh.tip == reviewed.tip else { return changed }

        let links = Self.link(
            items: rowsNow,
            sessions: Array(cache.sessions.values),
            processes: environment.processes(),
            commonBranchNames: Self.commonBranchNames
        )
        let lastActive = links.sessions[fresh.id]?.lastActiveAt
        fresh.facts.runningProcesses = links.processes[fresh.id]?.count ?? 0
        fresh.facts.sessionActiveRecently = lastActive.map {
            environment.now().timeIntervalSince($0) < WorkRules.recentSessionWindow
        } ?? false

        if let tip = fresh.tip {
            guard let index = await MergeDetector.updatedIndex(
                git: git, repository: reviewed.repositoryID, baseCommit: baseCommit,
                previous: cache.repositories[reviewed.repositoryID]?.index
            ), let firstParent = await MergeDetector.firstParentCommits(
                git: git, repository: reviewed.repositoryID, baseCommit: baseCommit
            ), let tipFacts = await MergeDetector.tipFacts(
                git: git, repository: reviewed.repositoryID, tip: tip,
                baseCommit: baseCommit, index: index, firstParent: firstParent
            ) else {
                return "usAIge couldn't re-check this one's commits."
            }
            fresh.apply(tipFacts)
        } else {
            fresh.facts.ownCommits = 0
        }
        let hadFolder = fresh.facts.hasWorktree && fresh.facts.folderExists && fresh.facts.folderReadable
        fresh.apply(
            await RepositoryReader.probe(git: git, item: fresh, repository: reviewed.repositoryID, baseCommit: baseCommit),
            hadFolderToRead: hadFolder
        )

        if hadFolder, let path = fresh.worktreePath {
            guard let ignored = await RepositoryReader.ignoredFiles(git: git, folder: path) else {
                return "usAIge couldn't re-check this folder's ignored files."
            }
            fresh.ignoredFiles = ignored
        }

        if case let .blocked(reason) = fresh.eligibility { return reason }
        // The person reviewed what would happen to the row as it was then.
        if fresh.status != reviewed.status {
            // Merge evidence outlasts main moving forward, so without this a
            // rewound main would keep showing a status that can't be deleted.
            if let tip = fresh.tip { cache.repositories[reviewed.repositoryID]?.tips[tip] = nil }
            return changed
        }
        // Files that appeared since the review were never shown to the person.
        let unreviewed = Set(fresh.irreplaceableIgnored).subtracting(reviewed.irreplaceableIgnored)
        if !unreviewed.isEmpty {
            // The list comes with the size reading, which otherwise lasts an
            // hour, and the next review has to show these files.
            if let path = fresh.worktreePath { cache.sizes[path] = nil }
            return changed
        }
        return nil
    }

    private func remember(_ record: DeletionRecord) {
        deletions.insert(record, at: 0)
        if deletions.count > Self.maximumDeletionRecords { deletions.removeLast(deletions.count - Self.maximumDeletionRecords) }
    }

    /// Brings a deleted row back. Returns what went wrong, if anything.
    func undo(_ record: DeletionRecord) async -> String? {
        guard let git = environment.git else { return "Git isn't available." }
        let failure = await WorkDeleter.undo(git: git, record: record)
        if failure == nil {
            deletions.removeAll { $0.id == record.id }
            persistDeletions()
        }
        return failure
    }

    // MARK: Persistence

    private func loadPersistedState() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: environment.cacheFile),
           let decoded = try? JSONDecoder().decode(BranchesCacheFile.self, from: data),
           decoded.version == BranchesCacheFile.currentVersion {
            cache = decoded
        }
        if cache.sessionFormat != BranchesCacheFile.currentSessionFormat {
            cache.sessions = [:]
            cache.sessionFormat = BranchesCacheFile.currentSessionFormat
        }
        if let data = try? Data(contentsOf: environment.deletionLogFile),
           let decoded = try? JSONDecoder().decode([DeletionRecord].self, from: data) {
            deletions = decoded
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        Self.write(data, to: environment.cacheFile)
    }

    private func persistDeletions() {
        guard let data = try? JSONEncoder().encode(deletions) else { return }
        Self.write(data, to: environment.deletionLogFile)
    }

    /// Saves what the window learned before it goes away.
    func saveAndStop() {
        activity = .idle
        if cacheLoaded { persistCache() }
    }

    private static func write(_ data: Data, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
