import Foundation
import Testing
@testable import UsageHUD

/// Each of these starts many git processes, so they run one at a time rather
/// than crowding the timing-sensitive tests running beside them.
@Suite(.serialized) struct BranchesScannerTests {

// MARK: Merge detection, against real history

@Test func aSquashMergedBranchIsFinishedAndNamesItsPullRequest() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: 42)
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .finished)
    guard case let .sameChanges(_, pullRequest) = row.facts.merge else {
        Issue.record("Expected a content match, got \(String(describing: row.facts.merge))")
        return
    }
    #expect(pullRequest == 42)
    #expect(row.workSummary == "All its changes are on main, as #42.")
    #expect(row.eligibility.isAllowed)
}

@Test func aSquashMergedBranchStaysFinishedAfterItsRemoteBranchIsDeleted() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    try fixture.git(["push", "--quiet", "origin", "--delete", "topic"])
    try fixture.git(["fetch", "--quiet", "--prune"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.commitsAtRisk ?? 0 > 0)
    #expect(row.status == .finished)
}

@Test func aRebaseMergedBranchIsFinished() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "A")
    try fixture.commit("b.txt", "b\n", message: "B")
    try fixture.git(["push", "--quiet", "-u", "origin", "topic"])
    // Main moves on, so copying the commits gives them new ids.
    try fixture.git(["switch", "--quiet", "main"])
    try fixture.commit("other.txt", "other\n", message: "Other work")
    try fixture.git(["cherry-pick", "topic~1", "topic"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == .sameCommits)
    #expect(row.status == .finished)
}

@Test func aBranchMergedWithAMergeCommitIsFinished() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "A")
    try fixture.git(["switch", "--quiet", "main"])
    try fixture.commit("other.txt", "other\n", message: "Other")
    try fixture.git(["merge", "--quiet", "--no-ff", "-m", "Merge topic", "topic"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == .mergeCommit)
    #expect(row.status == .finished)
}

@Test func aBrandNewBranchIsEmptyNotFinished() async throws {
    let fixture = try GitFixture()
    try fixture.git(["branch", "fresh"])
    let row = try #require(await fixture.scan().row(branch: "fresh"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .empty)
}

@Test func aPushedBranchNotOnMainIsPushed() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "A")
    try fixture.git(["push", "--quiet", "-u", "origin", "topic"])
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .pushed)
    #expect(row.facts.ownCommits == 1)
    #expect(row.facts.commitsAtRisk == 0)
}

@Test func localCommitsOnABranchAreNotSaved() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "A")
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .notSaved)
    #expect(row.statusExplanation == "1 commit exists only on this Mac.")
    #expect(!row.eligibility.isAllowed)
}

/// The real worktree that first showed as Empty: a detached folder holding
/// commits no branch, tag, or remote has.
@Test func aDetachedWorktreeWithCommitsOnNoBranchIsNotSaved() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("merge-sim")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path])
    try fixture.commit("a.txt", "a\n", message: "A", in: path)
    try fixture.commit("b.txt", "b\n", message: "B", in: path)
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.branch == nil)
    #expect(row.facts.commitsAtRisk == 2)
    #expect(row.status == .notSaved)
    #expect(!row.eligibility.isAllowed)
}

@Test func aDetachedWorktreeOnAnExistingBranchLosesNothing() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "A")
    let tip = try fixture.head()
    try fixture.git(["switch", "--quiet", "main"])
    let path = fixture.worktreePath("review")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path, tip])
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.facts.commitsAtRisk == 0)
    #expect(row.status == .pushed)
    #expect(row.eligibility.isAllowed)
}

/// `git patch-id` sees no difference between two changes to one binary file
/// unless the patch carries the content, and a wrong match here means data
/// loss.
@Test func differentChangesToTheSameBinaryFileAreNotAMatch() async throws {
    let fixture = try GitFixture()
    let binaryFile = fixture.repository + "/logo.bin"
    try Data([0, 1, 2, 3, 0, 9]).write(to: URL(fileURLWithPath: binaryFile))
    try fixture.git(["add", "logo.bin"])
    try fixture.git(["commit", "--quiet", "-m", "Add logo"])
    try fixture.git(["push", "--quiet", "origin", "main"])

    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try Data([0, 7, 7, 7, 0, 7]).write(to: URL(fileURLWithPath: binaryFile))
    try fixture.git(["commit", "--quiet", "-am", "Branch logo"])
    try fixture.git(["push", "--quiet", "-u", "origin", "topic"])

    try fixture.git(["switch", "--quiet", "main"])
    try Data([0, 5, 5, 5, 0, 5]).write(to: URL(fileURLWithPath: binaryFile))
    try fixture.git(["commit", "--quiet", "-am", "Main logo"])
    try fixture.git(["push", "--quiet", "origin", "main"])

    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .pushed)
}

