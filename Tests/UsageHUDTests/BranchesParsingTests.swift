import Foundation
import Testing
@testable import UsageHUD

// MARK: Git output

@Test func worktreeListKeepsLockReasonsWithLineBreaksAndSpaces() {
    let output = [
        "worktree /Users/me/My Project", "HEAD aaa", "branch refs/heads/main", "",
        "worktree /Users/me/old", "HEAD bbb", "detached", "locked Archived.\nDo not prune.", "prunable gitdir file points to non-existent location", "",
    ].joined(separator: "\0") + "\0"
    let records = GitParsing.worktrees(fromPorcelain: Data(output.utf8))
    #expect(records.count == 2)
    #expect(records[0].path == "/Users/me/My Project")
    #expect(records[0].branch == "main")
    #expect(!records[0].isLocked)
    #expect(records[1].isDetached)
    #expect(records[1].branch == nil)
    #expect(records[1].isLocked)
    #expect(records[1].lockReason == "Archived.\nDo not prune.")
    #expect(records[1].isPrunable)
}

@Test func branchListReadsUpstreamStateAndDates() {
    let text = "feature/a\0aaa\0origin/feature/a\0gone\01700000000\nlocal\0bbb\0\0\01700000001\n"
    let records = GitParsing.branches(fromForEachRef: text)
    #expect(records.map(\.name) == ["feature/a", "local"])
    #expect(records[0].upstream == "origin/feature/a")
    #expect(records[0].upstreamIsGone)
    #expect(records[1].upstream == nil)
    #expect(!records[1].upstreamIsGone)
    #expect(records[1].committedAt == Date(timeIntervalSince1970: 1_700_000_001))
}

@Test func statusCountsTreatARenameAsOneChangeAndSeparateIgnoredFiles() {
    let output = [" M changed.txt", "R  new.txt", "old.txt", "?? untracked.txt", "!! node_modules/", "!! .env", ""]
        .joined(separator: "\0")
    let counts = GitParsing.statusCounts(fromPorcelain: Data(output.utf8))
    #expect(counts.changed == 2)
    #expect(counts.untracked == 1)
    #expect(counts.ignored == ["node_modules", ".env"])
}

@Test func squashCommitSubjectsYieldTheirPullRequest() {
    #expect(GitParsing.pullRequestNumber(fromSubject: "Stop the leaks (#131)\n") == 131)
    #expect(GitParsing.pullRequestNumber(fromSubject: "Fix (#12) and more") == nil)
    #expect(GitParsing.pullRequestNumber(fromSubject: "No number") == nil)
    #expect(GitParsing.pullRequestNumber(fromSubject: "Odd (#abc)") == nil)
}

@Test func stashSubjectsCountByTheirBranch() {
    let counts = GitParsing.stashCountsByBranch(fromSubjects: "WIP on feature/a: 123 message\nOn feature/a: named\nWIP on main: 456 x\nnot a stash\n")
    #expect(counts == ["feature/a": 2, "main": 1])
}

// MARK: Session logs

