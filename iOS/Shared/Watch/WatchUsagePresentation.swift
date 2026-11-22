import Foundation

public extension WatchQuotaSnapshot {
    /// How close this limit is to running out: what's left of its lower window.
    var tightness: Double {
        min(primary.remainingPercent, secondary?.remainingPercent ?? 100)
    }

    /// The window closest to running out; the first window when they tie.
    var tightestWindow: WatchQuotaWindowSnapshot {
        guard let secondary, secondary.remainingPercent < primary.remainingPercent else { return primary }
        return secondary
    }
}

public extension WatchQuotaWindowSnapshot {
    /// The window's length, such as "5H" or "7D".
    var lengthTag: String? {
        guard let seconds = windowDurationSeconds, seconds > 0 else { return nil }
        if seconds.isMultiple(of: 86_400) { return "\(seconds / 86_400)D" }
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)H" }
        return "\(max(1, seconds / 60))M"
    }
}

public extension WatchToolQuotaSnapshot {
    /// The limit closest to running out; the first one when they tie.
    var tightestLimit: WatchQuotaSnapshot? {
        limits.min { $0.tightness < $1.tightness }
    }

    /// How many limits the tool has besides its tightest.
    var otherLimitCount: Int { max(0, limits.count - 1) }
}

#if DEBUG
/// Sample readings for Simulator screenshots and previews, matching the Mac's
/// Modern review screenshots. Launch with `-usaigeDemo YES` to show them.
public enum UsageDemoData {
    public static let launchArgumentKey = "usaigeDemo"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: launchArgumentKey)
    }

    public static func envelope(now: Date = Date()) -> WatchUsageSnapshotEnvelope {
        func window(_ remaining: Double, _ lengthHours: Int, resetsIn seconds: TimeInterval) -> WatchQuotaWindowSnapshot {
            WatchQuotaWindowSnapshot(
                remainingPercent: remaining,
                resetAt: now.addingTimeInterval(seconds),
                windowDurationSeconds: lengthHours * 3_600
            )
        }
        let soon: TimeInterval = 100 * 60          // 2H
        let week: TimeInterval = 2 * 86_400 + 72_000 // 3D
        func tool(_ id: String, _ name: String, _ symbol: String, _ limits: [WatchQuotaSnapshot]) -> WatchToolQuotaSnapshot {
            WatchToolQuotaSnapshot(
                id: "demo-mac:\(id)",
                displayName: name,
                sourceID: "demo-mac",
                sourceName: "MacBook Pro",
                serverUpdatedAt: now.addingTimeInterval(-60),
                sourceUpdatedAt: now.addingTimeInterval(-60),
                receivedAt: now,
                limits: limits,
                symbolName: symbol
            )
        }
        return WatchUsageSnapshotEnvelope(generatedAt: now, tools: [
            tool("chatgpt", "ChatGPT", "sparkle", [
                WatchQuotaSnapshot(id: "codex", displayName: "Codex",
                                   primary: window(62, 5, resetsIn: soon),
                                   secondary: window(81, 168, resetsIn: week), planType: "Pro"),
                WatchQuotaSnapshot(id: "codex-spark", displayName: "GPT-5.3-Codex-Spark",
                                   primary: window(90, 5, resetsIn: soon), planType: "Pro"),
            ]),
            tool("claude", "Claude", "asterisk", [
                WatchQuotaSnapshot(id: "all-models", displayName: "All models",
                                   primary: window(45, 5, resetsIn: soon),
                                   secondary: window(70, 168, resetsIn: week), planType: "Max"),
                WatchQuotaSnapshot(id: "fable", displayName: "Fable",
                                   primary: window(18, 168, resetsIn: week), planType: "Max"),
            ]),
            tool("cursor", "Cursor", "cube", [
                WatchQuotaSnapshot(id: "cursor-models", displayName: "Cursor models",
                                   primary: window(33, 31 * 24, resetsIn: 12 * 86_400 + 3_600)),
            ]),
            tool("grok", "Grok Build", "g.circle", [
                WatchQuotaSnapshot(id: "weekly-credits", displayName: "Weekly credits",
                                   primary: window(100, 168, resetsIn: week)),
            ]),
        ])
    }
}
#endif
