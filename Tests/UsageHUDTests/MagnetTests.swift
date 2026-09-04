import AppKit
import Testing
@testable import UsageHUD

private let visible = CGRect(x: 0, y: 25, width: 1_440, height: 875)
private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
private let size = CGSize(width: 260, height: 220)

@Test func magnetSnapsOnlyDropsNearAnEdge() {
    #expect(MagnetGeometry.edge(toSnap: CGRect(x: 10, y: 100, width: 260, height: 220), in: visible) == .left)
    #expect(MagnetGeometry.edge(toSnap: CGRect(x: 1_160, y: 100, width: 260, height: 220), in: visible) == .right)
    #expect(MagnetGeometry.edge(toSnap: CGRect(x: 600, y: 100, width: 260, height: 220), in: visible) == nil)
    #expect(MagnetGeometry.edge(toSnap: CGRect(x: 33, y: 100, width: 260, height: 220), in: visible) == nil)
    // Dragged past the edge still counts as that edge.
    #expect(MagnetGeometry.edge(toSnap: CGRect(x: -40, y: 100, width: 260, height: 220), in: visible) == .left)
}

@Test func magnetDockedFrameIsFlushAndInsideTheVisibleFrame() {
    let left = MagnetGeometry.dockedFrame(size: size, edge: .left, y: 300, visibleFrame: visible)
    #expect(left == CGRect(x: 0, y: 300, width: 260, height: 220))

    let right = MagnetGeometry.dockedFrame(size: size, edge: .right, y: 5_000, visibleFrame: visible)
    #expect(right.maxX == visible.maxX)
    #expect(right.maxY == visible.maxY)

    let low = MagnetGeometry.dockedFrame(size: size, edge: .right, y: -50, visibleFrame: visible)
    #expect(low.minY == visible.minY)
}

@Test func magnetHiddenFrameLeavesAPeekPastThePhysicalEdge() {
    let docked = MagnetGeometry.dockedFrame(size: size, edge: .left, y: 300, visibleFrame: visible)
    let hidden = MagnetGeometry.hiddenFrame(from: docked, edge: .left, screenFrame: screen)
    #expect(hidden.maxX == screen.minX + MagnetGeometry.hiddenPeek)
    #expect(hidden.minY == docked.minY)

    let dockedRight = MagnetGeometry.dockedFrame(size: size, edge: .right, y: 300, visibleFrame: visible)
    let hiddenRight = MagnetGeometry.hiddenFrame(from: dockedRight, edge: .right, screenFrame: screen)
    #expect(hiddenRight.minX == screen.maxX - MagnetGeometry.hiddenPeek)
}

@Test func magnetRevealsOnlyWhenThePointerPushesTheDockedEdge() {
    #expect(MagnetGeometry.pointerReveals(pointer: CGPoint(x: 0, y: 450), edge: .left, screenFrame: screen))
    #expect(MagnetGeometry.pointerReveals(pointer: CGPoint(x: 1_439, y: 450), edge: .right, screenFrame: screen))
    #expect(!MagnetGeometry.pointerReveals(pointer: CGPoint(x: 0, y: 450), edge: .right, screenFrame: screen))
    #expect(!MagnetGeometry.pointerReveals(pointer: CGPoint(x: 20, y: 450), edge: .left, screenFrame: screen))
    // A pointer on another display beside this edge is not on this edge.
    #expect(!MagnetGeometry.pointerReveals(pointer: CGPoint(x: 0, y: 1_200), edge: .left, screenFrame: screen))
}

@Test func magnetHidesOnlyOnceThePointerIsClearOfTheRail() {
    let frame = CGRect(x: 0, y: 300, width: 260, height: 220)
    #expect(!MagnetGeometry.pointerIsClear(of: frame, pointer: CGPoint(x: 100, y: 400)))
    #expect(!MagnetGeometry.pointerIsClear(of: frame, pointer: CGPoint(x: 270, y: 400)))
    #expect(MagnetGeometry.pointerIsClear(of: frame, pointer: CGPoint(x: 400, y: 400)))
}

@MainActor
@Test func magnetSettingsPersistTheDockedEdgeAndTheToggle() {
    let defaults = isolatedDefaults()
    var settings: HUDSettings? = HUDSettings(defaults: defaults)
    #expect(settings?.magnetEnabled == true)
    settings?.setPosition(CGPoint(x: 0, y: 300), edge: .left, for: "display-1")
    settings?.setPosition(CGPoint(x: 40, y: 60), for: "display-2")
    settings?.magnetEnabled = false
    settings = nil

    let restored = HUDSettings(defaults: defaults)
    #expect(restored.magnetEdge(for: "display-1") == .left)
    #expect(restored.position(for: "display-1") == CGPoint(x: 0, y: 300))
    #expect(restored.magnetEdge(for: "display-2") == nil)
    #expect(restored.magnetEnabled == false)
}

@MainActor
@Test func magnetControllerDocksHidesAndRevealsAroundThePointer() async throws {
    guard let mainScreen = NSScreen.main else { return }
    let pointer = TestPointer(location: CGPoint(x: 700, y: 400))
    let controller = MagnetController(isEnabled: true, pointerLocation: { pointer.location })
    let panel = NSPanel(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    controller.attach(to: panel)
    var recorded: [(MagnetEdge?, CGRect)] = []
    controller.onDockingChanged = { edge, frame, _ in recorded.append((edge, frame)) }

    controller.dock(to: .right, y: 300, on: mainScreen, animated: false)
    #expect(controller.isDocked)
    #expect(controller.isRevealed)
    #expect(panel.frame.maxX == mainScreen.visibleFrame.maxX)
    #expect(recorded.last?.0 == .right)

    // The pointer is away from the rail, so the scheduled hide fires. The
    // hide task shares the main actor with every other test, so wait for the
    // state instead of racing its timer.
    let deadline = Date().addingTimeInterval(MagnetController.hideDelay + 3)
    while controller.isRevealed, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(!controller.isRevealed)

    // Pushing the pointer against the docked edge brings it back.
    pointer.location = CGPoint(x: mainScreen.frame.maxX, y: mainScreen.frame.midY)
    controller.handlePointer(at: pointer.location)
    #expect(controller.isRevealed)

    // Turning Magnet off releases the rail where it was docked.
    controller.isEnabled = false
    #expect(!controller.isDocked)
    #expect(recorded.last?.0 == nil)
}

@MainActor
@Test func magnetRemembersTheDockedDisplayWhileHidden() throws {
    guard let mainScreen = NSScreen.main else { return }
    let controller = MagnetController(isEnabled: true, pointerLocation: { CGPoint(x: -10_000, y: -10_000) })
    let panel = NSPanel(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    controller.attach(to: panel)
    controller.dock(to: .right, y: 300, on: mainScreen, animated: false)
    #expect(MagnetController.displayID(of: mainScreen) != nil)
    #expect(controller.dockedScreen == mainScreen)

    // Slide it off screen and confirm the docked display is still the one
    // the reveal edge is measured against, not whatever the panel overlaps.
    controller.hide()
    #expect(!controller.isRevealed)
    #expect(controller.dockedScreen == mainScreen)
    controller.handlePointer(at: CGPoint(x: mainScreen.frame.maxX, y: mainScreen.frame.midY))
    #expect(controller.isRevealed)
    controller.undock()
    #expect(controller.dockedScreen == (panel.screen ?? NSScreen.main))
}

@MainActor
private final class TestPointer {
    var location: CGPoint
    init(location: CGPoint) { self.location = location }
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "usaige-magnet-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