@Test func theSameBinaryChangeOnMainIsAMatch() async throws {
    let fixture = try GitFixture()
    let binaryFile = fixture.repository + "/logo.bin"
    try Data([0, 1, 2, 3, 0, 9]).write(to: URL(fileURLWithPath: binaryFile))
    try fixture.git(["add", "logo.bin"])
    try fixture.git(["commit", "--quiet", "-m", "Add logo"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try Data([0, 7, 7, 7, 0, 7]).write(to: URL(fileURLWithPath: binaryFile))
    try fixture.git(["commit", "--quiet", "-am", "Branch logo"])
    try fixture.git(["push", "--quiet", "-u", "origin", "topic"])
    try fixture.git(["switch", "--quiet", "main"])
    try fixture.commit("other.txt", "x\n", message: "Other")
    try fixture.git(["merge", "--quiet", "--squash", "topic"])
    try fixture.git(["commit", "--quiet", "-m", "Squash"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .finished)
}

/// New commits added after a squash merge mean the branch's total change no
/// longer matches, so it must not stay Finished.
@Test func workAddedAfterASquashMergeIsNotFinished() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: 7)
    try fixture.git(["switch", "--quiet", "topic"])
    try fixture.commit("topic.txt", "one\ntwo\nthree\n", message: "After the merge")
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .notSaved)
}

/// `git patch-id` drops whitespace by default, so an indentation change, which
/// means something in Python or YAML, would look like the unindented commit.
@Test func aChangeThatDiffersOnlyInWhitespaceIsNotAMatch() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("run.py", "if ready:\n    start()\n", message: "Indented")
    try fixture.git(["switch", "--quiet", "main"])
    try fixture.commit("run.py", "if ready:\nstart()\n", message: "Not indented")
    try fixture.git(["push", "--quiet", "origin", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .notSaved)
}

/// Bringing back something main reverted makes a patch main's history already
/// has, but that work isn't on main.
@Test func reapplyingAChangeMainRevertedIsNotAMatch() async throws {
    let fixture = try GitFixture()
    try fixture.commit("feature.txt", "on\n", message: "Add feature")
    try fixture.git(["revert", "--no-edit", "HEAD"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("feature.txt", "on\n", message: "Reapply feature")
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .notSaved)
}

@Test func reapplyingSeveralRevertedCommitsIsNotAMatch() async throws {
    let fixture = try GitFixture()
    try fixture.commit("a.txt", "a\n", message: "Add a")
    try fixture.commit("b.txt", "b\n", message: "Add b")
    try fixture.git(["revert", "--no-edit", "HEAD"])
    try fixture.git(["revert", "--no-edit", "HEAD~2"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("a.txt", "a\n", message: "Add a again")
    try fixture.commit("b.txt", "b\n", message: "Add b again")
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .notSaved)
}

/// The same patch landing again after the branch started is a real merge, and
/// the newest commit with that patch is the one that counts.
@Test func aChangeThatLandedAgainAfterTheBranchStartedIsAMatch() async throws {
    let fixture = try GitFixture()
    try fixture.commit("feature.txt", "on\n", message: "Add feature")
    try fixture.git(["revert", "--no-edit", "HEAD"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    try fixture.commit("feature.txt", "on\n", message: "Reapply feature")
    try fixture.git(["push", "--quiet", "-u", "origin", "topic"])
    try fixture.git(["switch", "--quiet", "main"])
    try fixture.git(["merge", "--quiet", "--squash", "topic"])
    try fixture.git(["commit", "--quiet", "-m", "Reapply feature (#9)"])
    try fixture.git(["push", "--quiet", "origin", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .finished)
    #expect(row.workSummary == "All its changes are on main, as #9.")
}

/// A diff that dies partway still gives `patch-id` a clean, partial input, and
/// a partial change can match a real commit.
@Test func aMainBranchGitCantReadStillSettlesWithoutClaimingAMerge() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let blob = try fixture.git(["rev-parse", "topic:topic.txt"])
    let object = fixture.repository + "/.git/objects/" + blob.prefix(2) + "/" + blob.dropFirst(2)
    try FileManager.default.removeItem(atPath: object)
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.merge == nil)
    #expect(row.status == .pushed)
}

@Test func anOrphanWorktreeWithNoCommitsSettlesAsEmpty() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("orphan")
    try fixture.git(["worktree", "add", "--quiet", "--orphan", "-b", "orphan", path])
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.status == .empty)
}

// MARK: Worktree state

@Test func uncommittedOrNewFilesInAWorktreeAreNotSaved() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("changed", pullRequest: nil)
    try fixture.squashMerged("added", pullRequest: nil)
    let changed = fixture.worktreePath("changed")
    let added = fixture.worktreePath("added")
    try fixture.git(["worktree", "add", "--quiet", changed, "changed"])
    try fixture.git(["worktree", "add", "--quiet", added, "added"])
    try fixture.write("README.md", "edited\n", in: changed)
    try fixture.write("new.txt", "new\n", in: added)
    let snapshot = await fixture.scan()
    let changedRow = try #require(snapshot.row(worktree: changed))
    let addedRow = try #require(snapshot.row(worktree: added))
    #expect(changedRow.status == .notSaved)
    #expect(changedRow.facts.changedFiles == 1)
    #expect(addedRow.status == .notSaved)
    #expect(addedRow.facts.untrackedFiles == 1)
}

