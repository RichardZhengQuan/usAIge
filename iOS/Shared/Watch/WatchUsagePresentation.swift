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
/// Modern review screenshots. Launch with `-usaigeDemo YES` to show them, or
/// `-usaigeDemo edge` for the edge cases a layout has to survive.
public enum UsageDemoData {
    public static let launchArgumentKey = "usaigeDemo"

    public enum Scenario: String, Sendable {
        /// The Mac review screenshots' four tools.
        case standard
        /// Two Macs (one stale), long names, a limit with no window length
        /// or reset time, 0% and 100%, and active sessions.
        case edge
        /// The edge cases from the fifth tool on, for screens that can't scroll
        /// in a screenshot run.
        case edgeTail = "edge-tail"
    }

    public static var scenario: Scenario? {
        guard let value = UserDefaults.standard.string(forKey: launchArgumentKey)?.lowercased() else { return nil }
        if let scenario = Scenario(rawValue: value), scenario != .standard { return scenario }
        return ["yes", "true", "1"].contains(value) ? .standard : nil
    }

    public static var isEnabled: Bool { scenario != nil }

    public static func envelope(now: Date = Date()) -> WatchUsageSnapshotEnvelope {
        envelope(scenario ?? .standard, now: now)
    }

    public static func envelope(_ scenario: Scenario, now: Date = Date()) -> WatchUsageSnapshotEnvelope {
        if scenario == .edgeTail {
            let edge = envelope(.edge, now: now)
            return WatchUsageSnapshotEnvelope(generatedAt: now, tools: Array(edge.tools.dropFirst(4)))
        }
        func window(_ remaining: Double, minutes: Int?, resetsIn seconds: TimeInterval?) -> WatchQuotaWindowSnapshot {
            WatchQuotaWindowSnapshot(
                remainingPercent: remaining,
                resetAt: seconds.map { now.addingTimeInterval($0) },
                windowDurationSeconds: minutes.map { $0 * 60 }
            )
        }
        func window(_ remaining: Double, _ lengthHours: Int, resetsIn seconds: TimeInterval) -> WatchQuotaWindowSnapshot {
            window(remaining, minutes: lengthHours * 60, resetsIn: seconds)
        }
        let soon: TimeInterval = 100 * 60          // 2H
        let week: TimeInterval = 2 * 86_400 + 72_000 // 3D
        let tenHours: TimeInterval = 9 * 3_600 + 1_800
        func tool(
            _ id: String, _ name: String, _ symbol: String, _ limits: [WatchQuotaSnapshot],
            mac: (id: String, name: String) = ("demo-mac", "MacBook Pro"),
            updatedAgo: TimeInterval = 60,
            session: WatchSessionPhase? = nil
        ) -> WatchToolQuotaSnapshot {
            let updated = now.addingTimeInterval(-updatedAgo)
            return WatchToolQuotaSnapshot(
                id: "\(mac.id):\(id)",
                displayName: name,
                sourceID: mac.id,
                sourceName: mac.name,
                serverUpdatedAt: updated,
                sourceUpdatedAt: updated,
                receivedAt: now,
                limits: limits,
                sessionStatus: session.map { WatchSessionStatus(phase: $0, updatedAt: now.addingTimeInterval(-90)) },
                symbolName: symbol
            )
        }
        let chatGPT = tool("chatgpt", "ChatGPT", "sparkle", [
            WatchQuotaSnapshot(id: "codex", displayName: "Codex",
                               primary: window(62, 5, resetsIn: soon),
                               secondary: window(81, 168, resetsIn: week), planType: "Pro"),
            WatchQuotaSnapshot(id: "codex-spark", displayName: "GPT-5.3-Codex-Spark",
                               primary: window(90, 5, resetsIn: soon), planType: "Pro"),
        ], session: scenario == .edge ? .thinking : nil)
        let claude = tool("claude", "Claude", "asterisk", [
            WatchQuotaSnapshot(id: "all-models", displayName: "All models",
                               primary: window(45, 5, resetsIn: soon),
                               secondary: window(70, 168, resetsIn: week), planType: "Max"),
            WatchQuotaSnapshot(id: "fable", displayName: "Fable",
                               primary: window(scenario == .edge ? 0 : 18, 168, resetsIn: week), planType: "Max"),
        ], session: scenario == .edge ? .needsInput : nil)
        let cursor = tool("cursor", "Cursor", "cube", [
            WatchQuotaSnapshot(id: "cursor-models", displayName: "Cursor models",
                               primary: window(33, 31 * 24, resetsIn: 12 * 86_400 + 3_600)),
        ] + (scenario == .edge ? [
            WatchQuotaSnapshot(id: "auto", displayName: "Auto",
                               primary: window(12, 31 * 24, resetsIn: 12 * 86_400 + 3_600)),
        ] : []))
        let grok = tool("grok", "Grok Build", "g.circle", [
            WatchQuotaSnapshot(id: "weekly-credits", displayName: "Weekly credits",
                               primary: window(100, 168, resetsIn: week)),
        ])
        guard scenario == .edge else {
            return WatchUsageSnapshotEnvelope(generatedAt: now, tools: [chatGPT, claude, cursor, grok])
        }
        let studio = (id: "demo-studio", name: "Mac Studio")
        return WatchUsageSnapshotEnvelope(generatedAt: now, tools: [
            chatGPT, claude, cursor,
            tool("gemini", "Gemini", "sparkles", [
                WatchQuotaSnapshot(id: "gemini-pro", displayName: "Gemini Pro",
                                   primary: window(74, 24, resetsIn: tenHours)),
                WatchQuotaSnapshot(id: "gemini-flash", displayName: "Gemini Flash",
                                   primary: window(91, 24, resetsIn: tenHours)),
            ]),
            grok,
            tool("jetbrains", "JetBrains AI", "j.square", [
                WatchQuotaSnapshot(id: "quota", displayName: "Monthly quota",
                                   primary: window(5, minutes: nil, resetsIn: nil)),
            ]),
            tool("command-code", "Command Code Enterprise Workspace", "terminal", [
                WatchQuotaSnapshot(id: "org-requests", displayName: "Requests per rolling window for the whole organization",
                                   primary: window(58, minutes: 90, resetsIn: 25 * 60)),
            ]),
            tool("claude", "Claude", "asterisk", [
                WatchQuotaSnapshot(id: "all-models", displayName: "All models",
                                   primary: window(22, 5, resetsIn: soon),
                                   secondary: window(40, 168, resetsIn: week), planType: "Pro"),
            ], mac: studio, updatedAgo: 2 * 3_600, session: .error),
            tool("windsurf", "Windsurf", "wind", [
                WatchQuotaSnapshot(id: "windsurf", displayName: "Prompts",
                                   primary: window(8, 24, resetsIn: tenHours),
                                   secondary: window(51, 168, resetsIn: week)),
            ], mac: studio, updatedAgo: 2 * 3_600),
        ])
    }
}
#endif
