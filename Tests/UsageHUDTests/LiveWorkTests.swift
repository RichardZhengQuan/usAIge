import AppKit
import Foundation
import Testing
@testable import UsageHUD

private func task(
    _ id: String,
    tool: AIToolID = .claude,
    phase: CodexAgentPhase = .thinking,
    folder: String? = "/work/app",
    branch: String? = nil,
    processID: Int32? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> CodexAgentTask {
    CodexAgentTask(
        id: id, title: "Task \(id)", workspaceName: "app", phase: phase, updatedAt: updatedAt,
        toolID: tool, folder: folder, branch: branch, processID: processID
    )
}

private func process(
    _ id: Int32,
    in folder: String,
    bytes: UInt64 = 100,
    executable: String? = nil,
    ports: [Int] = []
) -> WorkProcess {
    WorkProcess(id: id, name: "p\(id)", folder: folder, memoryBytes: bytes, startedAt: nil, ports: ports, executablePath: executable)
}

private let locator = RepositoryLocator(home: "/Users/me")

private func read(
    _ tasks: [CodexAgentTask],
    processes: [WorkProcess] = [],
    applications: [AIToolID: [String]] = [:]
) -> LiveWorkSummary {
    LiveWorkReader.read(
        tasks: tasks, applications: applications, locator: locator, includePorts: false,
        scan: { _, _ in processes }
    )
}

// MARK: Where a session works

@Test func aMainCopysBranchComesFromItsOwnHead() throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "topic/one"])
    let place = try #require(RepositoryLocator.gitPlace(containing: fixture.repository))
    #expect(place.branch == "topic/one")
    #expect(!place.isLinkedWorktree)
    #expect(place.root == fixture.repository)
    #expect(place.detachedAt == nil)
}

@Test func aLinkedWorktreeIsToldFromTheMainCopy() throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("linked")
    try fixture.git(["worktree", "add", "--quiet", "-b", "linked", path])
    try FileManager.default.createDirectory(atPath: path + "/deep/inside", withIntermediateDirectories: true)
    let place = try #require(RepositoryLocator.gitPlace(containing: path + "/deep/inside"))
    #expect(place.isLinkedWorktree)
    #expect(place.branch == "linked")
    #expect(place.root == path)
    #expect(place.commonDirectory == fixture.repository + "/.git")
}

@Test func aDetachedWorktreeNamesItsCommit() throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("detached")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path])
    let place = try #require(RepositoryLocator.gitPlace(containing: path))
    #expect(place.branch == nil)
    #expect(place.detachedAt == String(try fixture.head().prefix(7)))
}

/// Walking up from a deleted worktree would otherwise find the project around
/// it, and report the project's branch as the session's.
@Test func aFolderThatsGoneDoesntClaimTheBranchOfWhatsAroundIt() throws {
    let fixture = try GitFixture()
    #expect(RepositoryLocator.gitPlace(containing: fixture.repository + "/.claude/worktrees/gone") == nil)
}

@Test func theFolderTrumpsWhatASessionsLogLastSaid() throws {
    let fixture = try GitFixture()
    try fixture.git(["switch", "--quiet", "-c", "now-here"])
    let summary = LiveWorkReader.read(
        tasks: [task("a", folder: fixture.repository, branch: "was-here")],
        applications: [:],
        locator: RepositoryLocator(home: fixture.home),
        includePorts: false,
        scan: { _, _ in [] }
    )
    let session = try #require(summary.sessions.first)
    #expect(session.branch == "now-here")
    #expect(session.placement == .mainCopy)
    #expect(session.repositoryName == "project")
}

@Test func aDetachedFolderDoesntFallBackToTheLogsBranch() throws {
    let fixture = try GitFixture()
    let path = fixture.worktreePath("detached")
    try fixture.git(["worktree", "add", "--quiet", "--detach", path])
    let summary = LiveWorkReader.read(
        tasks: [task("a", folder: path, branch: "stale")],
        applications: [:],
        locator: RepositoryLocator(home: fixture.home),
        includePorts: false,
        scan: { _, _ in [] }
    )
    let session = try #require(summary.sessions.first)
    #expect(session.branch == nil)
    #expect(session.detachedAt != nil)
    #expect(session.placement == .worktree("detached"))
}