@Test func aFinishedWorktreeWithARunningProcessIsInUseAndShowsItsPort() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    fixture.setRunningProcesses([fixture.process(named: "node", in: path + "/site", ports: [4296])])
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.status == .inUse)
    #expect(row.processes.first?.ports == [4296])
    #expect(!row.eligibility.isAllowed)
}

@Test func aSessionWritingToItsLogMarksItsFolderInUse() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    try fixture.write(".claude/projects/p/s.jsonl", #"{"cwd":"\#(path)"}"# + "\n", in: fixture.home)
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.sessions.count == 1)
    #expect(row.sessions.tools == ["Claude Code"])
    #expect(row.status == .inUse)

    // The same session long after its last write no longer blocks anything.
    let later = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let settled = try #require(await fixture.scan(with: later).row(worktree: path))
    #expect(settled.status == .finished)
    #expect(settled.sessions.count == 1)
}

@Test func theMainCopyAndTheMainBranchCanNeverBeDeleted() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    let snapshot = await fixture.scan()
    let copy = try #require(snapshot.row(worktree: fixture.repository))
    let main = try #require(snapshot.row(branch: "main"))
    #expect(copy.status == .mainCopy)
    #expect(!copy.eligibility.isAllowed)
    #expect(main.status == .mainCopy)
    #expect(!main.eligibility.isAllowed)
}

@Test func aSecondWorktreeOnTheMainBranchKeepsThatBranch() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic"])
    let path = fixture.worktreePath("on-main")
    try fixture.git(["worktree", "add", "--quiet", path, "main"])
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.status == .mainCopy)
    #expect(!row.eligibility.isAllowed)
}

@Test func aLockedRecordWithAMissingFolderShowsItsNoteAndStays() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("archived")
    try fixture.git(["worktree", "add", "--quiet", "-b", "archived", path])
    try fixture.git(["worktree", "lock", "--reason", "Keep until archived.", path])
    try FileManager.default.removeItem(atPath: path)
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.status == .folderGone)
    #expect(row.facts.lockReason == "Keep until archived.")
    #expect(!row.eligibility.isAllowed)
    #expect(row.commandsToRun == nil)
}

@Test func aFolderHoldingAnotherWorktreeCantBeDeleted() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("outer", pullRequest: nil)
    try fixture.squashMerged("inner", pullRequest: nil)
    let outer = fixture.worktreePath("outer")
    let inner = outer + "/.claude/worktrees/inner"
    try fixture.git(["worktree", "add", "--quiet", outer, "outer"])
    try fixture.git(["worktree", "add", "--quiet", inner, "inner"])
    // Ignored locally, as real projects ignore their `.claude` folder.
    try fixture.write(".git/info/exclude", ".claude\n", in: fixture.repository)
    let snapshot = await fixture.scan()
    let outerRow = try #require(snapshot.row(worktree: outer))
    #expect(outerRow.status == .finished)
    #expect(outerRow.facts.containsOtherWorktree)
    #expect(!outerRow.eligibility.isAllowed)
    #expect(try #require(snapshot.row(worktree: inner)).eligibility.isAllowed)
}

@Test func aStashMadeOnABranchIsNotSaved() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    try fixture.git(["switch", "--quiet", "topic"])
    try fixture.write("README.md", "edited\n")
    try fixture.git(["stash", "push", "--quiet", "-m", "later"])
    try fixture.git(["switch", "--quiet", "main"])
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.facts.stashCount == 1)
    #expect(row.status == .notSaved)
}

