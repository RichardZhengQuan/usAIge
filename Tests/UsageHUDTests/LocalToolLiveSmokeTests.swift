import Foundation
import Testing
@testable import UsageHUD

// Opt-in smoke tests against the real sign-ins on this Mac. They print the
// normalized limits and never print tokens. Run with:
//   USAIGE_LIVE_LOCAL_TOOLS=1 swift test --filter LiveLocalTools
// Claude is included only with USAIGE_LIVE_CLAUDE=1 because reading its
// Keychain item shows a macOS access prompt the first time.

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
    @Test func cursorLive() async throws {
        let result = try await CursorUsageProvider().refresh()
        print("[live] Cursor:\n\(describe(result))")
    }

    @Test func grokLive() async throws {
        let result = try await GrokUsageProvider().refresh()
        print("[live] Grok Build:\n\(describe(result))")
    }

    @Test(.enabled(if: liveClaudeEnabled)) func claudeLive() async throws {
        let result = try await ClaudeUsageProvider().refresh()
        print("[live] Claude:\n\(describe(result))")
    }
}
