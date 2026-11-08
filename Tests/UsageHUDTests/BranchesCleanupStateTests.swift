import Foundation
import Testing
@testable import UsageHUD

@Suite(.serialized)
struct BranchesCleanupStateTests {
    @MainActor
    @Test func cleanupSurvivesCloseReopenAndRefreshWithoutLosingItsProgress() async throws {
        let fixture = try await Task.detached { try BlockingCleanupFixture() }.value
        defer { try? fixture.resume() }
        let snapshot = await fixture.gitFixture.scan(with: fixture.scanner)
        let rows = try fixture.reviewedRows(in: snapshot)
        let store = BranchesStore(scanner: fixture.scanner, initialSnapshot: snapshot)
        store.startDelete(rows)
        // State is claimed synchronously, before the work task gets a turn.
        #expect(store.isDeleting)
        #expect(store.cleanupProgress?.total == 2)
        #expect(store.cleanupProgress?.currentName == rows[0].displayName)
        // A duplicate command cannot replace the running task or its total.
        store.startDelete([rows[1]])
        #expect(store.cleanupProgress?.total == 2)
        try await waitFor { fixture.removalStarted }

        let progress = try #require(store.cleanupProgress)
        store.windowClosed()
        store.windowOpened()
        store.refresh()
        #expect(store.cleanupProgress == progress)
        #expect(store.isDeleting)
        #expect(!store.isMeasuringToolStorage)
        try fixture.resume()
        try await waitFor { !store.isDeleting }
        store.windowClosed()

        #expect(store.cleanupProgress == nil)
        #expect(store.resultMessage?.deletedCount == 2)
        #expect(store.resultMessage?.undoable.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.gitFixture.worktreePath("one")))
        #expect(!FileManager.default.fileExists(atPath: fixture.gitFixture.worktreePath("two")))
    }

    @MainActor
    @Test func stopKeepsItsVisibleStateAndFinishesOnlyTheCurrentRow() async throws {
        let fixture = try await Task.detached { try BlockingCleanupFixture() }.value
        defer { try? fixture.resume() }
        let snapshot = await fixture.gitFixture.scan(with: fixture.scanner)
        let rows = try fixture.reviewedRows(in: snapshot)
        let store = BranchesStore(scanner: fixture.scanner, initialSnapshot: snapshot)
        store.startDelete(rows)
        try await waitFor { fixture.removalStarted }
        store.stopDeleting()
        #expect(store.cleanupProgress?.isStopping == true)
        #expect(store.isDeleting)
        store.windowClosed()
        store.windowOpened()
        #expect(store.cleanupProgress?.isStopping == true)
        try fixture.resume()
        try await waitFor { !store.isDeleting }
        store.windowClosed()

        #expect(store.resultMessage?.deletedCount == 1)
        #expect(store.resultMessage?.text.contains("Stopped. 1 left as they were.") == true)
        #expect(store.resultMessage?.undoable.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.gitFixture.worktreePath("one")))
        #expect(FileManager.default.fileExists(atPath: fixture.gitFixture.worktreePath("two")))
    }

    @MainActor
    @Test func hiddenRestoreRefreshesRowsWhenVisibleWithoutLosingItsResult() async throws {
        let fixture = try await Task.detached { try BlockingCleanupFixture() }.value
        try fixture.resume()
        let initial = await fixture.gitFixture.scan(with: fixture.scanner)
        let rows = try fixture.reviewedRows(in: initial)
        let store = BranchesStore(scanner: fixture.scanner, initialSnapshot: initial)
        // Establish a recent scan, so the usual key-window throttle would
        // otherwise leave the restored row missing for two minutes.
        store.windowOpened()
        try await waitFor { store.snapshot.activity == .idle }
        store.windowClosed()
        await store.delete(rows)
        let deleted = try #require(store.resultMessage?.undoable)
        #expect(deleted.count == 2)
        let path = fixture.gitFixture.worktreePath("one")
        let restored = try #require(deleted.first { $0.worktreePath == path })
        let untouched = try #require(deleted.first { $0.id != restored.id })

        await store.undo([restored])
        let result = try #require(store.resultMessage)
        #expect(!result.isProblem)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!store.snapshot.deletions.contains { $0.id == restored.id })
        #expect(store.snapshot.deletions.contains { $0.id == untouched.id })
        // Hidden restoration updates recovery records immediately but defers
        // the repository read until visibility actually returns.
        #expect(store.snapshot.row(worktree: path) == nil)

        store.setVisible(true)
        defer { store.windowClosed() }
        try await waitFor {
            store.snapshot.activity == .idle && store.snapshot.row(worktree: path) != nil
        }
        #expect(!store.snapshot.deletions.contains { $0.id == restored.id })
        #expect(store.snapshot.deletions.contains { $0.id == untouched.id })
        #expect(store.resultMessage?.id == result.id)
    }