@Test func sessionFieldsReadOnlyTheNamedKey() {
    let data = Data(#"{"cwd":"/Users/me/my \"quoted\" app","gitBranch":"one"} {"gitBranch":"two","message":"cwd is /fake"}"#.utf8)
    #expect(SessionLogFields.string(forKey: "cwd", in: data) == #"/Users/me/my "quoted" app"#)
    #expect(SessionLogFields.string(forKey: "gitBranch", in: data) == "one")
    #expect(SessionLogFields.string(forKey: "gitBranch", in: data, last: true) == "two")
    #expect(SessionLogFields.string(forKey: "missing", in: data) == nil)
}

@Test func sessionFieldsGiveUpOnAnUnterminatedValue() {
    #expect(SessionLogFields.string(forKey: "cwd", in: Data(#"{"cwd":"/Users/me"#.utf8)) == nil)
}

@Test func sessionIndexReadsClaudeAndCodexLogsAndReusesUnchangedOnes() throws {
    let fixture = try GitFixture()
    let home = URL(fileURLWithPath: fixture.home)
    try fixture.write(".claude/projects/p/one.jsonl", #"{"type":"user","cwd":"/work/a","gitBranch":"first"}"# + "\n" + #"{"type":"user","cwd":"/work/a","gitBranch":"latest"}"# + "\n", in: fixture.home)
    try fixture.write(".codex/sessions/2026/11/06/rollout-1.jsonl", #"{"payload":{"cwd":"/work/b","base_instructions":"x","git":{"commit_hash":"a","branch":"topic"}}}"# + "\n", in: fixture.home)
    try fixture.write(".codex/archived_sessions/rollout-2.jsonl", #"{"payload":{"cwd":"/work/c"}}"# + "\n", in: fixture.home)
    try fixture.write(".grok/sessions/%2Fwork%2Fd/session-1/summary.json", "{}", in: fixture.home)

    let indexer = SessionLogIndexer(home: home, cursorDatabase: URL(fileURLWithPath: fixture.root + "/none"))
    let first = indexer.update(from: [:])
    let byFolder = Dictionary(uniqueKeysWithValues: first.values.map { ($0.folder, $0) })
    #expect(byFolder["/work/a"]?.tool == "Claude Code")
    #expect(byFolder["/work/a"]?.branch == "latest")
    #expect(byFolder["/work/b"]?.tool == "Codex")
    #expect(byFolder["/work/b"]?.branch == "topic")
    #expect(byFolder["/work/c"]?.branch == nil)
    #expect(byFolder["/work/d"]?.tool == "Grok Build")

    // An unchanged log keeps its entry without being opened again.
    let claudeKey = try #require(first.first { $0.value.folder == "/work/a" }?.key)
    var previous = first
    previous[claudeKey]?.branch = "kept-from-cache"
    #expect(indexer.update(from: previous)[claudeKey]?.branch == "kept-from-cache")
}

// MARK: Locating repositories

@Test func locatorFollowsWorktreePointersToTheSharedDirectory() throws {
    let fixture = try GitFixture()
    try fixture.git(["worktree", "add", "--quiet", "-b", "topic", fixture.worktreePath("topic")])
    let expected = fixture.repository + "/.git"
    #expect(RepositoryLocator.commonDirectory(containing: fixture.repository) == expected)
    #expect(RepositoryLocator.commonDirectory(containing: fixture.worktreePath("topic")) == expected)
    try FileManager.default.createDirectory(atPath: fixture.repository + "/deep/inside", withIntermediateDirectories: true)
    #expect(RepositoryLocator.commonDirectory(containing: fixture.repository + "/deep/inside") == expected)
    #expect(RepositoryLocator.commonDirectory(containing: fixture.home) == nil)
}

@Test func protectedFoldersAreOfferedAsTheirProjectAndNotRead() throws {
    let locator = RepositoryLocator(home: "/Users/me")
    let result = locator.locate(folders: [
        "/Users/me/Documents/App/.claude/worktrees/one",
        "/Users/me/Documents/App/.claude/worktrees/two",
        "/Users/me/Documents/App",
        "/Users/me/Desktop/Other",
        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Third",
    ])
    #expect(result.repositories.isEmpty)
    #expect(result.notChecked == [
        "/Users/me/Desktop/Other",
        "/Users/me/Documents/App",
        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Third",
    ])
    #expect(!locator.isProtected("/Users/me/Documents2/App"))
    #expect(!locator.isProtected("/Users/me/Developer/App"))
    #expect(RepositoryLocator(home: "/Users/me", allowedFolders: ["/Users/me/Documents/App"]).isAllowed("/Users/me/Documents/App/sub"))
    #expect(!RepositoryLocator(home: "/Users/me", allowedFolders: ["/Users/me/Documents/App"]).isAllowed("/Users/me/Documents/Other"))
}

@Test func theShorthandForTemporaryFoldersMatchesTheRealPath() {
    #expect(RepositoryLocator.normalized("/tmp/x") == "/private/tmp/x")
    #expect(RepositoryLocator.normalized("/var/folders/a") == "/private/var/folders/a")
    #expect(RepositoryLocator.normalized("/Users/me/app/") == "/Users/me/app")
    #expect(RepositoryLocator.normalized("/") == "/")
}

// MARK: Status rules

private func facts(_ change: (inout WorkFacts) -> Void = { _ in }) -> WorkFacts {
    var facts = WorkFacts()
    facts.hasWorktree = true
    facts.folderExists = true
    facts.changedFiles = 0
    facts.untrackedFiles = 0
    facts.ownCommits = 2
    facts.commitsAtRisk = 0
    change(&facts)
    return facts
}

@Test func statusRulesPutWhatCouldBeLostFirst() {
    #expect(WorkRules.status(for: facts()) == .pushed)
    #expect(WorkRules.status(for: facts { $0.isMainCopy = true }) == .mainCopy)
    #expect(WorkRules.status(for: facts { $0.folderExists = false }) == .folderGone)
    #expect(WorkRules.status(for: facts { $0.runningProcesses = 1 }) == .inUse)
    #expect(WorkRules.status(for: facts { $0.sessionActiveRecently = true }) == .inUse)
    #expect(WorkRules.status(for: facts { $0.changedFiles = 1 }) == .notSaved)
    #expect(WorkRules.status(for: facts { $0.untrackedFiles = 1 }) == .notSaved)
    #expect(WorkRules.status(for: facts { $0.stashCount = 1 }) == .notSaved)
    #expect(WorkRules.status(for: facts { $0.commitsAtRisk = 1 }) == .notSaved)
    #expect(WorkRules.status(for: facts { $0.ownCommits = 0 }) == .empty)
    #expect(WorkRules.status(for: facts { $0.merge = .sameCommits }) == .finished)
    #expect(WorkRules.status(for: facts { $0.folderReadable = false }) == .notChecked)
    #expect(WorkRules.status(for: facts { $0.mainBranchKnown = false }) == .notChecked)
    #expect(WorkRules.status(for: facts { $0.changedFiles = nil }) == .checking)
    #expect(WorkRules.status(for: facts { $0.ownCommits = nil }) == .checking)
}

/// A squash-merged branch whose remote branch was deleted has commits on no
/// remote, but its work is on main.
@Test func mergedWorkCountsAsFinishedEvenIfItsCommitsLookUnpushed() {
    #expect(WorkRules.status(for: facts {
        $0.merge = .sameChanges(commit: "abc", pullRequest: 1)
        $0.commitsAtRisk = 3
    }) == .finished)
}

