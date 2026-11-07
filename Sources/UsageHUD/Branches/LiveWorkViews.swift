import SwiftUI

/// Water standing at `level`, from 0 (empty) to 1 (full), with a rippled
/// surface. An empty or full tank has no surface to ripple.
struct WaterShape: Shape {
    var level: Double
    /// Where along its wave the surface is, in radians.
    var phase: Double = 0
    var amplitude: CGFloat = 1.5
    var wavelength: CGFloat = 46

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let filled = min(max(level, 0), 1)
        guard filled > 0, rect.width > 0 else { return path }
        let surface = rect.maxY - rect.height * filled
        let ripple = filled < 1 ? amplitude : 0
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x = rect.minX
        while x < rect.maxX {
            path.addLine(to: CGPoint(x: x, y: surface + ripple * sin(phase + 2 * .pi * (x - rect.minX) / wavelength)))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: surface + ripple * sin(phase + 2 * .pi * rect.width / wavelength)))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A tank filled to `level`, in the rail's quota colours. It's still unless
/// `isMoving`, because every frame re-renders it on the main thread, and an
/// always-visible rail has to stay cheap while nobody is looking at it.
@available(macOS 14.0, *)
struct WaterLevelView: View {
    let level: Double
    let color: Color
    let isMoving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moves = isMoving && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / RailMotion.updatesPerSecond, paused: !moves)) { context in
            let phase = moves ? context.date.timeIntervalSinceReferenceDate * 1.6 : 0.6
            ZStack {
                WaterShape(level: level, phase: phase + 1.9)
                    .fill(color.opacity(0.22))
                WaterShape(level: level, phase: phase)
                    .fill(color.opacity(0.38))
            }
            .animation(.easeInOut(duration: 0.9), value: level)
        }
        .accessibilityHidden(true)
    }
}

/// The rail's always-visible summary of what the AI tools are doing: where
/// they're working, and how much of this Mac's memory they use, as water in a
/// tank. Hovering shows the detail beside the rail, and clicking opens the list.
@available(macOS 14.0, *)
struct LiveWorkTile: View {
    @ObservedObject var monitor: LiveWorkMonitor
    let open: () -> Void
    /// Reports hover changes with the tile's frame in the rail's coordinates.
    let onHoverChanged: (Bool, CGRect) -> Void
    var physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false
    @State private var frame = CGRect.zero

    private var summary: LiveWorkSummary { monitor.summary }

    private var share: Double {
        LiveWorkText.memoryShare(summary.memoryBytes, of: physicalMemory)
    }

    private var tankShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    private var tagFill: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(.ultraThinMaterial)
    }

    var body: some View {
        Button(action: open) {
            VStack(spacing: HUDMetrics.workTagGap) {
                VStack(spacing: -1) {
                    Text(LiveWorkText.percent(share))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Memory")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.7))
                }
                .frame(width: 64, height: HUDMetrics.waterTankHeight)
                .background {
                    ZStack {
                        tankShape.fill(tagFill)
                        WaterLevelView(
                            level: LiveWorkText.waterLevel(share),
                            color: LiveWorkText.severity(share).color,
                            isMoving: isHovered
                        )
                        .clipShape(tankShape)
                        tankShape.stroke(.secondary.opacity(0.18), lineWidth: 1)
                    }
                }

                // A ring's tag sits under it the same way.
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .bold))
                    Text(summary.sessions.isEmpty ? "Idle" : "\(summary.placeCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: HUDMetrics.workTagHeight)
                .background(tagFill, in: Capsule())
            }
            .frame(width: 64, height: HUDMetrics.workTileHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LiveWorkText.tileHelp(summary, of: physicalMemory))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { value in
            frame = value
            if isHovered { onHoverChanged(true, value) }
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering, frame)
        }
        .onDisappear { onHoverChanged(false, frame) }
        .accessibilityLabel(LiveWorkText.headline(summary))
        .accessibilityValue(LiveWorkText.memorySentence(summary.memoryBytes, of: physicalMemory))
        .accessibilityHint("Opens branches and worktrees")
    }
}

