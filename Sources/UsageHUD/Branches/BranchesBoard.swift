import Foundation

/// How full the disk holding the home folder is.
struct DiskSpace: Equatable, Sendable {
    var totalBytes: Int64
    var availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// The share used, after `freeing` more bytes.
    func usedShare(freeing bytes: Int64 = 0) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes - bytes) / Double(totalBytes)))
    }

    /// Free space as Finder counts it, including what macOS can purge.
    static func read(for url: URL) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0 else { return nil }
        return DiskSpace(totalBytes: Int64(total), availableBytes: available)
    }
}

/// The column a row belongs in: what a person would do about it.
enum WorkLane: Hashable, Sendable {
    case running
    case needsLook
    case safeToClear
}

/// The groups the review offers, each ticked or not as a whole.
enum ClearGroup: String, CaseIterable, Identifiable, Sendable {
    case quiet, branches, records, recent

    static let recentWindow: TimeInterval = 3 * 24 * 60 * 60

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: "Merged or empty folders"
        case .branches: "Merged branches with no folder"
        case .records: "Leftover records"
        case .recent: "Merged, but used in the last 3 days"
        }
    }

    var detail: String {
        switch self {
        case .quiet: "Nobody has used these for 3 days."
        case .branches: "Takes no space, and tidies the list."
        case .records: "The folder is already gone. Only Git's note of it is left."
        case .recent: "Off at first, in case you're still looking at them."
        }
    }

    var startsTicked: Bool { self != .recent }

    static func group(for item: WorkItem, now: Date) -> ClearGroup {
        if item.status == .folderGone { return .records }
        if item.worktreePath == nil { return .branches }
        if let used = item.lastUsedAt, now.timeIntervalSince(used) < recentWindow { return .recent }
        return .quiet
    }
}

/// A copy of a project nobody has used lately, whose rows that need a look
/// show as one card instead of crowding the column.
struct LeftoverCopy: Identifiable, Equatable, Sendable {
    let repository: RepositoryInfo
    let projectName: String
    let items: [WorkItem]
    let lastUsedAt: Date?

    var id: String { repository.id }
    var bytes: Int64 { items.compactMap(\.size?.totalBytes).reduce(0, +) }
    /// Rows holding work that exists only on this Mac.
    var unsavedCount: Int { items.filter { $0.status == .notSaved }.count }
}

/// One card in the "Needs a look" column.
enum LookEntry: Identifiable, Equatable, Sendable {
    case item(WorkItem)
    case copy(LeftoverCopy)
    case notChecked(folder: String)
    case unreadable(RepositoryInfo)

    var id: String {
        switch self {
        case let .item(item): "item|" + item.id
        case let .copy(copy): "copy|" + copy.id
        case let .notChecked(folder): "folder|" + folder
        case let .unreadable(repository): "repository|" + repository.id
        }
    }

    var bytes: Int64 {
        switch self {
        case let .item(item): item.size?.totalBytes ?? 0
        case let .copy(copy): copy.bytes
        case .notChecked, .unreadable: 0
        }
    }
}

/// A project to filter by: clones of one remote count as one project.
struct ProjectChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Everything the window lays out, worked out from a snapshot so it can be
/// tested apart from the view.
struct BranchesBoard: Equatable, Sendable {
    static let leftoverAfter: TimeInterval = 7 * 24 * 60 * 60

    var running: [WorkItem] = []
    var needsLook: [LookEntry] = []
    var safeToClear: [WorkItem] = []
    /// Rows not placed yet because they're still being read.
    var stillChecking = 0
    var projects: [ProjectChoice] = []

    var needsLookCount: Int {
        needsLook.reduce(0) { count, entry in
            if case let .copy(copy) = entry { return count + copy.items.count }
            return count + 1
        }
    }

    var needsLookBytes: Int64 { needsLook.map(\.bytes).reduce(0, +) }
    var safeBytes: Int64 { safeToClear.compactMap(\.size?.totalBytes).reduce(0, +) }