@Test func ignoredFilesSplitIntoCachesAndFilesNoBuildBringsBack() async throws {
    let fixture = try GitFixture()
    try fixture.commit(".gitignore", "node_modules/\n.env\n", message: "Ignore")
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    try fixture.write("node_modules/dep.js", String(repeating: "x", count: 100_000), in: path)
    try fixture.write(".env", "SECRET=1\n", in: path)
    let row = try #require(await fixture.scan().row(worktree: path))
    #expect(row.status == .finished)
    #expect(row.irreplaceableIgnored == [".env"])
    let size = try #require(row.size)
    #expect(size.cacheBytesByName["node_modules"] ?? 0 >= 100_000)
    #expect(size.otherIgnored == [".env"])
    #expect(size.totalBytes >= size.cacheBytes)
}

@Test func aRepositoryWithoutAMainBranchIsNotCheckedRatherThanGuessed() async throws {
    let fixture = try GitFixture()
    let lonely = fixture.root + "/lonely"
    try fixture.git(["init", "--quiet", "-b", "trunk", lonely], in: fixture.root)
    try fixture.commit("a.txt", "a\n", message: "A", in: lonely)
    try fixture.git(["branch", "side"], in: lonely)
    let scanner = BranchesScanner(environment: BranchesScanner.Environment(
        home: URL(fileURLWithPath: fixture.home),
        cacheFile: URL(fileURLWithPath: fixture.root + "/cache/lonely.json"),
        deletionLogFile: URL(fileURLWithPath: fixture.root + "/support/lonely.json"),
        git: GitClient.locate(),
        cursorDatabase: URL(fileURLWithPath: fixture.root + "/none"),
        addedFolders: { [lonely] },
        processes: { [] },
        now: Date.init
    ))
    let row = try #require(await fixture.scan(with: scanner).row(branch: "side"))
    #expect(row.status == .notChecked)
    #expect(!row.eligibility.isAllowed)
}

// MARK: Scanning cost

@Test func aSecondScanReusesWhatItAlreadyKnowsFromDisk() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: 5)
    _ = await fixture.scan()
    let cacheFile = URL(fileURLWithPath: fixture.root + "/cache/branches.json")
    let saved = try JSONDecoder().decode(BranchesCacheFile.self, from: Data(contentsOf: cacheFile))
    let stored = try #require(saved.repositories[fixture.repository + "/.git"])
    let tip = try fixture.head("topic")
    #expect(stored.tips[tip]?.merge != nil)
    #expect(stored.index?.baseCommit == (try fixture.head("origin/main")))

    // A fresh scanner, as a reopened window has, shows the merge immediately.
    let scanner = fixture.scanner()
    let collector = SnapshotCollector()
    actor FirstRows { var value: [WorkItem]?; func set(_ rows: [WorkItem]) { if value == nil, !rows.isEmpty { value = rows } } }
    let first = FirstRows()
    await scanner.scan(force: false) { snapshot in
        await collector.store(snapshot)
        await first.set(snapshot.items)
    }
    let firstRows = try #require(await first.value)
    #expect(firstRows.first { $0.branch == "topic" }?.facts.merge != nil)
}

/// Equal rows trading places on every refresh would move them under the pointer.
@Test func rowsComeOutInTheSameOrderEveryTime() async throws {
    let fixture = try GitFixture()
    for name in ["one", "two", "three", "four", "five"] { try fixture.git(["branch", name]) }
    let scanner = fixture.scanner()
    let first = await fixture.scan(with: scanner).items.map(\.id)
    #expect(first == first.sorted())
    for _ in 0..<5 {
        #expect(await scanner.refreshRunningProcesses().items.map(\.id) == first)
    }
}

@Test func anUnreadableCacheFileOnlyCostsASlowerScan() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    try fixture.write("cache/branches.json", "not json", in: fixture.root)
    let row = try #require(await fixture.scan().row(branch: "topic"))
    #expect(row.status == .finished)
}

@Test func theScanNeverChangesTheRepository() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    let before = try fixture.git(["for-each-ref"])
    let worktreesBefore = try fixture.git(["worktree", "list", "--porcelain"])
    let objectsBefore = try fixture.git(["count-objects", "-v"])
    _ = await fixture.scan()
    #expect(try fixture.git(["for-each-ref"]) == before)
    #expect(try fixture.git(["worktree", "list", "--porcelain"]) == worktreesBefore)
    #expect(try fixture.git(["count-objects", "-v"]) == objectsBefore)
}

