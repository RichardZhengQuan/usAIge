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

/// The memory gauge uses the same RAM and swap budget as the Memory page.
@available(macOS 14.0, *)
struct LiveWorkTile: View {
    @ObservedObject var monitor: LiveWorkMonitor
    let open: () -> Void
    /// Reports hover changes with the tile's frame in the rail's coordinates.
    let onHoverChanged: (Bool, CGRect) -> Void
    @AppStorage(PaperweightShipPreferences.memoryKey) private var shipName = PaperweightShipKind.sailboat.rawValue
    @AppStorage(InterfaceStyle.defaultsKey) private var style = InterfaceStyle.standard
    @Environment(\.hudPreviewsHover) private var previewsHover
    @State private var isHovered = false

    var body: some View {
        let memory = monitor.memoryUsage
        let share = memory?.usedShare
        let value = share.map(LiveWorkText.percent) ?? "–"
        let detail = memory?.compactTotal ?? "Memory"
        Button(action: open) {
            if style == .modern {
                ModernRailGauge(
                    share: share ?? 0, color: ModernPalette.memory,
                    value: value, detail: detail,
                    isHovered: isHovered || previewsHover
                ) { Image(systemName: "memorychip") }
            } else {
                RailResourcePaperweight(
                    configuration: PaperweightData.memory(summary: monitor.summary, running: [], systemUsage: memory),
                    ship: PaperweightShipKind(rawValue: shipName) ?? .sailboat,
                    value: value,
                    symbol: "memorychip",
                    detail: detail,
                    isMoving: isHovered || previewsHover
                )
            }
        }
        .buttonStyle(.plain)
        .help(memory?.breakdown() ?? AppLanguage.text("Memory unavailable"))
        .modifier(RailDetailHover(isHovered: $isHovered, changed: onHoverChanged))
        .accessibilityLabel("Memory")
        .accessibilityValue(memory?.breakdown() ?? AppLanguage.text("Unavailable"))
        .accessibilityHint("Opens Memory")
    }
}

@available(macOS 14.0, *)
struct CPUTile: View {
    @ObservedObject var monitor: SystemCPUMonitor
    let open: () -> Void
    var onHoverChanged: (Bool, CGRect) -> Void = { _, _ in }
    @AppStorage(InterfaceStyle.defaultsKey) private var style = InterfaceStyle.standard
    @Environment(\.hudTextSize) private var textSize
    @State private var hovered = false

