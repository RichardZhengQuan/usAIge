import Foundation
import Testing
@testable import UsageHUD

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 24 * 60 * 60

/// A finished worktree, measured, with nothing ignored that would be lost.
private func row(
    _ id: String,
    repository: String = "/work/app/.git",
    change: (inout WorkItem) -> Void = { _ in }
) -> WorkItem {
    var facts = WorkFacts()
    facts.hasWorktree = true
    facts.folderExists = true
    facts.changedFiles = 0
    facts.untrackedFiles = 0
    facts.ownCommits = 2
    facts.commitsAtRisk = 0
    facts.merge = .sameCommits
    var item = WorkItem(
        id: id, repositoryID: repository, repositoryName: "app", branch: id,
        worktreePath: "/work/trees/" + id, tip: "tip-" + id, upstream: nil,
        committedAt: now.addingTimeInterval(-10 * day), facts: facts, ignoredFiles: []
    )
    item.size = FolderSize(
        totalBytes: 1_000, cacheBytes: 600, cacheBytesByName: ["node_modules": 600],
        ignored: ["node_modules"], otherIgnoredBytes: 0, measuredAt: now
    )
    change(&item)
    return item
}

private func repository(_ id: String, name: String = "app", remote: String? = "git@github.com:me/app.git") -> RepositoryInfo {
    RepositoryInfo(id: id, name: name, project: remote.flatMap(ProjectIdentity.fromRemote))
}

// MARK: Lanes

@Test func eachRowGoesWhereItsDecisionBelongs() {
    #expect(BranchesBoard.lane(for: row("finished")) == .safeToClear)
    #expect(BranchesBoard.lane(for: row("empty") { $0.facts.ownCommits = 0; $0.facts.merge = nil }) == .safeToClear)
    #expect(BranchesBoard.lane(for: row("running") { $0.facts.runningProcesses = 1 }) == .running)
    #expect(BranchesBoard.lane(for: row("unsaved") { $0.facts.changedFiles = 3 }) == .needsLook)
    #expect(BranchesBoard.lane(for: row("pushed") { $0.facts.merge = nil }) == .needsLook)
    #expect(BranchesBoard.lane(for: row("locked") { $0.facts.isLocked = true }) == .needsLook)
    #expect(BranchesBoard.lane(for: row("gone") { $0.facts.folderExists = false }) == .safeToClear)
}

/// "Safe to clear" promises nothing is lost, so a folder holding a file no
/// build recreates can't be in it, even though it may be deleted.
@Test func aFolderWithFilesNoBuildBringsBackNeedsALook() {
    let secrets = row("secrets") { $0.ignoredFiles = ["node_modules", ".env"] }
    #expect(secrets.eligibility.isAllowed)
    #expect(BranchesBoard.lane(for: secrets) == .needsLook)
    #expect(BoardText.reason(secrets)?.text == "Keeps .env, which no build brings back")
    // Once the folder is gone, so are its files.
    let gone = row("gone") { $0.ignoredFiles = [".env"]; $0.facts.folderExists = false }
    #expect(BranchesBoard.lane(for: gone) == .safeToClear)
}

@Test func rowsStillBeingReadWaitOutsideTheColumns() {
    let unlisted = row("unlisted") { $0.ignoredFiles = nil }
    #expect(unlisted.isWaitingForIgnoredFiles)
    #expect(BranchesBoard.lane(for: unlisted) == nil)
    let checking = row("checking") { $0.facts.commitsAtRisk = nil }
    #expect(BranchesBoard.lane(for: checking) == nil)
    let board = BranchesBoard.make(
        snapshot: BranchesSnapshot(repositories: [repository("/work/app/.git")], items: [unlisted, checking, row("done")]),
        now: now
    )
    #expect(board.stillChecking == 2)
    #expect(board.safeToClear.map(\.id) == ["done"])
}

