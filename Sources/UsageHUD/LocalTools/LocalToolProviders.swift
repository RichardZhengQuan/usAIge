import Foundation

/// Builds the built-in local tool providers with the polling floors each
/// provider tolerates. Anthropic throttles its usage endpoint aggressively,
/// so Claude is polled least often; Cursor and Grok Build are polled on a
/// two-minute floor. A manual refresh may go sooner, but never faster than
/// the manual floor, so hovering the rail cannot hammer a provider.
enum LocalToolProviders {
    static func make(statusRegistry: LocalToolStatusRegistry) -> [any CodexUsageProviding] {
        [
            ThrottledUsageProvider(
                base: ClaudeUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 300,
                manualMinimumInterval: 60,
                rateLimitedInterval: 900
            ),
            ThrottledUsageProvider(
                base: CursorUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 120,
                manualMinimumInterval: 20
            ),
            ThrottledUsageProvider(
                base: GrokUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 120,
                manualMinimumInterval: 20
            ),
        ]
    }
}

/// Settings copy for each built-in local tool: where its limits come from
/// and what to do when it is not connected.
struct LocalToolGuidance: Identifiable, Sendable {
    let id: AIToolID
    let source: String
    let signInHint: String
    let expiredHint: String

    static let supported: [LocalToolGuidance] = [
        LocalToolGuidance(
            id: .chatGPT,
            source: "Codex sign-in on this Mac",
            signInHint: "Open the ChatGPT or Codex app and sign in.",
            expiredHint: "Open the ChatGPT or Codex app and sign in again."
        ),
        LocalToolGuidance(
            id: .claude,
            source: "Claude Code sign-in on this Mac",
            signInHint: "Open the Claude app, or use Sign In.",
            expiredHint: "Sign-in expired. Open the Claude app, or run `claude` in Terminal to refresh it."
        ),
        LocalToolGuidance(
            id: .cursor,
            source: "Cursor sign-in on this Mac",
            signInHint: "Open Cursor and sign in.",
            expiredHint: "Sign-in expired. Open Cursor and sign in again."
        ),
        LocalToolGuidance(
            id: .grok,
            source: "Grok Build sign-in on this Mac",
            signInHint: "Run `grok login` in Terminal.",
            expiredHint: "Sign-in expired. Run `grok login` in Terminal to sign in again."
        ),
    ]

    struct Presentation: Equatable {
        let text: String
        let isProblem: Bool
    }

    func presentation(for status: LocalToolStatus) -> Presentation {
        switch status {
        case .unknown: Presentation(text: "Checking…", isProblem: false)
        case .apiKeyOnly:
            Presentation(
                text: "Claude Code uses an API key here, which has no plan limits. Open the Claude app to show them, or sign in with your Claude plan.",
                isProblem: false
            )
        case .connected: Presentation(text: "Connected · \(source)", isProblem: false)
        case .connectedThroughClaudeApp:
            Presentation(text: "Connected · Claude app on this Mac. Reset times need a Claude Code sign-in.", isProblem: false)
        case .notInstalled: Presentation(text: "Not installed.", isProblem: false)
        case .signedOut: Presentation(text: "Not connected. \(signInHint)", isProblem: false)
        case .credentialExpired: Presentation(text: expiredHint, isProblem: true)
        case .apiKeyHelperSignInExpired:
            Presentation(
                text: "Your Claude plan sign-in expired and Claude Code runs on an API key here, so it won't renew it. Open the Claude app to show limits, or sign in again.",
                isProblem: true
            )
        case .missingScope:
            Presentation(text: "This sign-in cannot read limits. Sign out and sign in again.", isProblem: true)
        case .rateLimited:
            Presentation(text: "The provider is rate limiting usage checks. usAIge will retry later.", isProblem: true)
        case .keychainAccessDenied:
            Presentation(text: "macOS blocked reading the Claude Code sign-in from Keychain. Press Detect to try again.", isProblem: true)
        case let .failed(message): Presentation(text: message, isProblem: true)
        }
    }
}