/// Running or dirty beats merged: the folder may hold work no commit records.
@Test func mergedWorkStillInUseOrDirtyIsNotFinished() {
    #expect(WorkRules.status(for: facts { $0.merge = .sameCommits; $0.runningProcesses = 1 }) == .inUse)
    #expect(WorkRules.status(for: facts { $0.merge = .sameCommits; $0.untrackedFiles = 1 }) == .notSaved)
}

@Test func deleteIsOfferedOnlyWhereNothingCanBeLost() {
    func eligibility(_ change: (inout WorkFacts) -> Void) -> DeleteEligibility {
        let value = facts(change)
        return WorkRules.eligibility(for: value, status: WorkRules.status(for: value))
    }
    #expect(eligibility { $0.merge = .sameCommits }.isAllowed)
    #expect(eligibility { $0.ownCommits = 0 }.isAllowed)
    #expect(eligibility { _ in }.isAllowed)
    #expect(eligibility { $0.folderExists = false }.isAllowed)
    #expect(!eligibility { $0.isMainCopy = true }.isAllowed)
    #expect(!eligibility { $0.runningProcesses = 1 }.isAllowed)
    #expect(!eligibility { $0.changedFiles = 1 }.isAllowed)
    #expect(!eligibility { $0.commitsAtRisk = 1 }.isAllowed)
    #expect(!eligibility { $0.folderReadable = false }.isAllowed)
    #expect(!eligibility { $0.changedFiles = nil }.isAllowed)
    #expect(!eligibility { $0.merge = .sameCommits; $0.isLocked = true }.isAllowed)
    #expect(!eligibility { $0.folderExists = false; $0.isLocked = true }.isAllowed)
    #expect(!eligibility { $0.merge = .sameCommits; $0.containsOtherWorktree = true }.isAllowed)
}

@Test func commandsToRunQuoteUnusualNames() {
    let item = WorkItem(
        id: "x", repositoryID: "r", repositoryName: "r", branch: "topic/it's",
        worktreePath: "/Users/me/My Work", tip: "abc", upstream: nil, committedAt: nil,
        facts: facts { $0.ownCommits = 0 }, ignoredFiles: []
    )
    #expect(item.commandsToRun == "git -C r worktree remove '/Users/me/My Work'\ngit -C r branch -D -- 'topic/it'\\''s'")
    var blocked = item
    blocked.facts.runningProcesses = 1
    #expect(blocked.commandsToRun == nil)
}

