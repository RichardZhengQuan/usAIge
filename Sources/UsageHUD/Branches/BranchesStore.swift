import Combine
import Foundation

/// Window observations stop when hidden. An authorized cleanup owns its state
/// until it finishes, so closing and reopening the window cannot interrupt it.
@MainActor
final class BranchesStore: ObservableObject {
    static let addedFoldersKey = "usageHUD.branches.addedFolders.v1"
    private static let runningRefreshInterval: UInt64 = 5_000_000_000
    private static let rescanAfter: TimeInterval = 2 * 60

    @Published private(set) var snapshot = BranchesSnapshot()
    @Published private(set) var toolStorage: [ToolStorageEntry] = []
    @Published private(set) var isMeasuringToolStorage = false
    @Published private(set) var hasMeasuredToolStorage = false
    @Published private(set) var memoryShip: PaperweightShipKind = .sailboat
    @Published private(set) var storageShip: PaperweightShipKind = .galleon
    @Published private(set) var isDeleting = false
    /// Separate from scan activity: refreshes must never replace operation UI.
    @Published private(set) var cleanupProgress: CleanupProgress?
    /// The latest result of a delete or undo, shown until the next one.
    @Published var resultMessage: ResultMessage?
    @Published private(set) var diskSpace: DiskSpace?
    /// What each card would lose, once someone opened it.
    @Published private(set) var evidence: [String: WorkEvidence] = [:]

    struct CleanupProgress: Equatable, Sendable {
        enum Operation: Equatable, Sendable { case clearing, restoring }
        var operation: Operation
        var completed: Int
        var total: Int
        var currentName: String?
        var isStopping = false
    }

