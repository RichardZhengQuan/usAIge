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

@MainActor
@Test func showSettingsRequestsTheSwiftUISettingsScene() {
    let delegate = AppDelegate()
    var openCount = 0
    delegate.settingsSceneOpener = { openCount += 1 }

    delegate.showSettings()

    #expect(openCount == 1)
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
