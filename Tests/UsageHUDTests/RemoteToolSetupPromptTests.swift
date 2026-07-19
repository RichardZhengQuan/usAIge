import AppKit
import Foundation
import Testing
@testable import UsageHUD

@Test func setupPromptUsesOneTimePairingAndNormalizedUploads() {
    let prompt = RemoteToolSetupPrompt.text(pairingCode: "ABCD2345")

    #expect(prompt.contains("ABCD2345"))
    #expect(prompt.contains(RemoteToolSetupPrompt.claimURL))
    #expect(prompt.contains("uploadURL"))
    #expect(prompt.contains("writeToken"))
    #expect(prompt.contains("remainingPercent"))
    #expect(prompt.contains("Never guess, estimate"))
    #expect(prompt.contains("cannot be connected safely"))
    #expect(!prompt.contains("usaige://connect"))
}

@MainActor
@Test func setupPromptCopiesItsExactText() {
    let pasteboard = NSPasteboard(name: .init("usaige.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    #expect(RemoteToolSetupPrompt.copy(pairingCode: "ABCD2345", to: pasteboard))
    #expect(pasteboard.string(forType: .string) == RemoteToolSetupPrompt.text(pairingCode: "ABCD2345"))
}
