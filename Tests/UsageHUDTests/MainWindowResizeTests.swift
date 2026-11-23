import AppKit
import Testing
@testable import UsageHUD

/// The main window keeps the size the user drags it to, in both styles.
@MainActor
@Test(arguments: [InterfaceStyle.modern, .classic])
func mainWindowKeepsTheWidthItIsResizedTo(style: InterfaceStyle) throws {
    guard #available(macOS 14.0, *) else { return }
    let suite = "usaige.resize.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let previous = UserDefaults.standard.string(forKey: InterfaceStyle.defaultsKey)
    UserDefaults.standard.set(style.rawValue, forKey: InterfaceStyle.defaultsKey)
    defer {
        if let previous { UserDefaults.standard.set(previous, forKey: InterfaceStyle.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: InterfaceStyle.defaultsKey) }
    }
    let store = BranchesStore(defaults: defaults, initialSnapshot: BranchesSnapshot())
    let controller = BranchesWindowController(store: store) {}
    let window = try #require(controller.window)
    window.animationBehavior = .none
    window.setFrame(NSRect(x: 100, y: 100, width: 1180, height: 780), display: false)
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    for width in [1500.0, 1050.0] {
        window.setFrame(NSRect(x: 100, y: 100, width: width, height: 780), display: true)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        #expect(abs(window.frame.width - width) < 1, "\(style) window snapped to \(window.frame.width) from \(width)")
    }
}
