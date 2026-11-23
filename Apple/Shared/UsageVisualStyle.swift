import Foundation
import SwiftUI

extension WatchToolQuotaSnapshot {
    var staleAfter: Date {
        sourceUpdatedAt.addingTimeInterval(30 * 60)
    }

    func isStale(at date: Date) -> Bool {
        date > staleAfter
    }

    func visibleSessionPhase(isStale: Bool) -> WatchSessionPhase? {
        guard !isStale, let phase = sessionStatus?.phase, phase.showsLight else { return nil }
        return phase
    }
}

struct WatchToolTitle: View {
    let name: String
    let phase: WatchSessionPhase?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .lineLimit(1)

            if let phase {
                Circle()
                    .fill(color(for: phase))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
    }

    private func color(for phase: WatchSessionPhase) -> Color {
        switch phase {
        case .thinking: .blue
        case .complete: .green
        case .needsInput: .orange
        case .error: .red
        case .idle, .unknown: .clear
        }
    }
}

extension WatchQuotaWindowSnapshot {
    func accessibilitySummary(now: Date) -> String {
        let percent = ModernUsageColor.percent(remainingPercent).dropLast()
        let reset = ResetCountdown.accessibilityLabel(until: resetAt, now: now)
        return "\(percent) percent left, \(reset)"
    }
}
