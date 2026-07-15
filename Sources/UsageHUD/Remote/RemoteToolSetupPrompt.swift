import AppKit

enum RemoteToolSetupPrompt {
    static let text = """
    Help me connect an AI service to usAIge on this Mac.

    1. Ask which AI service and plan I use. Codex already connects to usAIge automatically, so I only need this for another service.
    2. Use only official documentation, APIs, or documented local commands. Confirm that my account exposes machine-readable current remaining limits and reset times, not only historical usage.
    3. If supported, help me identify or create a read-only local or team adapter. Its GET endpoint must return this shape:

       {"limits":[{"id":"requests","name":"Requests","primary":{"usedPercent":42,"windowDurationMinutes":300,"resetsAt":1893456000}}]}

       `remainingPercent` may replace `usedPercent`; `resetsAt` is Unix time in seconds. Use HTTP only for localhost and HTTPS everywhere else.
    4. Test the endpoint, then give me the display name, Usage URL, optional website URL, and one URL-encoded `usaige://connect?...` link without secrets. If authentication is required, explain how to create a revocable adapter-specific token and tell me to enter it in usAIge's Advanced setup; do not print the token in chat.
    5. Never guess or estimate limits, scrape a web UI, read browser cookies, reuse consumer OAuth or session credentials, or use undocumented private APIs.
    6. If my account cannot expose this data, say it cannot be connected safely. Personal Claude subscriptions currently have no official API for reading remaining limits.
    """

    @MainActor
    static func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