    var body: some View {
        let value = monitor.usage.map { LiveWorkText.percent($0.busy) } ?? "–"
        let status = monitor.usage?.trendStatus ?? .unknown
        Button(action: open) {
            if style == .modern {
                ModernRailGauge(share: monitor.usage?.busy ?? 0, color: status.color,
                                value: value, detail: "CPU", isHovered: hovered) {
                    CPUTrendPlot(samples: monitor.samples, compact: true).frame(width: 39, height: 26)
                }
            } else {
                VStack(spacing: HUDMetrics.resourceReadoutGap) {
                    ModernRingGauge(share: monitor.usage?.busy ?? 0, color: status.color, lineWidth: 3)
                        .frame(width: HUDMetrics.resourcePaperweightHeight, height: HUDMetrics.resourcePaperweightHeight)
                        .overlay { CPUTrendPlot(samples: monitor.samples, compact: true).frame(width: 22, height: 15) }
                    Text("CPU \(value)")
                        .font(.system(size: 11 * textSize.factor, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .hudRailLabel()
                        .frame(minHeight: HUDMetrics.resourceReadoutHeight * textSize.factor)
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(RailDetailHover(isHovered: $hovered, changed: onHoverChanged))
        .accessibilityLabel(Text("CPU usage", bundle: AppLanguage.resourceBundle))
        .accessibilityValue(monitor.usage == nil ? status.localizedTitle : Text("\(value) · \(status.localizedTitle)",
                                                                              bundle: AppLanguage.resourceBundle))
        .accessibilityHint(Text("Opens CPU", bundle: AppLanguage.resourceBundle))
    }
}

/// Disk capacity sits below memory. Hovering shows its card beside the rail.
@available(macOS 14.0, *)
struct StorageTile: View {
    @ObservedObject var monitor: LiveWorkMonitor
    let open: () -> Void
    /// Reports hover changes with the tile's frame in the rail's coordinates.
    var onHoverChanged: (Bool, CGRect) -> Void = { _, _ in }
    @AppStorage(PaperweightShipPreferences.storageKey) private var shipName = PaperweightShipKind.galleon.rawValue
    @AppStorage(InterfaceStyle.defaultsKey) private var style = InterfaceStyle.standard
    @Environment(\.hudPreviewsHover) private var previewsHover
    @State private var isHovered = false

    private var disk: DiskSpace? { monitor.diskSpace }

    private var detail: String {
        guard let disk else { return "Disk space unavailable" }
        return "\(LiveWorkText.percent(disk.usedShare())) full, \(BoardText.bytes(disk.availableBytes)) free"
    }

    var body: some View {
        Button(action: open) {
            if style == .modern {
                let used = disk?.usedShare() ?? 0
                ModernRailGauge(
                    share: used, color: ModernPalette.storageColor(usedShare: used),
                    value: disk.map { LiveWorkText.percent($0.usedShare()) } ?? "–",
                    detail: disk.map { RailResourceText.freeSpace($0.availableBytes) + " free" } ?? "–",
                    isHovered: isHovered || previewsHover
                ) { Image(systemName: "internaldrive") }
            } else {
                RailResourcePaperweight(
                    configuration: RailPaperweightData.storage(disk),
                    ship: PaperweightShipKind(rawValue: shipName) ?? .galleon,
                    value: disk.map { LiveWorkText.percent($0.usedShare()) } ?? "–",
                    symbol: "internaldrive",
                    detail: disk.map { RailResourceText.freeSpace($0.availableBytes) } ?? "–",
                    isMoving: isHovered || previewsHover
                )
            }
        }
        .buttonStyle(.plain)
        .modifier(RailDetailHover(isHovered: $isHovered, changed: onHoverChanged))
        .accessibilityLabel("Storage")
        .accessibilityValue(detail)
        .accessibilityHint("Opens Storage in branches and worktrees")
    }
}

/// The Modern rail's resource tile: a ring gauge with its symbol, and the
/// figure under it. Nothing moves, so the rail costs nothing while idle.
@available(macOS 14.0, *)
private struct ModernRailGauge<Face: View>: View {
    @Environment(\.hudTextSize) private var textSize
    let share: Double
    let color: Color
    let value: String
    let detail: String
    let isHovered: Bool
    @ViewBuilder let face: () -> Face

    var body: some View {
        // The same ring as a tool's, with its figure under it in place of
        // the reset tags, so the rail reads as one set of rings.
        VStack(spacing: 1) {
            // 63 points less the stroke's half on each side puts the ring's
            // centre line at 58, exactly where a tool's outer ring sits.
            ModernRingGauge(share: share, color: color, lineWidth: 5)
                .frame(width: 63, height: 63)
                .overlay {
                    face()
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                .scaleEffect(isHovered ? 1.04 : 1)
                .animation(.snappy(duration: 0.18), value: isHovered)
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 14 * textSize.factor, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 11 * textSize.factor, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .hudRailLabel()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

@available(macOS 14.0, *)
private struct RailResourcePaperweight: View {
    @Environment(\.hudTextSize) private var textSize
    let configuration: PaperweightConfiguration
    let ship: PaperweightShipKind
    let value: String
    let symbol: String
    let detail: String
    let isMoving: Bool

    var body: some View {
        VStack(spacing: HUDMetrics.resourceReadoutGap) {
            RailPaperweightView(configuration: configuration, ship: ship, hovered: isMoving)
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 12 * textSize.factor, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Label(detail, systemImage: symbol)
                    .font(.system(size: 10.5 * textSize.factor, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .hudRailLabel()
            .frame(height: HUDMetrics.resourceReadoutHeight * textSize.factor)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

enum RailResourceText {
    /// Whole units keep a readable space between the number and unit.
    static func freeSpace(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = Double(max(0, bytes))
        var unit = 0
        while amount >= 999.5, unit < units.count - 1 {
            amount /= 1_000
            unit += 1
        }
        return "\(Int64(amount.rounded())) \(units[unit])"
    }
}

/// One branch or worktree in a card: which, where, what it costs, and what its
/// most urgent session is doing. `showsTool` names the tool in a list that
/// mixes several.
@available(macOS 14.0, *)
struct LivePlaceRow: View {
    @Environment(\.usageCardColumns) private var columns
    let place: LiveWorkPlace
    var showsTool = false

    private var heading: String? {
        LiveWorkText.branchLine(place.lead)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: columns?.spacing ?? 5) {
                Image(systemName: heading == nil ? "folder" : "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: columns?.markerWidth)
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
                    .padding(.leading, columns?.contentInset ?? 0)
            }
            HStack(spacing: columns?.spacing ?? 5) {
                Circle()
                    .fill(place.lead.phase.statusColor ?? Color.secondary)
                    .frame(width: 7, height: 7)
                    .frame(width: columns?.markerWidth)
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
    var memory: SystemMemoryUsage? = nil
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memory").font(.headline)
                Spacer()
                Text(memory?.compactTotal ?? "Unavailable").monospacedDigit()
            }
            if let memory {
                Text(memory.breakdown())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
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
            Text("These figures count AI apps and processes running in their folders.")
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

/// The card beside the rail's Storage paperweight: how full the disk is now,
/// and what the Branches window last found using it.
@available(macOS 14.0, *)
struct StorageCard: View {
    let disk: DiskSpace?
    let breakdown: StorageBreakdown?
    var now = Date()
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openBranches: (() -> Void)? = nil

    private struct Row: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    private var rows: [Row] {
        guard let disk else { return [] }
        let free = Row(id: "free", title: "Free", bytes: max(0, disk.availableBytes), color: Color(railHex: 0xB4B2A9))
        guard let breakdown else {
            return [Row(id: "used", title: "Used", bytes: disk.usedBytes, color: Color(railHex: RailPaperweightData.storageColor(disk.usedShare()))), free]
        }
        let known = breakdown.worktreeBytes + breakdown.cacheBytes + breakdown.toolBytes
        return [
            Row(id: "wt", title: "Worktrees", bytes: breakdown.worktreeBytes, color: Color(railHex: 0xE2729A)),
            Row(id: "cache", title: "Build cache", bytes: breakdown.cacheBytes, color: Color(railHex: 0x3DB58C)),
            Row(id: "tool", title: "Tool storage", bytes: breakdown.toolBytes, color: Color(railHex: 0xF4B14A)),
            Row(id: "other", title: "macOS and apps", bytes: max(0, disk.usedBytes - known), color: Color(railHex: 0x5E9FE3)),
            free,
        ]
    }

    private var measuredText: String {
        guard let breakdown else { return "Open Branches to see what's using the space." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Measured \(formatter.localizedString(for: breakdown.measuredAt, relativeTo: now)) in Branches."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.headline)
                Spacer(minLength: 8)
                Text(disk.map { "\(LiveWorkText.percent($0.usedShare())) used" } ?? "Not read")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let disk {
                // One bar, split the way the paperweight stacks its layers.
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(rows) { row in
                            row.color.opacity(row.id == "free" ? 0.35 : 0.85)
                                .frame(width: max(row.bytes > 0 ? 2 : 0,
                                                  geometry.size.width * Double(row.bytes) / Double(max(1, disk.totalBytes))))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Circle().fill(row.color).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(row.title)
                            Spacer(minLength: 8)
                            Text(BoardText.bytes(row.bytes)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Divider()
            if let breakdown, breakdown.freeableBytes > 0 {
                Text("You can free about \(BoardText.bytes(breakdown.freeableBytes)).")
            }
            Text(measuredText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let openBranches {
                Button("Open Storage in Branches…", action: openBranches)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .railDetailCardChrome(width: 300, arrowEdge: arrowEdge, arrowOffset: arrowOffset)
    }
}

/// Every card the rail's detail panel can show.
@available(macOS 14.0, *)
struct RailDetailCard: View {
    enum Content {
        case cpu(SystemCPUMonitor)
        case quota(QuotaSnapshot, others: [QuotaSnapshot], work: [LiveSessionWork], memoryBytes: UInt64)
        case liveWork(LiveWorkSummary, memory: SystemMemoryUsage? = nil)
        case storage(DiskSpace?, StorageBreakdown?)
    }

    let content: Content
    var arrowEdge: HorizontalEdge = .leading
    var arrowOffset: CGFloat = 0
    var openDetails: (() -> Void)? = nil

    var body: some View {
        switch content {
        case let .cpu(monitor):
            CPUHoverCard(monitor: monitor, open: openDetails)
                .railDetailCardChrome(width: 330, arrowEdge: arrowEdge, arrowOffset: arrowOffset)
        case let .quota(snapshot, others, work, memoryBytes):
            QuotaDetailCard(
                snapshot: snapshot,
                otherLimits: others,
                work: work,
                memoryBytes: memoryBytes,
                arrowEdge: arrowEdge,
                arrowOffset: arrowOffset,
                openBranches: openDetails
            )
        case let .liveWork(summary, memory):
            LiveWorkCard(summary: summary, memory: memory, arrowEdge: arrowEdge, arrowOffset: arrowOffset, openBranches: openDetails)
        case let .storage(disk, breakdown):
            StorageCard(disk: disk, breakdown: breakdown, arrowEdge: arrowEdge, arrowOffset: arrowOffset, openBranches: openDetails)
        }
    }
}