@Test func theMainCopyShowsOnlyWhileSomethingRunsInIt() {
    let main = row("main") { $0.facts.isMainCopy = true }
    #expect(BranchesBoard.lane(for: main) == nil)
    let busy = row("main") { $0.facts.isMainCopy = true; $0.facts.sessionActiveRecently = true }
    #expect(BranchesBoard.lane(for: busy) == .running)
}

@Test func whatMightBeLostComesFirst() {
    let items = [
        row("pushed") { $0.facts.merge = nil },
        row("one-commit") { $0.facts.merge = nil; $0.facts.commitsAtRisk = 1 },
        row("many-commits") { $0.facts.merge = nil; $0.facts.commitsAtRisk = 9 },
    ]
    let board = BranchesBoard.make(snapshot: BranchesSnapshot(repositories: [repository("/work/app/.git")], items: items), now: now)
    #expect(board.needsLook.map(\.id) == ["item|many-commits", "item|one-commit", "item|pushed"])
}

// MARK: Copies

@Test func anOldCopyOfAProjectGathersItsLooseEndsInOneCard() {
    let current = "/work/app/.git"
    let old = "/work/app-copy/.git"
    let items = [
        row("current-unsaved") { $0.facts.changedFiles = 1; $0.sessions.lastActiveAt = now.addingTimeInterval(-day) },
        row("old-unsaved", repository: old) { $0.facts.merge = nil; $0.facts.commitsAtRisk = 2 },
        row("old-pushed", repository: old) { $0.facts.merge = nil },
        row("old-finished", repository: old),
    ]
    let snapshot = BranchesSnapshot(
        repositories: [repository(current), repository(old, name: "app-copy", remote: "https://github.com/ME/app")],
        items: items
    )
    let board = BranchesBoard.make(snapshot: snapshot, now: now)
    #expect(board.needsLook.count == 2)
    guard case let .copy(copy) = board.needsLook.last else {
        Issue.record("Expected the old copy's card last")
        return
    }
    #expect(copy.repository.id == old)
    #expect(copy.projectName == "app")
    #expect(copy.items.map(\.id) == ["old-unsaved", "old-pushed"])
    #expect(copy.unsavedCount == 1)
    #expect(board.needsLookCount == 3)
    // What's safe in the copy is still safe.
    #expect(board.safeToClear.map(\.id) == ["old-finished"])
    #expect(board.projects.map(\.name) == ["app"])
}

@Test func aCopyUsedThisWeekIsntCalledOld() {
    let old = "/work/app-copy/.git"
    let items = [
        row("current") { $0.sessions.lastActiveAt = now.addingTimeInterval(-day) },
        row("copy-work", repository: old) { $0.facts.changedFiles = 1; $0.sessions.lastActiveAt = now.addingTimeInterval(-3 * day) },
    ]
    let snapshot = BranchesSnapshot(repositories: [repository("/work/app/.git"), repository(old)], items: items)
    #expect(BranchesBoard.leftoverCopies(snapshot: snapshot, now: now).isEmpty)
    let board = BranchesBoard.make(snapshot: snapshot, now: now)
    #expect(board.needsLook.map(\.id) == ["item|copy-work"])
}

@Test func projectsComeFromTheRemoteWithoutItsCredentials() {
    let token = ProjectIdentity.fromRemote("https://x-access-token:ghp_secret@github.com/Owner/Repo.git")
    #expect(token?.key == "github.com/owner/repo")
    #expect(token?.name == "Repo")
    #expect(token?.key.contains("secret") == false)
    #expect(ProjectIdentity.fromRemote("git@github.com:Owner/Repo.git")?.key == "github.com/owner/repo")
    #expect(ProjectIdentity.fromRemote("ssh://git@github.com:22/Owner/Repo/")?.key == "github.com/owner/repo")
    #expect(ProjectIdentity.fromRemote("/Users/me/Code/Repo.git") == ProjectIdentity(key: "/Users/me/Code/Repo", name: "Repo"))
    #expect(ProjectIdentity.fromRemote("file:///srv/git/Repo.git")?.key == "/srv/git/Repo")
    #expect(ProjectIdentity.fromRemote("") == nil)
}

