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
    static func displayedCount(for snapshot: QuotaSnapshot, otherLimits: [QuotaSnapshot] = []) -> Int? {
        // Modern displays one ring per tool. Its tightest limit may be a
        // model-specific bucket while another holds the tool's reset credits.
        let availableCount = snapshot.availableResetCount ?? otherLimits.lazy.compactMap(\.availableResetCount).first
        guard let availableCount, availableCount > 0 else { return nil }
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
    let otherLimits: [QuotaSnapshot]
    let agentPhase: CodexAgentPhase
    let agentTaskID: String?
    let openTool: (AIToolDescriptor) -> Void
    let openAgentTask: (String) -> Void
    /// Reports hover changes with the row's frame in the rail's coordinates.
    let onDetailHoverChanged: (Bool, CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hudTextSize) private var textSize
    @AppStorage(InterfaceStyle.defaultsKey) private var style = InterfaceStyle.standard
    @State private var isHovered = false

    /// Modern draws Activity-style rings: thicker, on a track tinted with
    /// the ring's own colour.
    private var isModern: Bool { style == .modern }

    /// Modern draws every tool's outer ring at one size; a second limit
    /// nests inside it rather than shrinking the ring.
    private var primaryDiameter: CGFloat {
        if isModern { return snapshot.secondaryWindow == nil ? 58 : 45 }
        return 46
    }

    private func track(_ severity: QuotaSeverity, classicOpacity: Double) -> Color {
        if severity.showsScaryGlow { return .clear }
        return isModern ? severity.color.opacity(0.2) : Color.secondary.opacity(classicOpacity)
    }

    private var tool: AIToolDescriptor {
        .descriptor(for: snapshot)
    }

    private var primarySeverity: QuotaSeverity {
        QuotaSeverity(remainingPercent: snapshot.remainingPercent)
    }

    private var credits: Int? { ResetCreditPresentation.displayedCount(for: snapshot, otherLimits: otherLimits) }

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

            TimelineView(.periodic(from: .now, by: 60)) { context in
                RailResetBadges(snapshot: snapshot, credits: credits, now: context.date, isModern: isModern)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: HUDMetrics.rowHeight(for: textSize))
        .contentShape(Rectangle())
        .modifier(RailDetailHover(isHovered: $isHovered, changed: onDetailHoverChanged))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var usageRing: some View {
        ZStack {
            if let secondaryWindow = snapshot.secondaryWindow {
                Circle()
                    .stroke(track(secondarySeverity ?? .abundant, classicOpacity: 0.14), lineWidth: isModern ? 4.5 : 3)
                    .frame(width: 58, height: 58)
                quotaArc(
                    remainingPercent: secondaryWindow.remainingPercent,
                    diameter: 58,
                    lineWidth: isModern ? 4.5 : 3,
                    severity: secondarySeverity ?? .abundant
                )
            }

            Circle()
                .stroke(track(primarySeverity, classicOpacity: 0.18), lineWidth: isModern ? 5 : 4)
                .frame(width: primaryDiameter, height: primaryDiameter)
            quotaArc(
                remainingPercent: snapshot.remainingPercent,
                diameter: primaryDiameter,
                lineWidth: isModern ? 5 : 4,
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
            // Modern's card beside the rail says all this; a tooltip would
            // only cover it.
            .help(isModern ? "" : agentTaskID == nil ? "Open \(tool.name)" : "Open \(sessionNoun) · \(agentPhase.label)")
            .accessibilityLabel(agentTaskID == nil ? "Open \(tool.name)" : "Open \(sessionNoun)")
        }
        .frame(width: 60, height: 60)
        .background {
            if agentPhase.showsLight && !hasCriticalSeverity {
                AgentStatusRingLight(
                    phase: agentPhase,
                    diameter: AgentBreathingMotion.baseDiameter(
                        outsideQuotaRing: isModern || snapshot.secondaryWindow != nil ? 58 : 46,
                        quotaLineWidth: isModern ? 5 : snapshot.secondaryWindow == nil ? 4 : 3
                    ),
                    isHovered: isHovered
                )
            }
        }
        .help(agentPhase.showsLight && !isModern ? "\(tool.name) sessions · \(agentPhase.label)" : "")
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

    private var accessibilitySummary: String {
        var text = "\(tool.name), \(snapshot.displayName), \(snapshot.typeTag) window, \(Int(snapshot.remainingPercent.rounded())) percent remaining, \(ResetRemainingText.accessibilityLabel(until: snapshot.resetAt))"
        if let credits {
            text += ", \(credits) reset \(credits == 1 ? "credit" : "credits") available"
        }
        if let secondaryWindow = snapshot.secondaryWindow {
            text += ", \(secondaryWindow.typeTag) window, \(Int(secondaryWindow.remainingPercent.rounded())) percent remaining, \(ResetRemainingText.accessibilityLabel(until: secondaryWindow.resetAt))"
        }
        if agentPhase.showsLight {
            text += ", \(tool.name) sessions \(agentPhase.label)"
        }
        return text
    }

}

@available(macOS 14.0, *)
struct RailResetBadges: View {
    let snapshot: QuotaSnapshot
    let credits: Int?
    let now: Date
    let isModern: Bool
    @Environment(\.hudTextSize) private var textSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8 * textSize.factor) {
            badge(snapshot.primaryWindow, credits: credits)
            if let secondary = snapshot.secondaryWindow { badge(secondary) }
        }
        .hudRailLabel()
    }

    private func badge(_ window: QuotaWindowSnapshot, credits: Int? = nil) -> some View {
        let severity = QuotaSeverity(remainingPercent: window.remainingPercent)
        let description = ResetRemainingText.accessibilityLabel(until: window.resetAt, now: now)
        return HStack(alignment: .firstTextBaseline, spacing: 5 * textSize.factor) {
            Text(ResetRemainingText.compact(until: window.resetAt, now: now))
                .font(.system(size: (isModern ? 13 : 11) * textSize.factor, weight: .bold, design: .rounded))
                .shadow(color: severity.glowColor, radius: severity.glowRadius / 3)
                .shadow(color: severity.glowColor.opacity(0.8), radius: severity.glowRadius)
            if let credits {
                Text("\(credits)r")
                    .font(.system(size: (isModern ? 11 : 10) * textSize.factor, weight: .semibold, design: .rounded))
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .foregroundStyle(severity.color)
        .padding(.horizontal, 10 * textSize.factor)
        .frame(minWidth: 44 * textSize.factor)
        .frame(height: 20 * textSize.factor)
        .background(reduceTransparency ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityValue(credits.map { "\($0) reset \($0 == 1 ? "credit" : "credits") available" } ?? "")
        .help(isModern ? "" : description)
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
    /// The tool's other limits, when its rail ring stands for all of them.
    var otherLimits: [QuotaSnapshot] = []
    /// What this tool is doing now, and the memory it and that work use.
    var work: [LiveSessionWork] = []
    var memoryBytes: UInt64 = 0
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil
    @AppStorage(InterfaceStyle.defaultsKey) private var style = InterfaceStyle.standard

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

    @ViewBuilder
    var body: some View {
        if style == .modern { modern } else { classic }
    }

    /// The window's language: the tool's icon on a tile, then a bar for each
    /// limit window with what's left and its reset, as on the Usage page.
    private var modern: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AIToolIcon(tool: tool, size: 18)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name).font(.headline)
                    Text(snapshot.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let planType = snapshot.planType, !planType.isEmpty {
                    Text(planType.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .accessibilityLabel("Plan \(planType.capitalized)")
                }
            }
            limitWindows(snapshot)
            ForEach(otherLimits) { other in
                Divider()
                Text(other.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                limitWindows(other)
            }
            let credits = ([snapshot] + otherLimits).availableResets()
            if !credits.isEmpty {
                Divider()
                ModernResetCredits(credits: credits)
            }
            if !work.isEmpty || memoryBytes > 0 {
                Divider()
                HStack {
                    Text(work.isEmpty ? "Memory" : "Working now").font(.caption.weight(.semibold))
                    Spacer()
                    if memoryBytes > 0 {
                        Text(LiveWorkText.memory(memoryBytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !work.isEmpty {
                    LiveSessionList(sessions: work).font(.caption)
                    if let openBranches {
                        Button("All branches and worktrees…", action: openBranches)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .railDetailCardChrome(
            width: 320,
            showsCriticalGlow: lowestSeverity.showsScaryGlow
                || otherLimits.contains { QuotaSeverity(remainingPercent: min($0.remainingPercent, $0.secondaryWindow?.remainingPercent ?? 100)).showsScaryGlow },
            arrowEdge: arrowEdge,
            arrowOffset: arrowOffset
        )
    }

    private func limitWindows(_ limit: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(([limit.primaryWindow] + [limit.secondaryWindow].compactMap { $0 }).enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 3) {
                    ModernQuotaBar(window: window, showsReset: false)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text([ResetMomentText.sentence(window.resetAt, now: context.date),
                              ResetMomentText.countdown(window.resetAt, now: context.date).map { "in \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                    }
                }
            }
        }
    }

    private var classic: some View {
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

            ForEach(otherLimits) { other in
                Divider()
                Text(other.displayName).fontWeight(.semibold).lineLimit(1)
                windowDetail(
                    title: other.typeTag,
                    window: other.primaryWindow,
                    severity: QuotaSeverity(remainingPercent: other.remainingPercent)
                )
                if let secondary = other.secondaryWindow {
                    windowDetail(
                        title: secondary.typeTag,
                        window: secondary,
                        severity: QuotaSeverity(remainingPercent: secondary.remainingPercent)
                    )
                }
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
            showsCriticalGlow: lowestSeverity.showsScaryGlow
                || otherLimits.contains { QuotaSeverity(remainingPercent: min($0.remainingPercent, $0.secondaryWindow?.remainingPercent ?? 100)).showsScaryGlow },
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
        locale: Locale = AppLanguage.current.locale,
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

/// When a limit resets, said the way a person would: a time today, then
/// tomorrow, a weekday this week, or a date. Close to the reset it counts
/// down instead.
enum ResetMomentText {
    /// "3:40 PM", "tomorrow 9:00 AM", "Tue 9:00 AM", "Dec 3", "in 41 min".
    /// Read after "Resets" or "resets".
    static func moment(
        _ resetAt: Date?,
        now: Date = Date(),
        locale: Locale = AppLanguage.current.locale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let resetAt else { return nil }
        let seconds = resetAt.timeIntervalSince(now)
        if seconds <= 0 { return AppLanguage.text("now", locale: locale) }
        if seconds < 3_600 { return AppLanguage.format("in %ld min", locale: locale, max(1, Int(ceil(seconds / 60)))) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: resetAt)
        }
        let time: String = {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: resetAt)
        }()
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: resetAt)).day ?? 0
        switch days {
        case 0: return time
        case 1: return AppLanguage.format("tomorrow %@", locale: locale, time)
        case 2...6: return "\(format("EEE")) \(time)"
        default:
            return calendar.isDate(resetAt, equalTo: now, toGranularity: .year) ? format("MMMd") : format("yMMMd")
        }
    }

    /// "Resets 3:40 PM", or that the reset time is unknown.
    static func sentence(_ resetAt: Date?, now: Date = Date(), locale: Locale = AppLanguage.current.locale) -> String {
        guard let moment = moment(resetAt, now: now, locale: locale) else { return AppLanguage.text("No reset time", locale: locale) }
        return moment == AppLanguage.text("now", locale: locale) ? AppLanguage.text("Resetting now", locale: locale)
            : AppLanguage.format("Resets %@", locale: locale, moment)
    }

    /// How long until the reset, to the minute: "2h 41m", "3d 4h".
    static func countdown(_ resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt, resetAt > now else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: now, to: resetAt)
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
