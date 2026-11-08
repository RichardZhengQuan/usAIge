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

/// The rail's always-visible summary of what the AI tools are doing: where
/// they're working, and how much of this Mac's memory they use. Hovering
/// shows the detail beside the rail, and clicking opens the list.
@available(macOS 14.0, *)
struct LiveWorkTile: View {
    @ObservedObject var monitor: LiveWorkMonitor
    let open: () -> Void
    /// Reports hover changes with the tile's frame in the rail's coordinates.
    let onHoverChanged: (Bool, CGRect) -> Void
    var physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    @AppStorage(PaperweightShipPreferences.memoryKey) private var shipName = PaperweightShipKind.sailboat.rawValue
    @Environment(\.hudPreviewsHover) private var previewsHover
    @State private var isHovered = false
    @State private var frame = CGRect.zero

    private var summary: LiveWorkSummary { monitor.summary }

    private var share: Double {
        LiveWorkText.memoryShare(summary.memoryBytes, of: physicalMemory)
    }

    var body: some View {
        Button(action: open) {
            RailResourcePaperweight(
                configuration: RailPaperweightData.memory(summary, physicalMemory: physicalMemory),
                ship: PaperweightShipKind(rawValue: shipName) ?? .sailboat,
                value: LiveWorkText.percent(share),
                symbol: "memorychip",
                detail: summary.sessions.isEmpty ? "Idle" : "\(summary.placeCount)",
                isMoving: isHovered || previewsHover
            )
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
        .accessibilityHint("Opens Memory in branches and worktrees")
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
    @Environment(\.hudPreviewsHover) private var previewsHover
    @State private var isHovered = false
    @State private var frame = CGRect.zero

    private var disk: DiskSpace? { monitor.diskSpace }

    private var detail: String {
        guard let disk else { return "Disk space unavailable" }
        return "\(LiveWorkText.percent(disk.usedShare())) full, \(BoardText.bytes(disk.availableBytes)) free"
    }

    var body: some View {
        Button(action: open) {
            RailResourcePaperweight(
                configuration: RailPaperweightData.storage(disk),
                ship: PaperweightShipKind(rawValue: shipName) ?? .galleon,
                value: disk.map { LiveWorkText.percent($0.usedShare()) } ?? "–",
                symbol: "internaldrive",
                detail: disk.map { RailResourceText.freeSpace($0.availableBytes) } ?? "–",
                isMoving: isHovered || previewsHover
            )
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { value in
            frame = value
            if isHovered { onHoverChanged(true, value) }
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering, frame)
        }
        .onDisappear { onHoverChanged(false, frame) }
        .accessibilityLabel("Storage")
        .accessibilityValue(detail)
        .accessibilityHint("Opens Storage in branches and worktrees")
    }
}

@available(macOS 14.0, *)
private struct RailResourcePaperweight: View {
    let configuration: PaperweightConfiguration
    let ship: PaperweightShipKind
    let value: String
    let symbol: String
    let detail: String
    let isMoving: Bool

    var body: some View {
        let percentWidth: CGFloat = value.count >= 4 ? 34 : 28
        VStack(spacing: HUDMetrics.resourceReadoutGap) {
            RailPaperweightView(configuration: configuration, ship: ship, hovered: isMoving)
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                    .frame(width: percentWidth, alignment: .leading)
                HStack(spacing: 2) {
                    // Keep numbers readable before spending space on an icon.
                    if (symbol == "memorychip" && (detail.count <= 2 || (detail == "Idle" && value.count < 4)))
                        || (symbol == "internaldrive" && detail == "–") {
                        Image(systemName: symbol).font(.system(size: 8, weight: .medium))
                    }
                    Text(detail)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
                        .layoutPriority(1)
                }
                .font(value.count >= 4
                      ? .system(size: 10.5, weight: .medium, design: .rounded).width(.condensed)
                      : .system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 62 - percentWidth, alignment: .trailing)
            }
            .frame(width: 64, height: HUDMetrics.resourceReadoutHeight)
        }
        .frame(width: 64, height: HUDMetrics.resourceTileHeight)
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
        case quota(QuotaSnapshot, work: [LiveSessionWork], memoryBytes: UInt64)
        case liveWork(LiveWorkSummary)
        case storage(DiskSpace?, StorageBreakdown?)
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
        case let .storage(disk, breakdown):
            StorageCard(disk: disk, breakdown: breakdown, arrowEdge: arrowEdge, arrowOffset: arrowOffset, openBranches: openBranches)
        }
    }
}