// MARK: Search and projects

@Test func searchMatchesWhatTheWorkWasCalledAndProjectsNarrowIt() {
    let other = "/work/site/.git"
    let items = [
        row("fix-login") { $0.sessions.title = "Keep people signed in after an update" },
        row("menu-bar") { $0.subject = "Add the menu bar dot (#12)" },
        row("site-header", repository: other),
    ]
    let snapshot = BranchesSnapshot(
        repositories: [repository("/work/app/.git"), repository(other, name: "site", remote: "git@github.com:me/site.git")],
        items: items
    )
    #expect(BranchesBoard.make(snapshot: snapshot, query: "signed IN", now: now).safeToClear.map(\.id) == ["fix-login"])
    #expect(BranchesBoard.make(snapshot: snapshot, query: "menu dot", now: now).safeToClear.map(\.id) == ["menu-bar"])
    #expect(BranchesBoard.make(snapshot: snapshot, query: "nothing like it", now: now).safeToClear.isEmpty)
    let site = BranchesBoard.make(snapshot: snapshot, projectID: "github.com/me/site", now: now)
    #expect(site.safeToClear.map(\.id) == ["site-header"])
    #expect(site.projects.map(\.name) == ["app", "site"])
}

@Test func aCardIsNamedByTheSessionThenItsCommitThenItsFolder() {
    #expect(row("b") { $0.sessions.title = "Session title"; $0.subject = "Commit" }.workTitle == "Session title")
    #expect(row("b") { $0.subject = "Fix the rail (#131)" }.workTitle == "Fix the rail")
    #expect(row("b") { $0.subject = "" }.workTitle == "b")
    #expect(row("b") { $0.subject = ""; $0.worktreePath = nil }.workTitle == "b")
    #expect(row("b") { $0.subject = nil; $0.worktreePath = "/work/trees/review-folder" }.workTitle == "review-folder")
}

@Test func aFolderReusedForAnotherBranchDoesntBorrowItsTitle() {
    func entry(_ title: String?, branch: String?, at offset: TimeInterval) -> SessionLogEntry {
        SessionLogEntry(tool: "Claude Code", folder: "/f", branch: branch, size: 0,
                        modifiedAt: now.addingTimeInterval(offset), title: title)
    }
    let entries = [
        entry("Old work", branch: "old", at: -10),
        entry("Current work", branch: "current", at: -20),
        entry(nil, branch: "current", at: 0),
    ]
    #expect(WorkSessionSummary(entries: entries, branch: "current").title == "Current work")
    #expect(WorkSessionSummary(entries: entries, branch: nil).title == "Old work")
    #expect(WorkSessionSummary(entries: entries, branch: "current").lastActiveAt == now)
}

// MARK: Review

@Test func theReviewTicksEverythingButWhatWasUsedLately() {
    let quiet = row("quiet")
    let recent = row("recent") { $0.sessions.lastActiveAt = now.addingTimeInterval(-day) }
    let branchOnly = row("branch-only") { $0.worktreePath = nil; $0.facts.hasWorktree = false; $0.size = nil }
    let record = row("record") { $0.facts.folderExists = false }
    let items = [quiet, recent, branchOnly, record]
    #expect(items.map { ClearGroup.group(for: $0, now: now) } == [.quiet, .recent, .branches, .records])

    var selection = ClearSelection(items: items, now: now)
    #expect(selection.chosen == ["quiet", "branch-only", "record"])
    #expect(selection.bytes(from: items) == 2_000)
    #expect(selection.state(of: items) == nil)
    #expect(selection.state(of: [recent]) == false)

    selection.set([recent], to: true)
    #expect(selection.state(of: items) == true)
    #expect(selection.bytes(from: items) == 3_000)
    selection.set(items, to: false)
    #expect(selection.chosenItems(from: items).isEmpty)
}

