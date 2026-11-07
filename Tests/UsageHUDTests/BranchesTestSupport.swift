import Foundation
@testable import UsageHUD

/// A throwaway repository with a bare `origin`, so tests can squash, rebase,
/// push, and delete for real.
final class GitFixture: @unchecked Sendable {
    let root: String
    let origin: String
    let repository: String
    let home: String
    private let lock = NSLock()
    private var runningProcesses: [WorkProcess] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("usaige-branches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Git reports real paths, and the temporary folder is behind a link.
        root = RepositoryLocator.normalized(base.resolvingSymlinksInPath().path)
        origin = root + "/origin.git"
        repository = root + "/project"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main", origin], in: root)
        try git(["clone", "--quiet", origin, repository], in: root)
        try commit("README.md", "start\n", message: "First commit")
        try git(["push", "--quiet", "origin", "HEAD:main"])
        try git(["remote", "set-head", "origin", "main"])
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? repository)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(message: "git \(arguments.joined(separator: " ")): " + String(decoding: errorData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ contents: String, in directory: String? = nil) throws {
        let url = URL(fileURLWithPath: (directory ?? repository) + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit(_ path: String, _ contents: String, message: String, in directory: String? = nil) throws {
        try write(path, contents, in: directory)
        try git(["add", path], in: directory)
        try git(["commit", "--quiet", "-m", message], in: directory)
    }

    func head(_ reference: String = "HEAD", in directory: String? = nil) throws -> String {
        try git(["rev-parse", reference], in: directory)
    }

    func worktreePath(_ name: String) -> String { root + "/worktrees/" + name }

    /// A pushed branch with two commits, squashed onto main the way GitHub does.
    func squashMerged(_ branch: String, pullRequest: Int?) throws {
        try git(["switch", "--quiet", "-c", branch, "main"])
        try commit("\(branch).txt", "one\n", message: "One")
        try commit("\(branch).txt", "one\ntwo\n", message: "Two")
        try git(["push", "--quiet", "-u", "origin", branch])
        try git(["switch", "--quiet", "main"])
        try git(["merge", "--quiet", "--squash", branch])
        let suffix = pullRequest.map { " (#\($0))" } ?? ""
        try git(["commit", "--quiet", "-m", "Squashed \(branch)\(suffix)"])
        try git(["push", "--quiet", "origin", "main"])
    }

    func setRunningProcesses(_ processes: [WorkProcess]) {
        lock.withLock { runningProcesses = processes }
    }

    func process(named name: String, in folder: String, ports: [Int] = []) -> WorkProcess {
        WorkProcess(id: 4242, name: name, folder: folder, memoryBytes: 1024, startedAt: nil, ports: ports)
    }

    func scanner(now: @escaping @Sendable () -> Date = Date.init) -> BranchesScanner {
        let repository = repository
        return BranchesScanner(environment: BranchesScanner.Environment(
            home: URL(fileURLWithPath: home),
            cacheFile: URL(fileURLWithPath: root + "/cache/branches.json"),
            deletionLogFile: URL(fileURLWithPath: root + "/support/deletions.json"),
            git: GitClient.locate(),
            cursorDatabase: URL(fileURLWithPath: root + "/no-cursor.vscdb"),
            addedFolders: { [repository] },
            processes: { [weak self] in self?.lock.withLock { self?.runningProcesses } ?? [] },
            now: now
        ))
    }

    /// Scans and returns the rows of this repository.
    func scan(with scanner: BranchesScanner? = nil) async -> BranchesSnapshot {
        let scanner = scanner ?? self.scanner()
        let collector = SnapshotCollector()
        await scanner.scan(force: true) { await collector.store($0) }
        return await collector.latest
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

actor SnapshotCollector {
    private(set) var latest = BranchesSnapshot()
    func store(_ snapshot: BranchesSnapshot) { latest = snapshot }
}

extension BranchesSnapshot {
    func row(branch: String) -> WorkItem? {
        items.first { $0.branch == branch }
    }

    func row(worktree path: String) -> WorkItem? {
        items.first { $0.worktreePath == path }
    }
}
