import AppKit
import CoreGraphics
import Foundation

struct VisibilitySignals: Equatable, Sendable {
    let frontmostIsFullScreen: Bool
    let isPresenting: Bool
    let isScreenSharing: Bool
    let isKnownGame: Bool
    let isVideoFullScreen: Bool
}

enum VisibilityReason: Equatable, Sendable {
    case screenSharing
    case presentation
    case game
    case fullScreenVideo
    case fullScreenApp
}

enum VisibilityDecision: Equatable, Sendable {
    case visible
    case hidden(VisibilityReason)
}

enum VisibilityPolicy {
    static func evaluate(_ signals: VisibilitySignals, triggers: HideTriggers) -> VisibilityDecision {
        if signals.isScreenSharing && triggers.screenSharing { return .hidden(.screenSharing) }
        if signals.isPresenting && triggers.presentations { return .hidden(.presentation) }
        if signals.isKnownGame && triggers.games { return .hidden(.game) }
        if signals.isVideoFullScreen && triggers.fullScreenVideo { return .hidden(.fullScreenVideo) }
        if signals.frontmostIsFullScreen && triggers.fullScreenApps { return .hidden(.fullScreenApp) }
        return .visible
    }
}

@MainActor
final class VisibilityController {
    private let settings: HUDSettings
    private var timer: Timer?
    private var currentDecision: VisibilityDecision = .visible
    var onDecisionChange: ((VisibilityDecision) -> Void)?

    init(settings: HUDSettings) {
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer?.tolerance = 0.25
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        publish(VisibilityPolicy.evaluate(Self.captureSignals(), triggers: settings.hideTriggers))
    }

    private func publish(_ decision: VisibilityDecision) {
        guard decision != currentDecision else { return }
        currentDecision = decision
        onDecisionChange?(decision)
    }

    private static func captureSignals() -> VisibilitySignals {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return VisibilitySignals(
                frontmostIsFullScreen: false,
                isPresenting: false,
                isScreenSharing: false,
                isKnownGame: false,
                isVideoFullScreen: false
            )
        }
        let bundleID = app.bundleIdentifier ?? ""
        let fullScreen = isFullScreen(processID: app.processIdentifier)
        let presentationIDs: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]
        let videoIDs: Set<String> = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc",
        ]
        let directSharingIDs: Set<String> = ["com.apple.ScreenSharing", "com.apple.RemoteDesktop"]
        let conferenceIDs: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "Cisco-Systems.Spark"]
        let gameIDs: Set<String> = [
            "com.valvesoftware.steam", "com.blizzard.battle.net", "com.epicgames.EpicGamesLauncher",
        ]
        return VisibilitySignals(
            frontmostIsFullScreen: fullScreen,
            isPresenting: fullScreen && presentationIDs.contains(bundleID),
            isScreenSharing: directSharingIDs.contains(bundleID) || (fullScreen && conferenceIDs.contains(bundleID)),
            isKnownGame: fullScreen && gameIDs.contains(bundleID),
            isVideoFullScreen: fullScreen && videoIDs.contains(bundleID)
        )
    }

    private static func isFullScreen(processID: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screenSizes = NSScreen.screens.map(\.frame.size)
        return info.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            return screenSizes.contains { size in
                abs(size.width - width) <= 2 && abs(size.height - height) <= 2
            }
        }
    }
}