/// The window has no way to reach a network through what it runs: no remote
/// branch moves even if origin's copy has changed.
@Test func theScanDoesNotFetch() async throws {
    let fixture = try GitFixture()
    let other = fixture.root + "/other"
    try fixture.git(["clone", "--quiet", fixture.origin, other], in: fixture.root)
    try fixture.commit("remote.txt", "x\n", message: "Remote only", in: other)
    try fixture.git(["push", "--quiet", "origin", "main"], in: other)
    let before = try fixture.head("origin/main")
    _ = await fixture.scan()
    #expect(try fixture.head("origin/main") == before)
}

// MARK: Deleting

private func delete(_ row: WorkItem, in fixture: GitFixture, scanner: BranchesScanner) async -> DeletionOutcome {
    let outcomes = await scanner.delete([row]) { _ in }
    return outcomes[0]
}

@Test func deletingAFinishedWorktreeRemovesTheFolderAndBranchButNotTheRemote() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    #expect(row.status == .finished)

    let outcome = await delete(row, in: fixture, scanner: scanner)
    guard case .deleted = outcome else {
        Issue.record("Expected a delete, got \(outcome)")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try fixture.git(["branch", "--list", "topic"]).isEmpty)
    #expect(!(try fixture.git(["worktree", "list"])).contains(path))
    #expect(try fixture.git(["ls-remote", "--heads", "origin", "topic"]).contains("topic"))
    #expect(try fixture.git(["rev-parse", "--verify", "--quiet", "origin/topic"]).isEmpty == false)
    // `config --get-regexp` fails when nothing matches.
    #expect((try? fixture.git(["config", "--get-regexp", "^branch\\.topic\\."])) == nil)
}

@Test func undoBringsBackTheBranchFolderAndUpstream() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let tip = try fixture.head("topic")
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    let outcome = await delete(row, in: fixture, scanner: scanner)
    let record = try #require(outcome.record)
    #expect(record.canUndo)

    #expect(await scanner.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: path + "/topic.txt"))
    #expect(try fixture.head("topic") == tip)
    #expect(try fixture.git(["rev-parse", "--abbrev-ref", "topic@{upstream}"]) == "origin/topic")
    #expect(try fixture.git(["worktree", "list"]).contains(path))
    let snapshot = await fixture.scan(with: scanner)
    #expect(snapshot.deletions.isEmpty)
    #expect(snapshot.row(worktree: path)?.status == .finished)
}

@Test func undoDoesNotBringBackIgnoredFiles() async throws {
    let fixture = try GitFixture()
    try fixture.commit(".gitignore", "node_modules/\n", message: "Ignore")
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    try fixture.write("node_modules/dep.js", "x", in: path)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    let record = try #require(await delete(row, in: fixture, scanner: scanner).record)
    #expect(await scanner.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: path + "/topic.txt"))
    #expect(!FileManager.default.fileExists(atPath: path + "/node_modules/dep.js"))
}

@Test func deletingABranchWithoutAFolderLeavesEverythingElse() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let tip = try fixture.head("topic")
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(branch: "topic"))
    #expect(row.worktreePath == nil)
    let record = try #require(await delete(row, in: fixture, scanner: scanner).record)
    #expect(try fixture.git(["branch", "--list", "topic"]).isEmpty)
    #expect(await scanner.undo(record) == nil)
    #expect(try fixture.head("topic") == tip)
}

@Test func deletingADetachedFolderHasNoBranchToRemove() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("detached")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path])
    let branches = try fixture.git(["branch", "--list"])
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    #expect(row.status == .empty)
    let record = try #require(await delete(row, in: fixture, scanner: scanner).record)
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try fixture.git(["branch", "--list"]) == branches)
    #expect(record.canUndo)
    #expect(await scanner.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: path + "/README.md"))
}

@Test func aFoldersRecordGoesButItsBranchStaysUnjudged() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("vanished")
    try fixture.git(["worktree", "add", "--quiet", "-b", "vanished", path])
    try fixture.commit("work.txt", "only here\n", message: "Local work", in: path)
    try FileManager.default.removeItem(atPath: path)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    #expect(row.status == .folderGone)
    #expect(row.eligibility.isAllowed)
    #expect(!row.removesBranch)
    let outcome = await delete(row, in: fixture, scanner: scanner)
    let record = try #require(outcome.record)
    #expect(!record.canUndo)
    #expect(!(try fixture.git(["worktree", "list"])).contains(path))
    #expect(try fixture.git(["branch", "--list", "vanished"]).contains("vanished"))
}

// MARK: The re-check before deleting