/// Reading here could raise a macOS prompt or start an iCloud download, on a
/// timer, with nobody having asked. The session's own log says enough.
@Test func aProtectedFolderIsNeverReadAndItsLogSpeaksForIt() throws {
    let plain = try #require(read([task("a", folder: "/Users/me/Documents/App", branch: "topic")]).sessions.first)
    #expect(plain.branch == "topic")
    #expect(plain.placement == .folder("App"))
    #expect(plain.repositoryName == "App")

    let nested = try #require(read([
        task("b", folder: "/Users/me/Documents/App/.claude/worktrees/quick-fix/src", branch: "fix"),
    ]).sessions.first)
    #expect(nested.placement == .worktree("quick-fix"))
    #expect(nested.repositoryName == "App")
    #expect(LiveWorkText.placeLine(nested) == "App · worktree quick-fix")

    let sameName = try #require(read([
        task("c", folder: "/Users/me/Documents/App/.claude/worktrees/quick-fix", branch: "claude/quick-fix"),
    ]).sessions.first)
    #expect(LiveWorkText.placeLine(sameName) == "App · worktree")
}

@Test func aSessionWithNoFolderStillShows() throws {
    let session = try #require(read([task("a", folder: nil)]).sessions.first)
    #expect(session.placement == .unknown)
    #expect(LiveWorkText.placeLine(session) == "")
    #expect(LiveWorkText.branchLine(session) == nil)
}

// MARK: What it costs

@Test func processesBelongToTheDeepestSessionFolder() {
    let result = LiveWorkReader.attribute(
        [
            process(1, in: "/work/app"),
            process(2, in: "/work/app/src"),
            process(3, in: "/work/app/packages/site"),
            process(4, in: "/work/application"),
            process(5, in: "/elsewhere"),
        ],
        to: ["/work/app", "/work/app/packages"]
    )
    #expect(result["/work/app"]?.map(\.id).sorted() == [1, 2])
    #expect(result["/work/app/packages"]?.map(\.id) == [3])
}

@Test func aToolsWorktreeInsideAProjectIsntTheProjectsWork() {
    let result = LiveWorkReader.attribute(
        [process(1, in: "/work/app/.claude/worktrees/other"), process(2, in: "/work/app/.codex/worktrees/x/src")],
        to: ["/work/app"]
    )
    #expect(result["/work/app"] == nil)
}

@Test func sessionsInOneFolderDontCountItsMemoryTwice() {
    let summary = read(
        [task("a", tool: .claude), task("b", tool: .chatGPT)],
        processes: [process(1, in: "/work/app", bytes: 500)]
    )
    #expect(summary.sessions.count == 2)
    #expect(summary.sessions.allSatisfy { $0.processes.map(\.id) == [1] })
    #expect(summary.memoryBytes == 500)
    #expect(summary.memoryBytes(for: .claude) == 500)
    #expect(summary.memoryBytes(for: .chatGPT) == 500)
    #expect(summary.placeCount == 1)
}

@Test func aSessionsOwnProcessCountsEvenRunningFromElsewhere() throws {
    let summary = read(
        [task("a", folder: "/work/app", processID: 7)],
        processes: [process(7, in: "/somewhere/else", bytes: 300), process(8, in: "/work/app", bytes: 200)]
    )
    let session = try #require(summary.sessions.first)
    #expect(session.processes.map(\.id) == [7, 8])
    #expect(summary.memoryBytes == 500)
}

