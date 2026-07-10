import Testing
@testable import UsageHUD

@Test func enabledPrivacyTriggerHidesAndDisabledTriggerDoesNot() {
    let sharing = VisibilitySignals(
        frontmostIsFullScreen: false,
        isPresenting: false,
        isScreenSharing: true,
        isKnownGame: false,
        isVideoFullScreen: false
    )

    #expect(VisibilityPolicy.evaluate(sharing, triggers: .allEnabled) == .hidden(.screenSharing))
    var triggers = HideTriggers.allEnabled
    triggers.screenSharing = false
    #expect(VisibilityPolicy.evaluate(sharing, triggers: triggers) == .visible)
}

@Test func privacyFirstPrecedenceSelectsMostSensitiveReason() {
    let signals = VisibilitySignals(
        frontmostIsFullScreen: true,
        isPresenting: true,
        isScreenSharing: true,
        isKnownGame: true,
        isVideoFullScreen: true
    )

    #expect(VisibilityPolicy.evaluate(signals, triggers: .allEnabled) == .hidden(.screenSharing))
}

@Test func generalFullScreenActsAsFallback() {
    let signals = VisibilitySignals(
        frontmostIsFullScreen: true,
        isPresenting: false,
        isScreenSharing: false,
        isKnownGame: false,
        isVideoFullScreen: false
    )

    #expect(VisibilityPolicy.evaluate(signals, triggers: .allEnabled) == .hidden(.fullScreenApp))
    var triggers = HideTriggers.allEnabled
    triggers.fullScreenApps = false
    #expect(VisibilityPolicy.evaluate(signals, triggers: triggers) == .visible)
}
