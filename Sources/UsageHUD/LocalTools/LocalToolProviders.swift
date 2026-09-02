import Foundation

/// Builds the built-in local tool providers with the polling floors each
/// provider tolerates. Anthropic throttles its usage endpoint aggressively,
/// so Claude is polled least often; Cursor and Grok Build are polled on a
/// two-minute floor. A manual refresh may go sooner, but never faster than
/// the manual floor, so hovering the rail cannot hammer a provider.
enum LocalToolProviders {
    static func make(
        statusRegistry: LocalToolStatusRegistry,
        readsClaudeSignIn: @escaping @Sendable () async -> Bool
    ) -> [any CodexUsageProviding] {
        [
            ThrottledUsageProvider(
                base: ClaudeUsageProvider(statusRegistry: statusRegistry, isEnabled: readsClaudeSignIn),
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
            source: "Local Codex app-server",
            signInHint: "Open the ChatGPT or Codex app and sign in.",
            expiredHint: "Open the ChatGPT or Codex app and sign in again."
        ),
        LocalToolGuidance(
            id: .claude,
            source: "Claude Code sign-in on this Mac",
            signInHint: "Use Sign In, or run `claude auth login` in Terminal.",
            expiredHint: "Sign-in expired. Use Sign In, or run `claude` in Terminal to refresh it."
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
            expiredHint: "Sign-in expired. Run `grok` in Terminal so Grok Build refreshes it."
        ),
    ]

    struct Presentation: Equatable {
        let text: String
        let isProblem: Bool
    }

    func presentation(for status: LocalToolStatus) -> Presentation {
        switch status {
        case .unknown: Presentation(text: "Checking…", isProblem: false)
        case .disabled:
            Presentation(text: "Off. Turn on to read the Claude Code sign-in; macOS asks once per build.", isProblem: false)
        case .apiKeyOnly:
            Presentation(
                text: "No Claude plan sign-in yet (Claude Code uses an API key helper here). Sign in to show plan limits.",
                isProblem: false
            )
        case .connected: Presentation(text: "Connected · \(source)", isProblem: false)
        case .notInstalled: Presentation(text: "Not installed.", isProblem: false)
        case .signedOut: Presentation(text: "Not connected. \(signInHint)", isProblem: false)
        case .credentialExpired: Presentation(text: expiredHint, isProblem: true)
        case .missingScope:
            Presentation(text: "This sign-in cannot read limits. Sign out and sign in again.", isProblem: true)
        case .rateLimited:
            Presentation(text: "The provider is rate limiting usage checks. usAIge will retry later.", isProblem: true)
        case .keychainAccessDenied:
            Presentation(text: "Allow usAIge to read the Claude Code sign-in in Keychain, then press Detect.", isProblem: true)
        case let .failed(message): Presentation(text: message, isProblem: true)
        }
    }
}