/// Pasted into a terminal in another repository, a bare `git branch -D` would
/// delete a branch with the same name there.
@Test func commandsToRunNameTheRepositoryTheyBelongTo() {
    let item = WorkItem(
        id: "x", repositoryID: "/work/app/.git", repositoryName: "app", branch: "topic",
        worktreePath: nil, tip: "abc", upstream: nil, committedAt: nil,
        facts: { var value = facts { $0.ownCommits = 0 }; value.hasWorktree = false; return value }()
    )
    #expect(item.commandsToRun == "git -C /work/app branch -D -- topic")
}

@Test func onlyRecentDeletionsThatCanBeUndoneAreOffered() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func record(daysAgo: Double, branchWasDeleted: Bool = true, tip: String? = "abc") -> DeletionRecord {
        DeletionRecord(
            repositoryDirectory: "/r/.git", repositoryName: "r", displayName: "topic", worktreePath: nil,
            branch: "topic", branchWasDeleted: branchWasDeleted, tip: tip, upstream: nil,
            deletedAt: now.addingTimeInterval(-daysAgo * 86400)
        )
    }
    let recent = record(daysAgo: 1)
    let tooOld = record(daysAgo: 15)
    let recordOnly = record(daysAgo: 1, branchWasDeleted: false)
    #expect(BranchesPresentation.restorable([recent, tooOld, recordOnly], now: now) == [recent])
}

/// The review must be able to list every ignored file that would go, so a row
/// whose list hasn't been read yet can't be deleted.
@Test func deleteWaitsUntilTheFoldersIgnoredFilesAreKnown() {
    var item = WorkItem(
        id: "x", repositoryID: "r", repositoryName: "r", branch: "topic",
        worktreePath: "/Users/me/Work", tip: "abc", upstream: nil, committedAt: nil,
        facts: facts { $0.ownCommits = 0 }
    )
    #expect(item.status == .empty)
    #expect(!item.eligibility.isAllowed)
    item.ignoredFiles = [".env"]
    #expect(item.eligibility.isAllowed)
    // With no folder there's nothing to read.
    item.ignoredFiles = nil
    item.worktreePath = nil
    item.facts.hasWorktree = false
    item.facts.folderExists = false
    #expect(item.eligibility.isAllowed)
}

// MARK: Tool storage and sizes

@Test func simulatorRuntimeListBecomesRuntimeEntries() {
    let json = #"{"A":{"runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":8500000000},"B":{"name":"no size"}}"#
    let entries = ToolStorageScanner.simulatorRuntimes(fromListJSON: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].name == "iOS 26.5 simulator runtime")
    #expect(entries[0].bytes == 8_500_000_000)
    #expect(entries[0].kind == .runtime)
}

@Test func toolStorageShowsTheBiggestFirstAndSkipsTinyFolders() {
    let entries = ToolStorageScanner.displayOrder([
        ToolStorageEntry(name: "small", path: nil, bytes: 1024, kind: .review),
        ToolStorageEntry(name: "big", path: nil, bytes: 50_000_000_000, kind: .history),
        ToolStorageEntry(name: "middle", path: nil, bytes: 20_000_000, kind: .rebuildable),
    ])
    #expect(entries.map(\.name) == ["big", "middle"])
}

@Test func onlyKnownCacheNamesCountAsRebuildable() {
    #expect(FolderSizer.cacheName(forIgnoredPath: "node_modules") == "node_modules")
    #expect(FolderSizer.cacheName(forIgnoredPath: "site/node_modules") == "node_modules")
    #expect(FolderSizer.cacheName(forIgnoredPath: "pkg/__pycache__") == "__pycache__")
    #expect(FolderSizer.cacheName(forIgnoredPath: ".env") == nil)
    #expect(FolderSizer.cacheName(forIgnoredPath: "secrets/keys.json") == nil)
}

