import AppKit
import Combine
import SwiftUI

enum QuotaSeverity: Equatable, Sendable {
    case abundant
    case healthy
    case caution
    case low
    case critical

    init(remainingPercent: Double) {
        if remainingPercent <= 10 {
            self = .critical
        } else if remainingPercent <= 20 {
            self = .low
        } else if remainingPercent <= 40 {
            self = .caution
        } else if remainingPercent <= 60 {
            self = .healthy
        } else {
            self = .abundant
        }
    }

    var color: Color {
        switch self {
        case .abundant: .blue
        case .healthy: .green
        case .caution: .orange
        case .low: .red
        case .critical: Color(red: 0.72, green: 0, blue: 0.04)
        }
    }

    var glowColor: Color {
        self == .critical ? .red : .clear
    }

    var glowRadius: CGFloat {
        self == .critical ? 12 : 0
    }

    var showsScaryGlow: Bool {
        self == .critical
    }
}

enum QuotaRingPresentation {
    static func arcFraction(remainingPercent: Double) -> Double {
        if remainingPercent <= 0 { return 1 }
        return min(max(remainingPercent / 100, 0), 1)
    }
}

@available(macOS 14.0, *)
struct QuotaRowView: View {
    let snapshot: QuotaSnapshot
    let agentPhase: CodexAgentPhase
    let agentTaskID: String?
    let openTool: (AIToolDescriptor) -> Void
    let openAgentTask: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var criticalPulse = false

    private var tool: AIToolDescriptor {
        .descriptor(for: snapshot)
    }

    private var primarySeverity: QuotaSeverity {
        QuotaSeverity(remainingPercent: snapshot.remainingPercent)
    }

    private var secondarySeverity: QuotaSeverity? {
        snapshot.secondaryWindow.map {
            QuotaSeverity(remainingPercent: $0.remainingPercent)
        }
    }

    private var hasCriticalSeverity: Bool {
        primarySeverity.showsScaryGlow || secondarySeverity?.showsScaryGlow == true
    }

    var body: some View {
        VStack(spacing: 4) {
            usageRing

            HStack(spacing: 4) {
                typeTag(snapshot.typeTag, severity: primarySeverity)
                if let secondaryWindow = snapshot.secondaryWindow {
                    typeTag(
                        secondaryWindow.typeTag,
                        severity: QuotaSeverity(remainingPercent: secondaryWindow.remainingPercent)
                    )
                }
            }
        }
        .frame(width: 76, height: 76)
        .background {
            if hasCriticalSeverity {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.red.opacity(criticalPulse ? 0.72 : 0.42),
                                Color(red: 0.38, green: 0, blue: 0.02).opacity(0.56),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 48
                        )
                    )
                    .scaleEffect(criticalPulse ? 1.22 : 1.02)
                    .blur(radius: criticalPulse ? 4 : 7)
                    .shadow(color: .red, radius: criticalPulse ? 22 : 12)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            detailPopover
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .onAppear(perform: updateCriticalPulse)
        .onChange(of: hasCriticalSeverity) { _, _ in updateCriticalPulse() }
    }

    private var usageRing: some View {
        ZStack {
            if let secondaryWindow = snapshot.secondaryWindow {
                Circle()
                    .stroke(.secondary.opacity(0.14), lineWidth: 3)
                    .frame(width: 58, height: 58)
                quotaArc(
                    remainingPercent: secondaryWindow.remainingPercent,
                    diameter: 58,
                    lineWidth: 3,
                    severity: secondarySeverity ?? .abundant
                )
            }

            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 4)
                .frame(width: 46, height: 46)
            quotaArc(
                remainingPercent: snapshot.remainingPercent,
                diameter: 46,
                lineWidth: 4,
                severity: primarySeverity
            )
            Button {
                if agentPhase.showsLight, let agentTaskID {
                    openAgentTask(agentTaskID)
                } else {
                    openTool(tool)
                }
            } label: {
                AIToolIcon(tool: tool, size: 23)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(agentTaskID == nil ? "Open \(tool.name)" : "Open Codex task · \(agentPhase.label)")
            .accessibilityLabel(agentTaskID == nil ? "Open \(tool.name)" : "Open Codex task")
        }
        .frame(width: 60, height: 60)
        .background {
            if agentPhase.showsLight {
                AgentStatusRingLight(
                    phase: agentPhase,
                    diameter: snapshot.secondaryWindow == nil ? 46 : 58,
                    isHovered: isHovered
                )
            }
        }
        .help(agentPhase.showsLight ? "Codex agents · \(agentPhase.label)" : "")
    }