    /// Rows with a folder, biggest first: the cards worth seeing one by one.
    var safeFolders: [WorkItem] {
        safeToClear.filter { $0.worktreePath != nil && $0.status != .folderGone }
            .sorted { ($0.size?.totalBytes ?? -1, $1.id) > ($1.size?.totalBytes ?? -1, $0.id) }
    }

    func safe(in group: ClearGroup, now: Date) -> [WorkItem] {
        safeToClear.filter { ClearGroup.group(for: $0, now: now) == group }
    }

    static func lane(for item: WorkItem) -> WorkLane? {
        switch item.status {
        case .mainCopy:
            // The main copy can't go, but work in it is still running work.
            return item.facts.runningProcesses > 0 || item.facts.sessionActiveRecently ? .running : nil
        case .checking:
            return nil
        case .inUse:
            return .running
        case .notSaved, .pushed, .notChecked:
            return .needsLook
        case .finished, .empty, .folderGone:
            switch item.eligibility {
            case .allowed:
                // Clearing it would lose files, so it isn't "nothing to lose".
                return item.losesIgnoredFiles ? .needsLook : .safeToClear
            case .blocked:
                return item.isWaitingForIgnoredFiles ? nil : .needsLook
            }
        }
    }

    static func project(of repository: RepositoryInfo) -> ProjectChoice {
        ProjectChoice(id: repository.project?.key ?? repository.id, name: repository.project?.name ?? repository.name)
    }

    /// `query` matches what the work was called, its branch, folder, or
    /// repository; `projectID` keeps one project's rows.
    static func make(snapshot: BranchesSnapshot, query: String = "", projectID: String? = nil, now: Date) -> BranchesBoard {
        var board = BranchesBoard()
        let repositories = Dictionary(snapshot.repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectOf: (String) -> ProjectChoice? = { id in repositories[id].map(project(of:)) }

        var choices: [String: ProjectChoice] = [:]
        for repository in snapshot.repositories {
            let choice = project(of: repository)
            choices[choice.id] = choice
        }
        board.projects = choices.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let leftovers = leftoverCopies(snapshot: snapshot, now: now)
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let visible: (WorkItem) -> Bool = { item in
            if let projectID, projectOf(item.repositoryID)?.id != projectID { return false }
            guard !terms.isEmpty else { return true }
            let text = [item.workTitle, item.branch ?? "", item.worktreePath ?? "", item.repositoryName,
                        projectOf(item.repositoryID)?.name ?? ""].joined(separator: "\n").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }

        var looking: [WorkItem] = []
        var inCopies: [String: [WorkItem]] = [:]
        for item in snapshot.items {
            guard let lane = lane(for: item) else {
                if item.status == .checking || item.isWaitingForIgnoredFiles { board.stillChecking += 1 }
                continue
            }
            guard visible(item) else { continue }
            switch lane {
            case .running:
                board.running.append(item)
            case .safeToClear:
                board.safeToClear.append(item)
            case .needsLook:
                if leftovers[item.repositoryID] != nil {
                    inCopies[item.repositoryID, default: []].append(item)
                } else {
                    looking.append(item)
                }
            }
        }

        board.running.sort { ($0.lastUsedAt ?? .distantPast, $1.id) > ($1.lastUsedAt ?? .distantPast, $0.id) }
        looking.sort { lookOrder($0) < lookOrder($1) }
        board.needsLook = looking.map(LookEntry.item)
        for (id, items) in inCopies.sorted(by: { $0.key < $1.key }) {
            guard let repository = repositories[id], let lastUsed = leftovers[id] else { continue }
            board.needsLook.append(.copy(LeftoverCopy(
                repository: repository,
                projectName: project(of: repository).name,
                items: items.sorted { lookOrder($0) < lookOrder($1) },
                lastUsedAt: lastUsed
            )))
        }
        if projectID == nil {
            for folder in snapshot.notCheckedFolders where terms.allSatisfy({ folder.lowercased().contains($0) }) {
                board.needsLook.append(.notChecked(folder: folder))
            }
        }
        for repository in snapshot.repositories where repository.failure != nil {
            if let projectID, project(of: repository).id != projectID { continue }
            if terms.allSatisfy({ repository.name.lowercased().contains($0) }) {
                board.needsLook.append(.unreadable(repository))
            }
        }
        return board
    }

    /// What needs care most comes first: work that exists only here, the
    /// most of it first, then work saved elsewhere, then the rest.
    private static func lookOrder(_ item: WorkItem) -> (Int, Int, Double, String) {
        let rank: Int = switch item.status {
        case .notSaved: 0
        case .pushed: 1
        case .notChecked: 3
        default: 2
        }
        let weight = (item.facts.commitsAtRisk ?? 0) + (item.facts.changedFiles ?? 0) + (item.facts.untrackedFiles ?? 0)
        return (rank, -weight, -(item.lastUsedAt?.timeIntervalSince1970 ?? 0), item.id)
    }

    /// Copies of a project other than the one used most recently, when nobody
    /// has used them for a week. Keyed by repository, with when last used.
    static func leftoverCopies(snapshot: BranchesSnapshot, now: Date) -> [String: Date?] {
        var lastUsed: [String: Date] = [:]
        for item in snapshot.items {
            guard let date = item.lastUsedAt else { continue }
            lastUsed[item.repositoryID] = max(lastUsed[item.repositoryID] ?? .distantPast, date)
        }
        var byProject: [String: [RepositoryInfo]] = [:]
        for repository in snapshot.repositories {
            guard let key = repository.project?.key else { continue }
            byProject[key, default: []].append(repository)
        }
        var leftovers: [String: Date?] = [:]
        for copies in byProject.values where copies.count > 1 {
            let newest = copies.max { (lastUsed[$0.id] ?? .distantPast, $1.id) < (lastUsed[$1.id] ?? .distantPast, $0.id) }
            for copy in copies where copy.id != newest?.id {
                let used = lastUsed[copy.id]
                if used.map({ now.timeIntervalSince($0) >= leftoverAfter }) ?? true { leftovers[copy.id] = used }
            }
        }
        return leftovers
    }
}

enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case worktrees, buildCache, toolStorage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .buildCache: "Build cache"
        case .toolStorage: "Tool storage"
        }
    }
}

