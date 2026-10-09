import AppKit
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
    window.orderBack(nil)
    for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    if size == nil {
        hosting.setFrameSize(hosting.fittingSize)
        window.setContentSize(hosting.fittingSize)
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
    return hosting.bounds.size
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
        let scenes = [
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
        let claudeStatuses: [(String, LocalToolStatus, [QuotaSnapshot])] = [
            ("connected", .connected, mixedSnapshots),
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
