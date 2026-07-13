import Testing
@testable import UsageHUD

@Test func catalogProvidesDistinctLaunchTargetsForCommonAITools() {
    #expect(AIToolDescriptor.all.map(\.id) == [.chatGPT, .claude, .gemini, .cursor])
    #expect(AIToolDescriptor.descriptor(for: .chatGPT).bundleIdentifiers.contains("com.openai.codex"))
    #expect(AIToolDescriptor.descriptor(for: .cursor).bundleIdentifiers.contains("com.todesktop.230313mzl4w4u92"))
    #expect(AIToolDescriptor.all.allSatisfy { $0.webURL != nil })
}
