import AppKit
import Foundation
import SwiftUI
import Testing
@testable import UsageHUD

@Test func bundledProviderArtworkKeepsTheCircularAlpha() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let marks = repoRoot.appendingPathComponent("Sources/UsageHUD/Resources/ToolMarks")
    let environment = [BundledToolMark.environmentKey: marks.path]
    let tools: [AIToolID] = [
        .chatGPT, .claude, .cursor, .grok, .gemini, .jetBrainsAI, .windsurf, .copilot, .cline, .openCodeGo,
    ]
    var fileNames: Set<String> = []
    for id in tools {
        let fileName = try #require(BundledToolMark.fileName(for: id))
        #expect(fileNames.insert(fileName).inserted)
        let url = try #require(BundledToolMark.url(for: id, environment: environment))
        let image = try #require(NSImage(contentsOf: url))
        #expect(!image.isTemplate)
        let data = try Data(contentsOf: url)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 256 && bitmap.pixelsHigh == 256)
        #expect(bitmap.hasAlpha)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(bitmap.colorAt(x: 128, y: 128)?.alphaComponent == 1)
    }
    #expect(BundledToolMark.fileName(for: AIToolID(rawValue: "remote-tool")) == nil)
    #expect(BundledToolMark.url(for: .claude, environment: [:], bundle: Bundle(for: LocalToolTestAnchor.self)) == nil)
}

private final class LocalToolTestAnchor {}

/// Opt-in: renders every tool icon to PNG for a visual check.
///   USAIGE_RENDER_ICONS=/path/to/dir swift test --filter rendersToolGlyphs
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_ICONS"] != nil))
func rendersToolGlyphsToPNG() throws {
    guard #available(macOS 13.0, *) else { return }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["USAIGE_RENDER_ICONS"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for id in AIToolID.builtInIDs {
        for (variant, view) in [
            ("tile", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 64).padding(8).background(Color.white))),
            ("circle-light", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 64, circular: true).padding(8).background(Color.white))),
            ("circle-dark", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 64, circular: true).padding(8).background(Color.black).environment(\.colorScheme, .dark))),
            ("rail", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 32, circular: true).padding(4).background(Color.black))),
        ] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(id.rawValue)-\(variant).png"))
        }
    }
}

/// Opt-in: renders the AI Tools settings page at the real window size so the
/// layout can be checked without launching the app.
///   USAIGE_RENDER_SETTINGS=/path/to/dir swift test --filter rendersAIToolsSettingsPage
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_SETTINGS"] != nil))
func rendersAIToolsSettingsPage() throws {
    guard #available(macOS 14.0, *) else { return }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["USAIGE_RENDER_SETTINGS"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "usaige.render.settings.\(UUID().uuidString)")!
    let settings = HUDSettings(defaults: defaults)
    let registry = LocalToolStatusRegistry()
    registry.report(.apiKeyOnly, for: .claude)
    registry.report(.connected, for: .cursor)
    registry.report(.connected, for: .grok)
    let navigation = SettingsNavigation()
    navigation.route = [.aiTools]
    func snapshot(_ id: String, _ name: String, _ tool: AIToolID, remaining: Double, minutes: Int) -> QuotaSnapshot {
        var value = QuotaSnapshot(
            id: id, displayName: name, usedPercent: 100 - remaining, remainingPercent: remaining,
            resetAt: Date().addingTimeInterval(3600), windowDurationMinutes: minutes, planType: "pro",
            updatedAt: Date()
        )
        value.toolID = tool
        return value
    }
    let snapshots = [
        snapshot("codex", "Codex", .chatGPT, remaining: 62, minutes: 300),
        snapshot("codex_bengalfox", "GPT-5.3-Codex-Spark", .chatGPT, remaining: 90, minutes: 300),
        snapshot("cursor", "Cursor models", .cursor, remaining: 33, minutes: 44_640),
        snapshot("cursor_other", "Other models", .cursor, remaining: 0, minutes: 44_640),
        snapshot("grok", "Weekly credits", .grok, remaining: 100, minutes: 10_080),
    ]
    settings.registerBuckets(snapshots)
    let view = HUDSettingsView(
        settings: settings,
        snapshots: snapshots,
        launchAtLogin: inertLaunchAtLogin(),
        updateController: UpdateController(),
        relaySync: RelaySyncController(defaults: defaults),
        localToolStatus: registry,
        navigation: navigation,
        refreshUsage: {}
    )
    .frame(width: 520, height: 580)
    // Form and ScrollView are AppKit-backed, so draw through a real hosting
    // view in an offscreen window rather than ImageRenderer.
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 580)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.orderBack(nil)
    for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("ai-tools-page.png"))
}