/// Measured folder totals stay separate from disk allocation. Worktree totals
/// include their caches; the paperweight splits those bytes into separate layers.
struct BranchesStorageSummary: Sendable {
    let folders: [WorkItem]
    private let worktreeBytes: Int64
    private let cacheBytes: Int64
    private let toolBytes: Int64

    init(board: BranchesBoard, toolStorage: [ToolStorageEntry]) {
        let looking = board.needsLook.flatMap { entry -> [WorkItem] in
            switch entry {
            case let .item(item): [item]
            case let .copy(copy): copy.items
            case .notChecked, .unreadable: []
            }
        }
        var seen: Set<String> = []
        folders = (looking + board.safeFolders).filter { item in
            guard let path = item.worktreePath, item.facts.folderExists,
                  item.status != .inUse, item.status != .mainCopy, item.status != .folderGone else { return false }
            // Git records can name the same folder with different path spellings.
            let canonical = RepositoryLocator.normalized(URL(fileURLWithPath: path).standardizedFileURL.path)
            return seen.insert(canonical).inserted
        }
        worktreeBytes = folders.reduce(0) { $0 + max(0, $1.size?.totalBytes ?? 0) }
        cacheBytes = folders.reduce(0) { $0 + max(0, $1.size?.cacheBytes ?? 0) }
        toolBytes = toolStorage.reduce(0) { $0 + max(0, $1.bytes) }
    }

    func bytes(for kind: StorageCategory) -> Int64 {
        switch kind {
        case .worktrees: worktreeBytes
        case .buildCache: cacheBytes
        case .toolStorage: toolBytes
        }
    }

    var cacheFolders: [WorkItem] {
        folders.filter { ($0.size?.cacheBytes ?? 0) > 0 }.sorted {
            let left = $0.size?.cacheBytes ?? 0
            let right = $1.size?.cacheBytes ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }
}

extension WorkItem {
    /// Ignored files in a folder that still exists, which no build brings back.
    var losesIgnoredFiles: Bool {
        facts.folderExists && !irreplaceableIgnored.isEmpty
    }

