import SwiftUI

struct QuotaRow: View {
    let snapshot: QuotaSnapshot

    private var remaining: Double {
        min(max(snapshot.remainingPercent, 0), 100)
    }

    private var severity: QuotaSeverity {
        QuotaSeverity(remainingPercent: remaining)
    }

    private var displayTitle: String {
        let limitName = snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if limitName.localizedCaseInsensitiveCompare("Codex") == .orderedSame,
           snapshot.toolName.localizedCaseInsensitiveContains("chatgpt") {
            return "ChatGPT / Codex"
        }
        return snapshot.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let plan = snapshot.planType, !plan.isEmpty {
                            Text(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .layoutPriority(1)
                    if let sessionStatus = snapshot.sessionStatus, sessionStatus.phase.showsLight {
                        HStack(spacing: 5) {
                            InlineSessionStatusDot(phase: sessionStatus.phase)
                            Text(sessionStatus.phase.label)
                                .foregroundStyle(sessionStatus.phase.color)
                            Text("·")
                            Text(sessionStatus.updatedAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(remaining, format: .number.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(severity.color)
                    .shadow(color: severity.criticalGlowColor, radius: severity.criticalGlowRadius)
                Text("%")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Gauge(value: remaining, in: 0...100) {
                EmptyView()
            }
            .tint(severity.color)
            .shadow(color: severity.criticalGlowColor, radius: severity.criticalGlowRadius)
            .accessibilityLabel("\(displayTitle) remaining")
            .accessibilityValue("\(Int(remaining.rounded())) percent remaining")

            HStack(spacing: 12) {
                Label(snapshot.primaryWindow.typeTag, systemImage: "timer")
                Spacer()
                if let resetAt = snapshot.resetAt {
                    Text("Window resets \(resetAt, format: .dateTime.month(.abbreviated).day())")
                } else {
                    Text("Window reset unavailable")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let availableResetCount = snapshot.availableResetCount,
               availableResetCount > 0 {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(.green)
                    Text("Full reset")

                    Spacer()

                    Text("\(availableResetCount) available")
                        .foregroundStyle(.green)
                    if let expiresAt = snapshot.resetCreditExpiresAt {
                        Text("· Expires \(expiresAt, format: .dateTime.month(.abbreviated).day())")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            if let secondary = snapshot.secondaryWindow {
                Divider()
                SecondaryLimitRow(window: secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct InlineSessionStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: CodexSessionPhase
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(phase.color.opacity(0.24))
                .frame(width: 10, height: 10)
                .scaleEffect(isExpanded ? 1.55 : 0.9)
                .blur(radius: isExpanded ? 2.5 : 1)

            Circle()
                .fill(phase.color)
                .frame(width: 7, height: 7)
                .shadow(color: phase.color.opacity(0.75), radius: isExpanded ? 4 : 2)
        }
        .frame(width: 14, height: 14)
        .onAppear { updateAnimation() }
        .onChange(of: phase) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
        .accessibilityHidden(true)
    }

    private func updateAnimation() {
        isExpanded = false
        guard phase.showsLight, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            isExpanded = true
        }
    }
}

private struct SecondaryLimitRow: View {
    let window: QuotaWindowSnapshot

    private var severity: QuotaSeverity {
        QuotaSeverity(remainingPercent: window.remainingPercent)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.typeTag)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(severity.color)
            Text(window.remainingPercent / 100, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(severity.color)
                .shadow(color: severity.criticalGlowColor, radius: severity.criticalGlowRadius)
            if let resetAt = window.resetAt {
                Text("· Resets \(resetAt, format: .dateTime.month(.abbreviated).day())")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.typeTag), \(Int(window.remainingPercent.rounded())) percent remaining")
    }
}

private extension QuotaSeverity {
    var color: Color {
        switch self {
        case .abundant: .blue
        case .healthy: .green
        case .caution: .orange
        case .low: .red
        case .critical: Color(red: 0.72, green: 0, blue: 0.04)
        }
    }

    var criticalGlowColor: Color {
        self == .critical ? .red.opacity(0.55) : .clear
    }

    var criticalGlowRadius: CGFloat {
        self == .critical ? 8 : 0
    }
}

private extension CodexSessionPhase {
    var color: Color {
        switch self {
        case .idle: .clear
        case .thinking: Color(red: 0.18, green: 0.52, blue: 1.00)
        case .complete: Color(red: 0.18, green: 0.88, blue: 0.45)
        case .needsInput: Color(red: 1.00, green: 0.68, blue: 0.12)
        case .error: Color(red: 1.00, green: 0.20, blue: 0.47)
        }
    }

}