    @MainActor
    @Test func failedRestoreKeepsItsRecoveryRecordAndResult() async throws {
        let fixture = try await Task.detached { try BlockingCleanupFixture() }.value
        try fixture.resume()
        let initial = await fixture.gitFixture.scan(with: fixture.scanner)
        let row = try #require(initial.row(worktree: fixture.gitFixture.worktreePath("one")))
        let store = BranchesStore(scanner: fixture.scanner, initialSnapshot: initial)
        await store.delete([row])
        let record = try #require(store.resultMessage?.undoable.first)
        let path = try #require(record.worktreePath)
        // The branch can return, but Git must not replace this new folder.
        try fixture.gitFixture.write("blocker.txt", "Keep this file", in: path)

        await store.undo([record])
        let result = try #require(store.resultMessage)
        #expect(result.isProblem)
        #expect(result.undoable.map(\.id) == [record.id])
        #expect(store.snapshot.deletions.contains { $0.id == record.id })
        #expect(try String(contentsOfFile: path + "/blocker.txt", encoding: .utf8) == "Keep this file")

        store.setVisible(true)
        defer { store.windowClosed() }
        try await waitFor {
            store.snapshot.activity == .idle && store.snapshot.row(branch: "one") != nil
        }
        #expect(store.snapshot.deletions.contains { $0.id == record.id })
        #expect(store.resultMessage?.id == result.id)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

/// Holds a real Git removal after its safety checks so UI state can be
/// observed deterministically, without deleting any user repository.
private final class BlockingCleanupFixture: @unchecked Sendable {
    let gitFixture: GitFixture
    let scanner: BranchesScanner
    private let started: URL
    private let resumeFile: URL

    init() throws {
        let fixture = try GitFixture()
        gitFixture = fixture
        for name in ["one", "two"] {
            try fixture.squashMerged(name, pullRequest: nil)
            try fixture.git(["worktree", "add", "--quiet", fixture.worktreePath(name), name])
        }
        let git = try #require(GitClient.locate())
        started = URL(fileURLWithPath: fixture.root + "/removal-started")
        resumeFile = URL(fileURLWithPath: fixture.root + "/resume-removal")
        let wrapper = fixture.root + "/blocking-git"
        try fixture.write("blocking-git", """
            #!/bin/sh
            previous=
            for argument do
                if [ "$previous:$argument" = "worktree:remove" ]; then
                    : > '\(started.path)'
                    attempts=0
                    while [ ! -f '\(resumeFile.path)' ] && [ "$attempts" -lt 2000 ]; do
                        /bin/sleep 0.01
                        attempts=$((attempts + 1))
                    done
                    [ -f '\(resumeFile.path)' ] || exit 124
                fi
                previous=$argument
            done
            exec '\(git.executable.path)' "$@"
            """, in: fixture.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let repository = fixture.repository
        scanner = BranchesScanner(environment: .init(
            home: URL(fileURLWithPath: fixture.home),
            cacheFile: URL(fileURLWithPath: fixture.root + "/cache/branches.json"),
            deletionLogFile: URL(fileURLWithPath: fixture.root + "/support/deletions.json"),
            git: GitClient(executable: URL(fileURLWithPath: wrapper)),
            cursorDatabase: URL(fileURLWithPath: fixture.root + "/no-cursor.vscdb"),
            addedFolders: { [repository] }, processes: { [] },
            now: { Date().addingTimeInterval(3600) }
        ))
    }

    var removalStarted: Bool { FileManager.default.fileExists(atPath: started.path) }

    func resume() throws { try Data().write(to: resumeFile) }

    func reviewedRows(in snapshot: BranchesSnapshot) throws -> [WorkItem] {
        try ["one", "two"].map { name in
            try #require(snapshot.row(worktree: gitFixture.worktreePath(name)))
        }
    }
}