private func expectRefused(_ outcome: DeletionOutcome, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .refused = outcome else {
        Issue.record("Expected a refusal, got \(outcome)", sourceLocation: sourceLocation)
        return
    }
}

private func finishedWorktree(_ fixture: GitFixture, ignored: String? = nil) async throws -> (path: String, row: WorkItem, scanner: BranchesScanner) {
    if let ignored {
        try fixture.commit(".gitignore", ignored + "\n", message: "Ignore")
        try fixture.git(["push", "--quiet", "origin", "main"])
    }
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    #expect(row.status == .finished)
    return (path, row, scanner)
}

@Test func aCommitAddedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    try fixture.commit("late.txt", "late\n", message: "Late", in: path)
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path + "/late.txt"))
    #expect(try fixture.git(["branch", "--list", "topic"]).contains("topic"))
}

@Test func aFileCreatedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    try fixture.write("draft.txt", "draft\n", in: path)
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path + "/draft.txt"))
}

@Test func aProcessStartedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    fixture.setRunningProcesses([fixture.process(named: "node", in: path)])
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func anIgnoredFileThatAppearedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture, ignored: ".env")
    try fixture.write(".env", "SECRET=1\n", in: path)
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path + "/.env"))
}

@Test func anIgnoredFileThePersonReviewedDoesNotStopTheDelete() async throws {
    let fixture = try GitFixture()
    try fixture.commit(".gitignore", ".env\n", message: "Ignore")
    try fixture.git(["push", "--quiet", "origin", "main"])
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("topic")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    try fixture.write(".env", "SECRET=1\n", in: path)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    #expect(row.irreplaceableIgnored == [".env"])
    guard case .deleted = await delete(row, in: fixture, scanner: scanner) else {
        Issue.record("Expected the reviewed file not to stop the delete")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aWorktreeLockedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    try fixture.git(["worktree", "lock", path])
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func aBranchMovedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(branch: "topic"))
    try fixture.git(["switch", "--quiet", "topic"])
    try fixture.commit("late.txt", "late\n", message: "Late")
    let tip = try fixture.head()
    try fixture.git(["switch", "--quiet", "main"])
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(try fixture.head("topic") == tip)
}

/// The person reviewed "removes the folder and the branch". With the folder
/// gone that's no longer what would happen, so nothing happens.
@Test func aFolderThatVanishedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    try FileManager.default.removeItem(atPath: path)
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(try fixture.git(["branch", "--list", "topic"]).contains("topic"))
    #expect(try fixture.git(["worktree", "list"]).contains(path))
}

@Test func workThatStoppedBeingMergedAfterTheReviewStopsTheDelete() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    try fixture.git(["update-ref", "refs/remotes/origin/main", try fixture.head("origin/main~1")])
    expectRefused(await delete(row, in: fixture, scanner: scanner))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try fixture.git(["branch", "--list", "topic"]).contains("topic"))

    // The next look shows what the refusal found, not the remembered merge.
    let collector = SnapshotCollector()
    await scanner.scan(force: false) { await collector.store($0) }
    #expect(await collector.latest.row(worktree: path)?.status == .pushed)
}

/// The list of ignored files comes with the size reading, which lasts an hour,
/// so a refusal has to refresh it or every retry would be refused too.
@Test func aRefusalOverNewIgnoredFilesLetsTheNextReviewShowThem() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture, ignored: ".env")
    try fixture.write(".env", "SECRET=1\n", in: path)
    expectRefused(await delete(row, in: fixture, scanner: scanner))

    let collector = SnapshotCollector()
    await scanner.scan(force: false) { await collector.store($0) }
    let refreshed = try #require(await collector.latest.row(worktree: path))
    #expect(refreshed.irreplaceableIgnored == [".env"])
    guard case .deleted = await delete(refreshed, in: fixture, scanner: scanner) else {
        Issue.record("Expected the delete to go ahead once the file had been shown")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: path))
}

/// Git itself refuses to delete a branch a rebase is using, but `update-ref`
/// doesn't ask. While paused, the folder is detached and the branch has no row
/// tying it to that folder.
@Test func aBranchBeingRebasedInAnotherWorktreeIsKept() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    let path = fixture.worktreePath("rebasing")
    try fixture.git(["worktree", "add", "--quiet", path, "topic"])
    try fixture.git(["-c", "sequence.editor=sed -i '' '1s/^pick/edit/'", "rebase", "--quiet", "-i", "HEAD~1"], in: path)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(branch: "topic"))
    #expect(row.worktreePath == nil)
    #expect(row.eligibility.isAllowed)
    guard case .failed = await delete(row, in: fixture, scanner: scanner) else {
        Issue.record("Expected Git to refuse")
        return
    }
    #expect(try fixture.git(["branch", "--list", "topic"]).contains("topic"))
}

