import Foundation
import SwiftUI

extension QuotaSnapshot {
    /// Every free reset this limit's tool reports. A tool that gives only a
    /// count and its earliest expiry reads as one entry.
    var availableResets: [ResetCredit] {
        if !resetCredits.isEmpty { return resetCredits.filter { $0.remaining > 0 } }
        guard let count = availableResetCount, count > 0 else { return [] }
        return [ResetCredit(id: "\(id)-credits", title: count == 1 ? "Reset credit" : "Reset credits",
                            expiresAt: resetCreditExpiresAt, detail: nil, count: count)]
    }

    /// Attaches a tool's free resets, keeping the count and earliest expiry
    /// that notifications and paired devices read.
    mutating func attach(_ credits: [ResetCredit]) {
        let left = credits.filter { $0.remaining > 0 }
        guard !left.isEmpty else { return }
        resetCredits = left
        availableResetCount = left.filter(\.usableNow).reduce(0) { $0 + $1.remaining }
        resetCreditExpiresAt = left.compactMap(\.expiresAt).min()
    }
}

extension QuotaSnapshot {
    /// The same limit with its free resets left out.
    var withoutResetCredits: QuotaSnapshot {
        var copy = self
        copy.resetCredits = []
        copy.availableResetCount = nil
        copy.resetCreditExpiresAt = nil
        return copy
    }
}

extension Array where Element == QuotaSnapshot {
    /// A tool's free resets that haven't expired, from whichever of its
    /// limits carries them, soonest to expire first.
    func availableResets(now: Date = Date()) -> [ResetCredit] {
        (first { !$0.availableResets.isEmpty }?.availableResets ?? [])
            .filter { ($0.expiresAt ?? .distantFuture) > now }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}

enum ResetCreditText {
    /// "Expires Dec 11, 6:00 AM", with the year when it isn't this one.
    static func expiry(_ date: Date?, now: Date = Date(),
                       locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMdjmm" : "yMMMdjmm")
        return "Expires \(formatter.string(from: date))"
    }

    /// Whether it can be used now, and since when it was given.
    static func status(_ credit: ResetCredit, now: Date = Date()) -> String {
        let given = credit.grantedAt.map { date -> String in
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(
                Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMMd" : "yMMMd")
            return "Granted \(formatter.string(from: date))"
        }
        return [credit.usableNow ? "Ready to use" : "Not available yet", given].compactMap { $0 }.joined(separator: " · ")
    }

    /// "1 free reset", "3 free resets".
    static func count(_ credits: [ResetCredit]) -> String? {
        let total = credits.reduce(0) { $0 + $1.remaining }
        guard total > 0 else { return nil }
        return total == 1 ? "1 free reset" : "\(total) free resets"
    }
}

/// A tool's free resets: each one's name, what it refills and when it
/// expires. usAIge shows them; using one happens in the tool.
@available(macOS 14.0, *)
struct ModernResetCredits: View {
    let credits: [ResetCredit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free resets")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(credits) { credit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(credit.usableNow ? Color(nsColor: .systemGreen) : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(credit.title).font(.callout.weight(.semibold)).lineLimit(1)
                            if credit.remaining > 1 {
                                Text("×\(credit.remaining)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            if let expiry = ResetCreditText.expiry(credit.expiresAt) {
                                Text(expiry).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                            }
                        }
                        if let detail = credit.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(ResetCreditText.status(credit))
                            .font(.caption)
                            .foregroundStyle(credit.usableNow ? Color.secondary : Color.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