@Test func freedSpaceCountsOnlyFoldersThatWentAway() {
    let folder = row("folder")
    let branchOnly = row("branch") { $0.worktreePath = nil }
    let refused = row("refused")
    func record(_ path: String?) -> DeletionRecord {
        DeletionRecord(
            repositoryDirectory: "/r", repositoryName: "r", displayName: "x", worktreePath: path, branch: "x",
            branchWasDeleted: true, tip: "t", upstream: nil, deletedAt: now
        )
    }
    let outcomes: [DeletionOutcome] = [
        .deleted(record("/work/trees/folder")),
        .deleted(record(nil)),
        .refused(name: "refused", reason: "changed"),
    ]
    #expect(BranchesStore.freedBytes(items: [folder, branchOnly, refused], outcomes: outcomes) == 1_000)
    // A delete stopped partway has fewer outcomes than rows.
    #expect(BranchesStore.freedBytes(items: [folder, branchOnly, refused], outcomes: Array(outcomes.prefix(1))) == 1_000)
}

// MARK: Words

@Test func cardsSayWhyTheyCantSimplyGo() {
    #expect(BoardText.reason(row("x") { $0.facts.merge = nil; $0.facts.commitsAtRisk = 1; $0.facts.changedFiles = 2 })?.text
        == "1 commit only here, 2 files not committed")
    #expect(BoardText.reason(row("x") { $0.facts.merge = nil; $0.facts.commitsAtRisk = 1 })?.isLoss == true)
    #expect(BoardText.reason(row("x") { $0.facts.merge = nil })?.text == "Pushed, but not on main yet")
    #expect(BoardText.reason(row("x")) == nil)
    #expect(BoardText.size(row("x") { $0.worktreePath = nil }) == "No folder")
    #expect(BoardText.size(row("x") { $0.size = nil }) == "Measuring…")
}

@Test func agesReadLikeAPersonWouldSayThem() {
    let calendar = Calendar.current
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
    #expect(BoardText.age(noon.addingTimeInterval(-3600), now: noon) == "today")
    #expect(BoardText.age(noon.addingTimeInterval(-day), now: noon) == "yesterday")
    #expect(BoardText.age(noon.addingTimeInterval(-5 * day), now: noon) == "5 days ago")
    #expect(BoardText.age(noon.addingTimeInterval(-21 * day), now: noon) == "3 weeks ago")
}

@Test func theTankFallsByWhatClearingFrees() {
    let disk = DiskSpace(totalBytes: 1_000, availableBytes: 100)
    #expect(disk.usedShare() == 0.9)
    #expect(disk.usedShare(freeing: 300) == 0.6)
    #expect(disk.usedShare(freeing: 5_000) == 0)
    #expect(DiskSpace(totalBytes: 0, availableBytes: 0).usedShare() == 0)
}

@Suite struct BranchesStorageSummaryTests {
    private func measured(_ id: String, total: Int64, cache: Int64, change: (inout WorkItem) -> Void = { _ in }) -> WorkItem {
        row(id) {
            $0.size?.totalBytes = total
            $0.size?.cacheBytes = cache
            change(&$0)
        }
    }

    @Test func totalsIncludeWorktreeCachesAndAllToolStorageWithoutChangingTheBoard() {
        let looking = measured("unsaved", total: 3_000, cache: 1_000) { $0.facts.changedFiles = 1 }
        let safe = measured("safe", total: 1_000, cache: 500)
        let board = BranchesBoard(needsLook: [.item(looking)], safeToClear: [safe])
        let original = board
        let summary = BranchesStorageSummary(board: board, toolStorage: [
            ToolStorageEntry(name: "History", path: "/tools/history", bytes: 800, kind: .history),
            ToolStorageEntry(name: "Runtime", path: nil, bytes: 1_200, kind: .runtime),
        ])
        #expect(summary.bytes(for: .worktrees) == 4_000)
        #expect(summary.bytes(for: .buildCache) == 1_500)
        #expect(summary.bytes(for: .toolStorage) == 2_000)
        #expect(board == original)
    }

