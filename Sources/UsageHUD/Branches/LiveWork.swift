import AppKit
import Combine
import Foundation

/// Where a session works, as far as this Mac can tell.
enum WorkPlacement: Equatable, Sendable {
    case mainCopy
    case worktree(String)
    case folder(String)
    case unknown
}

/// One AI session that's current, with where it works and what it costs.
struct LiveSessionWork: Identifiable, Equatable, Sendable {
    let id: String
    let toolID: AIToolID
    let title: String
    let phase: CodexAgentPhase
    let updatedAt: Date
    let folder: String?
    let repositoryName: String?
    let branch: String?
    /// The short commit a worktree sits on when it's on no branch.
    let detachedAt: String?
    let placement: WorkPlacement
    let processes: [WorkProcess]
}

/// One branch or worktree in use, with the sessions working there. Sessions in
/// one folder share its processes, so this is what a list shows a row for.
struct LiveWorkPlace: Identifiable, Equatable, Sendable {
    let id: String
    /// Most urgent first, so the first says what the place is doing.
    let sessions: [LiveSessionWork]

    var lead: LiveSessionWork { sessions[0] }

    var processes: [WorkProcess] {
        var seen: Set<Int32> = []
        return sessions.flatMap(\.processes).filter { seen.insert($0.id).inserted }
    }

    var memoryBytes: UInt64 {
        processes.reduce(0) { $0 + $1.memoryBytes }
    }

    /// Groups sessions by folder, keeping the order they came in.
    static func places(from sessions: [LiveSessionWork]) -> [LiveWorkPlace] {
        var order: [String] = []
        var grouped: [String: [LiveSessionWork]] = [:]
        for session in sessions {
            let key = session.folder ?? session.id
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(session)
        }
        return order.map { LiveWorkPlace(id: $0, sessions: grouped[$0] ?? []) }
    }
}

/// What the rail shows about the AI tools' current work.
struct LiveWorkSummary: Equatable, Sendable {
    var sessions: [LiveSessionWork] = []
    /// Each tool's own app and helpers, which run outside any project folder.
    var appProcesses: [AIToolID: [WorkProcess]] = [:]

    func sessions(for toolID: AIToolID) -> [LiveSessionWork] {
        sessions.filter { $0.toolID == toolID }
    }

    /// Memory of everything counted, each process once: two sessions in one
    /// folder share its processes.
    var memoryBytes: UInt64 {
        Self.total(sessions.flatMap(\.processes) + appProcesses.values.flatMap { $0 })
    }

    func memoryBytes(for toolID: AIToolID) -> UInt64 {
        Self.total(sessions(for: toolID).flatMap(\.processes) + (appProcesses[toolID] ?? []))
    }

    /// How many separate folders the sessions work in.
    var placeCount: Int {
        Set(sessions.map { $0.folder ?? $0.id }).count
    }

    private static func total(_ processes: [WorkProcess]) -> UInt64 {
        var seen: Set<Int32> = []
        return processes.reduce(0) { sum, process in
            seen.insert(process.id).inserted ? sum + process.memoryBytes : sum
        }
    }
}

extension RepositoryLocator {
    /// A repository's state at a folder, read from `.git` with no git process.
    struct GitPlace: Equatable, Sendable {
        let root: String
        let commonDirectory: String
        let isLinkedWorktree: Bool
        let branch: String?
        let detachedAt: String?
    }

    /// Whether files in this folder can be read without a macOS prompt or an
    /// iCloud download.
    func canReadFiles(in folder: String) -> Bool {
        guard isAllowed(folder) else { return false }
        return !(isProtected(folder) && Self.isManagedByICloud(folder))
    }

