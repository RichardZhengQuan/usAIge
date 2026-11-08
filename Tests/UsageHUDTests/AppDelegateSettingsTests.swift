import AppKit
import Carbon
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
@Test func showSettingsUsesTheMainSettingsPageWhenAvailable() {
    let delegate = AppDelegate()
    var pageCount = 0
    var sceneCount = 0
    delegate.settingsPageOpener = { pageCount += 1 }
    delegate.settingsSceneOpener = { sceneCount += 1 }
    delegate.settingsNavigation.route = [.aiTools, .remoteToolPairing]

    delegate.showSettings()

    if #available(macOS 14.0, *) {
        #expect(pageCount == 1)
        #expect(sceneCount == 0)
    } else {
        #expect(pageCount == 0)
        #expect(sceneCount == 1)
    }
    #expect(delegate.settingsNavigation.route.isEmpty)
}

@MainActor
@Test func reopeningFromDockRequestsTheMainWindow() {
    let delegate = AppDelegate()
    let appDelegate: NSApplicationDelegate = delegate
    var openCount = 0
    var settingsOpenCount = 0
    delegate.mainWindowOpener = { openCount += 1 }
    delegate.settingsSceneOpener = { settingsOpenCount += 1 }

    let handled = appDelegate.applicationShouldHandleReopen?(
        NSApplication.shared,
        hasVisibleWindows: false
    )

    #expect(handled == true)
    #expect(openCount == 1)
    #expect(settingsOpenCount == 0)
}

@MainActor
@Test func normalLaunchOpensMainWindowAndBackgroundLaunchDoesNot() {
    #expect(AppDelegate.shouldShowMainWindow(arguments: [], launchEvent: nil))
    #expect(!AppDelegate.shouldShowMainWindow(arguments: ["--background"], launchEvent: nil))
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    #expect(!AppDelegate.shouldShowMainWindow(arguments: [], launchEvent: event))
    #expect(AppDelegate.shouldShowMainWindow(arguments: ["--show-main"], launchEvent: event))
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsServiceItem)), forKeyword: AEKeyword(keyAEPropData))
    #expect(!AppDelegate.shouldShowMainWindow(arguments: [], launchEvent: event))
}

