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

/// How often the rail's slow, continuous animations redraw. Each update
/// re-renders the rail on the main thread, so running them at the display's
/// full rate would use a steady share of a CPU core for no visible gain.
enum RailMotion {
    static let updatesPerSecond = 20.0
}

enum CriticalPulseMotion {
    static let period: TimeInterval = 1.24

    /// Eases between 0 and 1 and back over one period.
    static func value(at time: TimeInterval) -> Double {
        (1 - cos(2 * .pi * time / period)) / 2
    }
}

enum AgentBreathingMotion {
    static let minimumThickness: CGFloat = 2
    static let midpointThickness: CGFloat = 4
    static let maximumThickness: CGFloat = 6
    static let quotaRingGap: CGFloat = 1.5
    static let keyframeDuration: TimeInterval = 0.825
    static let minimumOpacity = 0.52
    static let midpointOpacity = 0.66
    static let maximumOpacity = 0.80

    /// The ring's thickness at `time`: from the midpoint down to the minimum,
    /// up to the maximum, and back, easing through each step.
    static func thickness(at time: TimeInterval) -> CGFloat {
        let stops = [
            midpointThickness,
            minimumThickness,
            midpointThickness,
            maximumThickness,
            midpointThickness,
        ]
        let position = time.truncatingRemainder(dividingBy: keyframeDuration * 4) / keyframeDuration
        let step = min(Int(position), 3)
        let progress = CGFloat(position - Double(step))
        let eased = progress * progress * (3 - 2 * progress)
        return stops[step] + (stops[step + 1] - stops[step]) * eased
    }

    static func baseDiameter(
        outsideQuotaRing quotaDiameter: CGFloat,
        quotaLineWidth: CGFloat
    ) -> CGFloat {
        quotaDiameter + quotaLineWidth + (quotaRingGap * 2)
    }

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
    /// Reports hover changes with the row's frame in the rail's coordinates.
    let onDetailHoverChanged: (Bool, CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false
    @State private var rowFrame = CGRect.zero

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
                typeTag(
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            rowFrame = frame
            if isHovered { onDetailHoverChanged(true, frame) }
        }
        .onHover { hoverState in
            isHovered = hoverState
            onDetailHoverChanged(hoverState, rowFrame)
        }
        .onDisappear { onDetailHoverChanged(false, rowFrame) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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
            .help(agentTaskID == nil ? "Open \(tool.name)" : "Open \(sessionNoun) · \(agentPhase.label)")
            .accessibilityLabel(agentTaskID == nil ? "Open \(tool.name)" : "Open \(sessionNoun)")
        }
        .frame(width: 60, height: 60)
        .background {
            if agentPhase.showsLight && !hasCriticalSeverity {
                AgentStatusRingLight(
                    phase: agentPhase,
                    diameter: AgentBreathingMotion.baseDiameter(
                        outsideQuotaRing: snapshot.secondaryWindow == nil ? 46 : 58,
                        quotaLineWidth: snapshot.secondaryWindow == nil ? 4 : 3
                    ),
                    isHovered: isHovered
                )
            }
        }
        .help(agentPhase.showsLight ? "\(tool.name) sessions · \(agentPhase.label)" : "")
    }