@Test func nestedWorktreesAreNotCountedInsideTheFolderThatHoldsThem() async throws {
    let fixture = try GitFixture()
    let outer = fixture.root + "/sized"
    try fixture.write("data/big.bin", String(repeating: "x", count: 2_000_000), in: outer)
    try fixture.write("node_modules/dep.js", String(repeating: "y", count: 1_000_000), in: outer)
    try fixture.write(".env", "SECRET=1\n", in: outer)
    let inner = outer + "/data"
    let nestedBytes = try #require(await FolderSizer.bytes(of: inner))

    let size = try #require(await FolderSizer.measure(
        folder: outer, ignored: ["node_modules", ".env"], nestedSizes: [inner: nestedBytes], now: Date()
    ))
    #expect(size.totalBytes < 1_500_000)
    #expect(size.cacheBytes >= 1_000_000)
    #expect(size.cacheBytesByName["node_modules"] == size.cacheBytes)
    #expect(size.otherIgnored == [".env"])
}

// MARK: Commands

@Test func commandRunnerStreamsOneProcessIntoAnother() async {
    let output = await CommandRunner.run(
        piping: ShellCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"]),
        into: ShellCommand(executable: URL(fileURLWithPath: "/usr/bin/tr"), arguments: ["a-z", "A-Z"])
    )
    #expect(output.succeeded)
    #expect(output.trimmedText == "HELLO")
}

@Test func aFailureEarlierInAPipeFailsTheWholeRun() async {
    let output = await CommandRunner.run(
        piping: ShellCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: []),
        into: ShellCommand(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
    )
    #expect(!output.succeeded)
}

// The runner works at utility priority, so on a busy machine stopping a
// command can take seconds. These tests only need to tell a stopped command
// from one left to finish, so the command runs far longer than the limit.
@Test func commandRunnerStopsAtItsDeadline() async {
    let started = Date()
    let output = await CommandRunner.run(
        ShellCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"]),
        timeout: 0.2
    )
    #expect(output.timedOut)
    #expect(!output.succeeded)
    #expect(Date().timeIntervalSince(started) < 30)
}

@Test func commandRunnerMarksOversizedOutputAsUnusable() async {
    let output = await CommandRunner.run(
        ShellCommand(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: []),
        timeout: 0.3,
        maximumOutputBytes: 1024
    )
    #expect(output.stdout.count == 1024)
    #expect(output.truncated)
    #expect(!output.succeeded)
}

@Test func commandRunnerStopsWhenItsTaskIsCancelled() async {
    let started = Date()
    let task = Task {
        await CommandRunner.run(ShellCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"]), timeout: 120)
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    let output = await task.value
    #expect(!output.succeeded)
    #expect(Date().timeIntervalSince(started) < 30)
}

@Test func commandRunnerReportsAMissingProgram() async {
    let output = await CommandRunner.run(
        ShellCommand(executable: URL(fileURLWithPath: "/nonexistent/program"), arguments: [])
    )
    #expect(output.status == -1)
    #expect(!output.succeeded)
}

@Test func gitWithoutDeveloperToolsIsNeverStartedThroughTheShim() {
    #expect(GitClient.locate(fileExists: { $0 == "/usr/bin/git" }) == nil)
    #expect(GitClient.locate(fileExists: { $0 == "/opt/homebrew/bin/git" })?.executable.path == "/opt/homebrew/bin/git")
    #expect(GitClient.locate(fileExists: {
        $0 == "/usr/bin/git" || $0 == "/Library/Developer/CommandLineTools/usr/bin/git"
    })?.executable.path == "/usr/bin/git")
}

@Test func gitRunsWithRepositoryConfigDisarmed() {
    let command = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git")).command(in: "/repo", ["status"])
    #expect(command.arguments.starts(with: ["-C", "/repo"]))
    #expect(command.arguments.contains("core.fsmonitor=false"))
    #expect(command.arguments.contains("core.hooksPath=/dev/null"))
    #expect(command.arguments.last == "status")
    #expect(GitClient.stablePatchOptions.contains("--no-ext-diff"))
    #expect(GitClient.stablePatchOptions.contains("--no-textconv"))
    let environment = GitClient.environment(base: ["GIT_DIR": "/elsewhere", "PATH": "/bin"])
    #expect(environment["GIT_DIR"] == nil)
    #expect(environment["PATH"] == "/bin")
    #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["GIT_NO_LAZY_FETCH"] == "1")
}

