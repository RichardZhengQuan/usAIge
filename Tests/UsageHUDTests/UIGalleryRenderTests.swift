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

private func bucket(
    _ id: String,
    _ name: String,
    _ tool: AIToolID,
    remaining: Double,
    minutes: Int,
    secondaryRemaining: Double? = nil,
    plan: String = "pro"
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

            func rail(hovered: Bool, wallpaper: GalleryWallpaper) -> some View {
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
                        screenState: PanelScreenState(visibleHeight: 2_000)
                    )
                    .environment(\.hudPreviewsHover, hovered)
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
            readDiskSpace: { disk }
        )
        await monitor.refresh()
        let idleMonitor = LiveWorkMonitor(
            currentTasks: { [] },
            runningApplications: { [:] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in [] },
            readDiskSpace: { disk }
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
        for appearance in GalleryAppearance.allCases {
            let wallpaper: GalleryWallpaper = appearance == .light ? .light : .dark
            for (name, tile) in railScenes {
                for hovered in [false, true] {
                    let (settings, _) = makeSettings()
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
                    LiveWorkCard(summary: monitor.summary)
                },
                size: nil, appearance: appearance, name: "live-tile-card-\(appearance.rawValue)"
            )
            try render(
                ZStack {
                    wallpaper.view
                    LiveWorkCard(summary: idleMonitor.summary)
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
                    StorageCard(disk: disk, breakdown: measured, now: now, openBranches: {})
                },
                size: nil, appearance: appearance, name: "storage-tile-card-\(appearance.rawValue)"
            )
            try render(
                ZStack {
                    wallpaper.view
                    StorageCard(disk: disk, breakdown: nil, now: now, openBranches: {})
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
                    LiveWorkCard(summary: summary)
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
            row.size = FolderSize(
                totalBytes: Int64(gigabytes * 1_000_000_000), cacheBytes: cache,
                cacheBytesByName: [".build": cache], ignored: [".build"],
                otherIgnoredBytes: 0, measuredAt: now
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

    private var sampleToolStorage: [ToolStorageEntry] {
        [
            ToolStorageEntry(name: "Xcode DerivedData", path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 8_800_000_000, kind: .rebuildable),
            ToolStorageEntry(name: "Claude Code transcripts", path: "/Users/me/.claude/projects", bytes: 4_200_000_000, kind: .history),
            ToolStorageEntry(name: "Codex plugins", path: "/Users/me/.codex/plugins", bytes: 3_200_000_000, kind: .runtime),
            ToolStorageEntry(name: "Codex sessions", path: "/Users/me/.codex/sessions", bytes: 2_400_000_000, kind: .history),
            ToolStorageEntry(name: "SwiftPM cache", path: "/Users/me/Library/Caches/org.swift.swiftpm", bytes: 1_100_000_000, kind: .rebuildable),
        ]
    }

    /// Each paperweight takes the front at both supported window sizes.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersBranches() async throws {
        guard #available(macOS 14.0, *) else { return }
        let snapshot = sampleBranchesSnapshot(now: Date())
        let defaults = try #require(UserDefaults(suiteName: "usaige.render.branches.\(UUID().uuidString)"))
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
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks },
            runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") },
            scan: { _, _ in processes },
            readDiskSpace: { disk }
        )
        await monitor.refresh()
        let sizes: [(String, CGSize)] = [
            ("regular", CGSize(width: 1080, height: 640)),
            ("minimum", CGSize(width: 900, height: 560)),
        ]
        for appearance in GalleryAppearance.allCases {
            for (sizeName, size) in sizes {
                for front in PaperweightID.allCases {
                    try render(
                        BranchesRootView(store: store, liveWork: monitor, initialFront: front),
                        size: size, appearance: appearance,
                        name: "branches-paperweight-\(front.rawValue)-\(sizeName)-\(appearance.rawValue)"
                    )
                }
            }
            for layerID in ["cache", "tool", "other", "free"] {
                try render(
                    BranchesRootView(store: store, liveWork: monitor, initialFront: .storage, initialSelectedLayerID: layerID),
                    size: CGSize(width: 900, height: 560), appearance: appearance,
                    name: "branches-paperweight-storage-minimum-\(layerID)-\(appearance.rawValue)"
                )
            }
            try render(BranchesRootView(store: store), size: CGSize(width: 900, height: 560),
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
                BranchesRootView(store: clearedStore, liveWork: monitor),
                size: CGSize(width: 900, height: 560), appearance: appearance,
                name: "branches-paperweight-cleared-minimum-\(appearance.rawValue)"
            )
            try render(
                BranchesRootView(store: clearingStore, liveWork: monitor),
                size: CGSize(width: 900, height: 560), appearance: appearance,
                name: "branches-paperweight-clearing-minimum-\(appearance.rawValue)"
            )
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendersEveryPaperweightShip() async throws {
        guard #available(macOS 14.0, *) else { return }
        let tasks = sampleLiveWork(), processes = sampleProcesses(), disk = sampleDiskSpace
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }
        )
        await monitor.refresh()
        let now = Date()
        let board = BranchesBoard.make(snapshot: sampleBranchesSnapshot(now: now), now: now)
        let configurations = [
            PaperweightData.memory(summary: monitor.summary, running: board.running, physicalMemory: 24 * 1_024 * 1_024 * 1_024),
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
        let monitor = LiveWorkMonitor(
            currentTasks: { tasks }, runningApplications: { [.claude: ["/Applications/Claude.app"]] },
            locator: { RepositoryLocator(home: "/Users/me") }, scan: { _, _ in processes },
            readDiskSpace: { disk }
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
                        BranchesRootView(store: store, liveWork: monitor, initialFront: front),
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
