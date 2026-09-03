import AppKit
import Foundation
import Testing
@testable import UsageHUD

@Test func applicationBundleUsesRegularDockPresentation() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL = projectRoot
        .appendingPathComponent("Sources/UsageHUD/Resources/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    #expect(plist["LSUIElement"] == nil)
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon.icns")
    #expect(
        FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/UsageHUD/Resources/AppIcon.icns")
                .path
        )
    )
}

@Test func macOSAppIconIncludesTransparentLegacyDockMask() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let iconURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/UsageHUD/Resources/AppIcon.png")
    let image = try #require(NSImage(contentsOf: iconURL))
    var proposedRect = NSRect(origin: .zero, size: image.size)
    let cgImage = try #require(
        image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    )
    let dataProvider = try #require(cgImage.dataProvider)
    let pixelData = try #require(dataProvider.data)
    let bytes = CFDataGetBytePtr(pixelData)
    let alphaOffset = cgImage.alphaInfo == .first || cgImage.alphaInfo == .premultipliedFirst
        ? 0
        : 3

    #expect(cgImage.alphaInfo != .none)
    #expect(cgImage.alphaInfo != .noneSkipFirst)
    #expect(cgImage.alphaInfo != .noneSkipLast)
    #expect(bytes?[alphaOffset] == 0)
}

@MainActor
@Test func showSettingsRequestsTheSwiftUISettingsScene() {
    let delegate = AppDelegate()
    var openCount = 0
    delegate.settingsSceneOpener = { openCount += 1 }
    delegate.settingsNavigation.route = [.aiTools, .remoteToolPairing]

    delegate.showSettings()

    #expect(openCount == 1)
    #expect(delegate.settingsNavigation.route.isEmpty)
}

@MainActor
@Test func reopeningFromDockRequestsTheSwiftUISettingsScene() {
    let delegate = AppDelegate()
    let appDelegate: NSApplicationDelegate = delegate
    var openCount = 0
    delegate.settingsSceneOpener = { openCount += 1 }

    let handled = appDelegate.applicationShouldHandleReopen?(
        NSApplication.shared,
        hasVisibleWindows: false
    )

    #expect(handled == true)
    #expect(openCount == 1)
}

@MainActor
@Test func openingSettingsNeverBringsBackTheWhatsNewWindow() {
    let whatsNew = WhatsNewWindowController(updateController: UpdateController()).window!
    let settings = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    settings.title = "usAIge Settings"
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 84, height: 120),
        styleMask: [.titled, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )

    #expect(!SettingsScenePresenter.isSettingsWindow(whatsNew))
    #expect(!SettingsScenePresenter.isSettingsWindow(panel))
    #expect(SettingsScenePresenter.isSettingsWindow(settings))
    // What's New listed first, as it is once it has been shown, must lose.
    #expect(SettingsScenePresenter.settingsWindow(in: [whatsNew, panel, settings]) === settings)
    #expect(SettingsScenePresenter.settingsWindow(in: [whatsNew, panel]) == nil)

    let untitledSettings = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    #expect(SettingsScenePresenter.settingsWindow(in: [whatsNew, untitledSettings]) === untitledSettings)
}
