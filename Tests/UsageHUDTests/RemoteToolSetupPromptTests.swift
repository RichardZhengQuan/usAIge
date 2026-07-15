import AppKit
import Foundation
import Testing
@testable import UsageHUD

@Test func setupPromptRequestsASafeConnectionLink() {
    let prompt = RemoteToolSetupPrompt.text

    #expect(prompt.contains("usaige://connect"))
    #expect(prompt.contains("display name"))
    #expect(prompt.contains("Usage URL"))
    #expect(prompt.contains("website URL"))
    #expect(prompt.contains("revocable adapter-specific token"))
    #expect(prompt.contains("\"limits\""))
    #expect(prompt.contains("\"primary\""))
    #expect(prompt.contains("usedPercent"))
    #expect(prompt.contains("resetsAt"))
    #expect(prompt.contains("Never guess or estimate limits"))
    #expect(prompt.contains("say it cannot be connected safely"))
    #expect(!prompt.contains("token=secret"))
}

@MainActor
@Test func setupPromptCopiesItsExactText() {
    let pasteboard = NSPasteboard(name: .init("usaige.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    #expect(RemoteToolSetupPrompt.copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == RemoteToolSetupPrompt.text)
}
