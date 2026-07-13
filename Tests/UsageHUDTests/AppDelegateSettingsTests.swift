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
@Test func showSettingsCreatesAVisibleNativeWindow() {
    let delegate = AppDelegate()

    delegate.showSettings()

    #expect(delegate.settingsWindow?.isVisible == true)
    #expect(delegate.settingsWindow?.title == "usAIge Settings")
    #expect(delegate.settingsWindow?.styleMask.contains(.titled) == true)
    #expect(delegate.settingsWindow?.level == .floating)
    #expect(delegate.settingsWindow?.hidesOnDeactivate == false)
    #expect(delegate.settingsWindow?.collectionBehavior.contains(.moveToActiveSpace) == true)
    #expect(delegate.settingsWindow?.collectionBehavior.contains(.canJoinAllSpaces) == false)
    delegate.settingsWindow?.close()
}

@MainActor
@Test func reopeningFromDockShowsSettings() {
    let delegate = AppDelegate()
    let appDelegate: NSApplicationDelegate = delegate

    let handled = appDelegate.applicationShouldHandleReopen?(
        NSApplication.shared,
        hasVisibleWindows: false
    )

    #expect(handled == true)
    #expect(delegate.settingsWindow?.isVisible == true)
    delegate.settingsWindow?.close()
}