@MainActor
@Test func mainWindowCommandsFocusSectionsWithoutLeavingOverview() {
    guard #available(macOS 14.0, *) else { return }
    let presentation = BranchesPaperweightPresentation()
    #expect(presentation.destination == .overview)
    presentation.show(.memory)
    presentation.navigate(to: .cleanup)
    #expect(presentation.destination == .overview)
    #expect(presentation.focusRequest?.section == .resources)
    #expect(presentation.selectedSection == .resources)
    #expect(presentation.request?.front == .storage)
    presentation.show(.memory)
    #expect(presentation.destination == .overview)
    #expect(presentation.request?.front == .memory)
    #expect(presentation.selectedSection == .resources)
    presentation.navigate(to: .worktrees)
    #expect(presentation.destination == .overview)
    #expect(presentation.focusRequest?.section == .branches)
    let firstBranchFocus = presentation.focusRequest?.id
    presentation.navigate(to: .worktrees)
    #expect(presentation.focusRequest?.id != firstBranchFocus)
    #expect(presentation.request?.front == .memory)
    presentation.navigate(to: .resources)
    #expect(presentation.destination == .overview)
    #expect(presentation.focusRequest?.section == .resources)
    #expect(presentation.request?.front == .memory)
    presentation.navigate(to: .settings)
    #expect(presentation.destination == .overview)
    #expect(presentation.focusRequest?.section == .settings)
    #expect(presentation.selectedSection == .settings)
    presentation.focus(.overview)
    #expect(presentation.selectedSection == .overview)
    #expect(presentation.focusRequest?.section == .overview)
    let firstOverviewFocus = presentation.focusRequest?.id
    presentation.focus(.overview)
    #expect(presentation.focusRequest?.id != firstOverviewFocus)
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

@MainActor
@Test func openingSettingsNeverBringsBackTheBranchesWindow() {
    let branches = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    branches.identifier = AppWindowIdentifiers.branches
    #expect(!SettingsScenePresenter.isSettingsWindow(branches))
    #expect(SettingsScenePresenter.settingsWindow(in: [branches]) == nil)
}

@MainActor
@Test func branchesWindowControllerUsesTheIdentifierSettingsLooksFor() async throws {
    guard #available(macOS 14.0, *) else { return }
    // Git runs off the main thread, which timing-sensitive tests need free.
    let fixture = try await Task.detached { try GitFixture() }.value
    let store = BranchesStore(scanner: fixture.scanner())
    let controller = BranchesWindowController(store: store, onClose: {})
    #expect(controller.window?.identifier == AppWindowIdentifiers.branches)
    #expect(controller.window?.isReleasedWhenClosed == false)
    #expect(controller.window?.contentView != nil)
}

/// An unused feature must cost nothing: once the window closes, its store and
/// everything the scan read have to go, even mid-scan.
@MainActor
@Test func closingTheBranchesWindowLetsItsStateGo() async throws {
    guard #available(macOS 14.0, *) else { return }
    // Git runs off the main thread, which timing-sensitive tests need free.
    let fixture = try await Task.detached {
        let fixture = try GitFixture()
        try fixture.squashMerged("topic", pullRequest: nil)
        return fixture
    }.value
    weak var releasedStore: BranchesStore?
    weak var releasedController: BranchesWindowController?
    var closeCount = 0
    do {
        let defaults = try #require(UserDefaults(suiteName: "usaige.branches.test.\(UUID().uuidString)"))
        let store = BranchesStore(defaults: defaults, scanner: fixture.scanner())
        var controller: BranchesWindowController? = BranchesWindowController(store: store) { closeCount += 1 }
        releasedStore = store
        releasedController = controller
        store.windowOpened()
        controller?.window?.close()
        controller = nil
    }
    #expect(closeCount == 1)
    let deadline = Date().addingTimeInterval(30)
    while releasedStore != nil || releasedController != nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(releasedStore == nil)
    #expect(releasedController == nil)
}


/// Closing the window must not abandon an already authorized cleanup or lose
/// its result. Reopening restores the same store and navigation request.
@MainActor
@Test func closingDuringCleanupKeepsItsResultForReopening() async throws {
    guard #available(macOS 14.0, *) else { return }
    let fixture = try await Task.detached {
        let fixture = try GitFixture()
        try fixture.squashMerged("topic", pullRequest: nil)
        return fixture
    }.value
    let scanner = fixture.scanner()
    let snapshot = await fixture.scan(with: scanner)
    let row = try #require(snapshot.row(branch: "topic"))
    let store = BranchesStore(scanner: scanner, initialSnapshot: snapshot)
    var closeCount = 0
    let controller = BranchesWindowController(store: store) { closeCount += 1 }
    controller.presentation.navigate(to: .cleanup)
    store.startDelete([row])
    #expect(store.isDeleting)
    controller.window?.close()
    #expect(closeCount == 0)
    #expect(controller.window?.contentView == nil)
    let deadline = Date().addingTimeInterval(30)
    while store.isDeleting, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(!store.isDeleting)
    let result = try #require(store.resultMessage)
    #expect(result.deletedCount == 1)
    controller.present()
    #expect(controller.window?.contentView != nil)
    #expect(controller.presentation.destination == .overview)
    #expect(controller.presentation.focusRequest?.section == .resources)
    #expect(controller.presentation.request?.front == .storage)
    #expect(store.resultMessage?.id == result.id)
    controller.window?.close()
    #expect(closeCount == 0)
    controller.present()
    #expect(store.resultMessage?.id == result.id)
    store.resultMessage = nil
    controller.window?.close()
    #expect(closeCount == 1)
}