// MARK: Processes

@Test func processScanFindsAChildsFolderButNotThisAppsOwnChildren() async throws {
    let fixture = try GitFixture()
    // A process started directly by this app is its own child and is ignored,
    // so a shell starts the one that should be seen.
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "sleep 30 & wait"]
    shell.currentDirectoryURL = URL(fileURLWithPath: fixture.repository)
    try shell.run()
    defer { shell.terminate() }

    var found: [WorkProcess] = []
    for _ in 0..<50 {
        found = ProcessScanner.scan().filter { $0.folder == fixture.repository }
        if found.contains(where: { $0.name == "sleep" }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(found.contains { $0.name == "sleep" })
    #expect(!found.contains { $0.id == shell.processIdentifier })
    #expect(!found.contains { $0.id == getpid() })
    for process in found where process.name == "sleep" { kill(process.id, SIGTERM) }
}

@Test func listeningPortsAreReadWithoutAHelper() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(bound == 0)
    #expect(listen(descriptor, 1) == 0)
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    let port = Int(UInt16(bigEndian: assigned.sin_port))
    #expect(ProcessScanner.listeningPorts(of: getpid()).contains(port))
}

@Test func sessionsAndProcessesAttachToTheDeepestWorktree() {
    func item(_ id: String, path: String?, branch: String?, repository: String = "repo") -> WorkItem {
        WorkItem(
            id: id, repositoryID: repository, repositoryName: "r", branch: branch, worktreePath: path,
            tip: nil, upstream: nil, committedAt: nil, facts: WorkFacts()
        )
    }
    func session(_ folder: String, branch: String? = nil, tool: String = "Codex") -> SessionLogEntry {
        SessionLogEntry(tool: tool, folder: folder, branch: branch, size: 0, modifiedAt: Date(timeIntervalSince1970: 100))
    }
    let items = [
        item("main", path: "/work/app", branch: "main"),
        item("nested", path: "/work/app/.claude/worktrees/x", branch: "x"),
        item("other", path: nil, branch: "topic"),
        item("elsewhere", path: "/work/other", branch: "z", repository: "repo2"),
    ]
    let links = BranchesScanner.link(
        items: items,
        sessions: [
            session("/work/app/src"),
            session("/work/app/.claude/worktrees/x/sub"),
            // Started in the main copy, working on another branch.
            session("/work/app", branch: "topic"),
            // Its folder is gone, but its branch name still identifies a row.
            session("/gone/folder", branch: "topic", tool: "Claude Code"),
            // Too general a name to link without a folder.
            session("/gone/other", branch: "main"),
        ],
        processes: [
            WorkProcess(id: 1, name: "node", folder: "/work/app/.claude/worktrees/x", memoryBytes: 0, startedAt: nil, ports: [3000]),
            WorkProcess(id: 2, name: "zsh", folder: "/work/app/src", memoryBytes: 0, startedAt: nil, ports: []),
            WorkProcess(id: 3, name: "unrelated", folder: "/work/application", memoryBytes: 0, startedAt: nil, ports: []),
        ],
        commonBranchNames: ["main"]
    )
    #expect(links.sessions["main"]?.count == 2)
    #expect(links.sessions["nested"]?.count == 1)
    #expect(links.sessions["other"]?.count == 2)
    #expect(links.sessions["other"]?.tools == ["Claude Code", "Codex"])
    #expect(links.processes["nested"]?.map(\.name) == ["node"])
    #expect(links.processes["main"]?.map(\.name) == ["zsh"])
    #expect(links.processes["elsewhere"] == nil)
}

// MARK: Presentation

private func presentationItem(
    id: String = "x",
    repository: String = "r",
    change: (inout WorkItem) -> Void = { _ in }
) -> WorkItem {
    var item = WorkItem(
        id: id, repositoryID: repository, repositoryName: repository, branch: id,
        worktreePath: "/work/" + id, tip: "abc", upstream: nil, committedAt: nil,
        facts: facts { $0.merge = .sameCommits }, ignoredFiles: []
    )
    change(&item)
    return item
}

@Test func countsGroupRowsByStatus() {
    let items = [
        presentationItem(id: "finished"),
        presentationItem(id: "unsaved") { $0.facts.changedFiles = 2 },
        presentationItem(id: "elsewhere", repository: "other"),
    ]
    #expect(BranchesPresentation.counts(items) == [.finished: 2, .notSaved: 1])
}