@Test func aBranchNameThatLooksLikeAnOptionIsDeletedByName() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: nil)
    try fixture.git(["update-ref", "refs/heads/-D", try fixture.head("topic")])
    let branches = try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads"])
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(branch: "-D"))
    guard case .deleted = await delete(row, in: fixture, scanner: scanner) else {
        Issue.record("Expected the delete to work")
        return
    }
    let remaining = try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads"])
    #expect(remaining == branches.split(separator: "\n").filter { $0 != "refs/heads/-D" }.joined(separator: "\n"))
}

/// The commits of a detached folder aren't all it can leave behind: its stashes
/// aren't tied to any branch row, but they live in the shared repository.
@Test func aStashMadeInADetachedWorktreeSurvivesDeletingIt() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("detached")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path])
    try fixture.write("README.md", "edited\n", in: path)
    try fixture.git(["stash", "push", "--quiet", "-m", "later"], in: path)
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let row = try #require(await fixture.scan(with: scanner).row(worktree: path))
    guard case .deleted = await delete(row, in: fixture, scanner: scanner) else {
        Issue.record("Expected the delete to work")
        return
    }
    #expect(try fixture.git(["stash", "list"]).contains("later"))
}

@Test func undoCanBeRetriedAfterOnlyHalfOfItWorked() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    let tip = try fixture.head("topic")
    let record = try #require(await delete(row, in: fixture, scanner: scanner).record)

    // Something now sits where the folder was, so only the branch can return.
    try fixture.write("blocker.txt", "x", in: path)
    let failure = try #require(await scanner.undo(record))
    #expect(failure.hasPrefix("The branch is back."))
    #expect(try fixture.head("topic") == tip)

    try FileManager.default.removeItem(atPath: path)
    #expect(await scanner.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: path + "/topic.txt"))
}

@Test func deletionsAreRememberedForUndoAcrossRestarts() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    _ = await delete(row, in: fixture, scanner: scanner)

    let reopened = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let snapshot = await fixture.scan(with: reopened)
    let record = try #require(snapshot.deletions.first)
    #expect(record.branch == "topic")
    #expect(await reopened.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func undoStopsRatherThanOverwriteWhatTookThePlaceOfTheDeletedWork() async throws {
    let fixture = try GitFixture()
    let (path, row, scanner) = try await finishedWorktree(fixture)
    let record = try #require(await delete(row, in: fixture, scanner: scanner).record)
    try fixture.git(["branch", "topic"])
    let failure = await scanner.undo(record)
    #expect(failure != nil)
    #expect(!FileManager.default.fileExists(atPath: path))
}

// MARK: What the cards show

@Test func cardsAreNamedByTheirOwnLastCommitAndTheRepositoryByItsRemote() async throws {
    let fixture = try GitFixture()
    try fixture.squashMerged("topic", pullRequest: 7)
    try fixture.git(["branch", "fresh"])
    let snapshot = await fixture.scan()
    // The squash names the branch's own commit, not the one main got.
    #expect(try #require(snapshot.row(branch: "topic")).workTitle == "Two")
    // A branch sitting on main has nothing of its own to be called.
    let fresh = try #require(snapshot.row(branch: "fresh"))
    #expect(fresh.subject == "")
    #expect(fresh.workTitle == "fresh")
    let repository = try #require(snapshot.repositories.first)
    // A clone of a folder is known by that folder, without its `.git`.
    #expect(repository.project?.key == fixture.root + "/origin")
    #expect(repository.project?.name == "origin")
    #expect(repository.folder == fixture.repository)
}

@Test func aCardShowsTheCommitsAndFilesThatWouldBeLost() async throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("local")
    try fixture.git(["worktree", "add", "--quiet", "-b", "local", path])
    try fixture.commit("one.txt", "1\n", message: "Only here, first", in: path)
    try fixture.commit("two.txt", "2\n", message: "Only here, second", in: path)
    try fixture.write("draft.txt", "draft\n", in: path)
    try fixture.write("one.txt", "changed\n", in: path)
    let scanner = fixture.scanner()
    let row = try #require(await fixture.scan(with: scanner).row(branch: "local"))
    #expect(row.status == .notSaved)
    #expect(row.workTitle == "Only here, second")

    let evidence = await scanner.evidence(for: row)
    #expect(evidence.commits == ["Only here, second", "Only here, first"])
    #expect(evidence.moreCommits == 0)
    #expect(Set(evidence.files) == ["one.txt", "draft.txt"])
}

