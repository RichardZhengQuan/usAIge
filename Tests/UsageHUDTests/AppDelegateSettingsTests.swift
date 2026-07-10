import AppKit
import Testing
@testable import UsageHUD

@MainActor
@Test func showSettingsCreatesAVisibleNativeWindow() {
    let delegate = AppDelegate()

    delegate.showSettings()

    #expect(delegate.settingsWindow?.isVisible == true)
    #expect(delegate.settingsWindow?.title == "usAIge Settings")
    #expect(delegate.settingsWindow?.styleMask.contains(.titled) == true)
    #expect(delegate.settingsWindow?.level == .floating)
    delegate.settingsWindow?.close()
}
