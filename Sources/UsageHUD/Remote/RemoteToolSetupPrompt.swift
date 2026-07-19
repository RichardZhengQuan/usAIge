import AppKit

enum RemoteToolSetupPrompt {
    static let claimURL = "https://usaige-macos.richardqz.chatgpt.site/api/v1/tool-pairings/claim"

    static func text(pairingCode: String) -> String {
        """
        Connect this AI tool to usAIge using one-time pairing code \(pairingCode).

        1. Use only official documentation, APIs, or documented local commands. Confirm that this account exposes machine-readable current remaining limits and reset times. Never guess, estimate, scrape a web UI, read browser cookies, or use undocumented private APIs.
        2. Claim the code once by POSTing JSON to \(claimURL):

           {"code":"\(pairingCode)","toolName":"My AI Tool","symbolName":"cpu","websiteURL":"https://example.com"}

        3. The response contains an uploadURL and a revocable writeToken. Store the token in the system credential store; do not print it in chat, logs, source code, or shell history.
        4. Upload normalized limits to uploadURL with `Authorization: Bearer <writeToken>` and this JSON shape:

           {"schemaVersion":1,"generatedAt":"2026-07-19T12:00:00Z","limits":[{"id":"weekly","name":"Weekly","planType":"Pro","primary":{"remainingPercent":42,"resetAt":"2026-07-20T12:00:00Z","windowDurationMinutes":10080},"secondary":null}]}

        5. Send only display metadata, normalized remaining percentages, reset times, and window durations. Keep provider credentials and raw account data on this machine. Refresh the upload when the official source changes.
        6. If this account cannot expose the data through a supported official method, do not claim the code; say it cannot be connected safely.
        """
    }

    @MainActor
    static func copy(
        pairingCode: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text(pairingCode: pairingCode), forType: .string)
    }
}