    @Test func leftoverCopiesContributeTheirActualFolders() {
        let first = measured("first", total: 1_000, cache: 200)
        let second = measured("second", total: 2_000, cache: 300)
        let copy = LeftoverCopy(repository: repository("/copy/.git"), projectName: "app", items: [first, second], lastUsedAt: now)
        let board = BranchesBoard(needsLook: [
            .copy(copy), .notChecked(folder: "/unread"), .unreadable(repository("/failed/.git")),
        ])
        let summary = BranchesStorageSummary(board: board, toolStorage: [])
        #expect(summary.folders.map(\.id) == ["first", "second"])
        #expect(summary.bytes(for: .worktrees) == 3_000)
        #expect(summary.bytes(for: .buildCache) == 500)
    }

    @Test func runningMainMissingAndBranchOnlyRowsDoNotContributeStorage() {
        let items = [
            row("safe"),
            row("running") { $0.facts.runningProcesses = 1 },
            row("main") { $0.facts.isMainCopy = true },
            row("busy-main") { $0.facts.isMainCopy = true; $0.facts.sessionActiveRecently = true },
            row("gone") { $0.facts.folderExists = false },
            row("unread-and-missing") { $0.facts.folderReadable = false; $0.facts.folderExists = false },
            row("branch-only") { $0.worktreePath = nil; $0.facts.hasWorktree = false },
        ]
        let board = BranchesBoard.make(snapshot: BranchesSnapshot(repositories: [repository("/work/app/.git")], items: items), now: now)
        let summary = BranchesStorageSummary(board: board, toolStorage: [])
        #expect(Set(board.running.map(\.id)) == ["running", "busy-main"])
        #expect(summary.folders.map(\.id) == ["safe"])
        #expect(summary.bytes(for: .worktrees) == 1_000)
        #expect(summary.bytes(for: .buildCache) == 600)
    }

    @Test func differentRecordsForTheSameFolderCountItsBytesOnce() {
        let first = row("first") { $0.worktreePath = "/var/tmp/project/work/../tree/" }
        let duplicate = row("duplicate") { $0.worktreePath = "/private/var/tmp/project/tree" }
        let board = BranchesBoard(needsLook: [.item(first)], safeToClear: [duplicate])
        let summary = BranchesStorageSummary(board: board, toolStorage: [])
        #expect(summary.folders.map(\.id) == ["first"])
        #expect(summary.bytes(for: .worktrees) == 1_000)
        #expect(summary.bytes(for: .buildCache) == 600)
    }

    @Test func zeroAndUnreadMeasurementsHaveNoMeasuredBytes() {
        let board = BranchesBoard(safeToClear: [row("unread") { $0.size = nil }, measured("zero", total: 0, cache: 0)])
        let summary = BranchesStorageSummary(board: board, toolStorage: [
            ToolStorageEntry(name: "Empty", path: nil, bytes: 0, kind: .review),
        ])
        for kind in StorageCategory.allCases {
            #expect(summary.bytes(for: kind) == 0)
        }
        #expect(summary.cacheFolders.isEmpty)
    }

    @Test func cacheFoldersPutTheLargestFirstWithStableTies() {
        let board = BranchesBoard(safeToClear: [
            measured("z", total: 1_000, cache: 600),
            measured("a", total: 1_000, cache: 600),
            measured("large", total: 1_000, cache: 900),
            measured("empty", total: 1_000, cache: 0),
            row("unread") { $0.size = nil },
        ])
        #expect(BranchesStorageSummary(board: board, toolStorage: []).cacheFolders.map(\.id) == ["large", "a", "z"])
    }
}

// MARK: Session titles