    /// Everything else says it can go, but its ignored files aren't listed yet.
    var isWaitingForIgnoredFiles: Bool {
        guard case .blocked = eligibility else { return false }
        return WorkRules.eligibility(for: facts, status: status).isAllowed
            && facts.hasWorktree && facts.folderExists && ignoredFiles == nil
    }
}

/// The review's choice: which rows to clear, starting from each group's
/// default. Ticking a group ticks every row in it.
struct ClearSelection: Equatable, Sendable {
    var chosen: Set<WorkItem.ID>

    init(items: [WorkItem], now: Date) {
        chosen = Set(items.filter { ClearGroup.group(for: $0, now: now).startsTicked }.map(\.id))
    }

    func state(of items: [WorkItem]) -> Bool? {
        let picked = items.filter { chosen.contains($0.id) }.count
        if picked == 0 { return false }
        return picked == items.count ? true : nil
    }

    mutating func set(_ items: [WorkItem], to isOn: Bool) {
        for item in items {
            if isOn { chosen.insert(item.id) } else { chosen.remove(item.id) }
        }
    }

    func chosenItems(from items: [WorkItem]) -> [WorkItem] {
        items.filter { chosen.contains($0.id) }
    }

    func bytes(from items: [WorkItem]) -> Int64 {
        chosenItems(from: items).compactMap(\.size?.totalBytes).reduce(0, +)
    }
}

/// The words on the cards and the hero, kept apart from the views.
enum BoardText {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "today", "yesterday", "5 days ago", "3 weeks ago".
    static func age(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }

    /// The line under a card's name saying why it can't simply go, if it can't.
    static func reason(_ item: WorkItem) -> (text: String, isLoss: Bool)? {
        switch item.status {
        case .notSaved:
            var parts: [String] = []
            let risk = item.facts.commitsAtRisk ?? 0
            if risk > 0 { parts.append("\(risk) \(risk == 1 ? "commit" : "commits") only here") }
            let files = (item.facts.changedFiles ?? 0) + (item.facts.untrackedFiles ?? 0)
            if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files") not committed") }
            if item.facts.stashCount > 0 { parts.append("\(item.facts.stashCount) stashed") }
            return (parts.isEmpty ? "Work only on this Mac" : parts.joined(separator: ", "), true)
        case .pushed:
            return ("Pushed, but not on main yet", false)
        case .notChecked:
            return (item.facts.mainBranchKnown ? "Not checked: macOS protects this folder" : "Its main branch wasn't found", false)
        case .finished, .empty, .folderGone:
            if item.losesIgnoredFiles {
                let files = item.irreplaceableIgnored
                let more = files.count > 2 ? " and \(files.count - 2) more" : ""
                return ("Keeps \(files.prefix(2).joined(separator: ", "))\(more), which no build brings back", false)
            }
            if case let .blocked(reason) = item.eligibility { return (reason, false) }
            return nil
        case .inUse, .mainCopy, .checking:
            return nil
        }
    }

    /// When and how big, for the card's last line.
    static func meta(_ item: WorkItem, now: Date) -> String {
        var parts: [String] = []
        if let used = item.lastUsedAt { parts.append(age(used, now: now)) }
        parts.append(size(item))
        return parts.joined(separator: " · ")
    }

    static func size(_ item: WorkItem) -> String {
        if item.worktreePath == nil { return "No folder" }
        if item.status == .folderGone { return "Folder gone" }
        guard let size = item.size else { return item.facts.folderReadable ? "Measuring…" : "Size not read" }
        return bytes(size.totalBytes)
    }

    /// What's running in a folder, for the "Running now" cards.
    static func running(_ item: WorkItem, now: Date) -> String {
        if !item.processes.isEmpty { return BranchesPresentation.runningSummary(item) }
        if let active = item.sessions.lastActiveAt {
            return "A session wrote \(BranchesPresentation.relativeTime(active, now: now))"
        }
        return "Running"
    }
}