    static func gitPlace(containing folder: String) -> GitPlace? {
        guard FileManager.default.fileExists(atPath: folder),
              let common = commonDirectory(containing: folder) else { return nil }
        var current = folder
        for _ in 0..<64 {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                let gitDirectory = isDirectory.boolValue ? dotGit : pointedGitDirectory(in: dotGit)
                guard let gitDirectory else { return nil }
                let head = (try? String(contentsOfFile: gitDirectory + "/HEAD", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reference = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)) : nil }
                let isHeadCommit = reference == nil && head?.isEmpty == false && head?.allSatisfy(\.isHexDigit) == true
                return GitPlace(
                    root: current,
                    commonDirectory: common,
                    isLinkedWorktree: FileManager.default.fileExists(atPath: gitDirectory + "/commondir"),
                    branch: reference,
                    detachedAt: isHeadCommit ? head.map { String($0.prefix(7)) } : nil
                )
            }
            guard current != "/", !current.isEmpty else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func pointedGitDirectory(in path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8), contents.hasPrefix("gitdir:") else {
            return nil
        }
        let pointer = contents.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        let full = pointer.hasPrefix("/") ? pointer : (path as NSString).deletingLastPathComponent + "/" + pointer
        return normalized((full as NSString).standardizingPath)
    }

    /// Worktrees an AI tool keeps inside a project, recognised from the path
    /// alone, for folders that can't be read.
    static func toolWorktreeName(in path: String) -> String? {
        for marker in worktreeMarkers {
            if let range = path.range(of: marker) {
                return path[range.upperBound...].split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    static let worktreeMarkers = ["/.claude/worktrees/", "/.codex/worktrees/"]
}

/// Builds the rail's summary from the sessions the tools report and the
/// process list. It reads only `.git` pointers, never starts a process, and
/// never touches a folder macOS protects.
enum LiveWorkReader {
    typealias Scan = @Sendable (_ includePorts: Bool, _ wanted: (pid_t, String, String?) -> Bool) -> [WorkProcess]

    static func read(
        tasks: [CodexAgentTask],
        applications: [AIToolID: [String]],
        locator: RepositoryLocator,
        includePorts: Bool,
        scan: Scan = { includePorts, wanted in ProcessScanner.scan(includePorts: includePorts, wanted: wanted) }
    ) -> LiveWorkSummary {
        if tasks.isEmpty, applications.isEmpty { return LiveWorkSummary() }
        let folders = Set(tasks.compactMap { $0.folder.map(RepositoryLocator.normalized) })
        let sessionProcessIDs = Set(tasks.compactMap(\.processID))
        let applicationRoots = applications.flatMap { entry in entry.value.map { (root: $0 + "/", toolID: entry.key) } }

        let processes = scan(includePorts) { pid, folder, executable in
            if sessionProcessIDs.contains(pid) { return true }
            if let executable, applicationRoots.contains(where: { executable.hasPrefix($0.root) }) { return true }
            return folders.contains { RepositoryLocator.contains($0, folder) }
        }

        var appProcesses: [AIToolID: [WorkProcess]] = [:]
        for process in processes {
            guard let executable = process.executablePath,
                  let toolID = applicationRoots.first(where: { executable.hasPrefix($0.root) })?.toolID else { continue }
            appProcesses[toolID, default: []].append(process)
        }

        let byFolder = attribute(processes, to: folders)
        var places: [String: RepositoryLocator.GitPlace?] = [:]
        let sessions = tasks.map { task -> LiveSessionWork in
            let folder = task.folder.map(RepositoryLocator.normalized)
            var own = folder.flatMap { byFolder[$0] } ?? []
            if let pid = task.processID, !own.contains(where: { $0.id == pid }),
               let process = processes.first(where: { $0.id == pid }) {
                own.append(process)
            }
            var place: RepositoryLocator.GitPlace?
            if let folder {
                if let known = places[folder] {
                    place = known
                } else {
                    place = locator.canReadFiles(in: folder) ? RepositoryLocator.gitPlace(containing: folder) : nil
                    places[folder] = .some(place)
                }
            }
            return LiveSessionWork(
                id: task.id,
                toolID: task.toolID,
                title: task.title,
                phase: task.phase,
                updatedAt: task.updatedAt,
                folder: folder,
                repositoryName: repositoryName(folder: folder, place: place),
                // A folder that can be read knows better than the session's
                // log, which says where the session last reported being.
                branch: place.map(\.branch) ?? task.branch,
                detachedAt: place?.detachedAt,
                placement: placement(folder: folder, place: place),
                processes: own.sorted { $0.memoryBytes > $1.memoryBytes }
            )
        }
        return LiveWorkSummary(sessions: sorted(sessions), appProcesses: appProcesses)
    }

    /// Gives each process to the deepest session folder holding it. A tool's
    /// worktree kept inside a project is its own place, not the project's.
    static func attribute(_ processes: [WorkProcess], to folders: Set<String>) -> [String: [WorkProcess]] {
        let deepestFirst = folders.sorted { $0.count > $1.count }
        var result: [String: [WorkProcess]] = [:]
        for process in processes {
            guard let owner = deepestFirst.first(where: { RepositoryLocator.contains($0, process.folder) }) else { continue }
            let inner = process.folder.dropFirst(owner.count)
            if RepositoryLocator.worktreeMarkers.contains(where: { inner.hasPrefix($0) }) { continue }
            result[owner, default: []].append(process)
        }
        return result
    }

    private static func repositoryName(folder: String?, place: RepositoryLocator.GitPlace?) -> String? {
        if let place { return RepositoryLocator.displayName(forCommonDirectory: place.commonDirectory) }
        guard let folder else { return nil }
        return URL(fileURLWithPath: RepositoryLocator.projectFolder(of: folder)).lastPathComponent
    }

    private static func placement(folder: String?, place: RepositoryLocator.GitPlace?) -> WorkPlacement {
        guard let folder else { return .unknown }
        if let place {
            return place.isLinkedWorktree
                ? .worktree(URL(fileURLWithPath: place.root).lastPathComponent)
                : .mainCopy
        }
        if let name = RepositoryLocator.toolWorktreeName(in: folder) { return .worktree(name) }
        return .folder(URL(fileURLWithPath: folder).lastPathComponent)
    }

    /// What needs the person first, then what's working, newest first.
    private static func sorted(_ sessions: [LiveSessionWork]) -> [LiveSessionWork] {
        func rank(_ phase: CodexAgentPhase) -> Int {
            switch phase {
            case .needsInput: 0
            case .error: 1
            case .thinking: 2
            case .complete: 3
            case .idle: 4
            }
        }
        return sessions.sorted {
            let (left, right) = (rank($0.phase), rank($1.phase))
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

/// Keeps the rail's summary current. A sample costs a walk of the process list
/// and a read of a few small files, so it runs every 10 seconds, and more often
/// only while a card showing the detail is open.
@MainActor
final class LiveWorkMonitor: ObservableObject {
    static let backgroundInterval: TimeInterval = 10
    static let detailInterval: TimeInterval = 3

    @Published private(set) var summary = LiveWorkSummary()

    private let currentTasks: @MainActor () -> [CodexAgentTask]
    private let runningApplications: @MainActor () -> [AIToolID: [String]]
    private let locator: @MainActor () -> RepositoryLocator
    private let scan: LiveWorkReader.Scan
    private var loop: Task<Void, Never>?
    private var isDetailShown = false
    private var isReading = false

    init(
        currentTasks: @escaping @MainActor () -> [CodexAgentTask],
        runningApplications: @escaping @MainActor () -> [AIToolID: [String]] = LiveWorkMonitor.runningToolApplications,
        locator: @escaping @MainActor () -> RepositoryLocator = LiveWorkMonitor.defaultLocator,
        scan: @escaping LiveWorkReader.Scan = { includePorts, wanted in
            ProcessScanner.scan(includePorts: includePorts, wanted: wanted)
        }
    ) {
        self.currentTasks = currentTasks
        self.runningApplications = runningApplications
        self.locator = locator
        self.scan = scan
    }

    func start() {
        guard loop == nil else { return }
        restartLoop()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Ports cost more to read, so they're only read while they can be seen.
    func detailVisibilityChanged(_ isShown: Bool) {
        guard isShown != isDetailShown else { return }
        isDetailShown = isShown
        if loop != nil { restartLoop() }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.isDetailShown ? Self.detailInterval : Self.backgroundInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        let tasks = currentTasks()
        let applications = runningApplications()
        let locator = locator()
        let includePorts = isDetailShown
        let scan = scan
        let updated = await Task.detached(priority: .utility) {
            LiveWorkReader.read(
                tasks: tasks,
                applications: applications,
                locator: locator,
                includePorts: includePorts,
                scan: scan
            )
        }.value
        if updated != summary { summary = updated }
    }

    static func runningToolApplications() -> [AIToolID: [String]] {
        var result: [AIToolID: [String]] = [:]
        for descriptor in AIToolDescriptor.all {
            let paths = descriptor.bundleIdentifiers
                .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .compactMap { $0.bundleURL?.path }
            if !paths.isEmpty { result[descriptor.id] = Array(Set(paths)) }
        }
        return result
    }

    static func defaultLocator() -> RepositoryLocator {
        RepositoryLocator(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            allowedFolders: UserDefaults.standard.stringArray(forKey: BranchesStore.addedFoldersKey) ?? []
        )
    }
}

/// The words the rail and its cards use for current work.
enum LiveWorkText {
    static func memory(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = bytes >= 1024 * 1024 * 1024 ? [.useGB] : [.useMB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    /// How much of this Mac's memory `bytes` is, from 0 to 1. Footprints can
    /// add up to more than the physical memory, since macOS compresses and swaps.
    static func memoryShare(_ bytes: UInt64, of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(Double(bytes) / Double(total), 1)
    }

    static func percent(_ share: Double) -> String {
        "\(Int((min(max(share, 0), 1) * 100).rounded()))%"
    }

    /// How high the water stands. Any memory in use shows some water, and a
    /// low tank keeps a visible line, even when the number rounds to nothing.
    static func waterLevel(_ share: Double) -> Double {
        guard share > 0 else { return 0 }
        return max(min(share, 1), 0.06)
    }

    /// The rail's rings show what's left and these show what's used, so one
    /// colour scale means the same thing in both.
    static func severity(_ share: Double) -> QuotaSeverity {
        QuotaSeverity(remainingPercent: (1 - min(max(share, 0), 1)) * 100)
    }

    static func memorySentence(
        _ bytes: UInt64,
        of total: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String {
        "\(memory(bytes)), \(percent(memoryShare(bytes, of: total))) of this Mac's \(memory(total))"
    }

    /// What the tile's two figures mean, for anyone who stops to ask.
    static func tileHelp(_ summary: LiveWorkSummary, of total: UInt64) -> String {
        var parts = ["AI tools are using \(memorySentence(summary.memoryBytes, of: total))."]
        let places = summary.placeCount
        if places > 0 {
            parts.append("\(places) \(places == 1 ? "branch or worktree has" : "branches and worktrees have") an AI session.")
        }
        return parts.joined(separator: " ")
    }

    static func branchLine(_ session: LiveSessionWork) -> String? {
        if let branch = session.branch { return branch }
        return session.detachedAt.map { "No branch, at \($0)" }
    }

    /// A worktree usually shares its name with its branch, so that isn't
    /// repeated.
    static func placeLine(_ session: LiveSessionWork) -> String {
        var parts: [String] = []
        if let repository = session.repositoryName { parts.append(repository) }
        switch session.placement {
        case .mainCopy:
            parts.append("main copy")
        case let .worktree(name):
            parts.append(session.branch?.hasSuffix(name) == true ? "worktree" : "worktree \(name)")
        case let .folder(name) where name != session.repositoryName:
            parts.append(name)
        case .folder, .unknown:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Where a place is, and what's running there.
    static func detailLine(_ place: LiveWorkPlace) -> String {
        var parts = [placeLine(place.lead)].filter { !$0.isEmpty }
        let count = place.processes.count
        if count > 0 { parts.append("\(count) \(count == 1 ? "process" : "processes")") }
        let ports = Array(Set(place.processes.flatMap(\.ports))).sorted()
        if let port = ports.first {
            parts.append(ports.count == 1 ? "port \(port)" : "ports \(ports.prefix(3).map(String.init).joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    static func headline(_ summary: LiveWorkSummary) -> String {
        let sessions = summary.sessions.count
        guard sessions > 0 else { return "No AI session is active" }
        let places = summary.placeCount
        let sessionText = "\(sessions) AI \(sessions == 1 ? "session" : "sessions")"
        return places > 1 ? "\(sessionText) in \(places) places" : sessionText
    }
}
