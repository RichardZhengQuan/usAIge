import Foundation

extension WatchQuotaWindowSnapshot {
    func accessibilitySummary(now: Date) -> String {
        let percent = ModernUsageColor.percent(remainingPercent).dropLast()
        let reset = ResetCountdown.accessibilityLabel(until: resetAt, now: now)
        return "\(percent) percent left, \(reset)"
    }
}
