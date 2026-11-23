import Foundation

/// Time until a usage window resets, written the way the Mac's Modern look
/// writes it: "2H", "3D", "45M", or "NOW".
public enum ResetCountdown {
    /// The compact countdown. A window's length (such as 7D) is not its time
    /// until reset, so a missing reset date reads as a dash.
    public static func compact(until resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "—" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "NOW" }
        if seconds >= 86_400 {
            return "\(Int(ceil(seconds / 86_400)))D"
        }
        if seconds >= 3_600 {
            return "\(Int(ceil(seconds / 3_600)))H"
        }
        return "\(max(1, Int(ceil(seconds / 60))))M"
    }

    /// "resets 2H", or "resets NOW"; nil when the reset time is unknown.
    public static func phrase(until resetAt: Date?, now: Date = Date()) -> String? {
        guard resetAt != nil else { return nil }
        return "resets \(compact(until: resetAt, now: now))"
    }

    public static func accessibilityLabel(until resetAt: Date?, now: Date = Date()) -> String {
        guard resetAt != nil else { return "Reset time unavailable" }
        let value = compact(until: resetAt, now: now)
        return value == "NOW" ? "Resetting now" : "Resets in \(value)"
    }
}
