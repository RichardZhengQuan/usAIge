import Foundation

/// Patch ids of the main branch's commits, kept between scans so only new
/// commits are read.
struct MainBranchIndex: Codable, Equatable, Sendable {
    var baseCommit: String
    var commitsByPatchID: [String: String]
}

/// What is known about one commit a branch or worktree sits on. Evidence that
/// its work reached main stays true as main moves on; "not merged" holds only
/// for the main branch commit it was checked against.
struct TipFacts: Codable, Equatable, Sendable {
    var baseCommit: String
    var ownCommits: Int
    var merge: MergeEvidence?

    func isCurrent(forBase base: String) -> Bool {
        merge != nil || baseCommit == base
    }
}

/// Tells whether a branch's work reached main without any network. Squash
/// merges leave a commit Git can't connect to the branch, so the check
/// compares content: a commit on main with the same patch as the branch.
enum MergeDetector {
    static let indexedCommitLimit = 5000

    /// `patch-id` needs each commit's full id on its own line to tell commits
    /// apart, whatever the person's log settings are.
    private static func logOptions() -> [String] {
        ["log", "-p", "--no-merges", "--format=medium", "--no-abbrev-commit", "--no-decorate"]
            + GitClient.stablePatchOptions
    }

    static func updatedIndex(
        git: GitClient,
        repository: String,
        baseCommit: String,
        previous: MainBranchIndex?
    ) async -> MainBranchIndex? {
        if let previous, previous.baseCommit == baseCommit { return previous }
        var known = [String: String]()
        var range = ["-n", String(indexedCommitLimit), baseCommit]
        if let previous {
            let isAncestor = await git.run(
                in: repository,
                ["merge-base", "--is-ancestor", previous.baseCommit, baseCommit]
            )
            if isAncestor.succeeded {
                known = previous.commitsByPatchID
                range = ["\(previous.baseCommit)..\(baseCommit)"]
            }
        }
        let output = await git.patchIDs(in: repository, of: logOptions() + range, timeout: 300)
        guard output.succeeded else { return nil }
        // The log prints newest first. A patch that landed more than once keeps
        // its newest commit, the one that may have landed after a branch began.
        for entry in GitParsing.patchIDs(from: output.text).reversed() { known[entry.patchID] = entry.commit }
        return MainBranchIndex(baseCommit: baseCommit, commitsByPatchID: known)
    }

    /// Commits made directly on main. A tip on main but not on this line
    /// arrived through a merge commit; one on this line may be a brand-new
    /// branch that was never worked on.
    static func firstParentCommits(git: GitClient, repository: String, baseCommit: String) async -> Set<String>? {
        let output = await git.run(
            in: repository,
            ["rev-list", "--first-parent", "-n", String(indexedCommitLimit), baseCommit],
            timeout: 60
        )
        guard output.succeeded else { return nil }
        return Set(output.text.split(separator: "\n").map(String.init))
    }

    static func tipFacts(
        git: GitClient,
        repository: String,
        tip: String,
        baseCommit: String,
        index: MainBranchIndex,
        firstParent: Set<String>
    ) async -> TipFacts? {
        let count = await git.run(in: repository, ["rev-list", "--count", tip, "--not", baseCommit])
        guard count.succeeded, let ownCommits = Int(count.trimmedText) else { return nil }
        if ownCommits == 0 {
            return TipFacts(
                baseCommit: baseCommit,
                ownCommits: 0,
                merge: firstParent.contains(tip) ? nil : .mergeCommit
            )
        }
        let evidence = await contentEvidence(
            git: git, repository: repository, tip: tip, ownCommits: ownCommits, baseCommit: baseCommit, index: index
        )
        return TipFacts(baseCommit: baseCommit, ownCommits: ownCommits, merge: evidence)
    }

    private static func contentEvidence(
        git: GitClient,
        repository: String,
        tip: String,
        ownCommits: Int,
        baseCommit: String,
        index: MainBranchIndex
    ) async -> MergeEvidence? {
        let mergeBase = await git.run(in: repository, ["merge-base", tip, baseCommit])
        guard mergeBase.succeeded, !mergeBase.trimmedText.isEmpty else { return nil }

        let total = await git.patchIDs(
            in: repository,
            of: ["diff"] + GitClient.stablePatchOptions + [mergeBase.trimmedText, tip]
        )
        if total.succeeded, let patch = GitParsing.patchIDs(from: total.text).first,
           let commit = index.commitsByPatchID[patch.patchID],
           await landedAfterBranchBegan(commit, mergeBase: mergeBase.trimmedText, git: git, repository: repository) {
            let subject = await git.run(in: repository, ["log", "-1", "--format=%s", commit])
            return .sameChanges(
                commit: commit,
                pullRequest: subject.succeeded ? GitParsing.pullRequestNumber(fromSubject: subject.text) : nil
            )
        }

        // A rebase merge copies each commit instead. A merge commit on the
        // branch can hold changes no patch shows, so those are left out.
        let merges = await git.run(in: repository, ["rev-list", "--count", "--merges", "\(baseCommit)..\(tip)"])
        guard merges.succeeded, merges.trimmedText == "0" else { return nil }
        let eachCommit = await git.patchIDs(in: repository, of: logOptions() + ["\(baseCommit)..\(tip)"])
        guard eachCommit.succeeded else { return nil }
        let patches = GitParsing.patchIDs(from: eachCommit.text)
        guard patches.count == ownCommits else { return nil }
        for patch in patches {
            guard let commit = index.commitsByPatchID[patch.patchID],
                  await landedAfterBranchBegan(commit, mergeBase: mergeBase.trimmedText, git: git, repository: repository)
            else { return nil }
        }
        return .sameCommits
    }

    /// What a branch's own newest commit says, to name its work. A branch
    /// merged with a merge commit has none left off main, so its last commit
    /// speaks for it; a branch sitting on a main commit has nothing to say.
    /// Returns nil when Git couldn't answer, and "" for nothing to say.
    static func subject(
        git: GitClient,
        repository: String,
        tip: String,
        baseCommit: String,
        merge: MergeEvidence?
    ) async -> String? {
        let own = await git.run(in: repository, ["log", "-1", "--no-merges", "--format=%s", tip, "--not", baseCommit])
        guard own.succeeded else { return nil }
        if !own.trimmedText.isEmpty { return own.trimmedText }
        guard merge == .mergeCommit else { return "" }
        let last = await git.run(in: repository, ["log", "-1", "--no-merges", "--format=%s", tip])
        return last.succeeded ? last.trimmedText : nil
    }

    /// A commit main already had when the branch began can't be how the branch
    /// merged. Matching one means the branch brings back something main has
    /// since reverted, and that work isn't on main.
    private static func landedAfterBranchBegan(
        _ commit: String,
        mergeBase: String,
        git: GitClient,
        repository: String
    ) async -> Bool {
        let check = await git.run(in: repository, ["merge-base", "--is-ancestor", commit, mergeBase])
        return check.status == 1 && !check.timedOut
    }
}