    @ViewBuilder
    private func quotaArc(
        remainingPercent: Double,
        diameter: CGFloat,
        lineWidth: CGFloat,
        severity: QuotaSeverity
    ) -> some View {
        let fraction = QuotaRingPresentation.arcFraction(remainingPercent: remainingPercent)

        if severity.showsScaryGlow {
            Circle()
                .stroke(Color.red, lineWidth: lineWidth + 8)
                .frame(width: diameter, height: diameter)
                .scaleEffect(criticalPulse ? 1.18 : 1.04)
                .blur(radius: criticalPulse ? 5 : 8)
                .shadow(color: .red, radius: criticalPulse ? 24 : 14)
                .accessibilityHidden(true)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Color.red,
                    style: StrokeStyle(lineWidth: lineWidth + 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .blur(radius: criticalPulse ? 5 : 8)
                .shadow(color: .red, radius: criticalPulse ? 20 : 12)
                .accessibilityHidden(true)
        }

        Circle()
            .trim(from: 0, to: fraction)
            .stroke(severity.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: diameter, height: diameter)
            .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
            .shadow(color: severity.glowColor.opacity(0.9), radius: severity.glowRadius * 0.7)
            .shadow(color: severity.glowColor.opacity(0.72), radius: severity.glowRadius)
    }

    private func updateCriticalPulse() {
        criticalPulse = false
        guard hasCriticalSeverity else { return }

        if reduceMotion {
            criticalPulse = true
        } else {
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                criticalPulse = true
            }
        }
    }

    private func typeTag(_ text: String, severity: QuotaSeverity) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(severity.color)
            .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
            .shadow(color: severity.glowColor.opacity(0.8), radius: severity.glowRadius)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AIToolIcon(tool: tool, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name).font(.headline)
                    Text(snapshot.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let planType = snapshot.planType, !planType.isEmpty {
                    Text("Plan \(planType.capitalized)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Plan")
                        .accessibilityValue(planType.capitalized)
                }
            }

            windowDetail(
                title: snapshot.typeTag,
                window: snapshot.primaryWindow,
                severity: primarySeverity
            )

            if let secondaryWindow = snapshot.secondaryWindow {
                Divider()
                windowDetail(
                    title: secondaryWindow.typeTag,
                    window: secondaryWindow,
                    severity: QuotaSeverity(remainingPercent: secondaryWindow.remainingPercent)
                )
            }
        }
        .font(.caption)
        .padding(14)
        .frame(width: 260)
    }

    private func windowDetail(
        title: String,
        window: QuotaWindowSnapshot,
        severity: QuotaSeverity
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold).foregroundStyle(severity.color)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% remaining")
                    .monospacedDigit()
            }
            QuotaProgressBar(
                remainingPercent: window.remainingPercent,
                severity: severity
            )
            LabeledContent("Resets") {
                Text(ResetDateText.format(window.resetAt))
            }
        }
    }

    private var accessibilitySummary: String {
        var text = "\(tool.name), \(snapshot.displayName), \(snapshot.typeTag) \(Int(snapshot.remainingPercent.rounded())) percent remaining"
        if let secondaryWindow = snapshot.secondaryWindow {
            text += ", \(secondaryWindow.typeTag) \(Int(secondaryWindow.remainingPercent.rounded())) percent remaining"
        }
        if agentPhase.showsLight {
            text += ", Codex agents \(agentPhase.label)"
        }
        return text
    }

}

@available(macOS 14.0, *)
private struct AgentStatusRingLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: CodexAgentPhase
    let diameter: CGFloat
    let isHovered: Bool
    @State private var isBreathing = false

    private var color: Color {
        switch phase {
        case .idle: .clear
        case .thinking: Color(red: 0.34, green: 0.56, blue: 1)
        case .complete: Color(red: 0.36, green: 0.82, blue: 0.52)
        case .needsInput: Color(red: 1, green: 0.72, blue: 0.24)
        case .error: Color(red: 1, green: 0.32, blue: 0.55)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(isHovered ? 0.52 : 0.42), lineWidth: 3)
                .frame(width: diameter, height: diameter)
                .blur(radius: 1.5)

            Circle()
                .stroke(color.opacity(isHovered ? 0.28 : 0.20), lineWidth: 8)
                .frame(width: diameter - 2, height: diameter - 2)
                .blur(radius: 4.5)
        }
        .scaleEffect(isBreathing ? 1.10 : 0.90)
        .opacity(isBreathing ? 0.90 : 0.50)
        .frame(width: 84, height: 84)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: restartBreathing)
        .onChange(of: phase) { _, _ in restartBreathing() }
        .onChange(of: reduceMotion) { _, _ in restartBreathing() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            restartBreathing()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            restartBreathing()
        }
    }

    private func restartBreathing() {
        withAnimation(.none) { isBreathing = false }
        guard phase.showsLight, !reduceMotion else { return }

        Task { @MainActor in
            await Task.yield()
            guard phase.showsLight, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.65).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

@available(macOS 14.0, *)
private struct QuotaProgressBar: View {
    let remainingPercent: Double
    let severity: QuotaSeverity

    private var fraction: Double {
        min(max(remainingPercent / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                if severity.showsScaryGlow {
                    Capsule()
                        .stroke(Color.red.opacity(0.9), lineWidth: 2)
                        .shadow(color: .red, radius: 5)
                        .shadow(color: .red.opacity(0.85), radius: 12)
                        .accessibilityHidden(true)
                }
                Capsule()
                    .fill(severity.color)
                    .frame(width: proxy.size.width * fraction)
                    .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
                    .shadow(color: severity.glowColor.opacity(0.9), radius: severity.glowRadius * 0.7)
                    .shadow(color: severity.glowColor.opacity(0.72), radius: severity.glowRadius)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Quota remaining")
        .accessibilityValue("\(Int(remainingPercent.rounded())) percent")
    }
}

enum ResetDateText {
    static func format(
        _ date: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let date else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