@Test func anAppsHelpersCountTowardItsToolWithoutASession() {
    let root = "/Applications/Claude.app"
    let summary = read(
        [],
        processes: [
            process(1, in: "/", bytes: 400, executable: root + "/Contents/MacOS/Claude"),
            process(2, in: "/", bytes: 600, executable: root + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            process(3, in: "/", bytes: 900, executable: "/Applications/Claude Other.app/Contents/MacOS/Other"),
        ],
        applications: [.claude: [root]]
    )
    #expect(summary.sessions.isEmpty)
    #expect(summary.memoryBytes == 1000)
    #expect(summary.memoryBytes(for: .claude) == 1000)
    #expect(summary.memoryBytes(for: .cursor) == 0)
}

/// A process that's both a tool's own and in a session's folder is one process.
@Test func aProcessCountedTwoWaysCostsOnce() {
    let root = "/Applications/ChatGPT.app"
    let summary = read(
        [task("a", tool: .chatGPT)],
        processes: [process(1, in: "/work/app", bytes: 250, executable: root + "/Contents/Resources/codex")],
        applications: [.chatGPT: [root]]
    )
    #expect(summary.memoryBytes(for: .chatGPT) == 250)
    #expect(summary.memoryBytes == 250)
}

/// Nothing to look for means the process list isn't walked at all.
@Test func withNoSessionsAndNoAppsNothingIsScanned() {
    final class Flag: @unchecked Sendable { var wasScanned = false }
    let flag = Flag()
    let summary = LiveWorkReader.read(
        tasks: [], applications: [:], locator: locator, includePorts: true,
        scan: { _, _ in
            flag.wasScanned = true
            return []
        }
    )
    #expect(summary == LiveWorkSummary())
    #expect(!flag.wasScanned)
}

@Test func onlyWantedProcessesGetTheirDetailsRead() {
    let summary = LiveWorkReader.read(
        tasks: [task("a", folder: "/work/app", processID: 7)],
        applications: [.claude: ["/Applications/Claude.app"]],
        locator: locator,
        includePorts: false,
        scan: { _, wanted in
            [
                (pid_t(7), "/x", nil as String?),
                (8, "/work/app/src", nil),
                (9, "/", "/Applications/Claude.app/Contents/MacOS/Claude"),
                (10, "/work/application", nil),
                (11, "/", "/Applications/Other.app/Contents/MacOS/Other"),
            ]
            .filter { wanted($0.0, $0.1, $0.2) }
            .map { process($0.0, in: $0.1, executable: $0.2) }
        }
    )
    #expect(Set(summary.sessions.flatMap(\.processes).map(\.id)) == [7, 8])
    #expect(summary.appProcesses[.claude]?.map(\.id) == [9])
}

@Test func theRealProcessListGivesMemoryAndExecutables() {
    let own = getpid()
    #expect(ProcessScanner.memoryBytes(of: own) > 0)
    #expect(ProcessScanner.executablePath(of: own)?.hasPrefix("/") == true)
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "sleep 5 & wait"]
    #expect(ProcessScanner.scan(wanted: { _, _, _ in false }).isEmpty)
}

// MARK: Order and words

@Test func whatNeedsThePersonComesFirst() {
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let summary = read([
        task("idle", phase: .idle),
        task("done", phase: .complete),
        task("old", phase: .thinking, updatedAt: older),
        task("new", phase: .thinking, updatedAt: newer),
        task("broken", phase: .error),
        task("asking", phase: .needsInput),
    ])
    #expect(summary.sessions.map(\.id) == ["asking", "broken", "new", "old", "done", "idle"])
}

@Test func theWordsDescribeWhatsKnown() {
    #expect(LiveWorkText.memory(412 * 1024 * 1024).hasSuffix("MB"))
    #expect(LiveWorkText.memory(3 * 1024 * 1024 * 1024).hasSuffix("GB"))
    #expect(LiveWorkText.headline(LiveWorkSummary()) == "No AI session is active")
    let one = read([task("a")])
    #expect(LiveWorkText.headline(one) == "1 AI session")
    let two = read([task("a", folder: "/work/one"), task("b", folder: "/work/two")])
    #expect(LiveWorkText.headline(two) == "2 AI sessions in 2 places")

    let serving = read(
        [task("a")],
        processes: [process(1, in: "/work/app", bytes: 1024 * 1024, ports: [4296]), process(2, in: "/work/app", bytes: 1024 * 1024)]
    )
    let detail = LiveWorkText.detailLine(LiveWorkPlace.places(from: serving.sessions)[0])
    #expect(detail.contains("2 processes"))
    #expect(detail.contains("port 4296"))
}