    struct ResultMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isProblem: Bool
        let undoable: [DeletionRecord]
        /// What the deleted folders measured. Files APFS shares with other
        /// folders count in each, so the disk can gain less.
        var freedBytes: Int64 = 0
        var deletedCount = 0
    }

    private let defaults: UserDefaults
    private let scanner: BranchesScanner
    private let diskURL: URL
    private var scanTask: Task<Void, Never>?
    private var toolStorageTask: Task<Void, Never>?
    private var runningTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var scanBeforeCleanup: Task<Void, Never>?
    private var evidenceTasks: [String: Task<Void, Never>] = [:]
    private var lastScanStartedAt: Date?
    private var isVisible = false
    private var measuredToolsThisOpen = false
    /// Restoring changes Git without publishing repository rows. A hidden
    /// window defers that read until it can show the restored work again.
    private var needsRepositoryReadAfterRestore = false

    init(
        defaults: UserDefaults = .standard,
        scanner: BranchesScanner? = nil,
        diskURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        initialSnapshot: BranchesSnapshot = BranchesSnapshot(),
        initialDiskSpace: DiskSpace? = nil,
        initialToolStorage: [ToolStorageEntry] = []
    ) {
        self.defaults = defaults
        self.diskURL = diskURL
        self.snapshot = initialSnapshot
        self.diskSpace = initialDiskSpace
        self.toolStorage = initialToolStorage
        self.hasMeasuredToolStorage = !initialToolStorage.isEmpty
        self.memoryShip = PaperweightShipPreferences.ship(for: .memory, defaults: defaults)
        self.storageShip = PaperweightShipPreferences.ship(for: .storage, defaults: defaults)
        let key = Self.addedFoldersKey
        self.scanner = scanner ?? BranchesScanner(environment: .live(addedFolders: {
            UserDefaults.standard.stringArray(forKey: key) ?? []
        }))
    }

    var addedFolders: [String] {
        defaults.stringArray(forKey: Self.addedFoldersKey) ?? []
    }

    func windowOpened() {
        let resumesRestoredWork = !isVisible && needsRepositoryReadAfterRestore && !isDeleting
        setVisible(true)
        if !resumesRestoredWork { startScan(force: false) }
        readDiskSpace()
        if !isDeleting, !measuredToolsThisOpen {
            measuredToolsThisOpen = true
            loadToolStorage(force: true)
        }
    }

    func ship(for paperweight: PaperweightID) -> PaperweightShipKind {
        paperweight == .memory ? memoryShip : storageShip
    }

    func chooseShip(_ ship: PaperweightShipKind, for paperweight: PaperweightID) {
        guard self.ship(for: paperweight) != ship else { return }
        if paperweight == .memory { memoryShip = ship } else { storageShip = ship }
        PaperweightShipPreferences.set(ship, for: paperweight, defaults: defaults)
    }

    /// Keeps the latest finished measurement for the rail's Storage card.
    /// Unchanged amounts aren't written again, so a quiet window writes nothing.
    func recordStorageBreakdown(_ breakdown: StorageBreakdown) {
        guard !breakdown.sameAmounts(as: StorageBreakdown.load(from: defaults)) else { return }
        breakdown.save(to: defaults)
    }

    /// Reuses the rail monitor's observed capacity without another disk read.
    /// A failed sample clears stale capacity instead of retaining old headroom.
    func updateObservedDiskSpace(_ space: DiskSpace?) {
        guard space != diskSpace else { return }
        diskSpace = space
    }

    /// Asking the volume can take a moment when macOS works out what it
    /// could purge, so it's read off the main thread.
    func readDiskSpace() {
        let url = diskURL
        Task { [weak self] in
            let space = await Task.detached(priority: .utility) { DiskSpace.read(for: url) }.value
            self?.updateObservedDiskSpace(space)
        }
    }

    /// Reads what a card would lose. Reading again replaces what was read.
    func loadEvidence(for item: WorkItem) {
        let key = Self.evidenceKey(item)
        guard evidence[key] == nil, evidenceTasks[key] == nil else { return }
        let scanner = scanner
        evidenceTasks[key] = Task { [weak self] in
            let read = await scanner.evidence(for: item)
            guard !Task.isCancelled else { return }
            self?.evidence[key] = read
            self?.evidenceTasks[key] = nil
        }
    }

    /// Evidence belongs to the row as it was read: a new commit or a newly
    /// changed file makes it stale.
    static func evidenceKey(_ item: WorkItem) -> String {
        let facts = item.facts
        return [item.id, item.tip ?? "", "\(facts.commitsAtRisk ?? -1)", "\(facts.changedFiles ?? -1)",
                "\(facts.untrackedFiles ?? -1)"].joined(separator: "|")
    }

    /// Re-reads when the person comes back, unless that just happened.
    func windowBecameKey() {
        if !needsRepositoryReadAfterRestore,
           let lastScanStartedAt, Date().timeIntervalSince(lastScanStartedAt) < Self.rescanAfter { return }
        startScan(force: false)
    }

    func windowClosed() {
        scanTask?.cancel()
        toolStorageTask?.cancel()
        runningTask?.cancel()
        // Cleanup continues independently of the window. Stop is an explicit
        // operation command, not a side effect of closing or navigating away.
        evidenceTasks.values.forEach { $0.cancel() }
        scanTask = nil
        toolStorageTask = nil
        runningTask = nil
        evidenceTasks = [:]
        isVisible = false
        measuredToolsThisOpen = false
        isMeasuringToolStorage = false
        if !isDeleting {
            let scanner = scanner
            Task { await scanner.saveAndStop() }
        }
    }

    /// What's running changes all the time, and reading it is cheap, so it
    /// updates while the window can be seen and not otherwise.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        runningTask?.cancel()
        runningTask = nil
        guard visible, !isDeleting else { return }
        if needsRepositoryReadAfterRestore { startScan(force: false) }
        let scanner = scanner
        runningTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.runningRefreshInterval)
                guard !Task.isCancelled else { return }
                let updated = await scanner.refreshRunningProcesses()
                guard !Task.isCancelled else { return }
                self?.applyRunning(updated)
            }
        }
    }

    private func applyRunning(_ updated: BranchesSnapshot) {
        guard !isDeleting, snapshot.items != updated.items else { return }
        snapshot = updated
    }

    func refresh() {
        startScan(force: true)
    }

    private func startScan(force: Bool) {
        guard !isDeleting else { return }
        needsRepositoryReadAfterRestore = false
        scanTask?.cancel()
        lastScanStartedAt = Date()
        let scanner = scanner
        scanTask = Task {
            await scanner.scan(force: force) { [weak self] snapshot in
                await self?.apply(snapshot)
            }
        }
    }

    private func apply(_ updated: BranchesSnapshot) {
        guard !Task.isCancelled, !isDeleting else { return }
        let finished = snapshot.activity != .idle && updated.activity == .idle
        snapshot = updated
        if finished { readDiskSpace() }
    }

    func loadToolStorage(force: Bool = false) {
        guard !isDeleting, toolStorageTask == nil else { return }
        isMeasuringToolStorage = true
        let scanner = scanner
        toolStorageTask = Task { [weak self] in
            let entries = await scanner.toolStorage(force: force)
            guard !Task.isCancelled else { return }
            self?.toolStorage = entries
            self?.hasMeasuredToolStorage = true
            self?.isMeasuringToolStorage = false
            self?.toolStorageTask = nil
        }
    }

    // MARK: Folders

    /// Lets usAIge read a folder it wouldn't touch by itself, or adds a
    /// repository no AI session has worked in.
    func addFolder(_ path: String) {
        var folders = addedFolders
        guard !folders.contains(path) else { return }
        folders.append(path)
        defaults.set(folders, forKey: Self.addedFoldersKey)
        startScan(force: false)
    }

    // MARK: Deleting

    /// Starts clearing, which `stopDeleting` can stop between rows.
    func startDelete(_ items: [WorkItem]) {
        guard beginCleanup(.clearing, names: items.map(\.displayName)) else { return }
        deleteTask = Task { [weak self] in
            await self?.performDelete(items)
        }
    }

    func stopDeleting() {
        guard cleanupProgress?.operation == .clearing, deleteTask != nil else { return }
        cleanupProgress?.isStopping = true
        deleteTask?.cancel()
    }

    func delete(_ items: [WorkItem]) async {
        guard beginCleanup(.clearing, names: items.map(\.displayName)) else { return }
        await performDelete(items)
    }

    private func beginCleanup(_ operation: CleanupProgress.Operation, names: [String]) -> Bool {
        guard !names.isEmpty, !isDeleting else { return false }
        // Claim the operation before scheduling work, so a second click cannot
        // replace its task handle before isDeleting becomes visible.
        isDeleting = true
        cleanupProgress = CleanupProgress(operation: operation, completed: 0, total: names.count,
                                          currentName: names.first)
        resultMessage = nil
        scanTask?.cancel()
        scanBeforeCleanup = scanTask
        scanTask = nil
        runningTask?.cancel()
        runningTask = nil
        toolStorageTask?.cancel()
        toolStorageTask = nil
        if isMeasuringToolStorage { measuredToolsThisOpen = false }
        isMeasuringToolStorage = false
        return true
    }

    private func finishCleanup() {
        deleteTask = nil
        cleanupProgress = nil
        isDeleting = false
        if isVisible {
            // Visibility may have stayed true while monitoring was suspended.
            setVisible(false)
            windowOpened()
        } else {
            let scanner = scanner
            Task { await scanner.saveAndStop() }
        }
    }

    private func performDelete(_ items: [WorkItem]) async {
        defer { finishCleanup() }
        // The scanner is reentrant while Git is awaited. Let the cancelled
        // read unwind before a destructive operation updates those same rows.
        await scanBeforeCleanup?.value
        scanBeforeCleanup = nil
        let scanner = scanner
        let outcomes = await scanner.delete(items) { [weak self] snapshot in
            await self?.applyWhileDeleting(snapshot, items: items)
        }
        var message = Self.message(for: outcomes)
        message.freedBytes = Self.freedBytes(items: items, outcomes: outcomes)
        let stopped = outcomes.count < items.count
        if stopped {
            message = ResultMessage(
                text: message.text + (message.text.isEmpty ? "" : "\n") + "Stopped. \(items.count - outcomes.count) left as they were.",
                isProblem: message.isProblem,
                undoable: message.undoable,
                freedBytes: message.freedBytes,
                deletedCount: message.deletedCount
            )
        }
        resultMessage = message
        readDiskSpace()
    }

    /// Updates sent while a delete runs, even after its task was stopped:
    /// stopping happens between rows, so they're still true.
    private func applyWhileDeleting(_ updated: BranchesSnapshot, items: [WorkItem]) {
        snapshot = updated
        if case let .clearing(done, total) = updated.activity {
            cleanupProgress?.completed = done
            cleanupProgress?.total = total
            cleanupProgress?.currentName = items.indices.contains(done) ? items[done].displayName : nil
        }
    }

    /// The deleted folders' measured sizes. Outcomes come in the order of
    /// `items`, and stop early if the delete was stopped.
    nonisolated static func freedBytes(items: [WorkItem], outcomes: [DeletionOutcome]) -> Int64 {
        zip(items, outcomes).reduce(0) { total, pair in
            guard pair.1.record?.worktreePath != nil else { return total }
            return total + (pair.0.size?.totalBytes ?? 0)
        }
    }

    func undo(_ records: [DeletionRecord]) async {
        guard beginCleanup(.restoring, names: records.map(\.displayName)) else { return }
        defer { finishCleanup() }
        await scanBeforeCleanup?.value
        scanBeforeCleanup = nil
        var failures: [String] = []
        var unfinished: [DeletionRecord] = []
        for (index, record) in records.enumerated() {
            cleanupProgress?.currentName = record.displayName
            if let failure = await scanner.undo(record) {
                failures.append("\(record.displayName): \(failure)")
                unfinished.append(record)
            } else {
                // The scanner has confirmed this record was restored. Keep
                // recovery controls truthful even while the window is hidden.
                snapshot.deletions.removeAll { $0.id == record.id }
            }
            // A failed restoration can still have brought back its branch.
            // Read Git again when visible, without polling a hidden window.
            needsRepositoryReadAfterRestore = true
            cleanupProgress?.completed = index + 1
        }
        resultMessage = failures.isEmpty
            ? ResultMessage(text: "Restored. Caches and ignored files don't come back.", isProblem: false, undoable: [])
            : ResultMessage(text: failures.joined(separator: "\n"), isProblem: true, undoable: unfinished)
        readDiskSpace()
    }

    static func message(for outcomes: [DeletionOutcome]) -> ResultMessage {
        var deleted: [DeletionRecord] = []
        var problems: [String] = []
        for outcome in outcomes {
            switch outcome {
            case let .deleted(record):
                deleted.append(record)
            case let .refused(name, reason):
                problems.append("\(name) wasn't deleted. \(reason)")
            case let .failed(name, reason, record):
                problems.append("\(name): \(reason)")
                if let record { deleted.append(record) }
            }
        }
        var parts: [String] = []
        if deleted.count == 1 {
            parts.append("Deleted \(deleted[0].displayName).")
        } else if deleted.count > 1 {
            parts.append("Deleted \(deleted.count) items.")
        }
        parts.append(contentsOf: problems)
        return ResultMessage(
            text: parts.joined(separator: "\n"),
            isProblem: !problems.isEmpty,
            undoable: deleted.filter(\.canUndo),
            deletedCount: deleted.count
        )
    }
}