    /// What clicking the ring opens: Codex's own task, another tool's app.
    private var sessionNoun: String {
        snapshot.toolID == .chatGPT ? "Codex task" : "\(tool.name) session"
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
            TimelineView(.animation(minimumInterval: 1 / RailMotion.updatesPerSecond, paused: reduceMotion)) { context in
                let pulse = reduceMotion
                    ? 1
                    : CriticalPulseMotion.value(at: context.date.timeIntervalSinceReferenceDate)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        Color.red.opacity(0.28),
                        style: StrokeStyle(lineWidth: lineWidth + 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(1.04 + 0.14 * pulse)
                    .blur(radius: 4 - pulse)
                    .shadow(color: Color.red.opacity(0.28), radius: 4)
                    .accessibilityHidden(true)
            }
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

    private func typeTag(
        resetAt: Date?,
        availableResetCount: Int?,
        isCondensed: Bool,
        severity: QuotaSeverity
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let resetText = ResetRemainingText.compact(until: resetAt, now: context.date)

            HStack(alignment: .center, spacing: isCondensed ? 1 : 2) {
                Text(resetText)
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
            // A material keeps the tag legible over any wallpaper. With Reduce
            // Transparency the rail's surface is the same solid material, so a
            // tint keeps the capsule distinct from it.
            .background(
                reduceTransparency ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ResetRemainingText.accessibilityLabel(until: resetAt, now: context.date)
            )
            .accessibilityValue(
                availableResetCount.map { "\($0) reset credits available" } ?? ""
            )
            .help(ResetRemainingText.accessibilityLabel(until: resetAt, now: context.date))
        }
    }

    private var accessibilitySummary: String {
        var text = "\(tool.name), \(snapshot.displayName), \(snapshot.typeTag) window, \(Int(snapshot.remainingPercent.rounded())) percent remaining, \(ResetRemainingText.accessibilityLabel(until: snapshot.resetAt))"
        if let secondaryWindow = snapshot.secondaryWindow {
            text += ", \(secondaryWindow.typeTag) window, \(Int(secondaryWindow.remainingPercent.rounded())) percent remaining, \(ResetRemainingText.accessibilityLabel(until: secondaryWindow.resetAt))"
        }
        if agentPhase.showsLight {
            text += ", \(tool.name) sessions \(agentPhase.label)"
        }
        return text
    }

}

/// A rounded card with an arrow pointing at the hovered row. `rect` includes
/// room for the arrow on both sides, so either side takes the same space.
@available(macOS 14.0, *)
struct QuotaDetailCardShape: Shape {
    static let arrowLength: CGFloat = 9
    private static let arrowHalfHeight: CGFloat = 10
    private static let cornerRadius: CGFloat = 18

    var arrowEdge: HorizontalEdge
    /// How far below the card's centre the arrow points.
    var arrowOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: Self.arrowLength, dy: 0)
        let radius = Self.cornerRadius
        let halfHeight = Self.arrowHalfHeight
        let margin = radius + halfHeight
        let arrowY = min(max(body.midY + arrowOffset, body.minY + margin), body.maxY - margin)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.maxY),
            radius: radius
        )
        if arrowEdge == .trailing {
            path.addLine(to: CGPoint(x: body.maxX, y: arrowY - halfHeight))
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: arrowY),
                tangent2End: CGPoint(x: body.maxX, y: arrowY + halfHeight),
                radius: 2
            )
            path.addLine(to: CGPoint(x: body.maxX, y: arrowY + halfHeight))
        }
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.minY),
            radius: radius
        )
        if arrowEdge == .leading {
            path.addLine(to: CGPoint(x: body.minX, y: arrowY + halfHeight))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: arrowY),
                tangent2End: CGPoint(x: body.minX, y: arrowY - halfHeight),
                radius: 2
            )
            path.addLine(to: CGPoint(x: body.minX, y: arrowY - halfHeight))
        }
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}

/// The details shown beside the rail for the hovered row.
@available(macOS 14.0, *)
struct QuotaDetailCard: View {
    /// Room around the card so its window doesn't clip the shadow or critical glow.
    static let windowInset: CGFloat = 28

    let snapshot: QuotaSnapshot
    /// What this tool is doing now, and the memory it and that work use.
    var work: [LiveSessionWork] = []
    var memoryBytes: UInt64 = 0
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil

    private var tool: AIToolDescriptor {
        .descriptor(for: snapshot)
    }

    private var lowestSeverity: QuotaSeverity {
        QuotaSeverity(
            remainingPercent: min(
                snapshot.remainingPercent,
                snapshot.secondaryWindow?.remainingPercent ?? 100
            )
        )
    }