/// One branch or worktree in a card: which, where, what it costs, and what its
/// most urgent session is doing. `showsTool` names the tool in a list that
/// mixes several.
@available(macOS 14.0, *)
struct LivePlaceRow: View {
    let place: LiveWorkPlace
    var showsTool = false

    private var heading: String? {
        LiveWorkText.branchLine(place.lead)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: heading == nil ? "folder" : "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(heading ?? place.lead.title)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if place.memoryBytes > 0 {
                    Text(LiveWorkText.memory(place.memoryBytes))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            let detail = LiveWorkText.detailLine(place)
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(place.lead.phase.statusColor ?? Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(sessionText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if place.sessions.count > 1 {
                    Spacer(minLength: 4)
                    Text("+\(place.sessions.count - 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("and \(place.sessions.count - 1) more sessions")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sessionText: String {
        let session = place.lead
        var parts: [String] = []
        if showsTool { parts.append(AIToolDescriptor.descriptor(for: session.toolID).name) }
        parts.append(session.phase.label)
        // With no branch to show, the title is already the row's heading.
        if heading != nil { parts.append(session.title) }
        return parts.joined(separator: " · ")
    }
}

/// The list in a card. Past `visibleRows` it scrolls, so a busy Mac can't
/// outgrow the screen, and a sliver of the next row shows there's more.
@available(macOS 14.0, *)
struct LiveSessionList: View {
    private static let rowHeight: CGFloat = 52

    let sessions: [LiveSessionWork]
    var visibleRows = 4
    var showsTool = false

    var body: some View {
        let places = LiveWorkPlace.places(from: sessions)
        let rows = VStack(alignment: .leading, spacing: 9) {
            ForEach(places) { place in
                LivePlaceRow(place: place, showsTool: showsTool)
            }
        }
        if places.count > visibleRows {
            ScrollView {
                rows.padding(.trailing, 10)
            }
            .frame(height: CGFloat(visibleRows) * Self.rowHeight + 20)
        } else {
            rows
        }
    }
}

/// The card beside the rail's tile: every AI tool's current work.
@available(macOS 14.0, *)
struct LiveWorkCard: View {
    let summary: LiveWorkSummary
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(LiveWorkText.headline(summary)).font(.headline)
                Spacer(minLength: 8)
                if summary.memoryBytes > 0 {
                    Text(LiveWorkText.memory(summary.memoryBytes))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if !summary.sessions.isEmpty {
                LiveSessionList(sessions: summary.sessions, visibleRows: 6, showsTool: true)
            }
            Divider()
            Text("\(LiveWorkText.memorySentence(summary.memoryBytes)). This counts AI apps and everything running in these folders.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let openBranches {
                Button("All branches and worktrees…", action: openBranches)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .railDetailCardChrome(width: 320, arrowEdge: arrowEdge, arrowOffset: arrowOffset)
    }
}

/// Either card the rail's detail panel can show.
@available(macOS 14.0, *)
struct RailDetailCard: View {
    enum Content {
        case quota(QuotaSnapshot, work: [LiveSessionWork], memoryBytes: UInt64)
        case liveWork(LiveWorkSummary)
    }

    let content: Content
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil

    var body: some View {
        switch content {
        case let .quota(snapshot, work, memoryBytes):
            QuotaDetailCard(
                snapshot: snapshot,
                work: work,
                memoryBytes: memoryBytes,
                arrowEdge: arrowEdge,
                arrowOffset: arrowOffset,
                openBranches: openBranches
            )
        case let .liveWork(summary):
            LiveWorkCard(summary: summary, arrowEdge: arrowEdge, arrowOffset: arrowOffset, openBranches: openBranches)
        }
    }
}
