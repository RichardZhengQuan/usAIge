import SwiftUI

enum QuotaSeverity: Equatable, Sendable {
    case normal
    case warning
    case critical

    init(remainingPercent: Double) {
        if remainingPercent <= 10 {
            self = .critical
        } else if remainingPercent <= 20 {
            self = .warning
        } else {
            self = .normal
        }
    }

    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct QuotaRowView: View {
    let snapshot: QuotaSnapshot
    @State private var now = Date()

    private var severity: QuotaSeverity {
        QuotaSeverity(remainingPercent: snapshot.remainingPercent)
    }

    private var resetText: String {
        guard let resetAt = snapshot.resetAt else { return "Reset time unavailable" }
        return "Resets in \(UsageStore.countdown(secondsRemaining: resetAt.timeIntervalSince(now)))"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: snapshot.remainingPercent / 100)
                    .stroke(severity.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(snapshot.remainingPercent.rounded()))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Text("\(Int(snapshot.remainingPercent.rounded()))% remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.displayName), \(Int(snapshot.remainingPercent.rounded())) percent remaining, \(resetText)")
        .task(id: snapshot.resetAt) {
            await updateCountdown()
        }
    }

    private func updateCountdown() async {
        guard let resetAt = snapshot.resetAt else { return }
        while !Task.isCancelled {
            now = Date()
            let remaining = resetAt.timeIntervalSince(now)
            guard remaining > 0 else { return }
            let delay: TimeInterval
            if remaining > 3_600 {
                delay = 60
            } else if remaining > 60 {
                delay = min(60, max(1, remaining - 60))
            } else {
                delay = 1
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
