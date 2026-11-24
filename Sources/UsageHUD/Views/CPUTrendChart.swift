import SwiftUI

struct CPUTrendChart: View {
    let samples: SystemCPUMonitor.History
    var plotHeight: CGFloat = 48
    @Environment(\.locale) private var locale

    var body: some View {
        let domain = samples.domain
        let points = samples.map(TrendPoint.init(cpu:))
        let readings = points.compactMap(\.value)
        return HStack(alignment: .top, spacing: 6) {
            TrendHistoryPlot(points: points, domain: domain, valueRange: 0...1, plotHeight: plotHeight) {
                if readings.isEmpty {
                    Text("Waiting for a CPU sample…", bundle: AppLanguage.resourceBundle).font(.caption)
                }
            }
            VStack(alignment: .trailing) {
                Text("100%")
                Spacer(minLength: 0)
                Text("0%")
            }
            .frame(height: plotHeight)
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption2.monospacedDigit())
        .foregroundColor(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("CPU usage, last 10 minutes",
                                 bundle: AppLanguage.resourceBundle))
        .accessibilityValue(accessibleRange(readings, domain: domain, status: points.last?.status ?? .unknown))
    }

    private func accessibleRange(_ readings: [Double], domain: ClosedRange<Date>, status: TrendStatus) -> Text {
        guard let min = readings.min(), let max = readings.max() else {
            return Text("Waiting for a CPU sample…", bundle: AppLanguage.resourceBundle)
        }
        let formatter = TrendTimeAxis.formatter(for: domain, locale: locale)
        let timeAndUsage = Text("\(formatter.string(from: domain.lowerBound)) to \(formatter.string(from: domain.upperBound)), \(LiveWorkText.percent(min)) to \(LiveWorkText.percent(max))",
                                bundle: AppLanguage.resourceBundle)
        return Text("\(timeAndUsage) · \(status.localizedTitle)", bundle: AppLanguage.resourceBundle)
    }
}

/// The floating CPU gauge uses the same measurements and time scale as the dashboard.
struct CPUTrendPlot: View {
    private let points: [TrendPoint]
    private let domain: ClosedRange<Date>
    let compact: Bool

    init(samples: SystemCPUMonitor.History, compact: Bool) {
        domain = samples.domain
        points = samples.map(TrendPoint.init(cpu:))
        self.compact = compact
    }

    var body: some View {
        TrendLinePlot(points: points, domain: domain, valueRange: 0...1, compact: compact)
    }
}

/// The measured timeline and its clock ticks share the same horizontal scale.
/// The radar still covers the space to the right of the latest timestamp.
struct TrendHistoryPlot<Overlay: View>: View {
    let points: [TrendPoint]
    let domain: ClosedRange<Date>
    let valueRange: ClosedRange<Double>
    let plotHeight: CGFloat
    @ViewBuilder let overlay: Overlay

    var body: some View {
        VStack(spacing: 3) {
            TrendLinePlot(points: points, domain: domain, valueRange: valueRange)
                .overlay(overlay)
                .frame(height: plotHeight)
            TrendTimeAxis(domain: domain)
        }
    }
}

struct TrendTimeScale {
    let domain: ClosedRange<Date>
    let startX: CGFloat
    let nowX: CGFloat
    private let pointsPerSecond: CGFloat

    init(domain: ClosedRange<Date>, width: CGFloat, inset: CGFloat = 3) {
        self.domain = domain
        let width = max(0, width)
        startX = min(inset, width / 2)
        nowX = startX + (width - 2 * startX) * 0.60
        let duration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        pointsPerSecond = duration > 0 ? (nowX - startX) / CGFloat(duration) : 0
    }

    func x(at date: Date) -> CGFloat {
        nowX - CGFloat(domain.upperBound.timeIntervalSince(date)) * pointsPerSecond
    }
}

struct TrendTimeAxis: View {
    let domain: ClosedRange<Date>
    @Environment(\.locale) private var locale

    var body: some View {
        let formatter = Self.formatter(for: domain, locale: locale)
        let midpoint = domain.lowerBound.addingTimeInterval(domain.upperBound.timeIntervalSince(domain.lowerBound) / 2)
        let startText = formatter.string(from: domain.lowerBound)
        let nowText = formatter.string(from: domain.upperBound)
        let tickSpace: CGFloat = 5
        return Text(verbatim: startText).hidden()
            .padding(.top, tickSpace)
            .frame(maxWidth: .infinity)
            .overlay(GeometryReader { geometry in
                let width = geometry.size.width
                let scale = TrendTimeScale(domain: domain, width: width)
                let middleX = scale.x(at: midpoint)
                let historyWidth = scale.nowX - scale.startX
                let showsStart = historyWidth >= 90
                let showsMiddle = historyWidth >= 190
                let labelY = (geometry.size.height + tickSpace) / 2
                let labelSpace = showsMiddle ? scale.nowX - middleX : historyWidth
                let nowRoom = max(0, min(2 * (width - scale.nowX), showsStart ? labelSpace - 12 : width))
                ZStack(alignment: .topLeading) {
                    Path { path in
                        let ticks = [scale.nowX] + (showsStart ? [scale.startX] : []) + (showsMiddle ? [middleX] : [])
                        for x in ticks {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: 3))
                        }
                    }
                    .stroke(lineWidth: 1)
                    if showsStart {
                        Text(verbatim: startText)
                            .frame(width: (showsMiddle ? middleX : scale.nowX) - scale.startX, alignment: .leading)
                            .offset(x: scale.startX, y: tickSpace)
                    }
                    if showsMiddle {
                        Text(verbatim: formatter.string(from: midpoint)).fixedSize()
                            .position(x: middleX, y: labelY)
                    }
                    nowLabel(time: nowText, available: nowRoom)
                        .frame(width: nowRoom)
                        .position(x: scale.nowX, y: labelY)
                }
            })
            .lineLimit(1)
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
    }

    @ViewBuilder private func nowLabel(time: String, available: CGFloat) -> some View {
        let full = Text("Latest · \(time)", bundle: AppLanguage.resourceBundle)
        let short = Text("Latest", bundle: AppLanguage.resourceBundle)
        if #available(macOS 13.0, *) {
            ViewThatFits(in: .horizontal) {
                full.fixedSize()
                short
            }
        } else if available >= 100 {
            full
        } else {
            short
        }
    }

    static func formatter(for domain: ClosedRange<Date>, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = domain.upperBound.timeIntervalSince(domain.lowerBound) < 120 ? .medium : .short
        return formatter
    }
}

