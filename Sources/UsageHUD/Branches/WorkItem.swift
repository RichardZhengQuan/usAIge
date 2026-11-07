import Foundation

enum WorkStatus: String, CaseIterable, Codable, Sendable {
    case inUse, notSaved, pushed, empty, finished, folderGone, mainCopy, notChecked, checking

    var label: String {
        switch self {
        case .inUse: "In use"
        case .notSaved: "Not saved"
        case .pushed: "Pushed"
        case .empty: "Empty"
        case .finished: "Finished"
        case .folderGone: "Folder gone"
        case .mainCopy: "Main copy"
        case .notChecked: "Not checked"
        case .checking: "Checking"
        }
    }

    /// The order a list reads best in: what needs care first.
    var rank: Int {
        switch self {
        case .inUse: 0
        case .notSaved: 1
        case .pushed: 2
        case .notChecked: 3
        case .checking: 4
        case .empty: 5
        case .finished: 6
        case .folderGone: 7
        case .mainCopy: 8
        }
    }
}

/// How a branch's work is known to be on the main branch.
enum MergeEvidence: Codable, Equatable, Sendable {
    /// Its tip was merged with a merge commit.
    case mergeCommit
    /// Its total change equals one commit on main, as a squash merge leaves.
    case sameChanges(commit: String, pullRequest: Int?)
    /// Each of its commits has an equal commit on main, as a rebase leaves.
    case sameCommits
}

/// Everything the status rules look at. A nil count means "not read yet".
struct WorkFacts: Equatable, Sendable {
    var isMainCopy = false
    var hasWorktree = false
    var folderExists = false
    /// False when the folder may not be read: a protected location, or one
    /// iCloud manages, where reading can prompt, hang, or start downloads.
    var folderReadable = true
    var mainBranchKnown = true
    var isLocked = false
    var lockReason: String?
    var isDetached = false
    var containsOtherWorktree = false
    var changedFiles: Int?
    var untrackedFiles: Int?
    var stashCount = 0
    var ownCommits: Int?
    var commitsAtRisk: Int?
    var merge: MergeEvidence?
    var runningProcesses = 0
    var sessionActiveRecently = false
}

enum DeleteEligibility: Equatable, Sendable {
    case allowed
    case blocked(String)

    var isAllowed: Bool { self == .allowed }
}

enum WorkRules {
    /// How long after a session last wrote to its log its folder counts as in
    /// use. Tools running inside an app have no process in the folder.
    static let recentSessionWindow: TimeInterval = 5 * 60

    static func status(for facts: WorkFacts) -> WorkStatus {
        if facts.isMainCopy { return .mainCopy }
        if facts.hasWorktree, facts.folderReadable, !facts.folderExists { return .folderGone }
        if facts.runningProcesses > 0 || facts.sessionActiveRecently { return .inUse }
        if !facts.mainBranchKnown { return .notChecked }
        if facts.hasWorktree, !facts.folderReadable { return .notChecked }
        if facts.hasWorktree, facts.changedFiles == nil || facts.untrackedFiles == nil { return .checking }
        guard let ownCommits = facts.ownCommits, let commitsAtRisk = facts.commitsAtRisk else { return .checking }
        if (facts.changedFiles ?? 0) > 0 || (facts.untrackedFiles ?? 0) > 0 { return .notSaved }
        if facts.stashCount > 0 { return .notSaved }
        // Commits that reached main in another form can look unpushed once
        // the remote branch is deleted, so the merge check comes first.
        if facts.merge != nil { return .finished }
        if commitsAtRisk > 0 { return .notSaved }
        if ownCommits == 0 { return .empty }
        return .pushed
    }

    static func eligibility(for facts: WorkFacts, status: WorkStatus) -> DeleteEligibility {
        if facts.isLocked {
            return .blocked("It's locked, so it stays until someone unlocks it in Git.")
        }
        if facts.containsOtherWorktree {
            return .blocked("Another worktree is inside this folder. Delete that one first.")
        }
        switch status {
        case .finished, .empty, .pushed, .folderGone:
            return .allowed
        case .mainCopy:
            return .blocked("This is the main copy of the repository.")
        case .inUse:
            return .blocked("Something is running here or used it in the last few minutes.")
        case .notSaved:
            return .blocked("Some of this work exists only on this Mac.")
        case .notChecked:
            return .blocked("usAIge couldn't check this one, so it can't tell what would be lost.")
        case .checking:
            return .blocked("Still checking.")
        }
    }
}

struct WorkSessionSummary: Equatable, Sendable {
    var count = 0
    var tools: [String] = []
    var lastActiveAt: Date?
    /// What the newest titled session called this work.
    var title: String?
}

struct FolderSize: Codable, Equatable, Sendable {
    var totalBytes: Int64
    var cacheBytes: Int64
    var cacheBytesByName: [String: Int64]
    /// Everything Git ignores in the folder, as it stood when measured.
    var ignored: [String]
    var otherIgnoredBytes: Int64
    var measuredAt: Date

    /// Ignored files outside the known cache names. Deleting a worktree loses
    /// them and no build brings them back.
    var otherIgnored: [String] {
        ignored.filter { FolderSizer.cacheName(forIgnoredPath: $0) == nil }
    }
}

struct WorkItem: Identifiable, Equatable, Sendable {
    let id: String
    let repositoryID: String
    let repositoryName: String
    var branch: String?
    var worktreePath: String?
    var tip: String?
    var upstream: String?
    var committedAt: Date?
    var facts: WorkFacts
    var ignoredFiles: [String]?
    var processes: [WorkProcess] = []
    var sessions = WorkSessionSummary()
    var size: FolderSize?
    /// The subject of its newest commit that isn't on main, or of its last
    /// commit if that reached main through a merge commit. Empty once read
    /// and found to have none.
    var subject: String?