    var body: some View {
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
                severity: QuotaSeverity(remainingPercent: snapshot.remainingPercent)
            )

            if let secondaryWindow = snapshot.secondaryWindow {
                Divider()
                windowDetail(
                    title: secondaryWindow.typeTag,
                    window: secondaryWindow,
                    severity: QuotaSeverity(remainingPercent: secondaryWindow.remainingPercent)
                )
            }

            if !work.isEmpty || memoryBytes > 0 {
                Divider()
                HStack {
                    Text(work.isEmpty ? "Memory" : "Working now").fontWeight(.semibold)
                    Spacer()
                    if memoryBytes > 0 {
                        Text(LiveWorkText.memory(memoryBytes)).monospacedDigit()
                    }
                }
                if !work.isEmpty {
                    LiveSessionList(sessions: work)
                    if let openBranches {
                        Button("All branches and worktrees…", action: openBranches)
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .font(.caption)
        .railDetailCardChrome(
            width: work.isEmpty ? 260 : 300,
            showsCriticalGlow: lowestSeverity.showsScaryGlow,
            arrowEdge: arrowEdge,
            arrowOffset: arrowOffset
        )
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
}

/// The surface every card beside the rail shares.
@available(macOS 14.0, *)
private struct RailDetailCardSurface: View {
    let showsCriticalGlow: Bool
    let arrowEdge: HorizontalEdge
    let arrowOffset: CGFloat

    var body: some View {
        let shape = QuotaDetailCardShape(arrowEdge: arrowEdge, arrowOffset: arrowOffset)
        ZStack {
            // Regular glass, unlike the rail's clear glass, keeps the text
            // legible over whatever window sits behind the card.
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
            shape.stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            if showsCriticalGlow {
                shape.stroke(Color.red.opacity(0.92), lineWidth: 2)
                    .shadow(color: .red.opacity(0.9), radius: 7)
                    .shadow(color: .red.opacity(0.55), radius: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

@available(macOS 14.0, *)
extension View {
    func railDetailCardChrome(
        width: CGFloat,
        showsCriticalGlow: Bool = false,
        arrowEdge: HorizontalEdge,
        arrowOffset: CGFloat
    ) -> some View {
        padding(14)
            .frame(width: width)
            .background {
                RailDetailCardSurface(
                    showsCriticalGlow: showsCriticalGlow,
                    arrowEdge: arrowEdge,
                    arrowOffset: arrowOffset
                )
                .padding(.horizontal, -QuotaDetailCardShape.arrowLength)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(QuotaDetailCard.windowInset)
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
        let isAnimating = phase.showsLight && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / RailMotion.updatesPerSecond, paused: !isAnimating)) { context in
            let thickness = isAnimating
                ? AgentBreathingMotion.thickness(at: context.date.timeIntervalSinceReferenceDate)
                : AgentBreathingMotion.midpointThickness
            let opacity = AgentBreathingMotion.opacity(for: thickness)
            ZStack {
                Circle()
                    .stroke(
                        lightColor.opacity((isHovered ? 0.70 : 0.54) * opacity),
                        lineWidth: 1
                    )
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 1)

                Circle()
                    .stroke(
                        lightColor.opacity((isHovered ? 0.42 : 0.30) * opacity),
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
                    .blur(radius: thickness * 0.48)
            }
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
    static func compact(until resetAt: Date?, now: Date = Date()) -> String {
        // A quota's window length (such as 7D) is not its time until reset.
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

    static func accessibilityLabel(until resetAt: Date?, now: Date = Date()) -> String {
        guard resetAt != nil else { return "Reset time unavailable" }
        let compactValue = compact(until: resetAt, now: now)
        return compactValue == "NOW" ? "Resetting now" : "Resets in \(compactValue)"
    }
}