/// A row per session would repeat one folder's memory down the card, which
/// reads as if it were counted each time.
@Test func sessionsInOneFolderShareARow() throws {
    let summary = read(
        [
            task("done", phase: .complete, folder: "/work/one"),
            task("working", phase: .thinking, folder: "/work/one"),
            task("elsewhere", phase: .complete, folder: "/work/two"),
            task("nowhere", phase: .idle, folder: nil),
        ],
        processes: [process(1, in: "/work/one", bytes: 700), process(2, in: "/work/two", bytes: 300)]
    )
    let places = LiveWorkPlace.places(from: summary.sessions)
    #expect(places.count == 3)
    let first = try #require(places.first)
    #expect(first.id == "/work/one")
    #expect(first.lead.id == "working")
    #expect(first.sessions.map(\.id) == ["working", "done"])
    #expect(first.memoryBytes == 700)
    #expect(places.map(\.memoryBytes).reduce(0, +) == summary.memoryBytes)
}

// MARK: The water level

@Test func theTanksLevelIsMemoryAgainstThisMac() {
    let gigabyte: UInt64 = 1024 * 1024 * 1024
    #expect(LiveWorkText.memoryShare(12 * gigabyte, of: 36 * gigabyte) == 1.0 / 3.0)
    #expect(LiveWorkText.percent(LiveWorkText.memoryShare(12 * gigabyte, of: 36 * gigabyte)) == "33%")
    // Compressed and swapped memory can add up to more than the Mac has.
    #expect(LiveWorkText.memoryShare(50 * gigabyte, of: 36 * gigabyte) == 1)
    #expect(LiveWorkText.percent(1) == "100%")
    #expect(LiveWorkText.memoryShare(gigabyte, of: 0) == 0)
    #expect(LiveWorkText.percent(0) == "0%")
    let sentence = LiveWorkText.memorySentence(12 * gigabyte, of: 36 * gigabyte)
    #expect(sentence.contains("33%"))
    #expect(sentence.contains("this Mac's"))
}

/// A little memory still shows as water, and none shows as an empty tank.
@Test func aLowTankKeepsAVisibleLine() {
    #expect(LiveWorkText.waterLevel(0) == 0)
    #expect(LiveWorkText.waterLevel(0.001) == 0.06)
    #expect(LiveWorkText.waterLevel(0.5) == 0.5)
    #expect(LiveWorkText.waterLevel(1) == 1)
}

/// Rings show what's left and water shows what's used, on one colour scale.
@Test func waterUsesTheRingsColoursForTheSameAmountLeft() {
    #expect(LiveWorkText.severity(0.2) == .abundant)
    #expect(LiveWorkText.severity(0.5) == .healthy)
    #expect(LiveWorkText.severity(0.7) == .caution)
    #expect(LiveWorkText.severity(0.85) == .low)
    #expect(LiveWorkText.severity(0.95) == .critical)
    #expect(LiveWorkText.severity(0.7) == QuotaSeverity(remainingPercent: 30))
}

/// Water alone doesn't say what it measures.
@Test func theTileSaysWhatItsFiguresMean() {
    let gigabyte: UInt64 = 1024 * 1024 * 1024
    var summary = read([task("a", folder: "/work/one"), task("b", folder: "/work/two")])
    summary.appProcesses[.claude] = [process(1, in: "/", bytes: 12 * gigabyte)]
    let help = LiveWorkText.tileHelp(summary, of: 24 * gigabyte)
    #expect(help.contains("AI tools are using"))
    #expect(help.contains("50% of this Mac's"))
    #expect(help.contains("2 branches and worktrees have an AI session."))
    #expect(!LiveWorkText.tileHelp(LiveWorkSummary(), of: 24 * gigabyte).contains("branch"))
}

@Test func waterStandsAtItsLevel() {
    let rect = CGRect(x: 0, y: 0, width: 64, height: 40)
    #expect(WaterShape(level: 0).path(in: rect).isEmpty)
    let half = WaterShape(level: 0.5, amplitude: 0).path(in: rect).boundingRect
    #expect(abs(half.minY - 20) < 0.01)
    #expect(half.maxY == 40)
    #expect(half.width == 64)
    let full = WaterShape(level: 1, amplitude: 5).path(in: rect).boundingRect
    #expect(full == rect)
    // Past the ends, the level stays inside the tank.
    #expect(WaterShape(level: 2, amplitude: 0).path(in: rect).boundingRect == rect)
    #expect(WaterShape(level: -1).path(in: rect).isEmpty)
    // The surface ripples around the level, and moves with the phase.
    let rippled = WaterShape(level: 0.5, phase: 0, amplitude: 2).path(in: rect).boundingRect
    #expect(rippled.minY < 20)
    #expect(rippled.minY >= 18)
    #expect(
        WaterShape(level: 0.5, phase: 0, amplitude: 2).path(in: rect)
            != WaterShape(level: 0.5, phase: 1, amplitude: 2).path(in: rect)
    )
}

