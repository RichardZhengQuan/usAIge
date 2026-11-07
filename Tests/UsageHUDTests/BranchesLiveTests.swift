import Foundation
import Testing
@testable import UsageHUD

// Opt-in check against the real repositories on this Mac. It only reads, and
// prints counts. Run with:
//   USAIGE_LIVE_BRANCHES=1 swift test --filter BranchesLive
// To compare its answers with GitHub's, name a file for the rows:
//   USAIGE_LIVE_BRANCHES_OUTPUT=/some/rows.json

private let liveEnabled = ProcessInfo.processInfo.environment["USAIGE_LIVE_BRANCHES"] == "1"

private actor ProgressRecorder {
    var latest = BranchesSnapshot()
    func record(_ snapshot: BranchesSnapshot) { latest = snapshot }
}

@Test(.enabled(if: liveEnabled)) func scanTheRepositoriesOnThisMacBranchesLive() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-branches-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var environment = BranchesScanner.Environment.live(addedFolders: { [] })
    environment.cacheFile = directory.appendingPathComponent("cache.json")
    environment.deletionLogFile = directory.appendingPathComponent("deletions.json")

    let recorder = ProgressRecorder()
    let scanner = BranchesScanner(environment: environment)
    let clock = ContinuousClock()
    let first = await clock.measure {
        await scanner.scan(force: true) { await recorder.record($0) }
    }
    let snapshot = await recorder.latest
    let second = await clock.measure {
        await scanner.scan(force: false) { await recorder.record($0) }
    }

    print("First scan \(first), second scan \(second)")
    print("Not checked: \(snapshot.notCheckedFolders.count) protected folders")
    for repository in snapshot.repositories {
        let rows = snapshot.items.filter { $0.repositoryID == repository.id }
        let counts = BranchesPresentation.counts(rows).map { "\($0.key.label) \($0.value)" }.sorted().joined(separator: ", ")
        print("\(repository.name): \(rows.count) rows. \(counts)")
    }
    #expect(!snapshot.items.contains { $0.status == .checking })

    if let output = ProcessInfo.processInfo.environment["USAIGE_LIVE_BRANCHES_OUTPUT"] {
        let rows = snapshot.items.map { item -> [String: String] in
            [
                "repository": item.repositoryName,
                "branch": item.branch ?? "",
                "path": item.worktreePath ?? "",
                "tip": item.tip ?? "",
                "status": item.status.label,
                "allowed": item.eligibility.isAllowed ? "yes" : "no",
                "own": item.facts.ownCommits.map(String.init) ?? "",
                "risk": item.facts.commitsAtRisk.map(String.init) ?? "",
                "merge": item.facts.merge.map { String(describing: $0) } ?? "",
                "processes": String(item.processes.count),
                "sessions": String(item.sessions.count),
                "bytes": item.size.map { String($0.totalBytes) } ?? "",
                "cache": item.size.map { String($0.cacheBytes) } ?? "",
                "ignored": item.irreplaceableIgnored.joined(separator: ","),
            ]
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: output))
    }
}
