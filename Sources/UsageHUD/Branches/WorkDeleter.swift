import Foundation

struct DeletionRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let repositoryDirectory: String
    let repositoryName: String
    let displayName: String
    let worktreePath: String?
    let branch: String?
    let branchWasDeleted: Bool
    let tip: String?
    let upstream: String?
    let deletedAt: Date

    /// A record whose folder was already gone has nothing to bring back.
    var canUndo: Bool { tip != nil && (branchWasDeleted || worktreePath != nil) }
}

enum DeletionOutcome: Equatable, Sendable {
    case deleted(DeletionRecord)
    /// The re-check found a reason to stop. Nothing was changed.
    case refused(name: String, reason: String)
    /// Git refused or failed, at the step `reason` names.
    case failed(name: String, reason: String, record: DeletionRecord?)

    var record: DeletionRecord? {
        switch self {
        case let .deleted(record): record
        case .refused: nil
        case let .failed(_, _, record): record
        }
    }
}

/// Removes a worktree and its branch, and brings them back on Undo. It never
/// passes `--force`, so Git itself refuses a folder with uncommitted files, and
/// a branch that moved since the review stays. Nothing here touches a remote.
enum WorkDeleter {
    static func perform(git: GitClient, item: WorkItem, repository: String, now: Date) async -> DeletionOutcome {
        var folderRemoved = false
        if let path = item.worktreePath {
            let removal = await git.run(in: repository, ["worktree", "remove", path], timeout: 120)
            guard removal.succeeded else {
                return .failed(name: item.displayName, reason: failureText(removal, doing: "remove the folder"), record: nil)
            }
            folderRemoved = true
        }
        var branchDeleted = false
        if item.removesBranch, let branch = item.branch, let tip = item.tip {
            if let failure = await deleteBranch(branch, expectedTip: tip, git: git, repository: repository) {
                let record = folderRemoved ? makeRecord(item, repository: repository, branchDeleted: false, now: now) : nil
                return .failed(name: item.displayName, reason: failure, record: record)
            }
            branchDeleted = true
        }
        return .deleted(makeRecord(item, repository: repository, branchDeleted: branchDeleted, now: now))
    }

    /// `git branch -D` refuses a branch in use anywhere, including by a rebase
    /// paused in another worktree, which `update-ref` wouldn't notice. It can't
    /// be told which commit to expect, so that's compared first.
    private static func deleteBranch(
        _ branch: String,
        expectedTip: String,
        git: GitClient,
        repository: String
    ) async -> String? {
        let current = await git.run(in: repository, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
        guard current.succeeded, current.trimmedText == expectedTip else {
            return "The branch changed, so it was left alone."
        }
        let deletion = await git.run(in: repository, ["branch", "-D", "--", branch])
        return deletion.succeeded ? nil : failureText(deletion, doing: "delete the branch")
    }

    private static func makeRecord(_ item: WorkItem, repository: String, branchDeleted: Bool, now: Date) -> DeletionRecord {
        DeletionRecord(
            repositoryDirectory: repository,
            repositoryName: item.repositoryName,
            displayName: item.displayName,
            worktreePath: item.facts.folderExists ? item.worktreePath : nil,
            branch: item.branch,
            branchWasDeleted: branchDeleted,
            tip: item.tip,
            upstream: item.upstream,
            deletedAt: now
        )
    }

    /// Recreates the branch at the same commit and checks out the folder
    /// again. Ignored files such as caches aren't in Git, so they don't return.
    /// Returns what went wrong, if anything.
    static func undo(git: GitClient, record: DeletionRecord) async -> String? {
        guard let tip = record.tip else { return "Nothing was recorded to restore." }
        let repository = record.repositoryDirectory
        var branchIsBack = false
        if record.branchWasDeleted, let branch = record.branch {
            // An earlier Undo may have got this far before the folder failed.
            let existing = await git.run(in: repository, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
            if existing.succeeded {
                guard existing.trimmedText == tip else {
                    return "Another branch named \(branch) exists now, so it was left alone."
                }
            } else {
                let created = await git.run(in: repository, ["branch", branch, tip])
                guard created.succeeded else {
                    return failureText(created, doing: "restore the branch")
                }
            }
            branchIsBack = true
        }
        if let path = record.worktreePath {
            let checkout = record.branch.map { ["worktree", "add", path, $0] } ?? ["worktree", "add", "--detach", path, tip]
            let added = await git.run(in: repository, checkout, timeout: 300)
            guard added.succeeded else {
                let failure = failureText(added, doing: "restore the folder")
                return branchIsBack ? "The branch is back. \(failure)" : failure
            }
        }
        if record.branchWasDeleted, let branch = record.branch, let upstream = record.upstream {
            // The remote branch may be gone by now, which isn't a failure.
            _ = await git.run(in: repository, ["branch", "--set-upstream-to=\(upstream)", branch])
        }
        return nil
    }

    private static func failureText(_ output: CommandOutput, doing action: String) -> String {
        if output.timedOut { return "Git took too long to \(action)." }
        let detail = output.errorText.split(separator: "\n").first.map(String.init) ?? "No details from Git."
        return "Git couldn't \(action): \(detail)"
    }
}