// MARK: What counts as current

private actor FixedTasks: CodexAgentProviding {
    let tasks: [CodexAgentTask]
    init(_ tasks: [CodexAgentTask]) { self.tasks = tasks }
    func refresh() async throws -> [CodexAgentTask] { tasks }
    func stop() async {}
}

@MainActor
@Test func currentWorkIsWhatsLiveOrUnseen() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = CodexAgentStore(sources: [.init(toolID: .chatGPT, provider: FixedTasks([
        task("working", tool: .chatGPT, phase: .thinking, updatedAt: now),
        task("asking", tool: .chatGPT, phase: .needsInput, updatedAt: now),
        task("finished-unseen", tool: .chatGPT, phase: .complete, updatedAt: now),
        task("finished-seen", tool: .chatGPT, phase: .complete, updatedAt: now.addingTimeInterval(-1)),
        task("just-a-thread", tool: .chatGPT, phase: .idle, updatedAt: now),
        task("open-but-idle", tool: .chatGPT, phase: .idle, processID: 42, updatedAt: now.addingTimeInterval(-90_000)),
        task("left-behind", tool: .chatGPT, phase: .thinking, updatedAt: now.addingTimeInterval(-90_000)),
    ]))])
    await store.refresh()
    store.acknowledge(taskID: "finished-seen")
    #expect(Set(store.currentTasks(now: now).map(\.id)) == ["working", "asking", "finished-unseen", "open-but-idle"])
}

// MARK: Sampling

private final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    func record(_ includePorts: Bool) { lock.withLock { flags.append(includePorts) } }
    var last: Bool? { lock.withLock { flags.last } }
    var count: Int { lock.withLock { flags.count } }
}

@MainActor
@Test func portsAreOnlyReadWhileADetailCardIsOpen() async {
    let log = ScanLog()
    let monitor = LiveWorkMonitor(
        currentTasks: { [task("a")] },
        runningApplications: { [:] },
        locator: { locator },
        scan: { includePorts, _ in
            log.record(includePorts)
            return []
        }
    )
    await monitor.refresh()
    #expect(log.last == false)
    monitor.detailVisibilityChanged(true)
    await monitor.refresh()
    #expect(log.last == true)
    monitor.detailVisibilityChanged(false)
    await monitor.refresh()
    #expect(log.last == false)
    #expect(monitor.summary.sessions.map(\.id) == ["a"])
}

@MainActor
@Test func samplingStopsWithTheApp() async throws {
    let log = ScanLog()
    let monitor = LiveWorkMonitor(
        currentTasks: { [task("a")] },
        runningApplications: { [:] },
        locator: { locator },
        scan: { includePorts, _ in
            log.record(includePorts)
            return []
        }
    )
    monitor.start()
    let deadline = Date().addingTimeInterval(30)
    while log.count == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(log.count == 1)
    monitor.stop()
    let settled = log.count
    monitor.detailVisibilityChanged(true)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(log.count == settled)
}

// MARK: The rail and its cards

@Test func theTileMakesRoomInTheRail() {
    let room = HUDMetrics.workTileHeight + 7
    #expect(HUDMetrics.railHeight(rowCount: 1, showsWorkTile: true) == HUDMetrics.railHeight(rowCount: 1) + room)
    #expect(HUDMetrics.railHeight(rowCount: 8, showsWorkTile: true) == 450)
    #expect(HUDMetrics.railHeight(rowCount: 8, maximumHeight: 2_000, showsWorkTile: true)
        == HUDMetrics.railHeight(rowCount: 8, maximumHeight: 2_000) + room)
}

