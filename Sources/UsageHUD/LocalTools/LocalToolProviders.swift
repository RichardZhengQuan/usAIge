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
                base: ClaudeUsageProvider(
                    credentials: NoClaudeCredentialSource(),
                    statusRegistry: statusRegistry
                ),
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
            source: "Claude Code on this Mac",
            signInHint: "No Claude session found on this Mac. usAIge checks automatically.",
            expiredHint: "Waiting for Claude usage. usAIge retries automatically."
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
                text: "Claude Code uses an API key. usAIge checks the Claude app session automatically for plan limits.",
                isProblem: false
            )
        case .connected: Presentation(text: "Connected · \(source)", isProblem: false)
        case .connectedThroughClaudeApp:
            Presentation(text: "Connected · Claude app on this Mac. Reset times unavailable.", isProblem: false)
        case .connectedThroughClaudeAppCache:
            Presentation(text: "Connected · Claude app cache on this Mac", isProblem: false)
        case .connectedThroughClaudeBridge:
            Presentation(text: "Connected · Refreshing automatically through Claude", isProblem: false)
        case .waitingForClaudeUsage:
            Presentation(text: "Waiting for Claude usage. usAIge checks automatically.", isProblem: false)
        case .notInstalled: Presentation(text: "Not installed.", isProblem: false)
        case .signedOut:
            Presentation(
                text: id == .claude ? signInHint : "Not connected. \(signInHint)",
                isProblem: false
            )
        case .credentialExpired: Presentation(text: expiredHint, isProblem: true)
        case .apiKeyHelperSignInExpired:
            Presentation(
                text: "Claude Code uses an API key. usAIge checks the Claude app session automatically for plan limits.",
                isProblem: true
            )
        case .missingScope:
            Presentation(
                text: id == .claude ? "Waiting for Claude usage. usAIge retries automatically." : "This sign-in cannot read limits. Sign out and sign in again.",
                isProblem: true
            )
        case .rateLimited:
            Presentation(text: "The provider is rate limiting usage checks. usAIge will retry later.", isProblem: true)
        case .keychainAccessDenied:
            Presentation(text: "macOS blocked reading local Claude credentials. usAIge retries automatically.", isProblem: true)
        case let .failed(message): Presentation(text: message, isProblem: true)
        }
    }
}
