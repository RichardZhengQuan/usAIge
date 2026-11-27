import Foundation
import Testing
@testable import UsageHUD

// Opt-in smoke tests against local usage sources on this Mac. They print the
// normalized limits and never print tokens. Run with:
//   USAIGE_LIVE_LOCAL_TOOLS=1 swift test --filter LiveLocalTools
// This run includes the Antigravity and Oh My Pi readers even when their
// AI Tools switches are off. See the Google account warning in the README.
// Claude is included only with USAIGE_LIVE_CLAUDE=1; its default collector
// reads existing desktop usage files without credentials or network requests.

private let liveEnabled = ProcessInfo.processInfo.environment["USAIGE_LIVE_LOCAL_TOOLS"] == "1"
private let liveClaudeEnabled = ProcessInfo.processInfo.environment["USAIGE_LIVE_CLAUDE"] == "1"

private func describe(_ result: AccountUsageResult) -> String {
    switch result {
    case .signedOut:
        return "signed out"
    case let .authenticated(snapshots):
        if snapshots.isEmpty { return "authenticated, no limits reported" }
        return snapshots.map { snapshot in
            var text = "\(snapshot.id) [\(snapshot.displayName)] \(Int(snapshot.remainingPercent.rounded()))% left, \(snapshot.typeTag)"
            if let resetAt = snapshot.resetAt { text += ", resets \(resetAt)" }
            if let secondary = snapshot.secondaryWindow {
                text += " | secondary \(Int(secondary.remainingPercent.rounded()))% left, \(secondary.typeTag)"
                if let resetAt = secondary.resetAt { text += ", resets \(resetAt)" }
            }
            if let plan = snapshot.planType { text += " (plan \(plan))" }
            return text
        }.joined(separator: "\n")
    }
}

@Suite("LiveLocalTools", .enabled(if: liveEnabled))
struct LiveLocalToolsSmokeTests {
    @Test func codexLive() async throws {
        let executable = try #require(CodexExecutableResolver.resolve())
        print("[live] Codex executable: \(executable.path)")
        let provider = CodexUsageProvider(rpc: JSONRPCConnection(transport: ProcessLineTransport(executableURL: executable)))
        let result = try await provider.refresh()
        await provider.stop()
        print("[live] Codex:\n\(describe(result))")
    }

    @Test func cursorLive() async throws {
        let result = try await CursorUsageProvider().refresh()
        print("[live] Cursor:\n\(describe(result))")
    }

    @Test func grokLive() async throws {
        let result = try await GrokUsageProvider().refresh()
        print("[live] Grok Build:\n\(describe(result))")
    }

    @Test func jetBrainsAILive() async throws {
        let registry = await LocalToolStatusRegistry()
        let result = try await JetBrainsAIUsageProvider(statusRegistry: registry).refresh()
        print("[live] JetBrains AI (\(await registry.status(for: .jetBrainsAI))):\n\(describe(result))")
    }

    @Test func windsurfLive() async throws {
        let registry = await LocalToolStatusRegistry()
        let result = try await WindsurfUsageProvider(statusRegistry: registry).refresh()
        print("[live] Windsurf (\(await registry.status(for: .windsurf))):\n\(describe(result))")
    }

    @Test func moreLocalToolsLive() async throws {
        let registry = await LocalToolStatusRegistry()
        let providers: [(AIToolID, any CodexUsageProviding)] = [
            (.antigravity, AntigravityUsageProvider(isOptedIn: { true }, statusRegistry: registry)),
            (.kiro, KiroUsageProvider(statusRegistry: registry)),
            (.amp, AmpUsageProvider(statusRegistry: registry)),
            (.muse, MuseUsageProvider(statusRegistry: registry)),
            (.ohMyPi, OhMyPiUsageProvider(isOptedIn: { true }, statusRegistry: registry)),
            (.commandCode, CommandCodeUsageProvider(statusRegistry: registry)),
            (.cline, ClineUsageProvider(statusRegistry: registry)),
            (.openCodeGo, OpenCodeGoUsageProvider(statusRegistry: registry)),
        ]
        for (id, provider) in providers {
            let text: String
            do { text = describe(try await provider.refresh()) } catch { text = "error \(error)" }
            print("[live] \(id.rawValue) (\(await registry.status(for: id))):\n\(text)")
        }
    }

    /// Reads the GitHub CLI's sign-in, so it runs only with USAIGE_LIVE_COPILOT=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_LIVE_COPILOT"] == "1"))
    func copilotLive() async throws {
        let registry = await LocalToolStatusRegistry()
        let result = try await CopilotUsageProvider(isOptedIn: { true }, statusRegistry: registry).refresh()
        print("[live] Copilot (\(await registry.status(for: .copilot))):\n\(describe(result))")
    }

    @Test(.enabled(if: liveClaudeEnabled)) func claudeLive() async throws {
        let result = try await ClaudeUsageProvider().refresh()
        print("[live] Claude:\n\(describe(result))")
    }
}