/// Wording and checks the window shares, kept apart from the view so they
/// can be tested directly.
enum BranchesPresentation {
    static func counts(_ items: [WorkItem]) -> [WorkStatus: Int] {
        var counts: [WorkStatus: Int] = [:]
        for item in items { counts[item.status, default: 0] += 1 }
        return counts
    }

    /// Deletions that can still be brought back. Git may clean up the commits
    /// of a deleted branch after two weeks, so older ones aren't offered.
    static func restorable(_ deletions: [DeletionRecord], now: Date) -> [DeletionRecord] {
        deletions.filter { $0.canUndo && now.timeIntervalSince($0.deletedAt) < 14 * 24 * 60 * 60 }
    }

    /// Reasons to think twice, which start a row unticked in the delete review.
    static func cautions(for item: WorkItem, now: Date) -> [String] {
        var cautions: [String] = []
        if let lastActive = item.sessions.lastActiveAt, now.timeIntervalSince(lastActive) < 3 * 24 * 60 * 60 {
            cautions.append("A session used this \(relativeTime(lastActive, now: now)).")
        }
        let files = item.irreplaceableIgnored
        if !files.isEmpty {
            let shown = files.prefix(4).joined(separator: ", ")
            let more = files.count > 4 ? " and \(files.count - 4) more" : ""
            cautions.append("Ignored files no build brings back would be lost: \(shown)\(more).")
        }
        if item.status == .pushed {
            cautions.append("This isn't on main yet. Its commits stay on the remote, but no local copy remains.")
        }
        return cautions
    }

    static func relativeTime(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func abbreviated(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        RepositoryLocator.contains(home, path) ? "~" + path.dropFirst(home.count) : path
    }

    /// What the row's "running" column says.
    static func runningSummary(_ item: WorkItem) -> String {
        guard !item.processes.isEmpty else { return "" }
        let ports = Array(Set(item.processes.flatMap(\.ports))).sorted()
        if let served = item.processes.first(where: { !$0.ports.isEmpty }), let port = ports.first {
            let others = item.processes.count - 1
            let suffix = others > 0 ? " and \(others) more" : ""
            return "\(served.name) on port \(port)\(suffix)"
        }
        let names = Array(Set(item.processes.map(\.name))).sorted()
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and \(names.count - 2) more" : "")
    }
}