@Test func claudeCodeTitlesPreferTheNameThePersonGave() {
    let log = Data("""
    {"type":"ai-title","aiTitle":"Model's idea","sessionId":"s"}
    {"type":"custom-title","customTitle":"First name","sessionId":"s"}
    {"type":"custom-title","customTitle":"Renamed \\"properly\\"","sessionId":"s"}
    """.utf8)
    #expect(SessionLogIndexer.claudeTitle(head: nil, tail: log) == "Renamed \"properly\"")
    let onlyAI = Data(#"{"type":"ai-title","aiTitle":"  Model's idea\nsecond line"}"#.utf8)
    #expect(SessionLogIndexer.claudeTitle(head: onlyAI, tail: Data()) == "Model's idea")
    #expect(SessionLogIndexer.claudeTitle(head: Data(#"{"cwd":"/x"}"#.utf8), tail: nil) == nil)
}

@Test func codexTitlesComeFromItsThreadIndex() {
    let index = Data("""
    {"id":"019DCF01-FFB5-7A13-BB0F-510B35F0BFD2","thread_name":"First","updated_at":"2026-04-27T12:56:11Z"}
    not json
    {"id":"019dcf01-ffb5-7a13-bb0f-510b35f0bfd2","thread_name":"Renamed","updated_at":"2026-04-28T12:56:11Z"}
    {"id":"019e057f-eda6-77e0-af84-262538997885","thread_name":"  "}
    """.utf8)
    let names = SessionLogIndexer.codexThreadNames(in: index)
    #expect(names == ["019dcf01-ffb5-7a13-bb0f-510b35f0bfd2": "Renamed"])
    #expect(SessionLogIndexer.codexThreadID(
        fromFileName: "rollout-2026-11-07T15-29-41-019DCF01-FFB5-7A13-BB0F-510B35F0BFD2.jsonl"
    ) == "019dcf01-ffb5-7a13-bb0f-510b35f0bfd2")
    #expect(SessionLogIndexer.codexThreadID(fromFileName: "notes.jsonl") == nil)
}

@Test func changedPathsSkipIgnoredFilesAndRenameSources() {
    let porcelain = Data(" M app.swift\0?? new.txt\0R  renamed.swift\0old.swift\0!! node_modules/\0".utf8)
    #expect(GitParsing.changedPaths(fromPorcelain: porcelain) == ["app.swift", "new.txt", "renamed.swift"])
}

// MARK: Memory rows

/// A worktree counts as running when its session wrote lately, even with no
/// process to measure. Such rows used to drop out of every Memory list.
@Test func runningWorkWithoutProcessesStaysListedUnderItsToolsMemoryLayer() {
    let measured = row("measured") {
        $0.processes = [WorkProcess(id: 7, name: "node", folder: "/work/trees/measured", memoryBytes: 500, startedAt: nil, ports: [])]
    }
    let claudeSession = row("claude-session") { $0.sessions.tools = ["Claude Code"] }
    let unknownTool = row("unknown-tool") { $0.sessions.tools = ["Somebody Else"] }
    let claude = PaperweightLayer(id: "tool-" + AIToolID.claude.rawValue, title: "Claude", bytes: 900, colorHex: 0, inkHex: 0, processIDs: [3])
    let dev = PaperweightLayer(id: "dev", title: "Dev servers", bytes: 500, colorHex: 0, inkHex: 0, processIDs: [7])
    let memory = PaperweightConfiguration(id: .memory, capacityBytes: 10_000, layers: [dev, claude], freeBytes: 8_600)
    let running = [measured, claudeSession, unknownTool]

    let devRows = PaperweightData.memoryRows(for: dev, in: memory, running: running)
    #expect(devRows.measured.map(\.id) == ["measured"])
    #expect(devRows.sessionOnly.isEmpty)

    let claudeRows = PaperweightData.memoryRows(for: claude, in: memory, running: running)
    #expect(claudeRows.measured.isEmpty)
    #expect(claudeRows.sessionOnly.map(\.id) == ["claude-session"])

    // A tool with no layer of its own still has a place: other memory.
    let otherRows = PaperweightData.memoryRows(for: memory.freeLayer, in: memory, running: running)
    #expect(otherRows.sessionOnly.map(\.id) == ["unknown-tool"])
}
