import Foundation

enum UsageState: Equatable, Sendable {
    /// Shown when no supported tool is signed in on this Mac.
    static let connectGuidance = "Sign in to Codex, Claude Code, Cursor, or Grok Build"

    case connecting
    case signedOut
    case unavailable(message: String)
    case empty
    case current([QuotaSnapshot])
    case stale([QuotaSnapshot], since: Date)
}
