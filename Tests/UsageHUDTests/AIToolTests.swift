import Foundation
import Testing
@testable import UsageHUD

@Test func catalogProvidesDistinctLaunchTargetsForCommonAITools() {
    #expect(AIToolDescriptor.all.map(\.id) == [.chatGPT, .claude, .gemini, .cursor])
    #expect(AIToolDescriptor.descriptor(for: .chatGPT).bundleIdentifiers.contains("com.openai.codex"))
    #expect(AIToolDescriptor.descriptor(for: .cursor).bundleIdentifiers.contains("com.todesktop.230313mzl4w4u92"))
    #expect(AIToolDescriptor.all.allSatisfy { $0.webURL != nil })
}

@MainActor
@Test func buildsCanonicalCodexTaskDeepLink() {
    #expect(
        AIToolLauncher.codexTaskURL(id: "019f1234-test")?.absoluteString
            == "codex://threads/019f1234-test"
    )
    #expect(AIToolLauncher.codexTaskURL(id: "") == nil)
}

@MainActor
@Test func opensStandaloneCodexOrFallsBackToTheCodexWebsite() {
    let installedApp = URL(fileURLWithPath: "/Applications/Codex.app")

    #expect(AIToolLauncher.codexBundleIdentifier == "com.openai.codex")
    #expect(AIToolLauncher.codexLaunchURL(applicationURL: installedApp) == installedApp)
    #expect(
        AIToolLauncher.codexLaunchURL(applicationURL: nil).absoluteString
            == "https://chatgpt.com/codex/"
    )
}
