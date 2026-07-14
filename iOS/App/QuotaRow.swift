import SwiftUI

struct QuotaRow: View {
    let snapshot: QuotaSnapshot

    private var remaining: Double {
        min(max(snapshot.remainingPercent, 0), 100)
    }

    private var tint: Color {
        if remaining <= 10 { return .red }
        if remaining <= 20 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.displayName)
                        .font(.headline)
                    if let plan = snapshot.planType, !plan.isEmpty {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(remaining, format: .number.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                Text("%")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Gauge(value: remaining, in: 0...100) {
                Text("Remaining")
            }
            .tint(tint)
            .accessibilityValue("\(Int(remaining.rounded())) percent remaining")

            HStack(spacing: 12) {
                Label(snapshot.primaryWindow.typeTag, systemImage: "timer")
                Spacer()
                if let resetAt = snapshot.resetAt {
                    Text("Resets \(resetAt, style: .relative)")
                } else {
                    Text("Reset time unavailable")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let secondary = snapshot.secondaryWindow {
                Divider()
                SecondaryLimitRow(window: secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct SecondaryLimitRow: View {
    let window: QuotaWindowSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(window.typeTag)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: window.remainingPercent, total: 100)
            Text(window.remainingPercent / 100, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
            if let resetAt = window.resetAt {
                Text("· \(resetAt, style: .relative)")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.typeTag), \(Int(window.remainingPercent.rounded())) percent remaining")
    }
}
