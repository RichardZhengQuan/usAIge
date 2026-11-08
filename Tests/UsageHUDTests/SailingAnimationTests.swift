import AppKit
import Testing
@testable import UsageHUD

/// Opt-in runtime verification of the real native animation clock.
/// USAIGE_VERIFY_SAILING_CLOCK=1 swift test --filter SailingAnimationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_VERIFY_SAILING_CLOCK"] == "1"), .serialized)
@MainActor
struct SailingAnimationTests {
    @Test func visibleSailingAdvancesAndInactiveHiddenOrReducedSailingStops() throws {
        guard #available(macOS 14.0, *) else { return }
        _ = NSApplication.shared
        let frame = NSRect(x: (NSScreen.main?.visibleFrame.minX ?? 0) + 30,
                           y: (NSScreen.main?.visibleFrame.minY ?? 0) + 30,
                           width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.level = .floating
        let view = UsageAtmosphereView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        defer {
            view.stop()
            window.orderOut(nil)
            window.close()
        }

        func configure(active: Bool, reduced: Bool = false) {
            view.configure(active: active, compact: false, weather: .rain, ship: .galleon,
                           showsShip: true, dark: false, reduced: reduced)
        }

        configure(active: true)
        window.orderFrontRegardless()
        pump(until: { window.isVisible && window.occlusionState.contains(.visible) }, timeout: 1)
        try #require(window.isVisible && window.occlusionState.contains(.visible),
                     "Sailing fixture could not become visible within 1s: visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), applicationHidden=\(NSApp.isHidden)")
        try #require(!NSApp.isHidden, "Sailing fixture is visible but the test application is hidden")
        configure(active: true)
        try #require(view.isAnimating, "Visible active sailing did not start its native clock")
        let start = view.animationTime
        pump(for: 0.15)
        #expect(view.animationTime > start, "Visible rain and cruising ship never advanced")

        configure(active: false)
        try #require(!view.isAnimating, "Inactive sailing retained its native timer")
        let paused = view.animationTime
        pump(for: 0.15)
        #expect(view.animationTime == paused, "Inactive sailing kept advancing")

        configure(active: true)
        try #require(view.isAnimating, "Sailing did not resume after becoming active")
        window.orderOut(nil)
        pump(until: { !view.isAnimating }, timeout: 0.25)
        try #require(!view.isAnimating, "Ordered-out sailing retained its native timer")
        let hidden = view.animationTime
        pump(for: 0.15)
        #expect(view.animationTime == hidden, "Hidden sailing kept advancing")

        // Show the fixture again so reduced motion is checked independently
        // of the hidden-window guard that stopped the preceding clock.
        configure(active: true, reduced: true)
        window.orderFrontRegardless()
        pump(until: { window.isVisible && window.occlusionState.contains(.visible) }, timeout: 1)
        try #require(window.isVisible && window.occlusionState.contains(.visible),
                     "Reduced-motion fixture could not become visible within 1s")
        configure(active: true, reduced: true)
        #expect(!view.isAnimating, "Reduced motion started a native animation timer")
        let reduced = view.animationTime
        pump(for: 0.15)
        #expect(view.animationTime == reduced, "Reduced-motion sailing kept advancing")
    }

    private func pump(for duration: TimeInterval) {
        pump(until: { false }, timeout: duration)
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