@Test func theReviewFlagsRecentUseIrreplaceableFilesAndUnmergedWork() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(BranchesPresentation.cautions(for: presentationItem(), now: now).isEmpty)

    let usedToday = presentationItem { $0.sessions.lastActiveAt = now.addingTimeInterval(-3600) }
    #expect(BranchesPresentation.cautions(for: usedToday, now: now).count == 1)
    let usedLongAgo = presentationItem { $0.sessions.lastActiveAt = now.addingTimeInterval(-7 * 86400) }
    #expect(BranchesPresentation.cautions(for: usedLongAgo, now: now).isEmpty)

    let cachesOnly = presentationItem { $0.ignoredFiles = ["node_modules", "site/.next"] }
    #expect(BranchesPresentation.cautions(for: cachesOnly, now: now).isEmpty)
    let withSecrets = presentationItem { $0.ignoredFiles = ["node_modules", ".env"] }
    let caution = BranchesPresentation.cautions(for: withSecrets, now: now)
    #expect(caution.count == 1)
    #expect(caution[0].contains(".env"))
    #expect(!caution[0].contains("node_modules"))

    let notOnMain = presentationItem { $0.facts.merge = nil }
    #expect(notOnMain.status == .pushed)
    #expect(BranchesPresentation.cautions(for: notOnMain, now: now).count == 1)
}

@Test func theRunningColumnLeadsWithWhatIsServing() {
    let idle = presentationItem()
    #expect(BranchesPresentation.runningSummary(idle) == "")
    let serving = presentationItem {
        $0.processes = [
            WorkProcess(id: 1, name: "zsh", folder: "/w", memoryBytes: 0, startedAt: nil, ports: []),
            WorkProcess(id: 2, name: "node", folder: "/w", memoryBytes: 0, startedAt: nil, ports: [4296]),
        ]
    }
    #expect(BranchesPresentation.runningSummary(serving) == "node on port 4296 and 1 more")
    let shells = presentationItem {
        $0.processes = ["zsh", "claude", "tail"].enumerated().map {
            WorkProcess(id: Int32($0.offset), name: $0.element, folder: "/w", memoryBytes: 0, startedAt: nil, ports: [])
        }
    }
    #expect(BranchesPresentation.runningSummary(shells) == "claude, tail and 1 more")
}

@Test func pathsInHomeAreShortened() {
    #expect(BranchesPresentation.abbreviated("/Users/me/Work/app", home: "/Users/me") == "~/Work/app")
    #expect(BranchesPresentation.abbreviated("/Users/me2/app", home: "/Users/me") == "/Users/me2/app")
    #expect(BranchesPresentation.abbreviated("/private/tmp/x", home: "/Users/me") == "/private/tmp/x")
}

@MainActor
@Test func aDeleteResultSaysWhatHappenedAndOffersUndoOnlyForWhatCan() {
    let record = DeletionRecord(
        repositoryDirectory: "/r/.git", repositoryName: "r", displayName: "topic", worktreePath: "/w",
        branch: "topic", branchWasDeleted: true, tip: "abc", upstream: nil, deletedAt: Date()
    )
    let recordOnly = DeletionRecord(
        repositoryDirectory: "/r/.git", repositoryName: "r", displayName: "gone", worktreePath: nil,
        branch: "gone", branchWasDeleted: false, tip: "abc", upstream: nil, deletedAt: Date()
    )
    let single = BranchesStore.message(for: [.deleted(record)])
    #expect(single.text == "Deleted topic.")
    #expect(!single.isProblem)
    #expect(single.undoable == [record])

    let mixed = BranchesStore.message(for: [
        .deleted(record),
        .deleted(recordOnly),
        .refused(name: "busy", reason: "Something is running."),
    ])
    #expect(mixed.text == "Deleted 2 items.\nbusy wasn't deleted. Something is running.")
    #expect(mixed.isProblem)
    #expect(mixed.undoable == [record])

    let partial = BranchesStore.message(for: [.failed(name: "topic", reason: "Git couldn't delete the branch.", record: record)])
    #expect(partial.isProblem)
    #expect(partial.undoable == [record])
}