@MainActor
@Suite(.serialized) struct LiveWorkCardPanelTests {
    private func makeRail() -> NSPanel {
        NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 84, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    private func snapshot(_ id: String) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, displayName: "Limit", usedPercent: 25, remainingPercent: 75,
            resetAt: Date(timeIntervalSince1970: 1_800_000_000), windowDurationMinutes: 300,
            planType: nil, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func theTilesCardSharesTheOnePanel() {
        guard #available(macOS 14.0, *) else { return }
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })
        controller.show(snapshot("a"), rowFrame: .zero)
        let first = controller.panel
        controller.hide(snapshotID: "a")
        controller.showLiveWork(rowFrame: .zero)
        #expect(controller.panel === first)
        #expect(controller.shownSnapshotID == QuotaDetailPanelController.liveWorkID)
        #expect(first?.parent === rail)
    }

    @Test func aUsageUpdateDoesntCloseTheTilesCard() {
        guard #available(macOS 14.0, *) else { return }
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })
        controller.showLiveWork(rowFrame: .zero)
        controller.update([snapshot("a")])
        #expect(controller.shownSnapshotID == QuotaDetailPanelController.liveWorkID)
        controller.update(liveWork: read([task("a")]))
        #expect(controller.shownSnapshotID == QuotaDetailPanelController.liveWorkID)
        controller.hide(snapshotID: QuotaDetailPanelController.liveWorkID)
        #expect(controller.panel?.parent == nil)
    }

    /// The monitor only spends more while something can be seen.
    @Test func openingAndClosingACardTellsTheMonitor() {
        guard #available(macOS 14.0, *) else { return }
        final class Visibility { var values: [Bool] = [] }
        let visibility = Visibility()
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })
        controller.onVisibilityChanged = { visibility.values.append($0) }
        controller.show(snapshot("a"), rowFrame: .zero)
        controller.hide(snapshotID: "other")
        controller.hide(snapshotID: "a")
        controller.showLiveWork(rowFrame: .zero)
        controller.hide(snapshotID: QuotaDetailPanelController.liveWorkID)
        #expect(visibility.values == [true, false, true, false])
    }

    private final class Pointer {
        var location = CGPoint(x: -10_000, y: -10_000)
    }

    /// A card open beside the rail, and the middle of the card on screen.
    private func openCard(_ pointer: Pointer) throws -> (controller: QuotaDetailPanelController, card: CGPoint, rail: NSPanel) {
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail }, pointerLocation: { pointer.location })
        controller.show(snapshot("a"), rowFrame: CGRect(x: 4, y: 10, width: 76, height: 80))
        let window = try #require(controller.panel?.frame)
        return (controller, CGPoint(x: window.midX, y: window.midY), rail)
    }

    private func wait(_ seconds: TimeInterval = QuotaDetailPanelController.hideDelay + 0.5) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The bug: moving onto the card closed it, because leaving the row did.
    @Test func aCardStaysOpenWhileThePointerIsOnIt() async throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, card, _) = try openCard(pointer)
        controller.pointerLeft(snapshotID: "a")
        pointer.location = card
        controller.handlePointer(at: card)
        #expect(controller.isPointerOnCard)
        try await wait()
        #expect(controller.shownSnapshotID == "a")
        #expect(controller.panel?.parent != nil)
        controller.hide(snapshotID: "a")
    }

    @Test func aCardClosesSoonAfterThePointerLeavesIt() async throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, card, _) = try openCard(pointer)
        pointer.location = card
        controller.handlePointer(at: card)
        pointer.location = CGPoint(x: -10_000, y: -10_000)
        controller.handlePointer(at: pointer.location)
        #expect(!controller.isPointerOnCard)
        #expect(controller.shownSnapshotID == "a")
        let deadline = Date().addingTimeInterval(30)
        while controller.shownSnapshotID != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.shownSnapshotID == nil)
        #expect(controller.panel?.parent == nil)
    }

    @Test func aCardClosesIfThePointerNeverReachesIt() async throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, _, _) = try openCard(pointer)
        controller.pointerLeft(snapshotID: "a")
        let deadline = Date().addingTimeInterval(30)
        while controller.shownSnapshotID != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.shownSnapshotID == nil)
    }

    /// The gap between the rail and the card mustn't close it on a slow mouse.
    @Test func crossingTheGapCountsAsReachingTheCard() throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, card, rail) = try openCard(pointer)
        let gap = CGPoint(x: rail.frame.maxX + 2, y: card.y)
        pointer.location = gap
        controller.handlePointer(at: gap)
        #expect(controller.isPointerOnCard)
        #expect(controller.panel?.ignoresMouseEvents == true)
        controller.hide(snapshotID: "a")
    }

    /// The window reaches over the rail for the shadow, and must not take the
    /// rail's hover or clicks there.
    @Test func onlyTheCardItselfTakesMouseEvents() throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, card, rail) = try openCard(pointer)
        let panel = try #require(controller.panel)
        #expect(panel.ignoresMouseEvents)

        controller.handlePointer(at: card)
        #expect(!panel.ignoresMouseEvents)

        let overRail = CGPoint(x: rail.frame.maxX - 2, y: card.y)
        #expect(panel.frame.contains(overRail))
        controller.handlePointer(at: overRail)
        #expect(panel.ignoresMouseEvents)

        controller.hide(snapshotID: "a")
        #expect(panel.ignoresMouseEvents)
    }

    @Test func returningToARowKeepsItsCard() async throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, _, _) = try openCard(pointer)
        controller.pointerLeft(snapshotID: "a")
        controller.show(snapshot("a"), rowFrame: CGRect(x: 4, y: 10, width: 76, height: 80))
        try await wait()
        #expect(controller.shownSnapshotID == "a")
        controller.hide(snapshotID: "a")
    }

    /// A row's late exit mustn't close the card that replaced its own.
    @Test func aLateExitDoesntCloseTheNextCard() async throws {
        guard #available(macOS 14.0, *) else { return }
        let pointer = Pointer()
        let (controller, _, _) = try openCard(pointer)
        controller.show(snapshot("b"), rowFrame: .zero)
        controller.pointerLeft(snapshotID: "a")
        try await wait()
        #expect(controller.shownSnapshotID == "b")
        controller.hide(snapshotID: "b")
    }

    @Test func theCardsLinkClosesItAndOpensTheList() throws {
        guard #available(macOS 14.0, *) else { return }
        final class Opened { var count = 0 }
        let opened = Opened()
        let pointer = Pointer()
        let (controller, _, _) = try openCard(pointer)
        controller.openBranches = { opened.count += 1 }
        controller.closeAndOpenBranches()
        #expect(opened.count == 1)
        #expect(controller.shownSnapshotID == nil)
    }

    @Test func aRowsCardGrowsToFitItsToolsWork() {
        guard #available(macOS 14.0, *) else { return }
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })
        controller.show(snapshot("a"), rowFrame: .zero)
        let plainHeight = controller.panel?.frame.height ?? 0
        var work = read([task("a", tool: .chatGPT, branch: "topic")])
        work.appProcesses[.chatGPT] = [process(1, in: "/", bytes: 1024)]
        controller.update(liveWork: work)
        #expect((controller.panel?.frame.height ?? 0) > plainHeight)
    }
}

// MARK: A docked rail

/// The card is the rail's child window, so a docked rail sliding away would
/// take it along from under the pointer.
@MainActor
@Test func aDockedRailStaysOutWhileThePointerIsOnItsCard() async throws {
    guard let screen = NSScreen.main else { return }
    final class Pointer { var location = CGPoint(x: -10_000, y: -10_000) }
    final class Flag { var value = true }
    let pointer = Pointer()
    let onCard = Flag()
    let magnet = MagnetController(isEnabled: true, pointerLocation: { pointer.location })
    magnet.keepsRevealed = { onCard.value }
    let panel = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 84, height: 300),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    magnet.attach(to: panel)
    magnet.dock(to: .right, y: 300, on: screen, animated: false)

    try await Task.sleep(nanoseconds: UInt64((MagnetController.hideDelay + 0.4) * 1_000_000_000))
    #expect(magnet.isRevealed)

    onCard.value = false
    let deadline = Date().addingTimeInterval(MagnetController.hideDelay + 30)
    while magnet.isRevealed, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(!magnet.isRevealed)
    magnet.isEnabled = false
}