struct TrendPoint: Equatable, Sendable {
    let date: Date
    let value: Double?
    var status: TrendStatus? = nil
}

extension TrendPoint {
    static func currentStatus(in points: [Self], domain: ClosedRange<Date>) -> TrendStatus {
        guard let latest = points.last(where: { domain.contains($0.date) }),
              latest.value?.isFinite == true else { return .unknown }
        return latest.status ?? .unknown
    }

    init(cpu sample: SystemCPUMonitor.Sample) {
        self.init(date: sample.date, value: sample.usage?.busy, status: sample.usage?.trendStatus)
    }
}

enum TrendStatus: Hashable, CaseIterable, Sendable {
    case normal, warning, critical, unknown

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .normal: Color(NSColor.systemGreen)
        case .warning: Color(NSColor.systemOrange)
        case .critical: Color(NSColor.systemRed)
        case .unknown: Color(NSColor.systemGray)
        }
    }

    var localizedTitle: Text { Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle) }
}

struct TrendSegment: Equatable {
    let status: TrendStatus
    let points: ArraySlice<TrendPoint>
    let marksEndpoint: Bool

    /// A sample describes the interval ending at its timestamp. Share the
    /// boundary vertex when its status changes and leave missing intervals open.
    static func make(from points: [TrendPoint], in domain: ClosedRange<Date>) -> [Self] {
        var segments: [Self] = []
        var start: Int?
        var status = TrendStatus.unknown
        func finish(at end: Int, marksEndpoint: Bool) {
            guard let first = start else { return }
            segments.append(Self(status: status, points: points[first..<end], marksEndpoint: marksEndpoint))
            start = nil
        }
        for index in points.indices {
            let point = points[index]
            guard domain.contains(point.date), point.value?.isFinite == true else {
                finish(at: index, marksEndpoint: true)
                continue
            }
            let next = point.status ?? .unknown
            if start == nil {
                start = index
            } else if next != status {
                finish(at: index, marksEndpoint: false)
                start = index - 1
            }
            status = next
        }
        finish(at: points.endIndex, marksEndpoint: true)
        return segments
    }
}

/// Draws chronological measurements in the supplied units; a missing measurement breaks the trace.
struct TrendLinePlot: View {
    let points: [TrendPoint]
    let domain: ClosedRange<Date>
    let valueRange: ClosedRange<Double>
    var compact = false

    private struct Paths {
        var line = Path()
        var fill = Path()
        var endpoints = Path()
    }

    var body: some View {
        GeometryReader { geometry in
            let paths = self.paths(in: geometry.size)
            ZStack(alignment: .topLeading) {
                TrendPlotGrid(compact: compact, status: TrendPoint.currentStatus(in: points, domain: domain),
                              areas: paths.mapValues(\.fill))
                ForEach(TrendStatus.allCases, id: \.self) { status in
                    if let path = paths[status] {
                        let color = status.color
                        path.line.stroke(color, style: StrokeStyle(lineWidth: compact ? 1.5 : 2, lineCap: .round, lineJoin: .round))
                        path.endpoints.fill(color)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Batch disjoint paths of each color so even rapidly oscillating
    /// readings creates at most four drawing layers for the sampled data.
    private func paths(in size: CGSize) -> [TrendStatus: Paths] {
        let inset: CGFloat = compact ? 1.5 : 3
        let timeScale = TrendTimeScale(domain: domain, width: size.width, inset: inset)
        let height = max(0, size.height - 2 * inset)
        let span = valueRange.upperBound - valueRange.lowerBound
        let dot: CGFloat = compact ? 3 : 5
        var result: [TrendStatus: Paths] = [:]
        for segment in TrendSegment.make(from: points, in: domain) {
            let coordinates = segment.points.compactMap { point -> CGPoint? in
                guard let value = point.value else { return nil }
                let level = span > 0 ? min(1, max(0, (value - valueRange.lowerBound) / span)) : 0.5
                return CGPoint(x: timeScale.x(at: point.date), y: inset + CGFloat(1 - level) * height)
            }
            guard let first = coordinates.first, let last = coordinates.last else { continue }
            let line = Path { $0.addLines(coordinates) }
            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: inset + height))
            fill.addLine(to: CGPoint(x: first.x, y: inset + height))
            fill.closeSubpath()
            result[segment.status, default: Paths()].line.addPath(line)
            result[segment.status, default: Paths()].fill.addPath(fill)
            if segment.marksEndpoint || coordinates.count == 1 {
                result[segment.status, default: Paths()].endpoints.addEllipse(
                    in: CGRect(x: last.x - dot / 2, y: last.y - dot / 2, width: dot, height: dot))
            }
        }
        return result
    }
}
