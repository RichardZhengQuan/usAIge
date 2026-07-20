import AppKit
import QuartzCore
import SwiftUI

@MainActor
private struct PopoverGlassStrengthTuner: NSViewRepresentable {
    let opacity: Double
    let showsCriticalBorder: Bool

    func makeNSView(context: Context) -> TuningView {
        let view = TuningView()
        view.opacity = opacity
        view.showsCriticalBorder = showsCriticalBorder
        return view
    }

    func updateNSView(_ nsView: TuningView, context: Context) {
        nsView.opacity = opacity
        nsView.showsCriticalBorder = showsCriticalBorder
        nsView.applyAppearance()
    }

    final class TuningView: NSView {
        var opacity = 1.0
        var showsCriticalBorder = false

        private static let criticalBorderLayerName = "usAIgeCriticalPopoverBorder"

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let contentView = window?.contentView,
                      let popoverFrame = contentView.superview,
                      let glassView = popoverFrame.subviews.first(where: { $0 !== contentView })
                else { return }

                glassView.alphaValue = opacity
                applyBorders(to: popoverFrame)
            }
        }

        private func applyBorders(to popoverFrame: NSView) {
            popoverFrame.wantsLayer = true

            let existingCriticalLayer = popoverFrame.layer?.sublayers?.first {
                $0.name == Self.criticalBorderLayerName
            }

            guard showsCriticalBorder else {
                existingCriticalLayer?.removeFromSuperlayer()
                return
            }

            let borderLayer = (existingCriticalLayer as? CAShapeLayer) ?? CAShapeLayer()
            borderLayer.name = Self.criticalBorderLayerName
            borderLayer.frame = popoverFrame.bounds
            borderLayer.path = Self.popoverOutlinePath(
                bodyRect: convert(bounds, to: popoverFrame),
                in: popoverFrame.bounds
            )
            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.strokeColor = NSColor.systemRed.cgColor
            borderLayer.lineWidth = 2.25
            borderLayer.lineJoin = .round
            borderLayer.shadowColor = NSColor.systemRed.cgColor
            borderLayer.shadowOpacity = 0.55
            borderLayer.shadowRadius = 6
            borderLayer.shadowOffset = .zero
            borderLayer.shadowPath = nil
            borderLayer.zPosition = 1_000
            borderLayer.contentsScale = window?.backingScaleFactor ?? 2

            if existingCriticalLayer == nil {
                popoverFrame.layer?.addSublayer(borderLayer)
            }
        }

        private static func popoverOutlinePath(bodyRect: CGRect, in bounds: CGRect) -> CGPath {
            let outline = bodyRect.insetBy(dx: 1, dy: 1)
            let arrowHalfHeight: CGFloat = 11
            let radius: CGFloat = 18
            let minX = outline.minX
            let minY = outline.minY
            let maxY = outline.maxY
            let bodyMaxX = outline.maxX
            let tipX = bounds.maxX - 1
            let midY = outline.midY
            let path = CGMutablePath()

            path.move(to: CGPoint(x: minX + radius, y: minY))
            path.addLine(to: CGPoint(x: bodyMaxX - radius, y: minY))
            path.addQuadCurve(
                to: CGPoint(x: bodyMaxX, y: minY + radius),
                control: CGPoint(x: bodyMaxX, y: minY)
            )
            path.addLine(to: CGPoint(x: bodyMaxX, y: midY - arrowHalfHeight))
            path.addLine(to: CGPoint(x: tipX, y: midY))
            path.addLine(to: CGPoint(x: bodyMaxX, y: midY + arrowHalfHeight))
            path.addLine(to: CGPoint(x: bodyMaxX, y: maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyMaxX - radius, y: maxY),
                control: CGPoint(x: bodyMaxX, y: maxY)
            )
            path.addLine(to: CGPoint(x: minX + radius, y: maxY))
            path.addQuadCurve(
                to: CGPoint(x: minX, y: maxY - radius),
                control: CGPoint(x: minX, y: maxY)
            )
            path.addLine(to: CGPoint(x: minX, y: minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: minX + radius, y: minY),
                control: CGPoint(x: minX, y: minY)
            )
            path.closeSubpath()
            return path
        }
    }
}

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
        self == .critical ? Color.red.opacity(0.28) : .clear
    }

    var glowRadius: CGFloat {
        self == .critical ? 4 : 0
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

enum ResetCreditPresentation {
    static func displayedCount(showsResetCredits: Bool, availableCount: Int?) -> Int? {
        guard showsResetCredits, let availableCount, availableCount > 0 else { return nil }
        return availableCount
    }
}

enum AgentBreathingMotion {
    static let minimumThickness: CGFloat = 2
    static let midpointThickness: CGFloat = 4
    static let maximumThickness: CGFloat = 6
    static let keyframeDuration: TimeInterval = 0.825
    static let minimumOpacity = 0.68
    static let midpointOpacity = 0.84
    static let maximumOpacity = 1.00

    static func outwardDiameter(baseDiameter: CGFloat, thickness: CGFloat) -> CGFloat {
        baseDiameter + thickness
    }

    static func opacity(for thickness: CGFloat) -> Double {
        if thickness <= midpointThickness {
            let progress = Double(
                (thickness - minimumThickness) / (midpointThickness - minimumThickness)
            )
            return minimumOpacity + progress * (midpointOpacity - minimumOpacity)
        }
        let progress = Double(
            (thickness - midpointThickness) / (maximumThickness - midpointThickness)
        )
        return midpointOpacity + progress * (maximumOpacity - midpointOpacity)
    }
}

extension CodexAgentPhase {
    var statusColor: Color? {
        switch self {
        case .idle: nil
        case .thinking: Color(red: 0.18, green: 0.52, blue: 1.00)
        case .complete: Color(red: 0.18, green: 0.88, blue: 0.45)
        case .needsInput: Color(red: 1.00, green: 0.68, blue: 0.12)
        case .error: Color(red: 1.00, green: 0.20, blue: 0.47)
        }
    }
}

@available(macOS 14.0, *)
struct QuotaRowView: View {
    let snapshot: QuotaSnapshot
    let showsResetCredits: Bool
    let agentPhase: CodexAgentPhase
    let agentTaskID: String?
    let openTool: (AIToolDescriptor) -> Void
    let openAgentTask: (String) -> Void
    let onDetailHoverChanged: (Bool) -> Void
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

    private var detailSeverity: QuotaSeverity {
        QuotaSeverity(
            remainingPercent: min(
                snapshot.remainingPercent,
                snapshot.secondaryWindow?.remainingPercent ?? 100
            )
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            usageRing

            HStack(spacing: 4) {
                typeTag(
                    fallbackText: snapshot.typeTag,
                    resetAt: snapshot.resetAt,
                    availableResetCount: ResetCreditPresentation.displayedCount(
                        showsResetCredits: showsResetCredits,
                        availableCount: snapshot.availableResetCount
                    ),
                    isCondensed: snapshot.secondaryWindow != nil,
                    severity: primarySeverity
                )
                if let secondaryWindow = snapshot.secondaryWindow {
                    typeTag(
                        fallbackText: secondaryWindow.typeTag,
                        resetAt: secondaryWindow.resetAt,
                        availableResetCount: nil,
                        isCondensed: true,
                        severity: QuotaSeverity(remainingPercent: secondaryWindow.remainingPercent)
                    )
                }
            }
        }
        .frame(width: 76, height: HUDMetrics.quotaRowHeight)
        .contentShape(Rectangle())
        .onHover { hoverState in
            isHovered = hoverState
            onDetailHoverChanged(hoverState)
        }
        .onDisappear { onDetailHoverChanged(false) }
        .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            detailPopover
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .onAppear {
            updateCriticalPulse()
        }
        .onChange(of: hasCriticalSeverity) { _, _ in updateCriticalPulse() }
    }

    private var usageRing: some View {
        ZStack {
            if let secondaryWindow = snapshot.secondaryWindow {
                Circle()
                    .stroke(
                        .secondary.opacity(secondarySeverity?.showsScaryGlow == true ? 0 : 0.14),
                        lineWidth: 3
                    )
                    .frame(width: 58, height: 58)
                quotaArc(
                    remainingPercent: secondaryWindow.remainingPercent,
                    diameter: 58,
                    lineWidth: 3,
                    severity: secondarySeverity ?? .abundant
                )
            }

            Circle()
                .stroke(
                    .secondary.opacity(primarySeverity.showsScaryGlow ? 0 : 0.18),
                    lineWidth: 4
                )
                .frame(width: 46, height: 46)
            quotaArc(
                remainingPercent: snapshot.remainingPercent,
                diameter: 46,
                lineWidth: 4,
                severity: primarySeverity
            )
            Button(action: performPrimaryAction) {
                AIToolIcon(
                    tool: tool,
                    size: 23,
                    showsContrastHalo: true,
                    contrastHaloColor: agentPhase.statusColor
                )
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(agentTaskID == nil ? "Open \(tool.name)" : "Open Codex task · \(agentPhase.label)")
            .accessibilityLabel(agentTaskID == nil ? "Open \(tool.name)" : "Open Codex task")
        }
        .frame(width: 60, height: 60)
        .background {
            if agentPhase.showsLight && !hasCriticalSeverity {
                AgentStatusRingLight(
                    phase: agentPhase,
                    diameter: snapshot.secondaryWindow == nil ? 46 : 58,
                    isHovered: isHovered
                )
            }
        }
        .help(agentPhase.showsLight ? "Codex agents · \(agentPhase.label)" : "")
    }

    private func performPrimaryAction() {
        if agentPhase.showsLight, let agentTaskID {
            openAgentTask(agentTaskID)
        } else {
            openTool(tool)
        }
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
                .trim(from: 0, to: fraction)
                .stroke(
                    Color.red.opacity(0.28),
                    style: StrokeStyle(lineWidth: lineWidth + 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .scaleEffect(criticalPulse ? 1.18 : 1.04)
                .blur(radius: criticalPulse ? 3 : 4)
                .shadow(color: Color.red.opacity(0.28), radius: 4)
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

    private func typeTag(
        fallbackText: String,
        resetAt: Date?,
        availableResetCount: Int?,
        isCondensed: Bool,
        severity: QuotaSeverity
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let resetText = ResetRemainingText.compact(until: resetAt, now: context.date)

            HStack(alignment: .center, spacing: isCondensed ? 1 : 2) {
                Text(resetText ?? fallbackText)
                    .font(.system(
                        size: isCondensed ? 9 : 11,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(severity.color)
                    .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
                    .shadow(color: severity.glowColor.opacity(0.8), radius: severity.glowRadius)

                if let availableResetCount {
                    Text("\(availableResetCount)r")
                        .font(.system(
                            size: isCondensed ? 7 : 8,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(severity.color)
                }
            }
            .padding(.horizontal, isCondensed ? 3 : 6)
            .frame(height: isCondensed ? 16 : 20, alignment: .center)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ResetRemainingText.accessibilityLabel(until: resetAt, now: context.date)
                    ?? fallbackText
            )
            .accessibilityValue(
                availableResetCount.map { "\($0) reset credits available" } ?? ""
            )
        }
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
        .presentationBackground {
            HUDGlassSurface(
                severity: detailSeverity,
                isActive: true,
                showsCriticalOutline: hasCriticalSeverity
            )
        }
        .background {
            PopoverGlassStrengthTuner(
                opacity: 0,
                showsCriticalBorder: hasCriticalSeverity
            )
        }
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

    private var color: Color {
        phase.statusColor ?? .clear
    }

    var body: some View {
        let lightColor = color
        Color.clear
            .frame(width: diameter, height: diameter)
        .keyframeAnimator(
            initialValue: AgentBreathingMotion.midpointThickness,
            repeating: phase.showsLight && !reduceMotion
        ) { _, thickness in
            let opacity = AgentBreathingMotion.opacity(for: thickness)
            ZStack {
                Circle()
                    .stroke(
                        lightColor.opacity((isHovered ? 0.88 : 0.74) * opacity),
                        lineWidth: 1
                    )
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 1)

                Circle()
                    .stroke(
                        lightColor.opacity((isHovered ? 0.60 : 0.48) * opacity),
                        lineWidth: thickness
                    )
                    .frame(
                        width: AgentBreathingMotion.outwardDiameter(
                            baseDiameter: diameter,
                            thickness: thickness
                        ),
                        height: AgentBreathingMotion.outwardDiameter(
                            baseDiameter: diameter,
                            thickness: thickness
                        )
                    )
                    .blur(radius: thickness * 0.55)
            }
        } keyframes: { _ in
            LinearKeyframe(
                AgentBreathingMotion.minimumThickness,
                duration: AgentBreathingMotion.keyframeDuration,
                timingCurve: .easeInOut
            )
            LinearKeyframe(
                AgentBreathingMotion.midpointThickness,
                duration: AgentBreathingMotion.keyframeDuration,
                timingCurve: .easeInOut
            )
            LinearKeyframe(
                AgentBreathingMotion.maximumThickness,
                duration: AgentBreathingMotion.keyframeDuration,
                timingCurve: .easeInOut
            )
            LinearKeyframe(
                AgentBreathingMotion.midpointThickness,
                duration: AgentBreathingMotion.keyframeDuration,
                timingCurve: .easeInOut
            )
        }
        .frame(width: diameter + 10, height: diameter + 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

enum ResetRemainingText {
    static func compact(until resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
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

    static func accessibilityLabel(until resetAt: Date?, now: Date = Date()) -> String? {
        guard let compactValue = compact(until: resetAt, now: now) else { return nil }
        return compactValue == "NOW" ? "Resetting now" : "Resets in \(compactValue)"
    }
}