    var status: WorkStatus { WorkRules.status(for: facts) }

    /// What the work was, for a person: what the session was called, else what
    /// its own last commit said, else its folder, else its branch.
    var workTitle: String {
        if let title = sessions.title { return title }
        if let subject, let cleaned = Self.withoutPullRequest(subject) { return cleaned }
        if let worktreePath { return URL(fileURLWithPath: worktreePath).lastPathComponent }
        return branch ?? "(no branch)"
    }

    /// GitHub's ` (#123)` suffix says nothing about the work.
    static func withoutPullRequest(_ subject: String) -> String? {
        var text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if GitParsing.pullRequestNumber(fromSubject: text) != nil, let open = text.range(of: " (#", options: .backwards) {
            text = String(text[..<open.lowerBound])
        }
        return text.isEmpty ? nil : text
    }

    var eligibility: DeleteEligibility {
        let eligibility = WorkRules.eligibility(for: facts, status: status)
        // The review has to be able to name every ignored file that would go.
        if eligibility.isAllowed, facts.hasWorktree, facts.folderExists, ignoredFiles == nil {
            return .blocked("Still checking which ignored files are in this folder.")
        }
        return eligibility
    }

    var displayName: String {
        if let branch { return branch }
        return worktreePath.map { "(no branch) " + URL(fileURLWithPath: $0).lastPathComponent } ?? "(no branch)"
    }

    /// When someone last touched it, by session or by commit.
    var lastUsedAt: Date? {
        [sessions.lastActiveAt, committedAt].compactMap { $0 }.max()
    }

    /// Whether the worktree's folder and its branch can go together. A record
    /// whose folder is gone gives up only the record: nothing has judged its
    /// branch, so the branch stays.
    var removesBranch: Bool {
        branch != nil && status != .folderGone
    }

    var whatDeleteRemoves: [String] {
        var parts: [String] = []
        if worktreePath != nil { parts.append(facts.folderExists ? "the folder" : "the worktree record") }
        if removesBranch { parts.append("the local branch") }
        return parts
    }

    var statusExplanation: String {
        switch status {
        case .inUse:
            return processes.isEmpty
                ? "A session used this in the last few minutes."
                : "Something is running in this folder."
        case .notSaved:
            let changed = (facts.changedFiles ?? 0) + (facts.untrackedFiles ?? 0)
            if changed > 0 { return "\(changed) \(changed == 1 ? "file isn't" : "files aren't") committed." }
            if facts.stashCount > 0 { return "\(facts.stashCount) stashed \(facts.stashCount == 1 ? "change was" : "changes were") made on this branch." }
            let risk = facts.commitsAtRisk ?? 0
            return "\(risk) \(risk == 1 ? "commit exists" : "commits exist") only on this Mac."
        case .pushed:
            return "Its commits are saved elsewhere but aren't on main as far as this Mac knows."
        case .empty:
            return "It has no commits of its own and no changes, so nothing would be lost."
        case .finished:
            return "Its work is on main and nothing is running here."
        case .folderGone:
            return facts.isLocked ? "The folder is gone and the record is locked." : "The folder is gone, and only Git's record of it is left."
        case .mainCopy:
            return "This is the repository's main copy."
        case .notChecked:
            return facts.mainBranchKnown
                ? "usAIge doesn't read this folder automatically, because it's protected or managed by iCloud."
                : "usAIge couldn't find this repository's main branch."
        case .checking:
            return "Still checking."
        }
    }

    var workSummary: String {
        if let merge = facts.merge {
            switch merge {
            case .mergeCommit: return "Merged into main with a merge commit."
            case let .sameChanges(_, pullRequest?): return "All its changes are on main, as #\(pullRequest)."
            case .sameChanges: return "All its changes are on main, matched by content."
            case .sameCommits: return "Each of its commits is on main, matched by content."
            }
        }
        var parts: [String] = []
        if let own = facts.ownCommits {
            parts.append(own == 0 ? "No commits of its own" : "\(own) \(own == 1 ? "commit" : "commits") not on main")
        }
        if let risk = facts.commitsAtRisk, risk > 0 { parts.append("\(risk) only on this Mac") }
        let changed = facts.changedFiles ?? 0
        if changed > 0 { parts.append("\(changed) changed \(changed == 1 ? "file" : "files")") }
        let untracked = facts.untrackedFiles ?? 0
        if untracked > 0 { parts.append("\(untracked) new \(untracked == 1 ? "file" : "files")") }
        return parts.isEmpty ? "Not read yet" : parts.joined(separator: ", ")
    }

    /// The commands the Delete button would run, for anyone who prefers to run
    /// them. A squash-merged branch needs `-D`, since Git can't see the merge.
    /// They name the repository, so pasting them into a terminal that's in
    /// another repository can't delete a branch with the same name there.
    var commandsToRun: String? {
        guard eligibility.isAllowed else { return nil }
        let folder = repositoryID.hasSuffix("/.git") ? String(repositoryID.dropLast(5)) : repositoryID
        let git = "git -C \(ShellQuoting.quoted(folder))"
        var lines: [String] = []
        if let worktreePath { lines.append("\(git) worktree remove \(ShellQuoting.quoted(worktreePath))") }
        if removesBranch, let branch { lines.append("\(git) branch -D -- \(ShellQuoting.quoted(branch))") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

enum ShellQuoting {
    static func quoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:@%"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