@Test func pushedWorkShowsWhatIsntOnMainYet() async throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "shared"])
    try fixture.commit("s.txt", "s\n", message: "Shared work")
    try fixture.git(["push", "--quiet", "-u", "origin", "shared"])
    try fixture.git(["switch", "--quiet", "main"])
    let scanner = fixture.scanner()
    let row = try #require(await fixture.scan(with: scanner).row(branch: "shared"))
    #expect(row.status == .pushed)
    #expect(await scanner.evidence(for: row).commits == ["Shared work"])
}

@Test func stoppingAClearLeavesTheRestAlone() async throws {
    let fixture = try GitFixture()
    for name in ["one", "two"] { try fixture.squashMerged(name, pullRequest: nil) }
    let scanner = fixture.scanner(now: { Date().addingTimeInterval(3600) })
    let snapshot = await fixture.scan(with: scanner)
    let rows = ["one", "two"].compactMap { snapshot.row(branch: $0) }
    #expect(rows.count == 2)
    let task = Task { await scanner.delete(rows) { _ in } }
    task.cancel()
    let outcomes = await task.value
    // Stopping takes effect between rows, so the last one is never reached.
    #expect(outcomes.count < rows.count)
    #expect(try fixture.git(["branch", "--list", "two"]).contains("two"))
}

@Test func stoppingDuringRemovalFinishesTheRowAndKeepsItsUndoRecord() async throws {
    let fixture = try GitFixture()
    for name in ["one", "two"] {
        try fixture.squashMerged(name, pullRequest: nil)
        try fixture.git(["worktree", "add", "--quiet", fixture.worktreePath(name), name])
    }
    let git = try #require(GitClient.locate())
    let started = fixture.root + "/removal-started"
    let resume = fixture.root + "/resume-removal"
    let wrapper = fixture.root + "/blocking-git"
    // Hold the actual removal command open, after all safety reads finished.
    // Cancellation must not terminate it before it can complete its row.
    try fixture.write("blocking-git", """
        #!/bin/sh
        trap 'exit 143' TERM
        previous=
        for argument do
            if [ "$previous:$argument" = "worktree:remove" ]; then
                : > '\(started)'
                attempts=0
                while [ ! -f '\(resume)' ] && [ "$attempts" -lt 1000 ]; do
                    /bin/sleep 0.01
                    attempts=$((attempts + 1))
                done
                [ -f '\(resume)' ] || exit 124
            fi
            previous=$argument
        done
        exec '\(git.executable.path)' "$@"
        """, in: fixture.root)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    let repository = fixture.repository
    let deletionLog = URL(fileURLWithPath: fixture.root + "/support/deletions.json")
    let scanner = BranchesScanner(environment: .init(
        home: URL(fileURLWithPath: fixture.home),
        cacheFile: URL(fileURLWithPath: fixture.root + "/cache/branches.json"),
        deletionLogFile: deletionLog,
        git: GitClient(executable: URL(fileURLWithPath: wrapper)),
        cursorDatabase: nil,
        addedFolders: { [repository] },
        processes: { [] },
        now: { Date().addingTimeInterval(3600) }
    ))
    let snapshot = await fixture.scan(with: scanner)
    let first = try #require(snapshot.row(worktree: fixture.worktreePath("one")))
    let second = try #require(snapshot.row(worktree: fixture.worktreePath("two")))
    let task = Task { await scanner.delete([first, second]) { _ in } }
    for _ in 0..<1000 {
        if FileManager.default.fileExists(atPath: started) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let removalStarted = FileManager.default.fileExists(atPath: started)
    task.cancel()
    try Data().write(to: URL(fileURLWithPath: resume))
    let outcomes = await task.value
    try #require(removalStarted)
    #expect(outcomes.count == 1)
    guard case let .deleted(record) = outcomes.first else {
        Issue.record("The active row should finish after Stop, got \(outcomes)")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.worktreePath("one")))
    #expect(try fixture.git(["branch", "--list", "one"]).isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.worktreePath("two")))
    #expect(try fixture.git(["branch", "--list", "two"]).contains("two"))
    #expect(record.canUndo)
    let persisted = try JSONDecoder().decode([DeletionRecord].self, from: Data(contentsOf: deletionLog))
    #expect(persisted.contains(record))
    #expect(await scanner.undo(record) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.worktreePath("one") + "/one.txt"))
    #expect(try fixture.head("one") == first.tip)
}

}
