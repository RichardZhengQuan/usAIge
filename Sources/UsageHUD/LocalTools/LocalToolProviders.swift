import Foundation

/// Builds the built-in local tool providers with the polling floors each
/// provider tolerates. Anthropic throttles its usage endpoint aggressively,
/// so Claude is polled least often; Cursor and Grok Build are polled on a
/// two-minute floor. JetBrains AI and Windsurf only read files their own apps
/// saved, so they are also read on every automatic tick. Tools read through
/// their own CLI are polled less often, since each reading starts a process. A manual refresh may
/// go sooner, but never faster than the manual floor, so hovering the rail
/// cannot hammer a provider.
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
            ThrottledUsageProvider(
                base: JetBrainsAIUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 60,
                manualMinimumInterval: 5
            ),
            ThrottledUsageProvider(
                base: WindsurfUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 60,
                manualMinimumInterval: 5
            ),
            // Antigravity answers on this Mac while it runs, so it is cheap.
            ThrottledUsageProvider(
                base: AntigravityUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 60,
                manualMinimumInterval: 10
            ),
            // Reads nothing until the user turns it on in AI Tools.
            ThrottledUsageProvider(
                base: CopilotUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 180,
                manualMinimumInterval: 20
            ),
            // `kiro-cli acp` starts the Kiro engine for each reading.
            ThrottledUsageProvider(
                base: KiroUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 300,
                manualMinimumInterval: 60
            ),
            ThrottledUsageProvider(
                base: AmpUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 180,
                manualMinimumInterval: 30
            ),
            ThrottledUsageProvider(
                base: MuseUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 180,
                manualMinimumInterval: 30
            ),
            // `omp usage` caches its upstream reports for five minutes.
            ThrottledUsageProvider(
                base: OhMyPiUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 300,
                manualMinimumInterval: 60
            ),
            ThrottledUsageProvider(
                base: CommandCodeUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 120,
                manualMinimumInterval: 20
            ),
            ThrottledUsageProvider(
                base: ClineUsageProvider(statusRegistry: statusRegistry),
                minimumInterval: 120,
                manualMinimumInterval: 20
            ),
            ThrottledUsageProvider(
                base: OpenCodeGoUsageProvider(statusRegistry: statusRegistry),
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
    /// Explains what turning on this reader permits and why it defaults to off.
    var optInHint: String? = nil

    /// Tools AI Tools always lists: the original four, and tools that need
    /// the user to turn them on, since that switch is how they are found.
    static let alwaysListed: Set<AIToolID> = Set<AIToolID>([.chatGPT, .claude, .cursor, .grok])
        .union(LocalToolOptIn.optInToolIDs)

    /// The supported tools in the user's rail order, leaving out the newer
    /// tools that aren't on this Mac (or haven't been checked yet) so the
    /// list fits without scrolling.
    static func listed(
        order: [AIToolID],
        status: (AIToolID) -> LocalToolStatus
    ) -> [LocalToolGuidance] {
        let ranked = order.compactMap { id in supported.first { $0.id == id } }
        let all = ranked + supported.filter { guidance in !ranked.contains { $0.id == guidance.id } }
        return all.filter { guidance in
            if alwaysListed.contains(guidance.id) { return true }
            switch status(guidance.id) {
            case .unknown, .notInstalled: return false
            default: return true
            }
        }
    }

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
        LocalToolGuidance(
            id: .jetBrainsAI,
            source: "AI quota saved by your JetBrains IDE",
            signInHint: "Sign in to JetBrains AI in a JetBrains IDE and use AI Assistant once.",
            expiredHint: "Sign in to JetBrains AI in your JetBrains IDE again."
        ),
        LocalToolGuidance(
            id: .windsurf,
            source: "Plan saved by Devin Desktop or Windsurf",
            signInHint: "Open Devin Desktop or Windsurf and sign in.",
            expiredHint: "Open Devin Desktop or Windsurf and sign in again."
        ),
        LocalToolGuidance(
            id: .antigravity,
            source: "Antigravity running on this Mac",
            signInHint: "Open Antigravity, or run `agy`, and sign in. usAIge reads its limits while it runs.",
            expiredHint: "Sign in to Antigravity again.",
            optInHint: "Off. Google supports only ACP for other apps. This reads Antigravity's private local server and could flag your Google account."
        ),
        LocalToolGuidance(
            id: .copilot,
            source: "GitHub CLI sign-in on this Mac",
            signInHint: "Run `gh auth login` in Terminal.",
            expiredHint: "Run `gh auth login` in Terminal to sign in again.",
            optInHint: "Off. Turn on to read Copilot limits with the GitHub CLI sign-in on this Mac."
        ),
        LocalToolGuidance(
            id: .kiro,
            source: "Kiro CLI on this Mac",
            signInHint: "Install the Kiro CLI and run `kiro-cli` to sign in.",
            expiredHint: "Run `kiro-cli` in Terminal to sign in again."
        ),
        LocalToolGuidance(
            id: .amp,
            source: "Amp CLI on this Mac",
            signInHint: "Install the Amp CLI and sign in with `amp login`.",
            expiredHint: "Run `amp login` in Terminal to sign in again."
        ),
        LocalToolGuidance(
            id: .muse,
            source: "Muse Code CLI on this Mac",
            signInHint: "Install Muse Code and run `muse login`.",
            expiredHint: "Run `muse login` in Terminal to sign in again."
        ),
        LocalToolGuidance(
            id: .ohMyPi,
            source: "Oh My Pi on this Mac",
            signInHint: "Install Oh My Pi and sign in to your accounts in `omp`.",
            expiredHint: "Run `omp login` in Terminal to sign in again.",
            optInHint: "Off. Turn on to run `omp usage`. For Google accounts, omp checks Google's internal API, which could flag them, so usAIge hides those."
        ),
        LocalToolGuidance(
            id: .commandCode,
            source: "Command Code sign-in on this Mac",
            signInHint: "Install the `cmd` CLI and run `cmd login`.",
            expiredHint: "Run `cmd login` in Terminal to sign in again."
        ),
        LocalToolGuidance(
            id: .cline,
            source: "Cline CLI sign-in on this Mac",
            signInHint: "Install the Cline CLI and run `cline auth`.",
            expiredHint: "Run `cline auth` in Terminal to sign in again."
        ),
        LocalToolGuidance(
            id: .openCodeGo,
            source: "OpenCode Zen sign-in on this Mac",
            signInHint: "Run `opencode auth login` and pick OpenCode Zen.",
            expiredHint: "Run `opencode auth login` and pick OpenCode Zen again."
        ),
    ]

    struct Presentation: Equatable {
        let text: String
        let isProblem: Bool
    }

    func presentation(for status: LocalToolStatus) -> Presentation {
        switch status {
        case .unknown: Presentation(text: "Checking…", isProblem: false)
        case .optInRequired:
            Presentation(text: optInHint ?? "Off. Turn on to read limits from \(source).", isProblem: false)
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
