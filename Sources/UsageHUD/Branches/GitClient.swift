import Foundation

/// Runs git for the Branches window. Repositories are found automatically, so
/// their config is not trusted: hooks, file monitors, external diff tools,
/// and text converters stay off, nothing fetches from a network, and reads
/// take no optional locks.
struct GitClient: Sendable {
    let executable: URL

    /// The stock `/usr/bin/git` is a shim that offers to install developer
    /// tools when none exist, so it is used only once they do.
    static func locate(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> GitClient? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileExists(path) {
            return GitClient(executable: URL(fileURLWithPath: path))
        }
        let developerToolGits = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        guard developerToolGits.contains(where: fileExists), fileExists("/usr/bin/git") else { return nil }
        return GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"))
    }

    static let hardenedConfiguration = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.untrackedCache=false",
        "-c", "core.pager=cat",
        "-c", "core.quotePath=false",
        "-c", "color.ui=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "-c", "log.showSignature=false",
    ]

    /// The same patch text for both sides of a comparison, whatever the
    /// repository or the person has configured. `--binary` keeps the content
    /// of binary files in the patch: without it, any two changes to the same
    /// binary file look identical to `git patch-id`.
    static let stablePatchOptions = [
        "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--binary",
        "--src-prefix=a/", "--dst-prefix=b/", "-U3",
    ]

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_EXTERNAL_DIFF"] {
            environment[key] = nil
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["LC_ALL"] = "C"
        return environment
    }

    func command(in directory: String, _ arguments: [String]) -> ShellCommand {
        ShellCommand(
            executable: executable,
            arguments: ["-C", directory] + Self.hardenedConfiguration + arguments,
            environment: Self.environment()
        )
    }

    func run(
        in directory: String,
        _ arguments: [String],
        timeout: TimeInterval = 20,
        maximumOutputBytes: Int = CommandRunner.defaultMaximumOutputBytes
    ) async -> CommandOutput {
        await CommandRunner.run(command(in: directory, arguments), timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    /// Patch ids of whatever `arguments` prints as patches. Each line of the
    /// result is `<patch id> <commit>`. `--verbatim` (Git 2.39 and later) keeps
    /// whitespace: by default two changes that differ only in indentation get
    /// the same id, and indentation can be the whole change. An older Git
    /// fails here, which means nothing matches rather than too much does.
    func patchIDs(in directory: String, of arguments: [String], timeout: TimeInterval = 60) async -> CommandOutput {
        await CommandRunner.run(
            piping: command(in: directory, arguments),
            into: command(in: directory, ["patch-id", "--verbatim"]),
            timeout: timeout
        )
    }
}

struct GitWorktreeRecord: Equatable, Sendable {
    var path: String
    var head: String?
    var branch: String?
    var isBare = false
    var isDetached = false
    var isLocked = false
    var lockReason: String?
    var isPrunable = false
}

struct GitBranchRecord: Equatable, Sendable {
    var name: String
    var tip: String
    var upstream: String?
    var upstreamIsGone: Bool
    var committedAt: Date?
}

struct GitStatusCounts: Equatable, Sendable {
    var changed = 0
    var untracked = 0
    var ignored: [String] = []
}

enum GitParsing {
    static let branchFormat = "%(refname:strip=2)%00%(objectname)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)"

    /// `git worktree list --porcelain -z`: one attribute per NUL, with an
    /// empty field between worktrees.
    static func worktrees(fromPorcelain data: Data) -> [GitWorktreeRecord] {
        var records: [GitWorktreeRecord] = []
        var current: GitWorktreeRecord?
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            guard !field.isEmpty else {
                if let finished = current { records.append(finished) }
                current = nil
                continue
            }
            let line = String(decoding: field, as: UTF8.self)
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]) : nil
            switch key {
            case "worktree":
                if let finished = current { records.append(finished) }
                current = GitWorktreeRecord(path: value ?? "")
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            case "locked":
                current?.isLocked = true
                current?.lockReason = value
            case "prunable":
                current?.isPrunable = true
            default:
                break
            }
        }
        if let finished = current { records.append(finished) }
        return records
    }

    static func branches(fromForEachRef text: String) -> [GitBranchRecord] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return GitBranchRecord(
                name: fields[0],
                tip: fields[1],
                upstream: fields[2].isEmpty ? nil : fields[2],
                upstreamIsGone: fields[3] == "gone",
                committedAt: TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// `git status --porcelain=v1 -z --ignored`. A rename or copy has a
    /// second path in its own field, which belongs to the same entry.
    static func statusCounts(fromPorcelain data: Data) -> GitStatusCounts {
        var counts = GitStatusCounts()
        var skipNext = false
        for field in data.split(separator: 0) {
            if skipNext {
                skipNext = false
                continue
            }
            guard field.count > 3 else { continue }
            let bytes = Array(field.prefix(2))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            switch (bytes[0], bytes[1]) {
            case (0x3F, 0x3F):
                counts.untracked += 1
            case (0x21, 0x21):
                counts.ignored.append(path.hasSuffix("/") ? String(path.dropLast()) : path)
            default:
                counts.changed += 1
                if bytes[0] == 0x52 || bytes[0] == 0x43 || bytes[1] == 0x52 || bytes[1] == 0x43 { skipNext = true }
            }
        }
        return counts
    }

    /// The paths with uncommitted changes in `git status --porcelain=v1 -z`,
    /// new files included and ignored ones left out. A rename names its new
    /// path first and the old one in the next field, which is skipped.
    static func changedPaths(fromPorcelain data: Data) -> [String] {
        var paths: [String] = []
        var skipNext = false
        for field in data.split(separator: 0) {
            if skipNext {
                skipNext = false
                continue
            }
            guard field.count > 3 else { continue }
            let bytes = Array(field.prefix(2))
            if bytes == [0x21, 0x21] { continue }
            paths.append(String(decoding: field.dropFirst(3), as: UTF8.self))
            if bytes[0] == 0x52 || bytes[0] == 0x43 || bytes[1] == 0x52 || bytes[1] == 0x43 { skipNext = true }
        }
        return paths
    }

    /// Lines of `<patch id> <commit>`, newest first as the log printed them.
    static func patchIDs(from text: String) -> [(patchID: String, commit: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// The pull request number GitHub appends to a squash commit's subject.
    static func pullRequestNumber(fromSubject subject: String) -> Int? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.range(of: "(#", options: .backwards) else { return nil }
        return Int(trimmed[open.upperBound...].dropLast())
    }

    /// Stash subjects read `WIP on <branch>: ...` or `On <branch>: ...`.
    static func stashCountsByBranch(fromSubjects text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let subject = line.hasPrefix("WIP on ") ? line.dropFirst(7) : line.hasPrefix("On ") ? line.dropFirst(3) : nil
            guard let subject, let colon = subject.firstIndex(of: ":") else { continue }
            counts[String(subject[..<colon]), default: 0] += 1
        }
        return counts
    }
}
