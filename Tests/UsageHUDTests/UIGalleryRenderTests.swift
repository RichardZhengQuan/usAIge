import AppKit
import Metal
import SwiftUI
import Testing
@testable import UsageHUD

// Opt-in: renders the rail, every Settings page, and What's New to PNGs in
// light and dark appearance, so UI changes can be reviewed without launching
// the app.
//   USAIGE_RENDER_UI=/path/to/dir swift test --filter UIGallery
// Materials are drawn offscreen, so blur over the wallpaper is approximate.

private let galleryDirectory = ProcessInfo.processInfo.environment["USAIGE_RENDER_UI"]

private actor FixedUsageProvider: CodexUsageProviding {
    let result: Result<AccountUsageResult, LocalToolUsageError>

    init(_ result: Result<AccountUsageResult, LocalToolUsageError>) {
        self.result = result
    }

    func refresh() async throws -> AccountUsageResult { try result.get() }
    func updates() async -> AsyncStream<[QuotaSnapshot]> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private actor FixedAgentProvider: CodexAgentProviding {
    let tasks: [CodexAgentTask]

    init(_ tasks: [CodexAgentTask]) {
        self.tasks = tasks
    }

    func refresh() async throws -> [CodexAgentTask] { tasks }
    func stop() async {}
}

private enum GalleryAppearance: String, CaseIterable {
    case light, dark

    var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

private enum GalleryWallpaper: String {
    case light, dark, busy

    @ViewBuilder var view: some View {
        switch self {
        case .light:
            LinearGradient(
                colors: [Color(red: 0.84, green: 0.89, blue: 0.97), Color(red: 0.98, green: 0.93, blue: 0.87)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dark:
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.15), Color(red: 0.2, green: 0.11, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .busy:
            AngularGradient(
                colors: [.orange, .pink, .blue, .teal, .yellow, .orange],
                center: .center
            )
        }
    }
}

/// Keep the exact native physics frame prepared by the gallery fixture.
@available(macOS 14.0, *)
@MainActor
private struct GalleryAtmosphereView: NSViewRepresentable {
    let view: UsageAtmosphereView

    func makeNSView(context: Context) -> UsageAtmosphereView { view }
    func updateNSView(_ view: UsageAtmosphereView, context: Context) {}
    static func dismantleNSView(_ view: UsageAtmosphereView, coordinator: ()) { view.stop() }
}

private func bucket(
    _ id: String,
    _ name: String,
    _ tool: AIToolID,
    remaining: Double,
    minutes: Int,
    secondaryRemaining: Double? = nil,
    plan: String = "pro",
    resetCredits: Int? = nil
) -> QuotaSnapshot {
    let now = Date().timeIntervalSince1970
    var snapshot = QuotaSnapshot.make(
        from: RateLimitBucket(
            limitID: id,
            limitName: name,
            usedPercent: 100 - remaining,
            windowDurationMinutes: minutes,
            resetsAt: now + Double(minutes) * 60 * 0.4,
            planType: plan,
            secondaryUsedPercent: secondaryRemaining.map { 100 - $0 },
            secondaryWindowDurationMinutes: secondaryRemaining.map { _ in 10_080 },
            secondaryResetsAt: secondaryRemaining.map { _ in now + 3 * 86_400 }
        ),
        updatedAt: Date()
    )
    snapshot.toolID = tool
    snapshot.availableResetCount = resetCredits
    return snapshot
}

private let mixedSnapshots = [
    bucket("codex", "Codex", .chatGPT, remaining: 62, minutes: 300, secondaryRemaining: 81),
    bucket("codex_bengalfox", "GPT-5.3-Codex-Spark", .chatGPT, remaining: 90, minutes: 300),
    bucket("claude", "All models", .claude, remaining: 45, minutes: 300, secondaryRemaining: 70, plan: "max"),
    bucket("claude_fable", "Fable", .claude, remaining: 18, minutes: 10_080, plan: "max"),
    bucket("cursor", "Cursor models", .cursor, remaining: 33, minutes: 44_640),
    bucket("grok", "Weekly credits", .grok, remaining: 100, minutes: 10_080),
]

private let criticalSnapshots = [
    bucket("codex", "Codex", .chatGPT, remaining: 4, minutes: 300, secondaryRemaining: 22),
    bucket("claude", "All models", .claude, remaining: 0, minutes: 300, secondaryRemaining: 9, plan: "max"),
    bucket("cursor", "Cursor models", .cursor, remaining: 52, minutes: 44_640),
]

private func agentTasks(_ phases: [AIToolID: CodexAgentPhase]) -> [AIToolID: [CodexAgentTask]] {
    phases.mapValues { phase in
        [CodexAgentTask(
            id: "task-\(phase.rawValue)",
            title: "Refactor the sync layer",
            workspaceName: "usAIge",
            phase: phase,
            updatedAt: Date()
        )]
    }.reduce(into: [:]) { result, entry in
        result[entry.key] = entry.value.map { task in
            var task = task
            task.toolID = entry.key
            return task
        }
    }
}

/// Renders `view` at `size`, or at the size the view settles on when `size`
/// is nil (the Settings window sizes itself to each page).
@MainActor
@discardableResult
private func render<V: View>(_ view: V, size: CGSize?, appearance: GalleryAppearance, name: String) throws -> CGSize {
    let directory = URL(fileURLWithPath: try #require(galleryDirectory))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // cacheDisplay draws only the view tree, so paint the window background
    // the real window would show behind it.
    let root = view
        .frame(width: size?.width, height: size?.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance.colorScheme)
        .environment(\.usageSceneFrozen, true)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size ?? CGSize(width: 520, height: 580))
    hosting.appearance = NSAppearance(named: appearance.name)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance.name)
    window.contentView = hosting
    // Ordering a window animates on a shared worker thread, and while the
    // screen is locked that never ends. The gallery opens enough windows to
    // use up those threads, which stops everything else in the process.
    window.animationBehavior = .none
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    if size == nil {
        hosting.setFrameSize(hosting.fittingSize)
        window.setContentSize(hosting.fittingSize)
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    // Native glass can omit the backing even from this offscreen capture.
    // Restore the intended opaque canvas; wallpaper blur remains approximate.
    let captured = try #require(bitmap.cgImage)
    let canvas = try #require(CGContext(
        data: nil, width: captured.width, height: captured.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: captured.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let pixels = CGRect(x: 0, y: 0, width: CGFloat(captured.width), height: CGFloat(captured.height))
    let drawingAppearance = try #require(NSAppearance(named: appearance.name))
    drawingAppearance.performAsCurrentDrawingAppearance {
        canvas.setFillColor(NSColor.windowBackgroundColor.cgColor)
        canvas.fill(pixels)
    }
    canvas.interpolationQuality = .none
    canvas.draw(captured, in: pixels)
    if #available(macOS 14.0, *) {
        try compositePaperweightSnapshots(in: hosting, on: canvas, pixelSize: pixels.size)
    }
    let flattened = NSBitmapImageRep(cgImage: try #require(canvas.makeImage()))
    let png = try #require(flattened.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
    return hosting.bounds.size
}

/// AppKit's cached display omits Metal surfaces, so capture those views once
/// and put them back at their existing positions in the opaque gallery image.
@available(macOS 14.0, *)
@MainActor
private func compositePaperweightSnapshots(in hosting: NSView, on canvas: CGContext, pixelSize: CGSize) throws {
    let scaleX = pixelSize.width / hosting.bounds.width
    let scaleY = pixelSize.height / hosting.bounds.height
    var remaining = [hosting]
    while let view = remaining.popLast() {
        guard let host = view as? PaperweightSceneHost else {
            remaining.append(contentsOf: view.subviews)
            continue
        }
        guard host.bounds.width > 0, host.bounds.height > 0 else { continue }
        // The no-graphics fallback is native AppKit and is already in the cache.
        guard MTLCreateSystemDefaultDevice() != nil else { continue }
        let image = try #require(host.snapshot())
        var proposed = NSRect(origin: .zero, size: image.size)
        let captured = try #require(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let rect = hosting.convert(host.bounds, from: host)
        let bottom = hosting.isFlipped ? hosting.bounds.maxY - rect.maxY : rect.minY - hosting.bounds.minY
        canvas.draw(captured, in: CGRect(
            x: (rect.minX - hosting.bounds.minX) * scaleX, y: bottom * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY
        ))
    }
}

@MainActor
private func makeSettings() -> (HUDSettings, UserDefaults) {
    let defaults = UserDefaults(suiteName: "usaige.render.gallery.\(UUID().uuidString)")!
    return (HUDSettings(defaults: defaults), defaults)
}

@Suite("UIGallery", .enabled(if: galleryDirectory != nil), .serialized)
@MainActor
struct UIGalleryRenderTests {
    private struct RailScene {
        let name: String
        let result: Result<AccountUsageResult, LocalToolUsageError>
        var phases: [AIToolID: CodexAgentPhase] = [:]
    }

    @Test func rendersTheRail() async throws {
        guard #available(macOS 14.0, *) else { return }
        let now = Date()
        var claudeWithReset = QuotaSnapshot.make(
            from: RateLimitBucket(
                limitID: "claude", limitName: "All models", usedPercent: 26,
                windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3_600).timeIntervalSince1970,
                planType: "max", secondaryUsedPercent: 96, secondaryWindowDurationMinutes: 10_080,
                secondaryResetsAt: now.addingTimeInterval(16 * 3_600).timeIntervalSince1970
            ), updatedAt: now
        )
        claudeWithReset.toolID = .claude
        let claudeWithoutReset = ClaudeUsageProvider.snapshots(
            fromClaudeApp: ClaudeAppUsageSample(recordedAt: now, sessionPercent: 26, weeklyPercent: 96),
            planType: "max"
        )
        let scenes = [
            RailScene(name: "claude-reset-known", result: .success(.authenticated([claudeWithReset]))),
            RailScene(name: "claude-reset-unavailable", result: .success(.authenticated(claudeWithoutReset))),
            RailScene(
                name: "mixed",
                result: .success(.authenticated(mixedSnapshots)),
                phases: [.chatGPT: .thinking, .claude: .complete, .cursor: .needsInput, .grok: .error]
            ),
            RailScene(name: "critical", result: .success(.authenticated(criticalSnapshots))),
            RailScene(name: "signed-out", result: .success(.signedOut)),
            RailScene(name: "unavailable", result: .failure(.http(503))),
        ]
        let classicDefaults = try #require(UserDefaults(suiteName: "usaige.render.rail.classic.\(UUID().uuidString)"))
        classicDefaults.set(InterfaceStyle.classic.rawValue, forKey: InterfaceStyle.defaultsKey)
        let modernDefaults = try #require(UserDefaults(suiteName: "usaige.render.rail.modern.\(UUID().uuidString)"))
        modernDefaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
        for scene in scenes {
            let (settings, _) = makeSettings()
            let store = UsageStore(provider: FixedUsageProvider(scene.result), monitorsNetworkChanges: false)
            await store.refresh()
            let tasks = agentTasks(scene.phases)
            let agentStore = CodexAgentStore(sources: AIToolID.builtInIDs.map { id in
                .init(toolID: id, provider: FixedAgentProvider(tasks[id] ?? []))
            })
            await agentStore.refresh()
            let rowCount = scene.result.map(\.snapshots.count).value ?? 0
            let railHeight = rowCount > 0 ? HUDMetrics.railHeight(rowCount: rowCount, maximumHeight: 2_000) : 120
            let canvas = CGSize(width: HUDMetrics.railWidth + 56, height: railHeight + 56)

            func rail(hovered: Bool, wallpaper: GalleryWallpaper, modern: Bool = false) -> some View {
                ZStack(alignment: .trailing) {
                    wallpaper.view
                    HUDView(
                        store: store,
                        agentStore: agentStore,
                        settings: settings,
                        updateController: UpdateController(),
                        openTool: { _ in },
                        openCodex: {},
                        openSettings: {},
                        resizePanel: { _ in },
                        screenState: modern ? Self.modernRailScreen : PanelScreenState(visibleHeight: 2_000)
                    )
                    .environment(\.hudPreviewsHover, hovered)
                    .defaultAppStorage(modern ? modernDefaults : classicDefaults)
                }
            }
            // The Modern rail runs the display's full height at its side.
            let modernCanvas = CGSize(width: HUDMetrics.railWidth + 120, height: Self.modernRailScreen.screenHeight)
            for appearance in GalleryAppearance.allCases {
                let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
                for hovered in [false, true] {
                    try render(rail(hovered: hovered, wallpaper: wallpaper, modern: true), size: modernCanvas,
                               appearance: appearance,
                               name: "modern-rail-\(scene.name)-\(appearance.rawValue)-\(hovered ? "hover" : "idle")")
                }
            }

            for appearance in GalleryAppearance.allCases {
                let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
                try render(rail(hovered: false, wallpaper: wallpaper), size: canvas, appearance: appearance,
                           name: "rail-\(scene.name)-\(appearance.rawValue)-idle")
                try render(rail(hovered: true, wallpaper: wallpaper), size: canvas, appearance: appearance,
                           name: "rail-\(scene.name)-\(appearance.rawValue)-hover")
            }
            try render(rail(hovered: false, wallpaper: .busy), size: canvas, appearance: .light,
                       name: "rail-\(scene.name)-light-idle-busy-wallpaper")
            try render(rail(hovered: true, wallpaper: .busy), size: canvas, appearance: .dark,
                       name: "rail-\(scene.name)-dark-hover-busy-wallpaper")
        }
    }

    /// A display with a 34-point menu bar and a 70-point Dock below.
    private static let modernRailScreen: PanelScreenState = {
        let state = PanelScreenState(visibleHeight: 696, screenHeight: 800, safeTop: 34, safeBottom: 70)
        state.railEdge = .right
        return state
    }()

    @Test func rendersUsageConnectionActions() async throws {
        guard #available(macOS 14.0, *) else { return }
        let (settings, defaults) = makeSettings()
        let store = UsageStore(provider: FixedUsageProvider(.success(.authenticated([]))), monitorsNetworkChanges: false)
        await store.refresh()
        let registry = LocalToolStatusRegistry(detectInstallations: { [.claude, .cursor] })
        await registry.refreshInstallations()
        registry.report(.waitingForClaudeUsage, for: .claude)
        registry.report(.credentialExpired, for: .cursor)
        for appearance in GalleryAppearance.allCases {
            defaults.set("", forKey: ModernUsageBoard.expandedDefaultsKey)
            try render(
                ModernUsageBoard(store: store, settings: settings, localToolStatus: registry, editing: false)
                    .padding(24).background(ModernPalette.page).defaultAppStorage(defaults),
                size: CGSize(width: 830, height: 290), appearance: appearance,
                name: "usage-folded-connections-\(appearance.rawValue)"
            )
            defaults.set("claude,cursor", forKey: ModernUsageBoard.expandedDefaultsKey)
            try render(
                ModernUsageBoard(store: store, settings: settings, localToolStatus: registry, editing: false)
                    .padding(24).background(ModernPalette.page).defaultAppStorage(defaults),
                size: CGSize(width: 830, height: 290), appearance: appearance,
                name: "usage-connection-actions-\(appearance.rawValue)"
            )
        }
    }

    /// The Modern window: the same sidebar and sections as Classic, with a
    /// capacity bar and grouped lists instead of the ocean.
    @Test func rendersModernStyle() async throws {
        guard #available(macOS 14.0, *) else { return }
        let suite = "usaige.render.modern.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
        let snapshot = sampleBranchesSnapshot(now: Date())
        let store = BranchesStore(
            defaults: defaults, initialSnapshot: snapshot, initialDiskSpace: sampleDiskSpace,
            initialToolStorage: sampleToolStorage, initialCleanupInventory: sampleCleanupInventory
        )
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace
        let memory = sampleMemoryUsage
        var cpuSamples = sampleCPUTicks.makeIterator()
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks },
            runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }, readMemoryUsage: { memory },
            readCPUTicks: { cpuSamples.next() }
        )
        await monitor.refresh()
        fillCPUHistory(monitor.cpu)
        fillResourceHistory(monitor, memory: memory, disk: disk)
        let (settings, _) = makeSettings()
        let usageStore = UsageStore(provider: FixedUsageProvider(.success(.authenticated(mixedSnapshots))),
                                    monitorsNetworkChanges: false)
        await usageStore.refresh()
        // A tool whose sign-in expired, one that isn't connected yet, and an
        // opt-in tool that's off.
        defaults.set(AIToolID.chatGPT.rawValue, forKey: ModernUsageBoard.expandedDefaultsKey)
        let installed = Set(mixedSnapshots.map(\.toolID)).union([.jetBrainsAI, .windsurf, .copilot])
        let status = LocalToolStatusRegistry(detectInstallations: { installed })
        await status.refreshInstallations()
        let devices = try await makeDeviceDockGalleryFixture()
        defer { devices.cleanup() }
        status.report(.credentialExpired, for: .jetBrainsAI)
        status.report(.signedOut, for: .windsurf)
        status.report(.optInRequired, for: .copilot)
        let unpaired = RelaySyncController(defaults: defaults)
        func window(_ presentation: BranchesPaperweightPresentation, devices: RelaySyncController) -> some View {
            MainRootView(store: store, liveWork: monitor, usageStore: usageStore, settings: settings,
                         presentation: presentation, syncContent: AnyView(ModernDevicesPage(relaySync: devices)),
                         localToolStatus: status, openSettings: {})
                .defaultAppStorage(defaults)
        }
        func page(_ page: ModernPage) -> BranchesPaperweightPresentation {
            let presentation = BranchesPaperweightPresentation()
            presentation.open(page)
            return presentation
        }
        for appearance in GalleryAppearance.allCases {
            for modernPage in ModernPage.allCases {
                try render(window(page(modernPage), devices: devices.controller), size: CGSize(width: 1180, height: 780),
                           appearance: appearance, name: "modern-page-\(modernPage.rawValue)-\(appearance.rawValue)")
            }
            try render(window(page(.overview), devices: devices.controller), size: CGSize(width: 1180, height: 1140),
                       appearance: appearance, name: "modern-system-trends-\(appearance.rawValue)")
            try render(window(page(.devices), devices: unpaired), size: CGSize(width: 1180, height: 780),
                       appearance: appearance, name: "modern-devices-empty-\(appearance.rawValue)")
            try render(CPUTile(monitor: monitor.cpu, open: {}).defaultAppStorage(defaults),
                       size: CGSize(width: HUDMetrics.railWidth, height: 120),
                       appearance: appearance, name: "rail-cpu-trend-\(appearance.rawValue)")
            try render(RailDetailCard(content: .cpu(monitor.cpu), openDetails: {}),
                       size: CGSize(width: 400, height: 380), appearance: appearance,
                       name: "rail-cpu-details-\(appearance.rawValue)")
            let breakdown = StorageBreakdown(storage: PaperweightData.storage(
                disk: disk, board: BranchesBoard.make(snapshot: snapshot, now: Date()), toolStorage: sampleToolStorage,
                isMeasuring: false), freeableBytes: store.cleanableSpace.bytes, measuredAt: Date())
            let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
            for (name, content) in [("memory", RailDetailCard.Content.liveWork(monitor.summary, memory: memory, history: monitor.memoryHistory)),
                                    ("storage", .storage(disk, breakdown, history: monitor.storageHistory))] {
                try render(ZStack {
                    wallpaper.view
                    RailDetailCard(content: content, openDetails: {})
                }, size: CGSize(width: 402, height: name == "memory" ? 640 : 445), appearance: appearance,
                   name: "rail-\(name)-details-\(appearance.rawValue)")
            }
            try render(
                BranchesRootView(store: store, liveWork: monitor, initialFront: .memory).defaultAppStorage(defaults),
                size: CGSize(width: 1000, height: 1_400), appearance: appearance,
                name: "modern-memory-\(appearance.rawValue)"
            )
            // The rail's card for one tool: its limits, free resets and what
            // it's working on now.
            let claude = usageStore.visibleSnapshots.filter { $0.toolID == .claude }
            if let first = claude.first {
                try render(
                    RailDetailCard(content: .quota(first, others: Array(claude.dropFirst()),
                                                   work: monitor.summary.sessions(for: .claude),
                                                   memoryBytes: monitor.summary.memoryBytes(for: .claude)))
                        .defaultAppStorage(defaults)
                        .padding(20),
                    size: CGSize(width: 400, height: 640), appearance: appearance,
                    name: "modern-rail-card-\(appearance.rawValue)"
                )
            }
            let docks = RelayDeviceDock.list(devices.controller.devices)
            let legacyWatch = try #require(docks.first { $0.phone == nil }?.watch)
            let phone = try #require(docks.first { $0.watch == nil }?.phone)
            let channel = try #require(devices.controller.channelID)
            devices.controller.chooseDockPhone(phone.id, for: legacyWatch.id, in: channel)
            try render(
                ModernDevicesPage(relaySync: devices.controller).defaultAppStorage(defaults),
                size: CGSize(width: 980, height: 700), appearance: appearance,
                name: "modern-devices-\(appearance.rawValue)"
            )
            devices.controller.chooseDockPhone(nil, for: legacyWatch.id, in: channel)
            // Editing on the Usage page: switches and drag handles.
            settings.hiddenBucketIDs.insert("codex_bengalfox")
            try render(
                ScrollView {
                    ModernUsageBoard(store: usageStore, settings: settings, localToolStatus: status, editing: true)
                        .padding(24)
                }
                .background(ModernPalette.page)
                .defaultAppStorage(defaults),
                size: CGSize(width: 980, height: 900), appearance: appearance,
                name: "modern-usage-editing-\(appearance.rawValue)"
            )
            settings.hiddenBucketIDs.remove("codex_bengalfox")
            for layerID in ["cache", "tool"] {
                try render(
                    BranchesRootView(store: store, liveWork: monitor, initialFront: .storage,
                                     initialSelectedLayerID: layerID).defaultAppStorage(defaults),
                    size: CGSize(width: 1000, height: 1_000), appearance: appearance,
                    name: "modern-storage-\(layerID)-\(appearance.rawValue)"
                )
            }
        }
    }

    @Test func rendersWorkspaceAccessPages() async throws {
        guard #available(macOS 14.0, *) else { return }
        let (settings, defaults) = makeSettings()
        defaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
        let protected = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/Project"
        let snapshot = BranchesSnapshot(notCheckedFolders: [protected])
        let store = BranchesStore(defaults: defaults, initialSnapshot: snapshot, initialDiskSpace: sampleDiskSpace)
        let memory = sampleMemoryUsage
        let monitor = LiveWorkMonitor(currentTasks: { [] }, runningApplications: { [:] },
                                      scan: { _, _ in [] }, readDiskSpace: { nil },
                                      readMemoryPressure: { .normal }, readMemoryUsage: { memory })
        await monitor.refresh()
        let usage = UsageStore(provider: FixedUsageProvider(.success(.authenticated(mixedSnapshots))),
                               monitorsNetworkChanges: false)
        await usage.refresh()
        let pages: [ModernPage] = [.overview, .memory, .storage, .branches, .worktrees, .usage]
        for page in pages {
            let presentation = BranchesPaperweightPresentation()
            presentation.open(page)
            for appearance in GalleryAppearance.allCases {
                for (width, height) in [(1000, 600), (1180, 780)] {
                    try render(
                        MainRootView(store: store, liveWork: monitor, usageStore: usage, settings: settings,
                                     presentation: presentation, openSettings: {})
                            .defaultAppStorage(defaults),
                        size: CGSize(width: width, height: height), appearance: appearance,
                        name: "workspace-locked-\(page.rawValue)-\(width)-\(appearance.rawValue)"
                    )
                }
            }
        }
    }

    /// Ten limits at once, as with many tools connected: the rail on a
    /// 1107-point display and the Modern Overview and Usage pages.
    @Test func rendersManyTools() async throws {
        guard #available(macOS 14.0, *) else { return }
        let ten = [
            bucket("codex", "Codex", .chatGPT, remaining: 62, minutes: 300, secondaryRemaining: 81),
            bucket("codex_spark", "GPT-5.3-Codex-Spark", .chatGPT, remaining: 90, minutes: 300),
            bucket("claude", "All models", .claude, remaining: 45, minutes: 300, secondaryRemaining: 70, plan: "max"),
            bucket("claude_fable", "Fable", .claude, remaining: 18, minutes: 10_080, plan: "max"),
            bucket("cursor", "Cursor models", .cursor, remaining: 33, minutes: 44_640),
            bucket("grok", "Weekly credits", .grok, remaining: 100, minutes: 10_080),
            bucket("gemini", "Gemini Pro", .gemini, remaining: 74, minutes: 1_440),
            bucket("gemini_flash", "Gemini Flash", .gemini, remaining: 91, minutes: 1_440),
            bucket("grok_heavy", "Heavy", .grok, remaining: 55, minutes: 10_080),
            bucket("cursor_auto", "Auto", .cursor, remaining: 12, minutes: 44_640),
        ]
        let suite = "usaige.render.many.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
        let (settings, _) = makeSettings()
        let store = UsageStore(provider: FixedUsageProvider(.success(.authenticated(ten))), monitorsNetworkChanges: false)
        await store.refresh()
        let agentStore = CodexAgentStore(sources: [])
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace, memory = sampleMemoryUsage
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [:] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }, readMemoryUsage: { memory }
        )
        await monitor.refresh()
        let screen = PanelScreenState(visibleHeight: 1_003, screenHeight: 1_107, safeTop: 34, safeBottom: 70)
        screen.railEdge = .right
        for appearance in GalleryAppearance.allCases {
            try render(
                ZStack(alignment: .trailing) {
                    (appearance == .light ? GalleryWallpaper.light : .dark).view
                    HUDView(store: store, agentStore: agentStore, settings: settings, updateController: UpdateController(),
                            openTool: { _ in }, openCodex: {}, openSettings: {}, resizePanel: { _ in },
                            screenState: screen, liveWork: monitor)
                        .defaultAppStorage(defaults)
                },
                size: CGSize(width: HUDMetrics.railWidth + 120, height: screen.screenHeight), appearance: appearance,
                name: "many-rail-\(appearance.rawValue)"
            )
        }
        let branches = BranchesStore(defaults: defaults, initialSnapshot: sampleBranchesSnapshot(now: Date()),
                                     initialDiskSpace: sampleDiskSpace, initialToolStorage: sampleToolStorage)
        for page in [ModernPage.overview, .usage] {
            let presentation = BranchesPaperweightPresentation()
            presentation.open(page)
            try render(
                MainRootView(store: branches, liveWork: monitor, usageStore: store, settings: settings,
                             presentation: presentation, openSettings: {})
                    .defaultAppStorage(defaults),
                size: CGSize(width: 1180, height: 780), appearance: .light, name: "many-\(page.rawValue)-light"
            )
        }
    }

    /// Twelve tools on the rail on 13-inch MacBook screens: the rows scroll
    /// between the safe areas with a fade, and the controls stay put.
    @Test func rendersTwelveToolsOnASmallMacBook() async throws {
        guard #available(macOS 14.0, *) else { return }
        let twelve = [
            bucket("codex", "Codex", .chatGPT, remaining: 62, minutes: 10_080, resetCredits: 3),
            bucket("claude", "All models", .claude, remaining: 45, minutes: 300, secondaryRemaining: 70,
                   plan: "max", resetCredits: 2),
            bucket("cursor", "Cursor models", .cursor, remaining: 33, minutes: 44_640),
            bucket("grok", "Weekly credits", .grok, remaining: 100, minutes: 10_080),
            bucket("gemini", "Gemini Pro", .gemini, remaining: 74, minutes: 1_440),
            bucket("jetbrains", "Monthly quota", .jetBrainsAI, remaining: 58, minutes: 43_200),
            bucket("windsurf", "Prompt credits", .windsurf, remaining: 21, minutes: 43_200),
            bucket("antigravity", "Agent requests", .antigravity, remaining: 88, minutes: 300),
            bucket("copilot", "Premium requests", .copilot, remaining: 40, minutes: 43_200),
            bucket("kiro", "Vibe requests", .kiro, remaining: 66, minutes: 43_200),
            bucket("amp", "Free tier", .amp, remaining: 9, minutes: 1_440),
            bucket("cline", "Credits", .cline, remaining: 95, minutes: 43_200),
        ]
        let suite = "usaige.render.twelve.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
        let (settings, _) = makeSettings()
        let store = UsageStore(provider: FixedUsageProvider(.success(.authenticated(twelve))), monitorsNetworkChanges: false)
        await store.refresh()
        let agentStore = CodexAgentStore(sources: [])
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace, memory = sampleMemoryUsage
        var cpuSamples = sampleCPUTicks.makeIterator()
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [:] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }, readMemoryUsage: { memory },
            readCPUTicks: { cpuSamples.next() }
        )
        await monitor.refresh()
        fillCPUHistory(monitor.cpu)
        // 13-inch MacBook Air (notch, 1470 x 956) and 13-inch MacBook Pro
        // (1440 x 900), each with the Dock at the bottom.
        let screens: [(String, PanelScreenState)] = [
            ("air13", PanelScreenState(visibleHeight: 956 - 37 - 62, screenHeight: 956, safeTop: 37, safeBottom: 62)),
            ("pro13", PanelScreenState(visibleHeight: 900 - 24 - 62, screenHeight: 900, safeTop: 24, safeBottom: 62)),
        ]
        for (name, screen) in screens {
            screen.railEdge = .right
            for appearance in GalleryAppearance.allCases {
                try render(
                    ZStack(alignment: .trailing) {
                        (appearance == .light ? GalleryWallpaper.light : .dark).view
                        HUDView(store: store, agentStore: agentStore, settings: settings, updateController: UpdateController(),
                                openTool: { _ in }, openCodex: {}, openSettings: {}, resizePanel: { _ in },
                                screenState: screen, liveWork: monitor)
                            .defaultAppStorage(defaults)
                    },
                    size: CGSize(width: HUDMetrics.railWidth + 120, height: screen.screenHeight), appearance: appearance,
                    name: "twelve-rail-\(name)-\(appearance.rawValue)"
                )
            }
        }
        // Exercise independent background, overall scale and label size.
        let screen = screens[0].1
        let appearances: [(Double, Double, HUDTextSize)] = [(0.38, 1.2, .standard), (0, 0.5, .small), (1, 1.5, .large)]
        for (opacity, scale, textSize) in appearances {
            let (tuned, _) = makeSettings()
            tuned.opacity = opacity
            tuned.scale = scale
            tuned.textSize = textSize
            for appearance in GalleryAppearance.allCases {
                try render(
                    ZStack(alignment: .trailing) {
                        (appearance == .light ? GalleryWallpaper.light : .dark).view
                        HUDView(store: store, agentStore: agentStore, settings: tuned, updateController: UpdateController(),
                                openTool: { _ in }, openCodex: {}, openSettings: {}, resizePanel: { _ in },
                                screenState: screen, liveWork: monitor)
                            .defaultAppStorage(defaults)
                    },
                    size: CGSize(width: HUDMetrics.railWidth(for: textSize) * scale + 120, height: screen.screenHeight),
                    appearance: appearance,
                    name: "tuned-rail-\(Int(opacity * 100))-\(scale)-\(textSize.rawValue)-\(appearance.rawValue)"
                )
            }
        }
    }

    @Test func rendersChineseLanguageSettings() throws {
        guard #available(macOS 14.0, *) else { return }
        let domain = "usaige.render.language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
        let settings = HUDSettings(defaults: defaults)
        let status = LocalToolStatusRegistry(detectInstallations: { [] })
        let usage = UsageStore(provider: FixedUsageProvider(.success(.authenticated([]))), monitorsNetworkChanges: false)
        let preferences = HUDSettingsRootView(
            settings: settings, store: usage, launchAtLogin: inertLaunchAtLogin(), updateController: UpdateController(),
            relaySync: RelaySyncController(defaults: defaults), localToolStatus: status,
            navigation: SettingsNavigation(), layout: .page)
        let navigation = BranchesPaperweightPresentation()
        navigation.focus(.settings)
        let window = MainRootView(store: BranchesStore(defaults: defaults), usageStore: usage, settings: settings,
                                  presentation: navigation, settingsContent: AnyView(preferences), openSettings: {})
            .appLanguageEnvironment()
            .defaultAppStorage(defaults)
        for appearance in GalleryAppearance.allCases {
            try render(window, size: CGSize(width: 1180, height: 820), appearance: appearance,
                       name: "modern-settings-chinese-\(appearance.rawValue)")
        }
    }

    @Test func rendersEverySettingsPage() throws {
        guard #available(macOS 14.0, *) else { return }
        let pages: [(String, [SettingsDestination])] = [
            ("settings-root", []),
            ("settings-ai-tools", [.aiTools]),
            ("settings-remote-pairing", [.remoteToolPairing]),
            ("settings-iphone-sync", [.iphoneSync]),
            ("settings-feedback", [.feedback]),
        ]
        let historyOnlySnapshots = mixedSnapshots.filter { $0.toolID != .claude }
            + ClaudeUsageProvider.snapshots(
                fromClaudeApp: ClaudeAppUsageSample(recordedAt: Date(), sessionPercent: 55, weeklyPercent: 30),
                planType: nil
            )
        let claudeStatuses: [(String, LocalToolStatus, [QuotaSnapshot])] = [
            ("connected", .connected, mixedSnapshots),
            ("claude-app-reset-unavailable", .connectedThroughClaudeApp, historyOnlySnapshots),
            ("claude-app-cache-reset-known", .connectedThroughClaudeAppCache, mixedSnapshots),
            ("claude-api-key-only", .apiKeyOnly, mixedSnapshots.filter { $0.toolID != .claude }),
            ("claude-waiting-automatically", .waitingForClaudeUsage, mixedSnapshots.filter { $0.toolID != .claude }),
            ("claude-expired-api-key-helper", .apiKeyHelperSignInExpired, mixedSnapshots.filter { $0.toolID != .claude }),
            ("nothing-connected", .signedOut, []),
        ]
        for (pageName, route) in pages {
            let variants = route == [.aiTools] ? claudeStatuses : [claudeStatuses[0]]
            for (variantName, claudeStatus, snapshots) in variants {
                for appearance in GalleryAppearance.allCases {
                    for (sizeName, size) in [("window", CGSize?.none), ("full", CGSize(width: 520, height: 1_500))] {
                        let (settings, defaults) = makeSettings()
                        settings.registerBuckets(snapshots)
                        let registry = LocalToolStatusRegistry()
                        registry.report(claudeStatus, for: .claude)
                        registry.report(snapshots.contains { $0.toolID == .cursor } ? .connected : .signedOut, for: .cursor)
                        registry.report(snapshots.contains { $0.toolID == .grok } ? .connected : .notInstalled, for: .grok)
                        let navigation = SettingsNavigation()
                        navigation.route = route
                        let view = SettingsWindowSizing {
                            HUDSettingsView(
                                settings: settings,
                                snapshots: snapshots,
                                launchAtLogin: inertLaunchAtLogin(),
                                updateController: UpdateController(),
                                relaySync: RelaySyncController(defaults: defaults),
                                localToolStatus: registry,
                                navigation: navigation,
                                refreshUsage: {}
                            )
                        }
                        let suffix = variants.count > 1 ? "-\(variantName)" : ""
                        let rendered = try render(view, size: size, appearance: appearance,
                                                  name: "\(pageName)\(suffix)-\(appearance.rawValue)-\(sizeName)")
                        // Report each page's self-sized window, like the live smoke
                        // tests report their limits.
                        if size == nil {
                            print("[gallery] \(pageName)\(suffix) window: \(Int(rendered.width))x\(Int(rendered.height))")
                        }
                    }
                }
            }
        }
    }

    @Test func rendersWhatsNew() throws {
        guard #available(macOS 14.0, *) else { return }
        let bundle = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let controller = UpdateController(bundle: bundle, manifestURLs: [])
        for appearance in GalleryAppearance.allCases {
            try render(WhatsNewView(updateController: controller, close: {}), size: CGSize(width: 560, height: 600),
                       appearance: appearance, name: "whats-new-\(appearance.rawValue)")
        }
    }

    private func sampleLiveWork() -> [CodexAgentTask] {
        func task(_ id: String, _ tool: AIToolID, _ title: String, _ phase: CodexAgentPhase, _ folder: String, _ branch: String, pid: Int32? = nil) -> CodexAgentTask {
            CodexAgentTask(
                id: id, title: title, workspaceName: "app", phase: phase, updatedAt: Date(),
                toolID: tool, folder: folder, branch: branch, processID: pid
            )
        }
        return [
            task("a", .chatGPT, "Build the Branches page", .thinking, "/Users/me/Developer/OneMind/.codex/worktrees/branches-page", "codex/branches-page-1529"),
            task("b", .chatGPT, "Fix the folder privacy leak", .needsInput, "/Users/me/Developer/OneMind/.codex/worktrees/folder-privacy", "codex/folder-path-privacy-20261106"),
            task("c", .claude, "Stop the rail's memory leaks", .thinking, "/Users/me/Documents/GPTUsage", "main", pid: 11),
            task("d", .cursor, "Tidy the settings copy", .complete, "/Users/me/Developer/site", "polish-settings"),
        ]
    }

    private func sampleProcesses() -> [WorkProcess] {
        func process(_ id: Int32, _ name: String, _ folder: String, _ megabytes: UInt64, ports: [Int] = [], executable: String? = nil) -> WorkProcess {
            WorkProcess(id: id, name: name, folder: folder, memoryBytes: megabytes * 1024 * 1024, startedAt: nil, ports: ports, executablePath: executable)
        }
        return [
            process(1, "codex", "/Users/me/Developer/OneMind/.codex/worktrees/branches-page", 210),
            process(2, "node", "/Users/me/Developer/OneMind/.codex/worktrees/branches-page", 340, ports: [4296]),
            process(3, "swift-build", "/Users/me/Developer/OneMind/.codex/worktrees/branches-page", 610),
            process(4, "codex", "/Users/me/Developer/OneMind/.codex/worktrees/folder-privacy", 190),
            process(11, "claude", "/Users/me/Documents/GPTUsage", 480),
            process(21, "Claude", "/", 900, executable: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
    }

    private var sampleDiskSpace: DiskSpace {
        DiskSpace(totalBytes: 1_000_000_000_000, availableBytes: 212_000_000_000)
    }

    private var sampleCPUTicks: [SystemCPUUsage.Ticks] {
        let percentages: [UInt32] = [23, 25, 30, 28, 47, 58, 49, 36, 32, 30, 27, 26, 34, 39, 38,
                                     46, 71, 83, 95, 92, 78, 54, 46, 48, 42, 38, 41, 44, 42, 40]
        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0
        var ticks = [SystemCPUUsage.Ticks(user: user, system: system, idle: idle, nice: 0)]
        for index in 0..<Int(SystemTrendWindow.duration / SystemCPUMonitor.sampleInterval) {
            let percent = percentages[index % percentages.count]
            system += percent / 3
            user += percent - percent / 3
            idle += 100 - percent
            ticks.append(.init(user: user, system: system, idle: idle, nice: 0))
        }
        return ticks
    }

    private func fillCPUHistory(_ monitor: SystemCPUMonitor) {
        let count = sampleCPUTicks.count
        let start = Date().addingTimeInterval(-Double(count - 1) * SystemCPUMonitor.sampleInterval)
        for index in 0..<count {
            monitor.sample(at: start.addingTimeInterval(Double(index) * SystemCPUMonitor.sampleInterval))
        }
    }

    private func fillResourceHistory(_ monitor: LiveWorkMonitor, memory: SystemMemoryUsage, disk: DiskSpace) {
        let end = Date()
        let start = SystemTrendWindow.ending(at: end).lowerBound
        let offsets: [Int64] = [0, 200, 500, 700, 250, -350, -450, -300, 100, 0]
        for index in 0...Int(SystemTrendWindow.duration / 10) {
            let bytes = memory.combinedUsedBytes + offsets[index % offsets.count] * 1_000_000
            let pressure: SystemMemoryPressure = switch index % 30 {
            case 7...10, 17...22: .warning
            case 11...16: .critical
            default: .normal
            }
            monitor.memoryHistory.record(bytes: bytes, status: pressure.trendStatus, at: start.addingTimeInterval(Double(index * 10)))
        }
        for (index, factor) in [100, 82, 70, 57, 55, 52, 38, 22, 21, 41, 100].enumerated() {
            let diskSample = DiskSpace(totalBytes: disk.totalBytes, availableBytes: disk.availableBytes / 100 * Int64(factor))
            monitor.storageHistory.record(bytes: diskSample.availableBytes, status: .storage(usedShare: diskSample.usedShare()),
                                          at: start.addingTimeInterval(Double(index * 60)))
        }
    }

    private var sampleMemoryUsage: SystemMemoryUsage {
        let gibibyte: Int64 = 1_024 * 1_024 * 1_024
        return SystemMemoryUsage(capacityBytes: 24 * gibibyte, usedBytes: 20 * gibibyte,
                                 swapUsedBytes: gibibyte + gibibyte / 2, swapTotalBytes: 4 * gibibyte)
    }

    /// The rail's tiles, the card beside them, and a row's card with its tool's
    /// work, from sample sessions.
    @Test func rendersLiveWork() async throws {
        guard #available(macOS 14.0, *) else { return }
        let tasks = sampleLiveWork()
        let processes = sampleProcesses()
        let disk = sampleDiskSpace
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks },
            runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }
        )
        await monitor.refresh()
        let idleMonitor = LiveWorkMonitor(
            currentTasks: { [] },
            runningApplications: { [:] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in [] },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }
        )
        await idleMonitor.refresh()
        let unreadMonitor = LiveWorkMonitor(
            currentTasks: { [] },
            runningApplications: { [:] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in [] },
            readDiskSpace: { nil }
        )
        var railScenes: [(String, LiveWorkMonitor)] = [
            ("working", monitor), ("idle", idleMonitor), ("unread", unreadMonitor),
        ]
        // Both ends of the disk range keep the free-space label readable and
        // show whether the small ship fits above a low or warning-level surface.
        for (name, space) in [
            ("disk-near-empty", DiskSpace(totalBytes: 1_000_000_000_000, availableBytes: 990_000_000_000)),
            ("disk-nearly-full", DiskSpace(totalBytes: 1_000_000_000_000, availableBytes: 51_000_000_000)),
            ("disk-full", DiskSpace(totalBytes: 1_000_000_000_000, availableBytes: 1_000_000_000)),
        ] {
            let sampled = LiveWorkMonitor(
                currentTasks: { tasks },
                runningApplications: { [.claude: ["/Applications/Claude.app"]] },
                locator: { RepositoryLocator(home: "/Users/me") },
                scan: { _, _ in processes },
                readDiskSpace: { space }
            )
            await sampled.refresh()
            railScenes.append((name, sampled))
        }

        let snapshots = Array(mixedSnapshots.prefix(4))
        let store = UsageStore(provider: FixedUsageProvider(.success(.authenticated(snapshots))), monitorsNetworkChanges: false)
        await store.refresh()
        let agentStore = CodexAgentStore(sources: [
            .init(toolID: .chatGPT, provider: FixedAgentProvider(tasks.filter { $0.toolID == .chatGPT })),
            .init(toolID: .claude, provider: FixedAgentProvider(tasks.filter { $0.toolID == .claude })),
        ])
        await agentStore.refresh()
        let railHeight = HUDMetrics.railHeight(rowCount: snapshots.count, maximumHeight: 2_000, showsWorkTile: true)
        let canvas = CGSize(width: HUDMetrics.railWidth + 56, height: railHeight + 56)
        let modernScreen = PanelScreenState(visibleHeight: 696, screenHeight: 800, safeTop: 34, safeBottom: 70)
        modernScreen.railEdge = .right
        for appearance in GalleryAppearance.allCases {
            let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
            for (name, tile) in railScenes {
                for hovered in [false, true] {
                    let (settings, settingsDefaults) = makeSettings()
                    // Modern's rail runs the display's full height; Classic floats.
                    settingsDefaults.set(InterfaceStyle.modern.rawValue, forKey: InterfaceStyle.defaultsKey)
                    try render(
                        ZStack(alignment: .trailing) {
                            wallpaper.view
                            HUDView(
                                store: store,
                                agentStore: agentStore,
                                settings: settings,
                                updateController: UpdateController(),
                                openTool: { _ in },
                                openCodex: {},
                                openSettings: {},
                                resizePanel: { _ in },
                                screenState: modernScreen,
                                liveWork: tile
                            )
                            .environment(\.hudPreviewsHover, hovered)
                            .defaultAppStorage(settingsDefaults)
                        },
                        size: CGSize(width: HUDMetrics.railWidth + 120, height: modernScreen.screenHeight),
                        appearance: appearance,
                        name: "modern-live-rail-\(name)-\(appearance.rawValue)-\(hovered ? "hover" : "idle")"
                    )
                    settingsDefaults.set(InterfaceStyle.classic.rawValue, forKey: InterfaceStyle.defaultsKey)
                    try render(
                        ZStack {
                            wallpaper.view
                            HUDView(
                                store: store,
                                agentStore: agentStore,
                                settings: settings,
                                updateController: UpdateController(),
                                openTool: { _ in },
                                openCodex: {},
                                openSettings: {},
                                resizePanel: { _ in },
                                screenState: PanelScreenState(visibleHeight: 2_000),
                                liveWork: tile
                            )
                            .environment(\.hudPreviewsHover, hovered)
                            .defaultAppStorage(settingsDefaults)
                        },
                        size: canvas, appearance: appearance,
                        name: "live-rail-\(name)-\(appearance.rawValue)-\(hovered ? "hover" : "idle")"
                    )
                }
            }
            try render(
                ZStack {
                    wallpaper.view
                    QuotaDetailCard(
                        snapshot: mixedSnapshots[0],
                        work: monitor.summary.sessions(for: .chatGPT),
                        memoryBytes: monitor.summary.memoryBytes(for: .chatGPT)
                    )
                },
                size: nil, appearance: appearance, name: "live-row-card-\(appearance.rawValue)"
            )
            try render(
                ZStack {
                    wallpaper.view
                    LiveWorkCard(summary: monitor.summary, memory: monitor.memoryUsage, history: monitor.memoryHistory)
                },
                size: nil, appearance: appearance, name: "live-tile-card-\(appearance.rawValue)"
            )
            try render(
                ZStack {
                    wallpaper.view
                    LiveWorkCard(summary: idleMonitor.summary, memory: idleMonitor.memoryUsage, history: idleMonitor.memoryHistory)
                },
                size: nil, appearance: appearance, name: "live-tile-card-idle-\(appearance.rawValue)"
            )
            let disk = DiskSpace(totalBytes: 994_000_000_000, availableBytes: 51_900_000_000)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var measured = StorageBreakdown(
                storage: PaperweightConfiguration(id: .storage, capacityBytes: disk.totalBytes, layers: [
                    PaperweightLayer(id: "other", title: "macOS and apps", bytes: 288_000_000_000, colorHex: 0x5E9FE3, inkHex: 0),
                    PaperweightLayer(id: "tool", title: "Tool storage", bytes: 102_770_000_000, colorHex: 0xF4B14A, inkHex: 0),
                    PaperweightLayer(id: "cache", title: "Build cache", bytes: 40_340_000_000, colorHex: 0x3DB58C, inkHex: 0),
                    PaperweightLayer(id: "wt", title: "Worktrees", bytes: 12_700_000_000, colorHex: 0xE2729A, inkHex: 0),
                ], freeBytes: disk.availableBytes),
                freeableBytes: 16_440_000_000, measuredAt: now
            )
            measured?.measuredAt = now.addingTimeInterval(-3 * 3600)
            try render(
                ZStack {
                    wallpaper.view
                    StorageCard(disk: disk, breakdown: measured, history: monitor.storageHistory, now: now, openBranches: {})
                },
                size: nil, appearance: appearance, name: "storage-tile-card-\(appearance.rawValue)"
            )
            try render(
                ZStack {
                    wallpaper.view
                    StorageCard(disk: disk, breakdown: nil, history: monitor.storageHistory, now: now, openBranches: {})
                },
                size: nil, appearance: appearance, name: "storage-tile-card-unmeasured-\(appearance.rawValue)"
            )
        }
    }

    /// The same cards from the sessions really running on this Mac, read the
    /// way the app reads them, with how long a sample takes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_LIVE_BRANCHES"] == "1"))
    func rendersLiveWorkFromThisMac() async throws {
        guard #available(macOS 14.0, *) else { return }
        var sources: [CodexAgentStore.Source] = [
            .init(toolID: .claude, provider: ClaudeCodeAgentProvider()),
            .init(toolID: .cursor, provider: CursorAgentProvider()),
            .init(toolID: .grok, provider: GrokBuildAgentProvider()),
        ]
        if CodexExecutableResolver.resolve() != nil {
            let transport = ProcessLineTransport(executableURL: { CodexExecutableResolver.resolve() })
            sources.append(.init(toolID: .chatGPT, provider: CodexAgentProvider(rpc: JSONRPCConnection(transport: transport))))
        }
        let agentStore = CodexAgentStore(sources: sources)
        await agentStore.refresh()
        let monitor = LiveWorkMonitor(currentTasks: { agentStore.currentTasks() })
        monitor.detailVisibilityChanged(true)
        await monitor.refresh()
        let summary = monitor.summary
        await agentStore.shutdown()

        let tasks = agentStore.currentTasks()
        let applications = LiveWorkMonitor.runningToolApplications()
        let locator = LiveWorkMonitor.defaultLocator()
        let clock = ContinuousClock()
        for includePorts in [false, true] {
            var total = Duration.zero
            for _ in 0..<20 {
                total += clock.measure {
                    _ = LiveWorkReader.read(tasks: tasks, applications: applications, locator: locator, includePorts: includePorts)
                }
            }
            print("LIVE sample with ports \(includePorts): \(total / 20) on average")
        }
        print("LIVE \(summary.sessions.count) sessions in \(summary.placeCount) places, \(LiveWorkText.memory(summary.memoryBytes))")
        for tool in AIToolDescriptor.all {
            print("LIVE \(tool.name): \(summary.sessions(for: tool.id).count) sessions, \(LiveWorkText.memory(summary.memoryBytes(for: tool.id))), app processes \(summary.appProcesses[tool.id]?.count ?? 0)")
        }
        for place in LiveWorkPlace.places(from: summary.sessions) {
            print("LIVE \(place.lead.toolID.rawValue) \(place.lead.phase.label) +\(place.sessions.count - 1) | branch \(LiveWorkText.branchLine(place.lead) ?? "-") | \(LiveWorkText.detailLine(place)) | \(LiveWorkText.memory(place.memoryBytes))")
        }
        for appearance in GalleryAppearance.allCases {
            let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
            try render(
                ZStack {
                    wallpaper.view
                    LiveWorkCard(summary: summary, memory: monitor.memoryUsage, history: monitor.memoryHistory)
                },
                size: nil, appearance: appearance, name: "real-tile-card-\(appearance.rawValue)"
            )
            for tool in AIToolDescriptor.all where !summary.sessions(for: tool.id).isEmpty {
                var quota = mixedSnapshots[0]
                quota.toolID = tool.id
                try render(
                    ZStack {
                        wallpaper.view
                        QuotaDetailCard(
                            snapshot: quota,
                            work: summary.sessions(for: tool.id),
                            memoryBytes: summary.memoryBytes(for: tool.id)
                        )
                    },
                    size: nil, appearance: appearance, name: "real-row-card-\(tool.id.rawValue)-\(appearance.rawValue)"
                )
            }
        }
    }

    /// Measured examples keep every storage view populated without scanning
    /// this Mac or changing a repository just to review the layout.
    private func sampleBranchesSnapshot(now: Date) -> BranchesSnapshot {
        let app = "/Users/me/Documents/GPTUsage/.git"
        let project = "/Users/me/Developer/OneMind/.git"
        let old = now.addingTimeInterval(-10 * 86_400)
        let processes = sampleProcesses()

        func item(
            _ id: String, _ title: String, repository: String = "/Users/me/Documents/GPTUsage/.git",
            folder: String? = nil, gigabytes: Double, cacheGigabytes: Double
        ) -> WorkItem {
            var facts = WorkFacts()
            facts.hasWorktree = true
            facts.folderExists = true
            facts.changedFiles = 0
            facts.untrackedFiles = 0
            facts.ownCommits = 2
            facts.commitsAtRisk = 0
            facts.merge = .sameCommits
            let cache = Int64(cacheGigabytes * 1_000_000_000)
            var row = WorkItem(
                id: id, repositoryID: repository,
                repositoryName: repository == app ? "usAIge" : "OneMind", branch: id,
                worktreePath: folder ?? "/Users/me/Developer/worktrees/\(id)",
                tip: "abc1234", upstream: "origin/\(id)", committedAt: old,
                facts: facts, ignoredFiles: [".build"]
            )
            row.sessions = WorkSessionSummary(count: 1, tools: ["Codex"], lastActiveAt: old, title: title)
            // A finished scan has checked the ignored build folder, so it can go.
            let review = WorktreeIgnoredReview(identity: CleanupFileIdentity(stat()), fingerprint: "sample",
                                               unverifiedPaths: [])
            row.ignoredReview = review
            row.size = FolderSize(
                totalBytes: Int64(gigabytes * 1_000_000_000), cacheBytes: cache,
                cacheBytesByName: [".build": cache], ignored: [".build"],
                otherIgnoredBytes: 0, measuredAt: now, ignoredReview: review
            )
            return row
        }

        var running = item(
            "branches-page", "Build the Branches page", repository: project,
            folder: "/Users/me/Developer/OneMind/.codex/worktrees/branches-page",
            gigabytes: 7.4, cacheGigabytes: 6.2
        )
        running.processes = processes.filter { $0.folder == running.worktreePath }
        running.facts.runningProcesses = running.processes.count
        running.sessions.lastActiveAt = now

        var main = item(
            "main", "Stop the rail's memory leaks", folder: "/Users/me/Documents/GPTUsage",
            gigabytes: 3.8, cacheGigabytes: 2.1
        )
        main.facts.isMainCopy = true
        main.facts.hasWorktree = false
        main.processes = processes.filter { $0.folder == main.worktreePath }
        main.facts.runningProcesses = main.processes.count
        main.sessions = WorkSessionSummary(count: 1, tools: ["Claude Code"], lastActiveAt: now, title: main.workTitle)

        var unsaved = item("folder-privacy", "Keep protected folders private", gigabytes: 6.7, cacheGigabytes: 5.2)
        unsaved.facts.merge = nil
        unsaved.facts.commitsAtRisk = 2
        unsaved.facts.changedFiles = 3
        unsaved.facts.untrackedFiles = 1
        unsaved.sessions.lastActiveAt = now.addingTimeInterval(-86_400)

        var pushed = item("settings-copy", "Make the settings easier to read", gigabytes: 4.2, cacheGigabytes: 2.8)
        pushed.facts.merge = nil
        let finished = item("finished-one", "Show usage across all tools", gigabytes: 8.6, cacheGigabytes: 7.4)
        let alsoFinished = item("finished-two", "Keep the rail on this screen", gigabytes: 2.3, cacheGigabytes: 1.5)
        var empty = item("empty-copy", "An unused experiment", gigabytes: 0.6, cacheGigabytes: 0.4)
        empty.facts.merge = nil
        empty.facts.ownCommits = 0

        return BranchesSnapshot(
            repositories: [
                RepositoryInfo(id: app, name: "usAIge", baseRef: "main"),
                RepositoryInfo(id: project, name: "OneMind", baseRef: "main"),
            ],
            items: [running, main, unsaved, pushed, finished, alsoFinished, empty]
        )
    }

    private var sampleCleanupInventory: StorageCleanupInventory {
        func row(_ kind: StorageArtifactKind, owner: String, bytes: Int64) -> StorageCleanupRow {
            let location = StorageArtifactLocation(kind: kind, owner: owner, workspace: owner)
            let inspection = CleanupFileInspection(identity: CleanupFileIdentity(stat()), fingerprint: "sample",
                                                   allocatedBytes: bytes, protectedPath: nil)
            return StorageCleanupRow(location: location, bytes: bytes, reason: nil,
                                     candidate: StorageCleanupCandidate(location: location, inspection: inspection))
        }
        return StorageCleanupInventory(rows: [
            row(.xcodeBuild, owner: "/Users/me/Library/Developer/Xcode/DerivedData/usAIge", bytes: 6_400_000_000),
            row(.npmCache, owner: "/Users/me", bytes: 3_100_000_000),
            row(.nodeModules, owner: "/Users/me/Developer/worktrees/finished-one", bytes: 300_000_000)
        ], foldersChecked: 3)
    }

    private var sampleToolStorage: [ToolStorageEntry] {
        [
            ToolStorageEntry(name: "Xcode DerivedData", path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 8_800_000_000, kind: .rebuildable),
            ToolStorageEntry(name: "Claude Code transcripts", path: "/Users/me/.claude/projects", bytes: 4_200_000_000, kind: .history),
            ToolStorageEntry(name: "Codex plugins", path: "/Users/me/.codex/plugins", bytes: 3_200_000_000, kind: .runtime),
            ToolStorageEntry(name: "Codex sessions", path: "/Users/me/.codex/sessions", bytes: 2_400_000_000, kind: .history),
            ToolStorageEntry(name: "SwiftPM cache", path: "/Users/me/Library/Caches/org.swift.swiftpm", bytes: 1_100_000_000, kind: .rebuildable),
        ]
    }

    /// Check both fronts from the minimum window through the default and a
    /// wide desktop, where a fixed camera leaves large empty side margins.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersBranches() async throws {
        guard #available(macOS 14.0, *) else { return }
        let snapshot = sampleBranchesSnapshot(now: Date())
        let defaults = try #require(UserDefaults(suiteName: "usaige.render.branches.\(UUID().uuidString)"))
        defaults.set(InterfaceStyle.classic.rawValue, forKey: InterfaceStyle.defaultsKey)
        let store = BranchesStore(
            defaults: defaults, initialSnapshot: snapshot, initialDiskSpace: sampleDiskSpace,
            initialToolStorage: sampleToolStorage
        )
        store.chooseShip(.thousandSunny, for: .memory)
        store.chooseShip(.sleepingWhiteHorse, for: .storage)
        let reviewed = snapshot.items.filter(\.eligibility.isAllowed)
        let tasks = sampleLiveWork()
        let processes = sampleProcesses()
        let disk = sampleDiskSpace
        let memory = sampleMemoryUsage
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks },
            runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }, readMemoryUsage: { memory }
        )
        await monitor.refresh()
        let sizes: [(String, CGSize)] = [
            ("regular", CGSize(width: 1080, height: 640)),
            ("minimum", CGSize(width: 900, height: 560)),
            ("default", CGSize(width: 1180, height: 780)),
            ("wide", CGSize(width: 1600, height: 900)),
        ]
        for appearance in GalleryAppearance.allCases {
            for (sizeName, size) in sizes {
                for front in PaperweightID.allCases {
                    try render(
                        BranchesRootView(store: store, liveWork: monitor, initialFront: front)
                            .defaultAppStorage(defaults)
                            .environment(\.usageSceneFrozen, true),
                        size: size, appearance: appearance,
                        name: "branches-paperweight-\(front.rawValue)-\(sizeName)-\(appearance.rawValue)"
                    )
                }
            }
            for layerID in ["cache", "tool", "other", "free"] {
                try render(
                    BranchesRootView(store: store, liveWork: monitor, initialFront: .storage,
                                     initialSelectedLayerID: layerID)
                        .defaultAppStorage(defaults),
                    size: CGSize(width: 900, height: 560), appearance: appearance,
                    name: "branches-paperweight-storage-minimum-\(layerID)-\(appearance.rawValue)"
                )
            }
            try render(BranchesRootView(store: store).defaultAppStorage(defaults),
                       size: CGSize(width: 900, height: 560),
                       appearance: appearance, name: "branches-no-monitor-\(appearance.rawValue)")
            try render(
                DeleteReviewView(request: DeleteReviewRequest(items: reviewed), confirm: { _ in }, cancel: {}),
                size: nil, appearance: appearance, name: "branches-review-\(appearance.rawValue)"
            )
        }
        let undoRecord = DeletionRecord(
            repositoryDirectory: "/Users/me/Documents/GPTUsage", repositoryName: "usAIge",
            displayName: "finished-one", worktreePath: "/Users/me/Developer/worktrees/finished-one",
            branch: "finished-one", branchWasDeleted: true, tip: "abc1234",
            upstream: "origin/finished-one", deletedAt: Date()
        )
        var clearedSnapshot = snapshot
        clearedSnapshot.items.removeAll { ["finished-one", "finished-two"].contains($0.id) }
        clearedSnapshot.deletions = [undoRecord]
        let clearedStore = BranchesStore(
            defaults: defaults, initialSnapshot: clearedSnapshot, initialDiskSpace: sampleDiskSpace,
            initialToolStorage: sampleToolStorage
        )
        clearedStore.resultMessage = BranchesStore.ResultMessage(
            text: "2 items cleared.", isProblem: false, undoable: [undoRecord], freedBytes: 10_900_000_000,
            deletedCount: 2
        )
        var clearingSnapshot = snapshot
        clearingSnapshot.activity = .clearing(done: 1, total: 3)
        let clearingStore = BranchesStore(
            defaults: defaults, initialSnapshot: clearingSnapshot, initialDiskSpace: sampleDiskSpace,
            initialToolStorage: sampleToolStorage
        )
        for appearance in GalleryAppearance.allCases {
            try render(
                BranchesRootView(store: clearedStore, liveWork: monitor)
                    .defaultAppStorage(defaults),
                size: CGSize(width: 900, height: 560), appearance: appearance,
                name: "branches-paperweight-cleared-minimum-\(appearance.rawValue)"
            )
            try render(
                BranchesRootView(store: clearingStore, liveWork: monitor)
                    .defaultAppStorage(defaults),
                size: CGSize(width: 900, height: 560), appearance: appearance,
                name: "branches-paperweight-clearing-minimum-\(appearance.rawValue)"
            )
        }
    }

    /// The default scene reads only its isolated visual preference. Freeze its
    /// clock so precipitation and ships can be compared across appearances.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersSailingWeather() async throws {
        guard #available(macOS 14.0, *) else { return }
        let suite = "usaige.render.sailing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks },
            runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }
        )
        await monitor.refresh()
        let store = BranchesStore(
            defaults: defaults, initialSnapshot: sampleBranchesSnapshot(now: Date()),
            initialDiskSpace: disk, initialToolStorage: sampleToolStorage
        )
        let normalSize = CGSize(width: 1180, height: 780)
        for appearance in GalleryAppearance.allCases {
            for weather in CruiseWeather.allCases where weather != .automatic {
                defaults.set(weather.rawValue, forKey: CruiseWeather.defaultsKey)
                let rendered = try render(
                    BranchesRootView(store: store, liveWork: monitor)
                        .defaultAppStorage(defaults)
                        .environment(\.usageSceneFrozen, true),
                    size: normalSize, appearance: appearance,
                    name: "branches-sailing-\(weather.rawValue)-default-\(appearance.rawValue)"
                )
                #expect(rendered == normalSize)
            }
            defaults.set(CruiseWeather.sunny.rawValue, forKey: CruiseWeather.defaultsKey)
            for (sizeName, size) in [
                ("minimum", CGSize(width: 900, height: 560)),
                ("wide", CGSize(width: 1600, height: 900)),
            ] {
                let rendered = try render(
                    BranchesRootView(store: store, liveWork: monitor)
                        .defaultAppStorage(defaults)
                        .environment(\.usageSceneFrozen, true),
                    size: size, appearance: appearance,
                    name: "branches-sailing-sunny-\(sizeName)-\(appearance.rawValue)"
                )
                #expect(rendered == size)
            }
        }
    }

    /// Inspect hull and mast visibility near a shake's peak while the same
    /// native simulation supplies both boat buoyancy and foreground water.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersUnsinkableSailing() throws {
        guard #available(macOS 14.0, *) else { return }
        let sizes: [(String, CGSize, Bool)] = [
            ("window", CGSize(width: 1180, height: 780), false),
            ("rail", CGSize(width: 84, height: 450), true),
        ]
        for appearance in GalleryAppearance.allCases {
            for weather in CruiseWeather.allCases where weather != .automatic {
                for (sizeName, size, compact) in sizes {
                    if compact, weather != .sunny, weather != .storm { continue }
                    // Sunny and storm cover both the long liner and tall
                    // galleon at each size; other weather keeps its window.
                    let ships: [PaperweightShipKind] = weather == .sunny || weather == .storm
                        ? [.liner, .galleon] : [.galleon]
                    for ship in ships {
                        let view = UsageAtmosphereView(frame: CGRect(origin: .zero, size: size))
                        view.configure(active: true, compact: compact, weather: weather, ship: ship,
                                       showsShip: true, dark: appearance == .dark, reduced: false,
                                       command: PaperweightSceneCommand(id: 1, kind: .shake))
                        for _ in 0..<30 { view.advanceAnimation(by: 1.0 / 120) }
                        view.configure(active: false, compact: compact, weather: weather, ship: ship,
                                       showsShip: true, dark: appearance == .dark, reduced: false)
                        #expect(!view.isAnimating)
                        let rendered = try render(
                            GalleryAtmosphereView(view: view), size: size, appearance: appearance,
                            name: "sailing-unsinkable-\(ship.rawValue)-\(weather.rawValue)-\(sizeName)-\(appearance.rawValue)"
                        )
                        #expect(rendered == size)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersEveryPaperweightShip() async throws {
        guard #available(macOS 14.0, *) else { return }
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }
        )
        await monitor.refresh()
        let now = Date()
        let board = BranchesBoard.make(snapshot: sampleBranchesSnapshot(now: now), now: now)
        let configurations = [
            PaperweightData.memory(summary: monitor.summary, running: board.running, systemUsage: sampleMemoryUsage),
            PaperweightData.storage(disk: disk, board: board, toolStorage: sampleToolStorage, isMeasuring: false),
        ]
        for ship in PaperweightShipKind.allCases {
            try render(
                PaperweightSceneView(
                    configurations: configurations, front: .storage, selectedLayerID: "wt",
                    ships: [.memory: .sailboat, .storage: ship], command: nil,
                    onSelect: { _, _ in }, onSwap: { _ in }, onMovingChanged: { _ in },
                    reduceMotionOverride: true
                ),
                size: CGSize(width: 400, height: 260), appearance: .light,
                name: "paperweight-ship-\(ship.rawValue)"
            )
        }
    }

    /// These images verify the native fallback and lists, rather than 3D output.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() == nil))
    func rendersBranchesWithoutGraphics() async throws {
        guard #available(macOS 14.0, *) else { return }
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace
        let memory = sampleMemoryUsage
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }, readMemoryPressure: { .normal }, readMemoryUsage: { memory }
        )
        await monitor.refresh()
        let defaults = try #require(UserDefaults(suiteName: "usaige.render.no-graphics.\(UUID().uuidString)"))
        let store = BranchesStore(
            defaults: defaults, initialSnapshot: sampleBranchesSnapshot(now: Date()),
            initialDiskSpace: disk, initialToolStorage: sampleToolStorage
        )
        let sizes: [(String, CGSize)] = [
            ("minimum", CGSize(width: 900, height: 560)),
            ("regular", CGSize(width: 1080, height: 640)),
        ]
        for appearance in GalleryAppearance.allCases {
            for (sizeName, size) in sizes {
                for front in PaperweightID.allCases {
                    try render(
                        BranchesRootView(store: store, liveWork: monitor, initialFront: front)
                            .defaultAppStorage(defaults)
                            .environment(\.usageSceneFrozen, true),
                        size: size, appearance: appearance,
                        name: "branches-no-graphics-\(front.rawValue)-\(sizeName)-\(appearance.rawValue)"
                    )
                }
            }
        }
    }

    /// A minimal app bundle carrying the repository's release notes, so What's
    /// New shows the current highlights.
    private func temporaryAppBundle() throws -> Bundle {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = repository.appendingPathComponent("Sources/UsageHUD/Resources")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-gallery-\(UUID().uuidString).app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: resources.appendingPathComponent("Info.plist"),
            to: contents.appendingPathComponent("Info.plist")
        )
        try FileManager.default.copyItem(
            at: resources.appendingPathComponent("ReleaseNotes.json"),
            to: contents.appendingPathComponent("Resources/ReleaseNotes.json")
        )
        return try #require(Bundle(url: root))
    }
}

private extension Result {
    var value: Success? { try? get() }
}
